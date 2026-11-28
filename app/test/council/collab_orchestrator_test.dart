// C1 内核的单元测试：不经过网络与 Flutter，用 Fake 驱动跑状态机。
//
// 覆盖（对齐《总方案 v4》C1 验收）：并发上限、单席超时、单席失败重试、
// 取消、预算硬上限、以及「执行到一半进程被杀后从断点续跑」。

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/council/collab_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个席位在一次调用里的剧本。
enum FakeKind { ok, fail, hang, abort }

final class FakeScript {
  const FakeScript(this.kind, {this.text = '', this.failFirst = 0});
  final FakeKind kind;
  final String text;

  /// 前 N 次调用失败，之后成功（验证重试）。
  final int failFirst;
}

final class FakeDriver implements CollabSessionDriver {
  FakeDriver(this.scripts);

  /// sessionId → 剧本；未列出的默认 ok。
  final Map<String, FakeScript> scripts;
  final opened = <String>[];
  final prompts = <String, List<String>>{};
  final cancelled = <String>[];
  final seen = <String, int>{};

  /// sessionId → 每次调用带的附件（校验 S6 的投递时机）。
  final got = <String, List<List<CollabAttachment>>>{};
  final _sessionSeat = <String, String>{};
  int _counter = 0;
  int _running = 0;
  int peak = 0;

  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async {
    opened.add(seat.id);
    final id = 's${_counter++}';
    _sessionSeat[id] = seat.id;
    return id;
  }

  @override
  Future<TurnOutcome> runTurn(
    String sessionId,
    String text, {
    Duration? timeout,
    List<CollabAttachment> attachments = const [],
  }) async {
    _running++;
    peak = math.max(peak, _running);
    try {
      final seatId = _sessionSeat[sessionId] ?? '';
      final script = scripts[seatId] ?? const FakeScript(FakeKind.ok, text: '答案');
      final count = (seen[seatId] ?? 0) + 1;
      seen[seatId] = count;
      prompts.putIfAbsent(sessionId, () => []).add(text);
      got.putIfAbsent(sessionId, () => []).add(attachments);
      switch (script.kind) {
        case FakeKind.ok:
          await Future<void>.delayed(const Duration(milliseconds: 5));
          if (count <= script.failFirst) {
            return const TurnOutcome(kind: TurnKind.failed, error: '第一次失败');
          }
          return TurnOutcome(kind: TurnKind.completed, text: script.text, tokensIn: 10, tokensOut: 20);
        case FakeKind.fail:
          return const TurnOutcome(kind: TurnKind.failed, error: '供应商报错');
        case FakeKind.abort:
          return const TurnOutcome(kind: TurnKind.aborted);
        case FakeKind.hang:
          await Future<void>.delayed(timeout ?? const Duration(seconds: 90));
          throw TimeoutException('fake hang', timeout);
      }
    } finally {
      _running--;
    }
  }

  @override
  Future<void> cancel(String sessionId) async {
    cancelled.add(sessionId);
  }
}

CouncilSpec spec({
  int seats = 3,
  CollabMode mode = CollabMode.quick,
  int maxConcurrency = 3,
  int budgetCalls = 16,
  Duration timeout = const Duration(milliseconds: 100),
}) => CouncilSpec(
  question: '手机端的本地 AI 应该优先做哪一类功能？',
  seats: [for (var i = 0; i < seats; i++) SeatSpec(id: 'seat$i', provider: 'p$i', model: 'm$i', label: '模型$i')],
  mode: mode,
  maxConcurrency: maxConcurrency,
  budgetCalls: budgetCalls,
  seatTimeout: timeout,
);

void main() {
  late Directory tmp;
  late CollabStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('collab_test');
    store = CollabStore(tmp);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  CollabOrchestrator make(FakeDriver driver, {String Function()? newId}) => CollabOrchestrator(
    driver: driver,
    store: store,
    newId: newId ?? () => 'run1',
    retryDelay: (_, _) => Duration.zero,
  );

  Future<CollabRun> waitTerminal(CollabOrchestrator o, String id) async {
    CollabRun? last;
    await for (final run in o.events) {
      last = run;
      if (run.phase.isTerminal) break;
    }
    return last ?? (await o.snapshot(id))!;
  }

  test('快速模式：三席并行作答，主席综合，落盘到终态', () async {
    final driver = FakeDriver({
      'seat0': const FakeScript(FakeKind.ok, text: '答案甲'),
      'seat1': const FakeScript(FakeKind.ok, text: '答案乙'),
      'seat2': const FakeScript(FakeKind.ok, text: '答案丙'),
    });
    final o = make(driver);
    final initial = await o.submit(spec());
    expect(initial.phase, CollabPhase.queued);

    final done = await waitTerminal(o, 'run1');
    expect(done.phase, CollabPhase.done);
    expect(done.verdict, isNotEmpty);
    expect(done.answeredCount, 3);
    expect(done.callsUsed, 4); // 3 席 + 主席
    expect(done.seats.values.every((s) => s.tokensIn > 0), isTrue);
    // 盘上是终态（重新读一遍验证「先写盘再执行」的收尾）
    final onDisk = await store.load('run1');
    expect(onDisk!.phase, CollabPhase.done);
    expect(File('${tmp.path}/runs/run1/verdict.md').existsSync(), isTrue);
    await o.dispose();
  });

  test('并发上限：5 席、上限 2，同时在飞的不超过 2', () async {
    final driver = FakeDriver({});
    final o = make(driver);
    await o.submit(spec(seats: 5, maxConcurrency: 2));
    final done = await waitTerminal(o, 'run1');
    expect(done.phase, CollabPhase.done);
    expect(driver.peak, lessThanOrEqualTo(2));
    expect(done.answeredCount, 5);
    await o.dispose();
  });

  test('单席超时：该席记超时，其余照常，裁决仍产出', () async {
    final driver = FakeDriver({'seat1': const FakeScript(FakeKind.hang)});
    final o = make(driver);
    await o.submit(spec(timeout: const Duration(milliseconds: 30)));
    final done = await waitTerminal(o, 'run1');
    expect(done.phase, CollabPhase.done);
    expect(done.seatOf('seat1').status, SeatStatus.timedOut);
    expect(done.seatOf('seat1').attempts, 2); // 超时也重试一次
    expect(done.answeredCount, 2);
    await o.dispose();
  });

  test('单席失败重试一次后成功', () async {
    final driver = FakeDriver({'seat2': const FakeScript(FakeKind.ok, text: '第二次才成功', failFirst: 1)});
    final o = make(driver);
    await o.submit(spec());
    final done = await waitTerminal(o, 'run1');
    expect(done.phase, CollabPhase.done);
    expect(done.seatOf('seat2').status, SeatStatus.answered);
    expect(done.seatOf('seat2').attempts, 2);
    expect(done.seatOf('seat2').answer, '第二次才成功');
    await o.dispose();
  });

  test('全员失败：运行以 failed 收尾并带原因', () async {
    final driver = FakeDriver({
      'seat0': const FakeScript(FakeKind.fail),
      'seat1': const FakeScript(FakeKind.fail),
      'seat2': const FakeScript(FakeKind.fail),
    });
    final o = make(driver);
    await o.submit(spec());
    final done = await waitTerminal(o, 'run1');
    expect(done.phase, CollabPhase.failed);
    expect(done.failure, contains('所有席位'));
    await o.dispose();
  });

  test('取消：慢席位运行中取消，收敛到 cancelled 并停会话', () async {
    final driver = FakeDriver({
      'seat0': const FakeScript(FakeKind.hang),
      'seat1': const FakeScript(FakeKind.hang),
      'seat2': const FakeScript(FakeKind.hang),
    });
    final o = make(driver);
    await o.submit(spec(maxConcurrency: 1, timeout: const Duration(seconds: 5)));
    // 等第一个席位进入 running 再取消
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await o.cancel('run1');
    final done = await waitTerminal(o, 'run1');
    expect(done.phase, CollabPhase.cancelled);
    expect(driver.cancelled, isNotEmpty);
    await o.dispose();
  });

  test('页面回来再 resume：正在跑的 run 不重开第二条驱动，席位不重置', () async {
    final driver = FakeDriver({'seat0': const FakeScript(FakeKind.ok)});
    final o = make(driver);
    await o.submit(spec(maxConcurrency: 1, timeout: const Duration(seconds: 2)));
    final live = await o.snapshot('run1');
    final resumed = await o.resume('run1');

    // 正在驱动中：原样返回内存快照（还是队列/第一轮），不把 running 改回 pending。
    expect(resumed, isNotNull);
    expect(resumed!.rev, live!.rev);
    expect(resumed.phase, live.phase);

    final done = await waitTerminal(o, 'run1');
    expect(done.phase, CollabPhase.done);
    // 三个席位会话，没有因为 resume 再开一轮（再驱动会多开 3 个）。
    expect(driver.opened, hasLength(3));
    expect(done.seats.values.where((seat) => seat.status == SeatStatus.answered), hasLength(3));
    await o.dispose();
  });

  test('不再有预算硬上限：调用次数超过旧上限也照常跑完', () async {
    // v4.4 · 1.4：budgetCalls 只是历史字段，不再当闸门用。这里给一个远低于
    // 实际调用次数的数字，运行必须仍然 done，并把真实次数记下来。
    final o = make(FakeDriver({}));
    await o.submit(spec(budgetCalls: 2));
    final done = await waitTerminal(o, 'run1');
    expect(done.phase, CollabPhase.done);
    expect(done.verdict, isNotNull);
    expect(done.callsUsed, greaterThan(2));
    await o.dispose();
  });

  test('审议模式：第二轮看到匿名答案并修订，调用次数为 席×2+1', () async {
    final driver = FakeDriver({});
    final o = make(driver);
    await o.submit(spec(mode: CollabMode.deliberative));
    final done = await waitTerminal(o, 'run1');
    expect(done.phase, CollabPhase.done);
    expect(done.callsUsed, 7);
    final reviewPrompts = driver.prompts.values.expand((ps) => ps.where((p) => p.contains('匿名')));
    expect(reviewPrompts, isNotEmpty);
    expect(reviewPrompts.first, contains('成员 1'));
    await o.dispose();
  });

  test('循证模式：权威先答，其余席位校验，调用 N+1 次', () async {
    final driver = FakeDriver({});
    final o = make(driver);
    await o.submit(spec(mode: CollabMode.evidence));
    final done = await waitTerminal(o, 'run1');
    expect(done.phase, CollabPhase.done);
    expect(done.callsUsed, 4); // 1 首答 + 2 校验 + 1 综合
    final verifyPrompts = driver.prompts.values.expand((ps) => ps.where((p) => p.contains('验证者')));
    expect(verifyPrompts, hasLength(2));
    expect(verifyPrompts.first, contains('【首答】'));
    expect(done.answeredCount, 3);
    await o.dispose();
  });

  test('断点续跑：盘上一半的进度，恢复后不重复问已答的席位', () async {
    // 手工摆一个「进程被杀时」的盘上状态：seat0 已答，seat1 卡在 running，seat2 未开始。
    final base = CollabRun(
      id: 'run1',
      spec: spec(),
      phase: CollabPhase.round1,
      seats: {
        'seat0': const SeatState(status: SeatStatus.answered, answer: '早答好了', sessionId: 'done-session'),
        'seat1': const SeatState(status: SeatStatus.running, sessionId: 'half-session'),
        'seat2': const SeatState(),
      },
      createdAt: DateTime(2026, 11, 25),
      updatedAt: DateTime(2026, 11, 25),
    );
    await store.save(base);

    final driver = FakeDriver({});
    final o = make(driver);
    final resumed = await o.resume('run1');
    expect(resumed, isNotNull);
    expect(resumed!.phase, CollabPhase.round1);
    final done = await waitTerminal(o, 'run1');

    expect(done.phase, CollabPhase.done);
    // 只重问 seat1（复用 half-session）和 seat2；seat0 不动。
    expect(driver.opened, isNot(contains('seat0')));
    // seat1 复用上次的会话继续问（不新建），seat2 才新建会话。
    expect(driver.prompts['half-session'], isNotNull);
    expect(driver.opened, contains('seat2'));
    expect(done.seatOf('seat0').answer, '早答好了');
    expect(done.seatOf('seat1').sessionId, 'half-session');
    await o.dispose();
  });

  test('参数校验：席位过少拒绝提交；预算数字不再参与校验', () async {
    final o = make(FakeDriver({}));
    await expectLater(o.submit(spec(seats: 1)), throwsArgumentError);
    // 预算再小也能开跑（V4.4 取消了硬上限），这里只确认不抛。
    final run = await o.submit(spec(budgetCalls: 1));
    expect(run.phase, isNot(CollabPhase.failed));
    await o.dispose();
  });

  test('JSON 往返：run 的全部字段可序列化还原', () {
    final run = CollabRun(
      id: 'r1',
      spec: spec(),
      phase: CollabPhase.reviewing,
      seats: const {
        'seat0': SeatState(status: SeatStatus.answered, answer: 'a', sessionId: 's0', tokensIn: 1, tokensOut: 2),
      },
      verdict: 'v',
      callsUsed: 3,
      cancelRequested: false,
      createdAt: DateTime(2026, 11, 25, 8),
      updatedAt: DateTime(2026, 11, 25, 9),
      rev: 7,
    );
    final back = CollabRun.fromJson(run.toJson());
    expect(back.id, 'r1');
    expect(back.phase, CollabPhase.reviewing);
    expect(back.spec.seats.length, 3);
    expect(back.seatOf('seat0').best, 'a');
    expect(back.callsUsed, 3);
    expect(back.rev, 7);
    // 席位预设（决定工具，如联网）也随运行落盘。
    expect(
      SeatSpec.fromJson(const SeatSpec(id: 'x', provider: 'p', model: 'm', agentPreset: 'research').toJson())
          .agentPreset,
      'research',
    );
    // 未知字段不炸（向后兼容）
    final withUnknown = {...run.toJson(), 'futureField': 42};
    expect(CollabRun.fromJson(withUnknown).id, 'r1');
  });

  test('附件：随第一轮投给每个席位，主席综合那一步不重复上传', () async {
    final driver = FakeDriver({});
    final o = make(driver);
    final image = CollabAttachment(name: 'q.png', bytes: Uint8List.fromList(const [1, 2, 3]), mediaType: 'image/png');
    await o.submit(spec(seats: 2), attachments: [image]);
    final done = await waitTerminal(o, 'run1');
    expect(done.phase, CollabPhase.done);

    final batches = [for (final list in driver.got.values) ...list];
    final withFiles = [
      for (final batch in batches)
        if (batch.isNotEmpty) batch,
    ];
    // 两个席位各收到一次；同一份附件不重复上传。
    expect(withFiles, hasLength(2));
    expect(withFiles.every((batch) => batch.single.name == 'q.png' && batch.single.isImage), isTrue);
    expect(batches.any((batch) => batch.isEmpty), isTrue, reason: '主席那一步不带附件');
    await o.dispose();
  });
}
