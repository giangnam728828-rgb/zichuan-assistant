// 团队（C4）的编排：群聊里的一条消息，转发给点名的队友（没点名就全体），
// 各队友在**各自的子会话**里作答，结果按发言人的身份落进群聊记录。
//
// 与议会的区别：
// 1. 团队是长会话。每个队友的 sessionId 记在 [TeamState.sessions] 里，下次
//    继续说还是同一个会话，队友记得自己之前说过什么。
// 2. 队友之间看不到彼此的会话，所以别人的发言靠 [TeamState.cursors] 按增量
//    补进提示词——每个队友只看「上次同步之后」群里的新消息，不重复复读。
// 3. @ 点名决定这一条谁能看到：点了名的只转给被点名的人，没点名转给全体。
//
// 三条硬规则沿用议会：先写盘再执行、并发有上限、失败重试一次。

import 'dart:async';

import '../council/collab_models.dart';
import '../council/collab_orchestrator.dart';
import 'team_models.dart';
import 'team_store.dart';

/// 一次团队会话（群聊）的编排器。
final class TeamOrchestrator {
  TeamOrchestrator({
    required CollabSessionDriver driver,
    required TeamStore store,
    DateTime Function()? clock,
    String Function()? newId,
    this.maxConcurrency = 3,
    this.turnTimeout = const Duration(seconds: 150),
    this.contextLimit = 12,
    this.contextChars = 700,
    this.workspaceId,
    Future<void> Function(Duration)? pause,
    Duration Function(String? error)? retryDelay,
  }) : _driver = driver,
       _store = store,
       _clock = clock ?? DateTime.now,
       _newId = newId ?? _defaultId,
       _pause = pause ?? ((d) => Future<void>.delayed(d)),
       _retryDelay = retryDelay ?? _defaultRetryDelay;

  final CollabSessionDriver _driver;
  final TeamStore _store;
  final DateTime Function() _clock;
  final String Function() _newId;
  final Future<void> Function(Duration) _pause;
  final Duration Function(String? error) _retryDelay;

  /// 同时在飞的队友数（手机并发：3）。
  final int maxConcurrency;

  /// 单个队友一轮的时限。
  final Duration turnTimeout;

  /// 补背景时最多带几条别人的消息。
  final int contextLimit;

  /// 单条背景消息的截断长度。
  final int contextChars;

  /// 队友子会话落在哪个工作区；空则默认目录。
  final String? workspaceId;

  static Duration _defaultRetryDelay(String? error) {
    final text = (error ?? '').toLowerCase();
    final limited =
        text.contains('429') ||
        text.contains('rate') ||
        text.contains('limit') ||
        text.contains('限流') ||
        text.contains('too many');
    if (limited) return const Duration(seconds: 4);
    return const Duration(milliseconds: 600);
  }

  final _events = StreamController<TeamState>.broadcast();
  bool _disposed = false;

  /// 串行队列：所有状态更新依次执行，避免并发队友互相覆盖。
  Future<void> _queue = Future<void>.value();

  /// 最新快照的内存索引（重启后由 load 补齐）。
  final _latest = <String, TeamState>{};

  /// 每个团队一条串行闸门：同一团队的两条消息不会同时驱动同一批子会话。
  final _locks = <String, Future<void>>{};

  /// 正在飞的子会话（取消时直接停）。
  final _inflight = <String, Set<String>>{};

  /// 已被取消的团队：在飞的队友看到它就收手，不再落结果。
  final _aborted = <String>{};

  var _msgSeq = 0;

  static String _defaultId() => 't${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  String _msgId() =>
      'm${_clock().microsecondsSinceEpoch.toRadixString(36)}${(_msgSeq++).toRadixString(36)}';

  /// 状态流：每次落盘成功后发一份新快照，界面只订阅它。
  Stream<TeamState> get events => _events.stream;

  /// 落盘仓库（界面用它列出历史团队）。
  TeamStore get store => _store;

  // ---------------------------------------------------------------------------
  // 建队与成员维护

  /// 建一个团队。队友 2 到 6 个，名字会自动去重（空名补「队友 N」）。
  Future<TeamState> create({String? id, required List<Teammate> teammates}) async {
    final mates = normalizeTeammates(teammates);
    if (mates.length < 2 || mates.length > 6) {
      throw ArgumentError('队友数量必须在 2 到 6 之间');
    }
    final now = _clock();
    final state = TeamState(
      id: id ?? _newId(),
      teammates: mates,
      createdAt: now,
      updatedAt: now,
      rev: 1,
    );
    await _store.save(state);
    _latest[state.id] = state;
    _emit(state);
    return state;
  }

  /// 加一个队友（建会话推迟到第一次发言）。
  Future<TeamState> addMate(String teamId, Teammate mate) => _update(teamId, (current) {
    if (current.teammates.length >= 6) throw StateError('一个团队最多 6 个队友');
    return current.copyWith(teammates: normalizeTeammates([...current.teammates, mate]));
  });

  /// 改队友的名字/角色/模型。改名撞车直接报错，不偷偷加序号。
  Future<TeamState> updateMate(String teamId, Teammate mate) => _update(teamId, (current) {
    if (mate.name.trim().isEmpty) throw ArgumentError('队友名字不能为空');
    final clash = current.teammates.any(
      (other) => other.id != mate.id && other.name.toLowerCase() == mate.name.trim().toLowerCase(),
    );
    if (clash) throw ArgumentError('已经有队友叫「${mate.name.trim()}」');
    return current.copyWith(
      teammates: [
        for (final other in current.teammates)
          other.id == mate.id
              ? mate.copyWith(
                  name: mate.name.trim(),
                  brief: mate.brief.trim(),
                )
              : other,
      ],
    );
  });

  /// 移除队友：连带清掉它的会话与游标，并在群里留一句系统提示。
  Future<TeamState> removeMate(String teamId, String mateId) => _update(teamId, (current) {
    final mate = current.mate(mateId);
    if (mate == null) return current;
    return current.copyWith(
      teammates: [
        for (final other in current.teammates)
          if (other.id != mateId) other,
      ],
      sessions: {...current.sessions}..remove(mateId),
      cursors: {...current.cursors}..remove(mateId),
      messages: [
        ...current.messages,
        TeamMsg(
          id: _msgId(),
          role: TeamMsgRole.system,
          text: '「${mate.name}」离开了团队。',
          at: _clock(),
        ),
      ],
    );
  });

  // ---------------------------------------------------------------------------
  // 发言

  /// 我在群里说一句：解析 @ 点名 → 落盘 → 转发给被点名的队友（没点名则全体）。
  ///
  /// 返回这一轮全部答完之后的快照；过程中每一次变化都会从 [events] 发出。
  Future<TeamState> send(String teamId, String text) {
    final body = text.trim();
    if (body.isEmpty) throw ArgumentError('消息不能为空');
    return _serial(teamId, () async {
      _aborted.remove(teamId);
      final targets = <String>[];
      final after = await _update(teamId, (current) {
        final parsed = parseMentions(current.teammates, body);
        final picked = parsed.targets.isEmpty ? current.teammates : parsed.targets;
        targets
          ..clear()
          ..addAll([for (final mate in picked) mate.id]);
        return current.copyWith(
          messages: [
            ...current.messages,
            TeamMsg(id: _msgId(), role: TeamMsgRole.user, text: parsed.text, at: _clock()),
          ],
        );
      });
      if (targets.isEmpty) return after;
      await _each(targets, (mateId) => _runMate(teamId, mateId));
      return _latest[teamId] ?? after;
    });
  }

  /// 停掉这一轮：置标志 + 尽力停掉在飞的子会话，群里留一句提示。
  Future<void> cancel(String teamId) async {
    final first = _aborted.add(teamId);
    for (final sessionId in _inflight[teamId]?.toList() ?? const <String>[]) {
      unawaited(_driver.cancel(sessionId).catchError((_) {}));
    }
    if (!first) return;
    await _update(teamId, (current) {
      return current.copyWith(
        messages: [
          ...current.messages,
          TeamMsg(id: _msgId(), role: TeamMsgRole.system, text: '已停止这一轮。', at: _clock()),
        ],
      );
    });
  }

  // ---------------------------------------------------------------------------
  // 读取

  Future<TeamState?> load(String teamId) async {
    final state = _latest[teamId] ?? await _store.load(teamId);
    if (state != null) _latest[teamId] = state;
    return state;
  }

  /// 全部团队，最近更新的在前。
  Future<List<TeamState>> list() async {
    final all = await _store.list();
    for (final state in all) {
      _latest[state.id] = state;
    }
    return all;
  }

  /// 最近一个团队（进入团队页时先看它）。
  Future<TeamState?> latest() async {
    final all = await list();
    return all.isEmpty ? null : all.first;
  }

  Future<void> dispose() async {
    _disposed = true;
    await _events.close();
  }

  // ---------------------------------------------------------------------------
  // 单个队友的一轮

  Future<void> _runMate(String teamId, String mateId) async {
    try {
      await _runMateOnce(teamId, mateId);
    } catch (_) {
      // 落盘失败等内部错误不该拖垮其他队友；这个队友这一轮没结果就是没结果。
    }
  }

  Future<void> _runMateOnce(String teamId, String mateId) async {
    final snapshot = await load(teamId);
    if (snapshot == null || _aborted.contains(teamId)) return;
    final mate = snapshot.mate(mateId);
    if (mate == null) return;

    final prompt = _prompt(snapshot, mate);
    var sessionId = snapshot.sessions[mate.id];
    String? lastError;
    for (var attempt = 1; attempt <= 2; attempt++) {
      if (_aborted.contains(teamId)) return;
      String? registered;
      try {
        if (sessionId == null) {
          sessionId = await _driver.openSession(_seatOf(mate), workspaceId: workspaceId);
          if (sessionId.isEmpty) throw StateError('会话没有返回 sessionId');
          final created = sessionId;
          // 先落盘会话 id 再发消息：进程中途被杀时下次还能接上同一会话。
          await _update(teamId, (current) => current.copyWith(sessions: {...current.sessions, mate.id: created}));
          if (_aborted.contains(teamId)) return;
        }
        final sid = sessionId;
        _inflight.putIfAbsent(teamId, () => <String>{}).add(sid);
        registered = sid;
        final outcome = await _driver.runTurn(sid, prompt, timeout: turnTimeout);
        if (_aborted.contains(teamId)) return;
        final text = outcome.text.trim();
        if (outcome.isCompleted && text.isNotEmpty) {
          await _appendAnswer(teamId, mate, text);
          return;
        }
        lastError = _reasonOf(outcome);
      } catch (error) {
        if (_aborted.contains(teamId)) return;
        lastError = '$error';
      } finally {
        if (registered != null) _inflight[teamId]?.remove(registered);
      }
      if (attempt >= 2) break;
      await _pause(_retryDelay(lastError));
    }
    await _appendFailure(teamId, mate, lastError ?? '调用失败');
  }

  static String _reasonOf(TurnOutcome outcome) {
    final error = outcome.error?.trim();
    if (error != null && error.isNotEmpty) return error;
    return switch (outcome.kind) {
      TurnKind.completed => '空回复',
      TurnKind.aborted => '被中断',
      TurnKind.failed => '调用失败',
    };
  }

  Future<void> _appendAnswer(String teamId, Teammate mate, String text) => _update(teamId, (current) {
    final messages = [
      ...current.messages,
      TeamMsg(
        id: _msgId(),
        role: TeamMsgRole.teammate,
        teammateId: mate.id,
        text: text,
        at: _clock(),
      ),
    ];
    return current.copyWith(
      messages: messages,
      // 它已经看过群里到目前为止的全部内容（含自己这条）。
      cursors: {...current.cursors, mate.id: messages.length},
    );
  });

  Future<void> _appendFailure(String teamId, Teammate mate, String error) => _update(teamId, (current) {
    return current.copyWith(
      messages: [
        ...current.messages,
        TeamMsg(
          id: _msgId(),
          role: TeamMsgRole.teammate,
          teammateId: mate.id,
          text: '（这一轮没答上来：$error）',
          at: _clock(),
          failed: true,
        ),
      ],
    );
  });

  // ---------------------------------------------------------------------------
  // 提示词

  /// 拼一个队友这一轮看到的全部内容：自己是谁、别人是谁、群里新发生了什么、
  /// 现在要回应的那句话。
  String _prompt(TeamState state, Teammate mate) {
    final buffer = StringBuffer()..writeln('你是团队里的「${mate.name}」。');
    if (mate.brief.trim().isNotEmpty) buffer.writeln('你的角色：${mate.brief.trim()}');
    final others = [
      for (final other in state.teammates)
        if (other.id != mate.id) other,
    ];
    if (others.isEmpty) {
      buffer.writeln('这个团队目前只有你一个人。');
    } else {
      final list = [
        for (final other in others)
          other.brief.trim().isEmpty ? other.name : '${other.name}（${other.brief.trim()}）',
      ];
      buffer.writeln('团队其他成员：${list.join('、')}。');
    }
    buffer
      ..writeln('你们在一个群聊里，各答各的那一份：不要替别人发言，也不要假装别人已经回答。')
      ..writeln('直接说内容，不要复述这段说明。');

    final ask = _lastAsk(state.messages);
    final from = (state.cursors[mate.id] ?? 0).clamp(0, state.messages.length);
    final relay = <TeamMsg>[];
    for (var i = from; i < state.messages.length; i++) {
      final msg = state.messages[i];
      if (msg.teammateId == mate.id) continue; // 自己说过的话在会话里，不重复喂
      if (ask != null && msg.id == ask.id) continue; // 要回应的那句单独放
      relay.add(msg);
    }
    final tail = relay.length > contextLimit ? relay.sublist(relay.length - contextLimit) : relay;
    if (tail.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('【群里刚发生的事】');
      for (final msg in tail) {
        buffer.writeln('${_who(state, msg)}：${_clip(msg.text)}');
      }
    }
    if (ask != null) {
      buffer
        ..writeln()
        ..writeln('【现在需要你回应】')
        ..writeln(ask.text);
    }
    return buffer.toString();
  }

  static TeamMsg? _lastAsk(List<TeamMsg> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == TeamMsgRole.user) return messages[i];
    }
    return null;
  }

  static String _who(TeamState state, TeamMsg msg) => switch (msg.role) {
    TeamMsgRole.user => '我（用户）',
    TeamMsgRole.teammate => state.mate(msg.teammateId ?? '')?.name ?? '队友',
    TeamMsgRole.system => '系统',
  };

  static final _space = RegExp(r'\s+');

  String _clip(String text) {
    final one = text.replaceAll(_space, ' ').trim();
    return one.length <= contextChars ? one : '${one.substring(0, contextChars)}…';
  }

  static SeatSpec _seatOf(Teammate mate) => SeatSpec(
    id: mate.id,
    provider: mate.provider,
    model: mate.model,
    reasoningEffort: mate.reasoningEffort,
    label: mate.name,
  );

  // ---------------------------------------------------------------------------
  // 队列与并发

  /// 同一团队串行：一条消息的答复全部落盘之后，才轮到下一条。
  Future<T> _serial<T>(String teamId, Future<T> Function() action) {
    final previous = _locks[teamId] ?? Future<void>.value();
    final done = Completer<void>();
    _locks[teamId] = done.future;
    return previous.then((_) async {
      try {
        return await action();
      } finally {
        done.complete();
        if (identical(_locks[teamId], done.future)) _locks.remove(teamId);
      }
    });
  }

  /// 并发池：每次最多 [maxConcurrency] 个队友在飞。
  Future<void> _each(List<String> ids, Future<void> Function(String id) task) async {
    if (ids.isEmpty) return;
    final limit = maxConcurrency.clamp(1, ids.length);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= ids.length) return;
        await task(ids[index]);
      }
    }

    await Future.wait([for (var i = 0; i < limit; i++) worker()]);
  }

  /// 串行更新：读最新 → 改 → 原子落盘 → 广播。
  Future<TeamState> _update(String teamId, TeamState Function(TeamState current) mutate) {
    final task = _queue.then((_) async {
      final current = _latest[teamId] ?? await _store.load(teamId);
      if (current == null) throw StateError('团队不存在：$teamId');
      final next = mutate(current).copyWith(updatedAt: _clock(), rev: current.rev + 1);
      await _store.save(next);
      _latest[teamId] = next;
      _emit(next);
      return next;
    });
    _queue = task.then((_) {}, onError: (_) {});
    return task;
  }

  void _emit(TeamState state) {
    if (_disposed || _events.isClosed) return;
    _events.add(state);
  }
}
