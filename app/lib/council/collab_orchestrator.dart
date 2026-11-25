// 议会/团队的编排内核（C1）：一个可恢复的状态机，不依赖界面存活。
//
// 流程（议会议题）：
//   queued → round1（各席位并发独立作答）→ reviewing（可选：互看匿名
//   答案后修订）→ synthesizing（主席综合出裁决）→ done / cancelled / failed
//
// 三条硬规则：
// 1. 先写盘再执行。所有状态更新走串行队列（[_update]）：读盘上最新快照 →
//    改 → 原子落盘 → 广播。落盘成功后才发下一个请求；进程被杀后
//    [resume] 从盘上的状态继续，已答过的席位不重复提问。
// 2. 手机并发有上限。[CouncilSpec.maxConcurrency] 决定同时在飞的席位数，
//    单席超过 [CouncilSpec.seatTimeout] 记超时，失败重试一次。
// 3. 预算有硬上限。[CouncilSpec.budgetCalls] 是调用次数上限，用尽即
//    failed，绝不多发一次请求。
//
// 这里不碰 Flutter：驱动接口 [CollabSessionDriver] 在生产里由
// [DshCollabDriver]（包 DshClient）实现，测试里由 Fake 实现。

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import '../collab/collab_session_book.dart';
import 'collab_models.dart';
import 'collab_store.dart';

/// 单次 turn 的收尾方式。
enum TurnKind { completed, aborted, failed }

/// 一次 turn 的结果：终稿文本与用量。
final class TurnOutcome {
  const TurnOutcome({
    required this.kind,
    this.text = '',
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.error,
  });

  final TurnKind kind;
  final String text;
  final int tokensIn;
  final int tokensOut;
  final String? error;

  bool get isCompleted => kind == TurnKind.completed;
}

/// 编排器与模型侧之间的最小接口。
///
/// 生产实现：[DshCollabDriver]。测试实现直接给结果，不经过网络。
abstract interface class CollabSessionDriver {
  /// 为席位开一个子会话并设好模型，返回 sessionId。
  Future<String> openSession(SeatSpec seat, {String? workspaceId});

  /// 在会话里发一条消息，等这一轮结束，返回终稿。
  ///
  /// [timeout] 到点后放弃等待（内部负责取消订阅），由调用方决定怎么记。
  Future<TurnOutcome> runTurn(String sessionId, String text, {Duration? timeout});

  /// 尽量停下会话里正在跑的一轮（取消时用）。
  Future<void> cancel(String sessionId);
}

class _Cancelled implements Exception {}

class _BudgetExceeded implements Exception {}

/// 议会/团队的编排器。
final class CollabOrchestrator {
  CollabOrchestrator({
    required CollabSessionDriver driver,
    required CollabStore store,
    String Function()? newId,
    DateTime Function()? clock,
    Duration Function(int attempt, TurnOutcome last)? retryDelay,
    this.onSession,
  }) : _driver = driver,
       _store = store,
       _newId = newId ?? _defaultId,
       _clock = clock ?? DateTime.now,
       _retryDelay = retryDelay ?? _defaultRetryDelay;

  final CollabSessionDriver _driver;
  final CollabStore _store;
  final String Function() _newId;
  final DateTime Function() _clock;

  /// 开出一个席位会话时的回调：协作页据此登记，历史列表不再单列这些会话。
  final void Function(CollabSessionInfo info)? onSession;

  /// 失败重试前的等待：限流给更长的时间，普通错误短等。
  final Duration Function(int attempt, TurnOutcome last) _retryDelay;

  static Duration _defaultRetryDelay(int attempt, TurnOutcome last) {
    final text = (last.error ?? '').toLowerCase();
    final limited =
        text.contains('429') ||
        text.contains('rate') ||
        text.contains('limit') ||
        text.contains('限流') ||
        text.contains('too many');
    if (limited) return attempt <= 1 ? const Duration(seconds: 4) : const Duration(seconds: 8);
    return const Duration(milliseconds: 600);
  }

  final _events = StreamController<CollabRun>.broadcast();
  bool _disposed = false;

  /// 正在驱动中的运行（防止同一 run 被并行驱动两次）。
  final _driving = <String>{};

  /// 正在跑的席位会话（取消时直接停）。
  final _activeSessions = <String>{};

  /// 串行队列：所有状态更新依次执行，避免并发席位互相覆盖。
  Future<void> _queue = Future<void>.value();

  /// 最新快照的内存索引（重启后由 load 补齐）。
  final _latest = <String, CollabRun>{};

  static String _defaultId() => 'c${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  /// 状态流转流：每次落盘成功后发一份新快照，界面只订阅它。
  Stream<CollabRun> get events => _events.stream;

  /// 落盘仓库（界面用它捡回未完成的运行）。
  CollabStore get store => _store;

  /// 提交议题：校验 → 落盘 → 后台驱动。返回初始快照。
  Future<CollabRun> submit(CouncilSpec spec) async {
    _validate(spec);
    final now = _clock();
    final run = CollabRun(
      id: _newId(),
      spec: spec,
      phase: CollabPhase.queued,
      seats: {for (final s in spec.seats) s.id: const SeatState()},
      createdAt: now,
      updatedAt: now,
    );
    await _store.save(run);
    _latest[run.id] = run;
    if (!_disposed && !_events.isClosed) _events.add(run);
    _driveLater(run.id);
    return run;
  }

  /// 从盘上恢复；已到终态则原样返回，不再驱动。
  Future<CollabRun?> resume(String runId) async {
    final run = await _store.load(runId);
    if (run == null) return null;
    _latest[run.id] = run;
    if (run.phase.isTerminal) return run;
    // 上次执行到一半被打断：running 的席位保留 sessionId，回到待执行。
    final fixed = await _update(run.id, (current) {
      var next = current;
      for (final seat in current.spec.seats) {
        final state = current.seatOf(seat.id);
        if (state.status == SeatStatus.running) {
          next = next.withSeat(seat.id, state.copyWith(status: SeatStatus.pending));
        }
      }
      return next;
    });
    _driveLater(fixed.id);
    return fixed;
  }

  /// 请求取消：置标志并尝试停下正在跑的会话；驱动循环在下一步收敛。
  Future<void> cancel(String runId) async {
    final current = _latest[runId] ?? await _store.load(runId);
    if (current == null || current.phase.isTerminal) return;
    await _update(runId, (r) => r.copyWith(cancelRequested: true));
    for (final session in [..._activeSessions]) {
      unawaited(_driver.cancel(session).catchError((_) {}));
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _events.close();
  }

  /// 最近一次快照（内存优先，没有则读盘）。
  Future<CollabRun?> snapshot(String runId) async => _latest[runId] ?? await _store.load(runId);

  // ---------------------------------------------------------------------------
  // 串行状态更新

  /// 在串行队列里更新一次运行状态：读最新 → 改 → 落盘 → 广播。
  Future<CollabRun> _update(String runId, CollabRun Function(CollabRun current) mutate) {
    final task = _queue.then((_) async {
      final current = _latest[runId] ?? await _store.load(runId);
      if (current == null) throw StateError('运行不存在：$runId');
      final next = mutate(current).copyWith(updatedAt: _clock(), rev: current.rev + 1);
      await _store.save(next);
      _latest[runId] = next;
      if (!_disposed && !_events.isClosed) _events.add(next);
      return next;
    });
    _queue = task.then((_) {}, onError: (_) {});
    return task;
  }

  void _driveLater(String runId) {
    if (_driving.contains(runId)) return;
    _driving.add(runId);
    unawaited(
      _drive(runId)
          .catchError((Object e) async {
            try {
              final latest = await _store.load(runId);
              if (latest != null && !latest.phase.isTerminal) {
                await _update(runId, (r) => r.copyWith(phase: CollabPhase.failed, failure: '内部错误：$e'));
              }
            } on Object {
              // 落盘也失败：盘上是上一次完整快照，可再次 resume。
            }
          })
          .whenComplete(() => _driving.remove(runId)),
    );
  }

  Future<void> _drive(String runId) async {
    try {
      while (true) {
        final run = _require(runId);
        if (run.cancelRequested) {
          await _transition(runId, CollabPhase.cancelled);
          return;
        }
        switch (run.phase) {
          case CollabPhase.queued:
          case CollabPhase.round1:
            await _roundOne(runId);
          case CollabPhase.reviewing:
            await _review(runId);
          case CollabPhase.verifying:
            await _verify(runId);
          case CollabPhase.synthesizing:
            await _synthesize(runId);
          case CollabPhase.done:
            await _store.writeVerdict(_require(runId));
            return;
          case CollabPhase.cancelled:
          case CollabPhase.failed:
            return;
        }
        if (_require(runId).phase.isTerminal) return;
      }
    } on _Cancelled {
      await _transition(runId, CollabPhase.cancelled);
    } on _BudgetExceeded {
      await _transition(runId, CollabPhase.failed, failure: '预算用尽：这次运行已达到调用次数上限');
    }
  }

  CollabRun _require(String runId) {
    final run = _latest[runId];
    if (run == null) throw StateError('运行不在内存里：$runId');
    return run;
  }

  // ---------------------------------------------------------------------------
  // 第一轮：各席位独立作答

  Future<void> _roundOne(String runId) async {
    if (_require(runId).phase == CollabPhase.queued) {
      await _transition(runId, CollabPhase.round1);
    }
    var run = _require(runId);
    // 循证：第一轮只问权威席位（主席），其余席位到校验轮再上场。
    final pending = run.spec.mode == CollabMode.evidence
        ? [run.spec.chair]
        : [
            for (final seat in run.spec.seats)
              if (!run.seatOf(seat.id).isUsable) seat,
          ];
    await _eachSeat(
      runId,
      pending,
      (current, seat) => _roundPrompt(current, seat),
      (seat, outcome) => _update(runId, (current) {
        if (outcome.kind != TurnKind.completed) return current;
        final state = current.seatOf(seat.id);
        return current.withSeat(
          seat.id,
          state.copyWith(status: SeatStatus.answered, answer: outcome.text.trim()),
        );
      }),
    );
    final latest = _require(runId);
    if (latest.cancelRequested) throw _Cancelled();
    if (latest.answeredCount == 0) {
      await _transition(runId, CollabPhase.failed, failure: '所有席位都没能给出答案');
      return;
    }
    final next = switch (latest.spec.mode) {
      CollabMode.deliberative => CollabPhase.reviewing,
      CollabMode.evidence => CollabPhase.verifying,
      CollabMode.quick => CollabPhase.synthesizing,
    };
    await _transition(runId, next);
  }

  // ---------------------------------------------------------------------------
  // 校验轮（循证）：权威首答 + 其余席位校验补漏

  Future<void> _verify(String runId) async {
    var run = _require(runId);
    final authority = run.spec.chair;
    final first = run.seatOf(authority.id).best;
    if (first == null || first.isEmpty) {
      await _transition(runId, CollabPhase.failed, failure: '权威席位没有给出首答');
      return;
    }
    final seats = [
      for (final seat in run.spec.seats)
        if (seat.id != authority.id && !run.seatOf(seat.id).isUsable) seat,
    ];
    await _eachSeat(
      runId,
      seats,
      (current, seat) => _verifyPrompt(current, seat, first),
      (seat, outcome) => _update(runId, (current) {
        if (outcome.kind != TurnKind.completed) return current;
        final state = current.seatOf(seat.id);
        return current.withSeat(seat.id, state.copyWith(status: SeatStatus.answered, answer: outcome.text.trim()));
      }),
    );
    if (_require(runId).cancelRequested) throw _Cancelled();
    await _transition(runId, CollabPhase.synthesizing);
  }

  List<({String label, String text})> _answers(CollabRun run, {String? exceptId}) => [
    for (final seat in run.spec.seats)
      if (seat.id != exceptId && run.seatOf(seat.id).best?.isNotEmpty == true)
        (label: seat.displayName, text: run.seatOf(seat.id).best!),
  ];

  // ---------------------------------------------------------------------------
  // 审议轮：互看匿名答案后修订

  Future<void> _review(String runId) async {
    final run = _require(runId);
    final seats = [
      for (final seat in run.spec.seats)
        if (run.seatOf(seat.id).isUsable) seat,
    ];
    await _eachSeat(
      runId,
      seats,
      (current, seat) => _reviewPrompt(current, seat),
      (seat, outcome) => _update(runId, (current) {
        if (outcome.kind != TurnKind.completed) return current;
        final state = current.seatOf(seat.id);
        return current.withSeat(seat.id, state.copyWith(status: SeatStatus.revised, revised: outcome.text.trim()));
      }),
    );
    if (_require(runId).cancelRequested) throw _Cancelled();
    await _transition(runId, CollabPhase.synthesizing);
  }

  // ---------------------------------------------------------------------------
  // 综合：主席写裁决

  Future<void> _synthesize(String runId) async {
    final run = _require(runId);
    final chair = run.spec.chair;
    final answers = _answers(run);
    if (answers.isEmpty) {
      await _transition(runId, CollabPhase.failed, failure: '没有可综合的答案');
      return;
    }
    final outcome = await _runSeat(runId, chair, _synthPrompt(run, answers));
    switch (outcome.kind) {
      case TurnKind.completed:
        final verdict = outcome.text.trim();
        final latest = _require(runId);
        if (latest.cancelRequested) throw _Cancelled();
        final withVerdict = await _update(
          runId,
          (r) => r.copyWith(verdict: verdict.isEmpty ? '（主席没有写出裁决）' : verdict),
        );
        // 裁决正文单独存一份可读的 Markdown，落好了才进终态。
        await _store.writeVerdict(withVerdict);
        await _transition(runId, CollabPhase.done);
      case TurnKind.aborted:
        throw _Cancelled();
      case TurnKind.failed:
        await _transition(runId, CollabPhase.failed, failure: '主席没能写出裁决：${outcome.error ?? '未知原因'}');
    }
  }

  // ---------------------------------------------------------------------------
  // 并发池

  /// 在并发上限内跑完 [seats]；每席位先取提示词再执行，结果交给 [apply]。
  Future<void> _eachSeat(
    String runId,
    List<SeatSpec> seats,
    String Function(CollabRun current, SeatSpec seat) promptOf,
    Future<void> Function(SeatSpec seat, TurnOutcome outcome) apply,
  ) async {
    if (seats.isEmpty) return;
    final maxWorkers = _require(runId).spec.maxConcurrency.clamp(1, seats.length);
    var index = 0;
    Future<void> worker() async {
      while (true) {
        if (index >= seats.length) return;
        final seat = seats[index++];
        if (_require(runId).cancelRequested) return;
        final outcome = await _runSeat(runId, seat, promptOf(_require(runId), seat));
        await apply(seat, outcome);
      }
    }

    await Future.wait([for (var i = 0; i < maxWorkers; i++) worker()]);
  }

  /// 跑一个席位的一轮：先落盘「running」（先写盘再执行），超时/失败重试一次。
  Future<TurnOutcome> _runSeat(String runId, SeatSpec seat, String prompt) async {
    var attempts = 0;
    var last = const TurnOutcome(kind: TurnKind.failed, error: '没有结果');
    while (attempts < 2) {
      attempts++;
      // 预算：每次调用前计数并检查，超限立即停下。
      final before = await _update(runId, (r) {
        if (r.callsUsed >= r.spec.budgetCalls) throw _BudgetExceeded();
        return r.copyWith(callsUsed: r.callsUsed + 1, seats: {
          ...r.seats,
          seat.id: r.seatOf(seat.id).copyWith(status: SeatStatus.running, attempts: attempts),
        });
      });
      final state = before.seatOf(seat.id);
      String sessionId;
      try {
        sessionId = state.sessionId ?? await _driver.openSession(seat, workspaceId: before.spec.workspaceId);
      } on Object catch (e) {
        last = TurnOutcome(kind: TurnKind.failed, error: '开会话失败：$e');
        await _update(runId, (r) {
          final s = r.seatOf(seat.id);
          return r.withSeat(seat.id, s.copyWith(status: SeatStatus.failed, error: last.error));
        });
        continue;
      }
      await _update(runId, (r) {
        final s = r.seatOf(seat.id);
        return r.withSeat(seat.id, s.copyWith(sessionId: sessionId));
      });
      if (state.sessionId == null) {
        // 新开出来的会话：登记它属于这次议会的哪个席位（失败也不影响运行）。
        try {
          onSession?.call((
            sessionId: sessionId,
            label: seat.label ?? seat.model,
            ownerId: runId,
            parentLabel: before.spec.question,
          ));
        } on Object {
          // 登记只是给历史列表用的，不能挡住议会。
        }
      }
      _activeSessions.add(sessionId);
      try {
        final outcome = await _driver.runTurn(sessionId, prompt, timeout: before.spec.seatTimeout);
        last = outcome;
        await _update(runId, (r) {
          final s = r.seatOf(seat.id);
          return r.withSeat(
            seat.id,
            s.copyWith(
              status: switch (outcome.kind) {
                TurnKind.completed => SeatStatus.answered,
                TurnKind.aborted => SeatStatus.cancelled,
                TurnKind.failed => SeatStatus.failed,
              },
              tokensIn: s.tokensIn + outcome.tokensIn,
              tokensOut: s.tokensOut + outcome.tokensOut,
              error: outcome.error,
            ),
          );
        });
        if (outcome.kind != TurnKind.failed) return outcome; // aborted 也不重试
      } on TimeoutException {
        last = TurnOutcome(kind: TurnKind.failed, error: '超过 ${before.spec.seatTimeout.inSeconds} 秒没有完成');
        await _update(runId, (r) {
          final s = r.seatOf(seat.id);
          return r.withSeat(seat.id, s.copyWith(status: SeatStatus.timedOut, error: last.error));
        });
      } on Object catch (e) {
        last = TurnOutcome(kind: TurnKind.failed, error: '$e');
        await _update(runId, (r) {
          final s = r.seatOf(seat.id);
          return r.withSeat(seat.id, s.copyWith(status: SeatStatus.failed, error: last.error));
        });
      } finally {
        _activeSessions.remove(sessionId);
      }
      // 还有一次机会：先退避再试（限流等更久）；用户已取消就收手。
      if (attempts < 2) {
        if (_require(runId).cancelRequested) return last;
        await Future<void>.delayed(_retryDelay(attempts, last));
      }
    }
    return last;
  }

  // ---------------------------------------------------------------------------
  // 提示词

  String _roundPrompt(CollabRun run, SeatSpec seat) {
    final buffer = StringBuffer()
      ..writeln('你是议会中的一员，正在独立回答下面的议题。')
      ..writeln()
      ..writeln('【议题】')
      ..writeln(run.spec.question)
      ..writeln();
    if (seat.role.briefing.isNotEmpty) {
      buffer
        ..writeln('【你的角色】')
        ..writeln(seat.role.briefing)
        ..writeln();
    }
    buffer
      ..writeln('【要求】')
      ..writeln('- 直接给出你的答案，不要复述议题，不要客套。')
      ..writeln('- 结论先行，理由随后；不确定的地方明确标注「不确定」。')
      ..writeln('- 控制在 200 到 400 字。');
    return buffer.toString();
  }

  String _reviewPrompt(CollabRun run, SeatSpec seat) {
    final own = run.seatOf(seat.id).answer ?? '';
    final others = _answers(run, exceptId: seat.id);
    final buffer = StringBuffer()
      ..writeln('你在议会里已经回答过一次议题，现在看到其他成员的匿名答案，请修订你的回答。')
      ..writeln()
      ..writeln('【议题】')
      ..writeln(run.spec.question)
      ..writeln()
      ..writeln('【你之前的回答】')
      ..writeln(own)
      ..writeln();
    if (others.isNotEmpty) {
      buffer.writeln('【其他成员的答案（匿名）】');
      for (var i = 0; i < others.length; i++) {
        buffer
          ..writeln('成员 ${i + 1}：')
          ..writeln(others[i].text)
          ..writeln();
      }
    }
    buffer
      ..writeln('【要求】')
      ..writeln('- 保留你认为正确的内容，明确你改变了什么、为什么。')
      ..writeln('- 不要迎合多数：如果坚持原判断，说明其他成员漏掉了什么。')
      ..writeln('- 输出修订后的完整答案，200 到 400 字。');
    return buffer.toString();
  }

  String _verifyPrompt(CollabRun run, SeatSpec seat, String first) {
    final buffer = StringBuffer()
      ..writeln('你是议会中的验证者。一位权威成员已经就下面的议题给出首答，请你校验并补漏。')
      ..writeln()
      ..writeln('【议题】')
      ..writeln(run.spec.question)
      ..writeln()
      ..writeln('【首答】')
      ..writeln(first)
      ..writeln();
    if (seat.role.briefing.isNotEmpty) {
      buffer
        ..writeln('【你的角色】')
        ..writeln(seat.role.briefing)
        ..writeln();
    }
    buffer
      ..writeln('【要求】')
      ..writeln('- 指出首答里的事实错误、逻辑漏洞或遗漏，逐条写明。')
      ..writeln('- 补充你认为必要的点；如果你认同首答，说明你核对了什么。')
      ..writeln('- 不要重复首答的全文，控制在 150 到 300 字。');
    return buffer.toString();
  }

  String _synthPrompt(CollabRun run, List<({String label, String text})> answers) {
    final buffer = StringBuffer()
      ..writeln('你是议会主席。下面是同一个议题的所有成员答案，请综合出最终裁决。')
      ..writeln()
      ..writeln('【议题】')
      ..writeln(run.spec.question)
      ..writeln()
      ..writeln('【成员答案】');
    for (var i = 0; i < answers.length; i++) {
      buffer
        ..writeln('成员 ${i + 1}（${answers[i].label}）：')
        ..writeln(answers[i].text)
        ..writeln();
    }
    final failed = [
      for (final seat in run.spec.seats)
        if (!run.seatOf(seat.id).isUsable) seat.displayName,
    ];
    if (failed.isNotEmpty) {
      buffer
        ..writeln('（${failed.join('、')} 没有给出有效答案，综合时请说明这一点。）')
        ..writeln();
    }
    buffer
      ..writeln('【输出格式】')
      ..writeln('## 结论')
      ..writeln('一句话结论，然后给出置信度（高 / 中 / 低）和理由。')
      ..writeln('## 共识')
      ..writeln('成员们一致同意的点，逐条列出。')
      ..writeln('## 分歧')
      ..writeln('成员之间的分歧，说明哪边更有说服力。')
      ..writeln('## 建议核实')
      ..writeln('需要用户自己确认的事实或前提。');
    return buffer.toString();
  }

  // ---------------------------------------------------------------------------

  Future<void> _transition(String runId, CollabPhase phase, {String? failure}) =>
      _update(runId, (r) => r.copyWith(phase: phase, failure: failure));

  void _validate(CouncilSpec spec) {
    if (spec.question.trim().isEmpty) throw ArgumentError('议题不能为空');
    if (spec.seats.length < 2 || spec.seats.length > 6) {
      throw ArgumentError('席位数量必须在 2 到 6 之间');
    }
    final ids = <String>{};
    for (final seat in spec.seats) {
      if (seat.id.isEmpty) throw ArgumentError('席位 id 不能为空');
      if (!ids.add(seat.id)) throw ArgumentError('席位 id 重复：${seat.id}');
    }
    if (spec.budgetCalls < spec.estimatedCalls) {
      throw ArgumentError('预算 ${spec.budgetCalls} 少于预计调用 ${spec.estimatedCalls}');
    }
  }
}

/// 生产驱动：在 [DshClient] 上的实现。
///
/// 每席位一个普通子会话：`session/create` → `session/selectModel` →
/// `session/prompt` → `session/follow` 直到 `turn/end`。
final class DshCollabDriver implements CollabSessionDriver {
  DshCollabDriver(this.client);

  final DshClient client;

  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async {
    final created = await client.createSession(workspaceId: workspaceId);
    if (created.sessionId.isEmpty) {
      throw StateError('session/create 没有返回 sessionId');
    }
    await client.setModel(
      created.sessionId,
      provider: seat.provider,
      model: seat.model,
      reasoningEffort: seat.reasoningEffort,
    );
    return created.sessionId;
  }

  @override
  Future<TurnOutcome> runTurn(String sessionId, String text, {Duration? timeout}) async {
    final completer = Completer<TurnOutcome>();
    var answer = '';
    var tokensIn = 0;
    var tokensOut = 0;
    var baseline = 0; // 快照之前的旧事件（历史回放）不参与本次 turn 的判定
    var sawSnapshot = false;
    final subscription = client.watch(sessionId).listen(
      (event) {
        if (event is SessionSnapshotEvent) {
          sawSnapshot = true;
          for (final e in event.events) {
            if (e.seq > baseline) baseline = e.seq;
          }
          return;
        }
        if (event is! SessionLogEvent || event.seq <= baseline) return;
        if (event is AssistantMessageEvent) {
          final texts = [
            for (final part in event.message.parts)
              if (part is TextPart) part.text,
          ];
          if (texts.isNotEmpty) answer = texts.join('\n');
          tokensIn += event.usage?.inputTokens ?? 0;
          tokensOut += event.usage?.outputTokens ?? 0;
        } else if (event is TurnEndedEvent) {
          if (completer.isCompleted) return;
          final reason = event.reason;
          completer.complete(
            TurnOutcome(
              kind: reason.isCompleted
                  ? TurnKind.completed
                  : reason.isAborted
                  ? TurnKind.aborted
                  : TurnKind.failed,
              text: answer,
              tokensIn: tokensIn,
              tokensOut: tokensOut,
              error: reason.isError ? (reason.error?.message ?? reason.kind) : (reason.isCompleted ? null : reason.kind),
            ),
          );
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) {
          completer.complete(TurnOutcome(kind: TurnKind.failed, error: '$e'));
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(const TurnOutcome(kind: TurnKind.failed, error: '会话流已经断开'));
        }
      },
    );
    try {
      // 等快照（基线）最多 5 秒再发 prompt，避免历史回放干扰判定。
      for (var i = 0; i < 50 && !sawSnapshot; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (completer.isCompleted) break;
      }
      await client.prompt(sessionId, text);
      return await completer.future.timeout(timeout ?? const Duration(seconds: 90));
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<void> cancel(String sessionId) async {
    // 会话级「停」没有单独 RPC：归档并停止活动，等价于把这次运行放弃。
    await client.archiveSession(sessionId, stopActivity: true);
  }
}
