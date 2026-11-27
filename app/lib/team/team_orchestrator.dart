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
import 'dart:convert';

import '../collab/collab_activity.dart';
import '../collab/collab_session_book.dart';
import '../council/collab_models.dart';
import '../council/collab_orchestrator.dart';
import 'team_models.dart';
import 'team_store.dart';
import 'team_tasks.dart';

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
    Duration Function(int minutes)? wakeInterval,
    this.onSession,
  }) : _driver = driver,
       _store = store,
       _clock = clock ?? DateTime.now,
       _newId = newId ?? _defaultId,
       _pause = pause ?? ((d) => Future<void>.delayed(d)),
       _retryDelay = retryDelay ?? _defaultRetryDelay,
       _wakeInterval = wakeInterval ?? ((minutes) => Duration(minutes: minutes));

  final CollabSessionDriver _driver;
  final TeamStore _store;
  final DateTime Function() _clock;
  final String Function() _newId;
  final Future<void> Function(Duration) _pause;
  final Duration Function(String? error) _retryDelay;
  final Duration Function(int minutes) _wakeInterval;

  /// 开出一个队友会话时的回调：团队页据此登记，历史列表不再单列这些会话。
  final FutureOr<void> Function(CollabSessionInfo info)? onSession;

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

  /// 取消发生的时刻：新消息只清除「它开始之前」的取消，
  /// 不会把刚按下的停止又悄悄打开。
  final _abortedAt = <String, DateTime>{};

  /// 正在跑一轮的团队（定时唤醒看到它在跑就跳过这次）。
  final _active = <String>{};

  /// 正在执行任务图的团队：防止同一张图被重复驱动。
  final _runActive = <String>{};

  /// 每个团队的定时唤醒。
  final _wakeTimers = <String, Timer>{};

  /// 每个团队一把写锁：可写的队友排队跑，避免两个 agent 同时改同一份文件。
  final _writeGates = <String, Future<void>>{};

  var _msgSeq = 0;

  static String _defaultId() => 't${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  String _msgId() => 'm${_clock().microsecondsSinceEpoch.toRadixString(36)}${(_msgSeq++).toRadixString(36)}';

  /// 状态流：每次落盘成功后发一份新快照，界面只订阅它。
  Stream<TeamState> get events => _events.stream;

  /// 落盘仓库（界面用它列出历史团队）。
  TeamStore get store => _store;

  // ---------------------------------------------------------------------------
  // 建队与成员维护

  /// 建一个团队。队友 2 到 6 个，名字会自动去重（空名补「队友 N」）。
  ///
  /// [leadId] 指定主管（可选）：没点名时先由他接活，他可以 @ 队友分派。
  /// 建一个团队会话。[allowEmpty] 用于「点团队直接进聊天」：先建一条空会话，
  /// 队友在聊天里的初始化面板补；发消息前至少要两位（见 [send]）。
  Future<TeamState> create({
    String? id,
    required List<Teammate> teammates,
    String? leadId,
    String title = '',
    bool allowEmpty = false,
  }) async {
    final mates = normalizeTeammates(teammates);
    final max = 6;
    if (mates.length > max || (!allowEmpty && mates.length < 2)) {
      throw ArgumentError('队友数量必须在 2 到 6 之间');
    }
    if (leadId != null && !mates.any((mate) => mate.id == leadId)) {
      throw ArgumentError('指定的主管不在这个团队里');
    }
    final now = _clock();
    final state = TeamState(
      id: id ?? _newId(),
      title: title,
      teammates: mates,
      leadId: leadId,
      createdAt: now,
      updatedAt: now,
      rev: 1,
    );
    await _store.save(state);
    _latest[state.id] = state;
    _emit(state);
    return state;
  }

  /// 改会话标题（历史列表里显示）。
  Future<TeamState> rename(String teamId, String title) =>
      _update(teamId, (current) => current.copyWith(title: title.trim()));

  /// 设/撤主管。[mateId] 为空就是撤销。
  Future<TeamState> setLead(String teamId, String? mateId) => _update(teamId, (current) {
    if (mateId == null) return current.copyWith(clearLead: true);
    if (current.mate(mateId) == null) throw ArgumentError('这个队友不在团队里');
    return current.copyWith(leadId: mateId);
  });

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
          other.id == mate.id ? mate.copyWith(name: mate.name.trim(), brief: mate.brief.trim()) : other,
      ],
    );
  });

  /// 移除队友：连带清掉它的会话与游标，并在群里留一句系统提示。
  Future<TeamState> removeMate(String teamId, String mateId) => _update(teamId, (current) {
    final mate = current.mate(mateId);
    if (mate == null) return current;
    final wasLead = current.leadId == mateId;
    return current.copyWith(
      teammates: [
        for (final other in current.teammates)
          if (other.id != mateId) other,
      ],
      sessions: {...current.sessions}..remove(mateId),
      cursors: {...current.cursors}..remove(mateId),
      clearLead: wasLead,
      messages: [
        ...current.messages,
        TeamMsg(
          id: _msgId(),
          role: TeamMsgRole.system,
          text: wasLead ? '「${mate.name}」离开了团队（主管一职空了出来）。' : '「${mate.name}」离开了团队。',
          at: _clock(),
        ),
      ],
    );
  });

  // ---------------------------------------------------------------------------
  // 发言

  /// 我在群里说一句：解析 @ 点名 → 落盘 → 转发给被点名的队友。
  ///
  /// 没点名时有主管就先交给主管（他会 @ 人分派），没主管才全员作答。
  /// 一位队友答完把活移交（或主管分派）给别人时，会接着把那一轮跑完，
  /// 最多再转两手，防互相推诿的死循环。
  ///
  /// 返回这一轮全部答完之后的快照；过程中每一次变化都会从 [events] 发出。
  Future<TeamState> send(String teamId, String text, {List<CollabAttachment> attachments = const []}) {
    final body = text.trim();
    // 只发附件也允许（S6）；群聊里显示「（附件）」占位。
    if (body.isEmpty && attachments.isEmpty) throw ArgumentError('消息不能为空');
    final startedAt = _clock();
    return _serial(teamId, () async {
      // 这次发送开始之后按下的停止，不能被当成上一轮的旧标记清掉。
      if (_abortedAt[teamId] case final at? when !at.isBefore(startedAt)) {
        final stopped = _latest[teamId] ?? await load(teamId);
        if (stopped != null) return stopped;
        throw StateError('团队不存在：$teamId');
      }
      _aborted.remove(teamId);
      _abortedAt.remove(teamId);
      final targets = <String>[];
      final after = await _update(teamId, (current) {
        final parsed = parseMentions(current.teammates, body);
        final picked = parsed.targets.isNotEmpty
            ? parsed.targets
            : switch (current.lead) {
                final lead? => [lead],
                null => current.teammates,
              };
        targets
          ..clear()
          ..addAll([for (final mate in picked) mate.id]);
        return current.copyWith(
          messages: [
            ...current.messages,
            TeamMsg(
              id: _msgId(),
              role: TeamMsgRole.user,
              text: parsed.text.isEmpty ? '（附件）' : parsed.text,
              at: _clock(),
            ),
          ],
        );
      });
      if (targets.isEmpty) return after;
      _active.add(teamId);
      try {
        final lead = after.lead;
        // 有主管且这一条就是发给主管的：先让他出任务图（S8）。
        // 出不来就退回群聊分派：他刚才那段回答已经落进群里，接着 @ 人跑。
        final planning = lead != null && targets.length == 1 && targets.first == lead.id;
        if (!planning) {
          await _drive(teamId, targets, attachments: attachments);
          return _latest[teamId] ?? after;
        }
        final planned = await _planAndRun(teamId, after, lead, attachments);
        if (planned) return _latest[teamId] ?? after;
        final latest = _latest[teamId] ?? after;
        final answer = _lastMateAnswer(latest, lead.id);
        final mentioned = answer == null
            ? const <Teammate>[]
            : parseAssignments(latest.teammates, answer, exceptId: lead.id);
        final next = [
          for (final mate in mentioned)
            if (mate.id != lead.id) mate.id,
        ];
        if (next.isNotEmpty) await _drive(teamId, next, attachments: attachments);
      } finally {
        _active.remove(teamId);
      }
      return _latest[teamId] ?? after;
    });
  }

  /// 设定时唤醒（[minutes] 为空就是关掉）。
  ///
  /// 到点时如果这一轮还没跑完就跳过，不叠着跑；[wakePrompt] 是到点要在群里
  /// 说的那句话。配置落盘，下次打开页面（或换设备）还会接着催。
  Future<TeamState> setWake(String teamId, int? minutes, {String? wakePrompt}) async {
    if (minutes != null && (minutes < 1 || minutes > 24 * 60)) {
      throw ArgumentError('间隔要在 1 分钟到 24 小时之间');
    }
    // 先停表再改配置：关掉唤醒时不能等落盘完才停，那一拍足够再催一次。
    _wakeTimers.remove(teamId)?.cancel();
    final state = await _update(teamId, (current) {
      return current.copyWith(
        wakeMinutes: minutes,
        clearWake: minutes == null,
        wakePrompt: (wakePrompt ?? '').trim().isEmpty ? null : wakePrompt!.trim(),
      );
    });
    _scheduleWake(state);
    return state;
  }

  /// 开关「可写队友排队」。
  Future<TeamState> setExclusiveWrite(String teamId, bool on) =>
      _update(teamId, (current) => current.copyWith(exclusiveWrite: on));

  /// 到点：像用户发了一句那样驱动一轮。
  Future<void> _wake(String teamId) async {
    if (_disposed) return;
    final state = await load(teamId);
    if (state == null || state.wakeMinutes == null) return;
    if (_active.contains(teamId) || _aborted.contains(teamId)) return;
    // 读取与发送之间可能刚被关掉：再问一次内存里最新的一份。
    if (_latest[teamId]?.wakeMinutes == null) return;
    try {
      await send(teamId, state.wakePrompt);
    } catch (_) {
      // 唤醒失败不该把定时器打崩：下一轮继续试。
    }
  }

  void _scheduleWake(TeamState state) {
    _wakeTimers.remove(state.id)?.cancel();
    final minutes = state.wakeMinutes;
    if (minutes == null || minutes <= 0 || _disposed) return;
    _wakeTimers[state.id] = Timer.periodic(_wakeInterval(minutes), (_) => _wake(state.id));
  }

  /// 跑一批人的回合；答完看谁把活交给了别人，接着跑下一批。
  ///
  /// 同一个人在一次 [send] 里只跑一轮（[seen] 记着），所以 A→B→A 的推诿
  /// 会在第三跳停下；[depth] 再兜一层底。
  Future<void> _drive(
    String teamId,
    List<String> mateIds, {
    int depth = 0,
    Set<String>? seen,
    List<CollabAttachment> attachments = const [],
  }) async {
    final visited = seen ?? <String>{};
    final pending = [
      for (final id in mateIds)
        if (id.isNotEmpty && !visited.contains(id)) id,
    ];
    if (pending.isEmpty || _aborted.contains(teamId)) return;
    visited.addAll(pending);
    final answers = <String, ({String text, String? toId})>{};
    await _each(pending, (mateId) async {
      final answer = await _runMate(teamId, mateId, attachments);
      if (answer != null) answers[mateId] = answer;
    });
    if (depth >= 2 || _aborted.contains(teamId) || answers.isEmpty) return;

    final state = await load(teamId);
    if (state == null) return;
    final next = <String>[];
    void queue(String id) {
      if (visited.contains(id) || next.contains(id)) return;
      if (state.mate(id) == null) return;
      next.add(id);
    }

    for (final entry in answers.entries) {
      // 移交给谁：答复末尾写了「移交 @名字」。
      final toId = entry.value.toId;
      if (toId != null) queue(toId);
      // 主管在正文里 @ 人分派。
      if (state.leadId == entry.key) {
        for (final target in parseAssignments(state.teammates, entry.value.text, exceptId: entry.key)) {
          queue(target.id);
        }
      }
    }
    if (next.isEmpty) return;
    await _drive(teamId, next, depth: depth + 1, seen: visited, attachments: attachments);
  }

  /// 停掉这一轮：置标志 + 尽力停掉在飞的子会话，群里留一句提示。
  Future<void> cancel(String teamId) async {
    _abortedAt[teamId] = _clock();
    final first = _aborted.add(teamId);
    for (final sessionId in _inflight[teamId]?.toList() ?? const <String>[]) {
      unawaited(_driver.cancel(sessionId).catchError((_) {}));
    }
    if (!first) return;
    await _update(teamId, (current) {
      final run = current.run;
      return current.copyWith(
        running: const [],
        // 任务图一起停：没完成的任务标取消，已完成的成果保留。
        run: run == null
            ? null
            : run.copyWith(
                status: TeamRunStatus.cancelled,
                tasks: [
                  for (final task in run.tasks)
                    if (task.isOpen) task.copyWith(status: TeamTaskStatus.cancelled) else task,
                ],
              ),
        messages: [
          ...current.messages,
          TeamMsg(id: _msgId(), role: TeamMsgRole.system, text: '已停止这一轮。', at: _clock()),
        ],
      );
    });
  }

  // ---------------------------------------------------------------------------
  // S8：任务图（主管规划 → 依赖调度 → 审核 → 汇总）

  /// 让主管出计划。返回 true 表示这一轮已经按任务图处理（不管成败），
  /// false 表示没有拿到可用计划，调用方退回群聊分派。
  Future<bool> _planAndRun(String teamId, TeamState state, Teammate lead, List<CollabAttachment> attachments) async {
    final reply = await _runMateTurn(
      teamId,
      state,
      lead,
      attachments,
      promptOverride: _planPrompt(state, lead),
      append: false,
    );
    if (reply == null) return false;
    final plan = parseTeamPlan(reply.text);
    if (plan == null) {
      // 不是计划：把这段当普通回答落进群聊，可能它本身就是答案。
      await _appendAnswer(teamId, lead, reply.text);
      return false;
    }
    final idOfName = {for (final mate in state.teammates) mate.name.toLowerCase(): mate.id};
    final bound = bindPlan(plan, idOfName: idOfName);
    if (bound.tasks == null) {
      await _appendSystem(teamId, '主管的计划没能执行：${bound.problem}。改按群聊分派继续。');
      return false;
    }
    final now = _clock();
    final run = TeamRun(
      id: 'run${now.microsecondsSinceEpoch.toRadixString(36)}',
      sessionId: teamId,
      status: plan.tasks.isEmpty ? TeamRunStatus.done : TeamRunStatus.running,
      supervisorId: lead.id,
      tasks: bound.tasks!,
      goal: _lastUserText(state),
      summary: plan.summary,
      createdAt: now,
      updatedAt: now,
    );
    await _update(teamId, (current) => current.copyWith(run: run));
    if (_aborted.contains(teamId)) {
      await _markRunCancelled(teamId, run.id);
      return true;
    }
    if (plan.tasks.isEmpty) {
      // 不拆分：主管给的 summary 就是最终答复。
      final answer = plan.summary.isEmpty ? reply.text.trim() : plan.summary;
      if (answer.isNotEmpty) await _appendAnswer(teamId, lead, answer);
      return true;
    }
    await _executeRun(teamId, run);
    return true;
  }

  String _planPrompt(TeamState state, Teammate lead) {
    final members = [
      for (final mate in state.teammates)
        if (mate.id != lead.id) '${mate.name}${mate.brief.trim().isEmpty ? '' : '（${mate.brief.trim()}）'}',
    ];
    return [
      '你是团队的主管。把用户这件事拆成任务图，交给队友执行；能一个人做完就不要拆。',
      if (members.isNotEmpty) '可用的队友：${members.join('、')}。',
      '规则：每个任务一个负责人，负责人必须写队友的名字；deps 填依赖的任务编号，没有依赖就写 []；',
      '任务不要比队友多；不要写你准备怎么做，直接给结构。',
      '只输出一个 JSON 代码块，不要别的文字：',
      '{"tasks":[{"id":"t1","title":"任务标题","owner":"队友名字","deps":[],"input":"具体要他做什么"}],"summary":"不需要拆分时，这里直接给最终答复，否则留空"}',
    ].join('\n');
  }

  String _taskPrompt(TeamState state, TeamRun run, TeamTask task) {
    final buffer = StringBuffer()
      ..writeln('你是团队里的「${state.mate(task.ownerId)?.name ?? '队友'}」。')
      ..writeln('团队的总目标：${run.goal.isEmpty ? '（见群聊）' : run.goal}')
      ..writeln()
      ..writeln('你负责的任务「${task.title}」：')
      ..writeln(task.input.trim().isEmpty ? task.title : task.input.trim());
    if (task.review.trim().isNotEmpty && task.attempts > 0) {
      buffer
        ..writeln()
        ..writeln('【主管的返工意见】')
        ..writeln(task.review.trim());
    }
    final upstream = [
      for (final other in run.tasks)
        if (task.deps.contains(other.id) && other.result.trim().isNotEmpty)
          '「${other.title}」的结果：${_clip(other.result)}',
    ];
    if (upstream.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('【上游任务的结果】')
        ..writeln(upstream.join('\n'));
    }
    buffer
      ..writeln()
      ..writeln('只完成这一个任务，直接给结果；不要复述这段说明，不要 @ 别人。');
    return buffer.toString();
  }

  Future<void> _executeRun(String teamId, TeamRun run) async {
    if (!_runActive.add(teamId)) return;
    try {
      if (_aborted.contains(teamId)) {
        await _markRunCancelled(teamId, run.id);
        return;
      }
      await _runReadyRound(teamId, run.id);
      await _reviewAndSummarize(teamId, run.id);
    } finally {
      _runActive.remove(teamId);
    }
  }

  /// 跑掉所有依赖已满足的任务；每个成员同一时间只拿一个。
  Future<void> _runReadyRound(String teamId, String runId) async {
    var guard = 0;
    while (guard++ < 24) {
      if (_aborted.contains(teamId) || _disposed) return;
      final state = await load(teamId);
      final run = state?.run;
      if (state == null || run == null || run.id != runId) return;
      if (run.status == TeamRunStatus.cancelled || run.status == TeamRunStatus.done) return;
      final settled = settleBlocked(run.tasks);
      if (!_sameTaskStatuses(settled, run.tasks)) {
        await _update(teamId, (current) => current.copyWith(run: current.run?.copyWith(tasks: settled)));
      }
      final ready = readyTasks(settled);
      if (ready.isEmpty) return;
      final byOwner = <String, TeamTask>{};
      for (final task in ready) {
        byOwner.putIfAbsent(task.ownerId, () => task);
      }
      await _eachAll(byOwner.keys.toList(), (ownerId) => _runTask(teamId, runId, byOwner[ownerId]!));
    }
  }

  Future<void> _runTask(String teamId, String runId, TeamTask task) async {
    final state = await load(teamId);
    final run = state?.run;
    if (state == null || run == null || run.id != runId || _aborted.contains(teamId)) return;
    final mate = state.mate(task.ownerId);
    if (mate == null) {
      await _update(
        teamId,
        (current) => current.copyWith(
          run: current.run?.withTask(task.id, (t) => t.copyWith(status: TeamTaskStatus.failed, review: '负责人已经不在团队里')),
        ),
      );
      return;
    }
    // 先写盘再执行：进程被杀后知道这个任务曾经开跑。
    await _update(
      teamId,
      (current) => current.copyWith(
        run: current.run?.withTask(
          task.id,
          (t) => t.copyWith(status: TeamTaskStatus.running, attempts: t.attempts + 1),
        ),
      ),
    );
    final current = await load(teamId);
    if (current == null) return;
    final live = current.run?.task(task.id) ?? task;
    final reply = await _runMateTurn(
      teamId,
      current,
      mate,
      const [],
      promptOverride: _taskPrompt(current, current.run ?? run, live),
    );
    if (reply == null) {
      await _update(
        teamId,
        (current) => current.copyWith(
          run: current.run?.withTask(task.id, (t) => t.copyWith(status: TeamTaskStatus.failed, review: '执行失败')),
        ),
      );
      return;
    }
    await _update(
      teamId,
      (current) => current.copyWith(
        run: current.run?.withTask(
          task.id,
          (t) => t.copyWith(status: TeamTaskStatus.done, result: reply.text, review: ''),
        ),
      ),
    );
  }

  /// 审核 → 需要时返工（单任务最多两次）→ 汇总。
  Future<void> _reviewAndSummarize(String teamId, String runId) async {
    for (var round = 0; round < 3; round++) {
      final state = await load(teamId);
      final run = state?.run;
      if (state == null || run == null || run.id != runId) return;
      if (run.status == TeamRunStatus.cancelled) return;
      final done = [
        for (final task in run.tasks)
          if (task.status == TeamTaskStatus.done) task,
      ];
      final unfinished = [
        for (final task in run.tasks)
          if (task.status != TeamTaskStatus.done) task,
      ];
      if (done.isEmpty) {
        await _update(
          teamId,
          (current) => current.copyWith(
            run: current.run?.copyWith(status: TeamRunStatus.failed, note: '没有任何任务完成'),
          ),
        );
        return;
      }
      await _update(teamId, (current) => current.copyWith(run: current.run?.copyWith(status: TeamRunStatus.reviewing)));
      final decisions = await _review(teamId, state, run, done);
      var revised = false;
      await _update(teamId, (current) {
        final live = current.run;
        if (live == null) return current;
        var tasks = live.tasks;
        for (final task in tasks) {
          final decision = decisions[task.id];
          if (decision == null) continue;
          final (verdict, note) = decision;
          if (verdict == 'revise' && task.attempts <= 2) {
            revised = true;
            tasks = [
              for (final t in tasks)
                if (t.id == task.id) t.copyWith(status: TeamTaskStatus.pending, review: note) else t,
            ];
          } else {
            tasks = [
              for (final t in tasks)
                if (t.id == task.id) t.copyWith(review: note) else t,
            ];
          }
        }
        return current.copyWith(
          run: live.copyWith(tasks: tasks, status: revised ? TeamRunStatus.running : TeamRunStatus.summarizing),
        );
      });
      if (!revised) {
        await _summarize(teamId, runId, note: unfinished.isEmpty ? '' : '有 ${unfinished.length} 个任务没有完成');
        return;
      }
      await _runReadyRound(teamId, runId);
    }
    await _summarize(teamId, runId, note: '达到返工上限，用已有结果汇总');
  }

  /// 主管审核；解析不出来就当作全部通过，不让格式问题卡住交付。
  Future<Map<String, (String, String)>> _review(
    String teamId,
    TeamState state,
    TeamRun run,
    List<TeamTask> done,
  ) async {
    final lead = state.mate(run.supervisorId);
    if (lead == null) return const {};
    final listing = [for (final task in done) '任务 ${task.id}「${task.title}」：\n${_clipLong(task.result, 1200)}']
        .join('\n\n');
    final prompt = [
      '你是团队的主管，审核队友交回的结果。',
      '总目标：${run.goal}',
      '',
      listing,
      '',
      '只输出一个 JSON 代码块：',
      '{"reviews":[{"taskId":"t1","verdict":"pass","note":"一句话结论"}]}',
      'verdict 只能是 pass 或 revise；revise 表示这份结果没完成任务、需要返工。不要因为措辞不好就退回。',
    ].join('\n');
    final reply = await _runMateTurn(teamId, state, lead, const [], promptOverride: prompt, append: false);
    if (reply == null) return const {};
    return _parseReviews(reply.text);
  }

  Map<String, (String, String)> _parseReviews(String raw) {
    final text = raw.trim();
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return const {};
    Object? decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } on FormatException {
      return const {};
    }
    if (decoded is! Map || decoded['reviews'] is! List) return const {};
    final out = <String, (String, String)>{};
    for (final item in decoded['reviews'] as List) {
      if (item is! Map) continue;
      final id = item['taskId'] as String? ?? item['id'] as String?;
      if (id == null) continue;
      final verdict = (item['verdict'] as String? ?? 'pass').toLowerCase() == 'revise' ? 'revise' : 'pass';
      out[id] = (verdict, (item['note'] as String? ?? '').trim());
    }
    return out;
  }

  Future<void> _summarize(String teamId, String runId, {String note = ''}) async {
    final state = await load(teamId);
    final run = state?.run;
    if (state == null || run == null || run.id != runId) return;
    if (run.status == TeamRunStatus.cancelled || _aborted.contains(teamId)) return;
    final lead = state.mate(run.supervisorId);
    String summary = '';
    if (lead != null) {
      final results = [
        for (final task in run.tasks)
          if (task.result.trim().isNotEmpty) '「${task.title}」：\n${_clipLong(task.result, 1500)}',
      ].join('\n\n');
      final prompt = [
        '你是团队的主管。把下面这些结果汇总成一条给用户的完整答复。',
        '总目标：${run.goal}',
        if (note.isNotEmpty) '注意：$note',
        '',
        results.isEmpty ? '（没有可用的任务结果）' : results,
        '',
        '直接写答复本身；不要 JSON，不要提任务编号，不要罗列过程。用户只想要结论。',
      ].join('\n');
      final reply = await _runMateTurn(teamId, state, lead, const [], promptOverride: prompt, append: false);
      summary = reply?.text.trim() ?? '';
    }
    if (summary.isEmpty) {
      summary = [
        for (final task in run.tasks)
          if (task.result.trim().isNotEmpty) task.result.trim(),
      ].join('\n\n');
    }
    final finalNote = note.isEmpty ? '' : note;
    await _update(
      teamId,
      (current) => current.copyWith(
        run: current.run?.copyWith(
          status: summary.isEmpty ? TeamRunStatus.failed : TeamRunStatus.done,
          summary: summary,
          note: finalNote,
        ),
      ),
    );
    if (summary.isNotEmpty && lead != null) await _appendAnswer(teamId, lead, summary);
    if (summary.isEmpty) await _appendSystem(teamId, '这次没有拿到可汇总的结果。');
  }

  Future<void> _markRunCancelled(String teamId, String runId) async {
    await _update(teamId, (current) {
      final run = current.run;
      if (run == null || run.id != runId) return current;
      return current.copyWith(
        run: run.copyWith(
          status: TeamRunStatus.cancelled,
          tasks: [
            for (final task in run.tasks)
              if (task.isOpen) task.copyWith(status: TeamTaskStatus.cancelled) else task,
          ],
        ),
      );
    });
  }

  /// 应用被杀/引擎断开后继续：已完成的跳过，中断的重新排队。
  Future<TeamState?> resumeRun(String teamId) async {
    final state = await load(teamId);
    final run = state?.run;
    if (state == null || run == null || run.isTerminal) return state;
    if (_runActive.contains(teamId) || _active.contains(teamId)) return state;
    final reset = [
      for (final task in run.tasks)
        if (task.status == TeamTaskStatus.running) task.copyWith(status: TeamTaskStatus.pending) else task,
    ];
    final next = run.copyWith(
      status: TeamRunStatus.running,
      tasks: settleBlocked(reset),
      note: '',
      updatedAt: _clock(),
    );
    final updated = await _update(teamId, (current) => current.copyWith(run: next));
    unawaited(_executeRun(teamId, next));
    return updated;
  }

  Future<void> _appendSystem(String teamId, String text) => _update(teamId, (current) {
    return current.copyWith(
      messages: [
        ...current.messages,
        TeamMsg(id: _msgId(), role: TeamMsgRole.system, text: text, at: _clock()),
      ],
    );
  });

  String? _lastMateAnswer(TeamState state, String mateId) {
    for (final message in state.messages.reversed) {
      if (message.teammateId == mateId && message.role == TeamMsgRole.teammate) return message.text;
    }
    return null;
  }

  static String _lastUserText(TeamState state) {
    for (final message in state.messages.reversed) {
      if (message.role == TeamMsgRole.user) return message.text;
    }
    return '';
  }

  static bool _sameTaskStatuses(List<TeamTask> a, List<TeamTask> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].status != b[i].status) return false;
    }
    return true;
  }

  static String _clipLong(String text, int limit) {
    final one = text.trim();
    return one.length <= limit ? one : '${one.substring(0, limit)}…';
  }

  /// 任务图执行不设并发上限：同一成员一次只拿一个，实际并发等于成员数。
  Future<void> _eachAll(List<String> ids, Future<void> Function(String id) task) async {
    if (ids.isEmpty) return;
    await Future.wait([for (final id in ids) task(id)]);
  }

  // ---------------------------------------------------------------------------
  // 读取

  Future<TeamState?> load(String teamId) async {
    final loaded = _latest[teamId] ?? await _store.load(teamId);
    if (loaded == null) return null;
    _latest[teamId] = loaded;
    var state = loaded;
    // 盘上还记着「谁在跑」，但这个进程里没有一轮在跑：上次进程留下的残影，
    // 擦掉再显示，免得页面永远挂着「正在跑」。
    if (state.running.isNotEmpty && !_active.contains(state.id)) {
      try {
        state = await _update(state.id, (current) => current.copyWith(running: const []));
      } on Object {
        // 擦不掉就照原样显示，不挡打开团队。
      }
    }
    // 盘上有唤醒配置但内存里没在跑（进程刚起来）：接上。
    if (state.wakeMinutes != null && !_wakeTimers.containsKey(state.id)) _scheduleWake(state);
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
    for (final timer in _wakeTimers.values) {
      timer.cancel();
    }
    _wakeTimers.clear();
    await _events.close();
  }

  // ---------------------------------------------------------------------------
  // 单个队友的一轮

  /// 跑一位队友的一轮；成功返回它说的正文和「移交给了谁」。
  ///
  /// 可写的队友排队跑（同一团队一把写锁），只读顾问可以并行——他们不动文件。
  Future<({String text, String? toId})?> _runMate(
    String teamId,
    String mateId,
    List<CollabAttachment> attachments,
  ) async {
    try {
      final state = await load(teamId);
      final mate = state?.mate(mateId);
      final gated = mate != null && !mate.readOnly && (state?.exclusiveWrite ?? true);
      if (!gated) return await _runMateOnce(teamId, mateId, attachments);
      return await _withWriteGate(teamId, () => _runMateOnce(teamId, mateId, attachments));
    } catch (_) {
      // 落盘失败等内部错误不该拖垮其他队友；这个队友这一轮没结果就是没结果。
      return null;
    }
  }

  /// 同一团队的可写回合串行：前一位收工，下一位才动文件。
  Future<T> _withWriteGate<T>(String teamId, Future<T> Function() action) {
    final previous = _writeGates[teamId] ?? Future<void>.value();
    final done = Completer<void>();
    _writeGates[teamId] = done.future;
    return previous.then((_) async {
      try {
        return await action();
      } finally {
        done.complete();
        if (identical(_writeGates[teamId], done.future)) _writeGates.remove(teamId);
      }
    });
  }

  Future<({String text, String? toId})?> _runMateOnce(
    String teamId,
    String mateId,
    List<CollabAttachment> attachments,
  ) async {
    final snapshot = await load(teamId);
    if (snapshot == null || _aborted.contains(teamId)) return null;
    final mate = snapshot.mate(mateId);
    if (mate == null) return null;
    return _runMateTurn(teamId, snapshot, mate, attachments);
  }

  /// 「谁在跑」：内存 + 广播，不排队写盘。结束时顺手擦掉这一位的实时过程。
  void _setRunning(String teamId, String mateId, {required bool on}) {
    final current = _latest[teamId];
    if (current == null) return;
    final running = [...current.running]..remove(mateId);
    if (on) running.add(mateId);
    final activity = {...current.activity};
    if (!on) activity.remove(mateId);
    final next = current.copyWith(running: running, activity: activity);
    _latest[teamId] = next;
    _emit(next);
  }

  /// 一位队友此刻的真实进度：内存 + 广播，不写盘（每 90ms 一次，写盘会拖慢并发）。
  void _setActivity(String teamId, String mateId, CollabActivity activity) {
    final current = _latest[teamId];
    if (current == null) return;
    // 已经收工的回合迟到的事件不再写回去：那一行进度得跟着人一起消失。
    if (!current.running.contains(mateId)) return;
    final next = current.copyWith(activity: {...current.activity, mateId: activity});
    _latest[teamId] = next;
    _emit(next);
  }

  /// 一位队友的一轮正文：开会话、问、落答案或失败，失败重试一次。
  Future<({String text, String? toId})?> _runMateTurn(
    String teamId,
    TeamState snapshot,
    Teammate mate,
    List<CollabAttachment> attachments, {

    /// 任务图执行时用任务专属说明；空则用群聊上下文。
    String? promptOverride,

    /// 规划/审核/汇总这类内部调用不把原文写进群聊。
    bool append = true,
  }) async {
    // 「谁在跑」和实时过程只在这里记账：群聊回合和任务图的规划/执行/审核/
    // 汇总都走这个入口，页面上谁在动一目了然；跑完（含失败、取消）一起擦掉，
    // 不留一条「还在动」的残影。
    _setRunning(teamId, mate.id, on: true);
    try {
      return await _runMateTurnBody(
        teamId,
        snapshot,
        mate,
        attachments,
        promptOverride: promptOverride,
        append: append,
      );
    } finally {
      _setRunning(teamId, mate.id, on: false);
    }
  }

  Future<({String text, String? toId})?> _runMateTurnBody(
    String teamId,
    TeamState snapshot,
    Teammate mate,
    List<CollabAttachment> attachments, {
    String? promptOverride,
    bool append = true,
  }) async {
    final prompt = promptOverride ?? _prompt(snapshot, mate);
    var sessionId = snapshot.sessions[mate.id];
    String? lastError;
    for (var attempt = 1; attempt <= 2; attempt++) {
      if (_aborted.contains(teamId)) return null;
      String? registered;
      try {
        if (sessionId == null) {
          sessionId = await _driver.openSession(_seatOf(mate), workspaceId: workspaceId);
          if (sessionId.isEmpty) throw StateError('会话没有返回 sessionId');
          final created = sessionId;
          // 先落盘会话 id 再发消息：进程中途被杀时下次还能接上同一会话。
          await _update(teamId, (current) => current.copyWith(sessions: {...current.sessions, mate.id: created}));
          // 登记它属于这个团队的哪位队友（失败也不影响这一轮）。
          try {
            await onSession?.call((
              sessionId: created,
              label: mate.name,
              ownerId: teamId,
              parentLabel: snapshot.messages.where((m) => m.role == TeamMsgRole.user).firstOrNull?.text,
            ));
          } on Object {
            // 登记只是给历史列表用的，不能挡住群聊。
          }
          if (_aborted.contains(teamId)) {
            // 取消发生在开会话/落盘的当口：刚开出来的会话也停掉，别留着它空转。
            unawaited(_driver.cancel(created).catchError((_) {}));
            return null;
          }
        }
        final sid = sessionId;
        _inflight.putIfAbsent(teamId, () => <String>{}).add(sid);
        registered = sid;
        if (_aborted.contains(teamId)) {
          // 取消发生在开会话/登记的当口：这一轮还没发出去，直接停下。
          unawaited(_driver.cancel(sid).catchError((_) {}));
          return null;
        }
        final outcome = await runTurnObserved(
          driver: _driver,
          sessionId: sid,
          text: prompt,
          timeout: turnTimeout,
          // 附件只在这一位第一次拿到消息时投递，后续轮次已经在会话上下文里。
          attachments: snapshot.sessions[mate.id] == null ? attachments : const [],
          onActivity: (activity) => _setActivity(teamId, mate.id, activity),
        );
        if (_aborted.contains(teamId)) return null;
        final text = outcome.text.trim();
        if (outcome.isCompleted && text.isNotEmpty) {
          final parsed = parseHandoff(snapshot.teammates, text);
          final body = parsed.text.isEmpty && parsed.toId != null ? '（这件事交给下一位）' : parsed.text;
          if (append) await _appendAnswer(teamId, mate, body, handoffTo: parsed.toId);
          return (text: body, toId: parsed.toId);
        }
        lastError = _reasonOf(outcome);
      } catch (error) {
        if (_aborted.contains(teamId)) return null;
        lastError = '$error';
      } finally {
        if (registered != null) _inflight[teamId]?.remove(registered);
      }
      if (attempt >= 2) break;
      await _pause(_retryDelay(lastError));
    }
    if (append) await _appendFailure(teamId, mate, lastError ?? '调用失败');
    return null;
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

  Future<void> _appendAnswer(String teamId, Teammate mate, String text, {String? handoffTo}) =>
      _update(teamId, (current) {
        final messages = [
          ...current.messages,
          TeamMsg(
            id: _msgId(),
            role: TeamMsgRole.teammate,
            teammateId: mate.id,
            text: text,
            at: _clock(),
            handoffTo: handoffTo,
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
    final isLead = state.leadId == mate.id;
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
        for (final other in others) other.brief.trim().isEmpty ? other.name : '${other.name}（${other.brief.trim()}）',
      ];
      buffer.writeln('团队其他成员：${list.join('、')}。');
    }
    if (mate.readOnly) {
      buffer.writeln('你是团队的只读顾问：只给分析、方案和结论，不要修改文件，也不要执行会产生副作用的命令。');
    }
    if (isLead) {
      buffer
        ..writeln('你是这个团队的主管：能自己做的就自己做；需要别人动手时，在回复里用 @名字 说明要他做什么，')
        ..writeln('系统会把你的话转给他们，他们答完你也能看到。');
    } else {
      buffer.writeln('如果这件事该由别的队友接手，在回复最后单独写一行「移交 @名字」；不要替别人作答。');
    }
    buffer
      ..writeln('你们在一个群聊里，各答各的那一份：不要假装别人已经回答。')
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
    // 有人明确把活交给这位队友：单独提一句，别让它埋在群聊流水里。
    for (var i = state.messages.length - 1; i >= from; i--) {
      final msg = state.messages[i];
      if (msg.handoffTo != mate.id) continue;
      buffer
        ..writeln()
        ..writeln('【这件事交给你了】')
        ..writeln('${_who(state, msg)} 把下面的活交给了你：')
        ..writeln(_clip(msg.text));
      break;
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
    agentPreset: mate.agentPreset,
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
      // running 描述的是「这个进程此刻谁在跑」，不写进盘：进程被杀后
      // 下次打开就不会以为还在跑。
      await _store.save(next.copyWith(running: const []));
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
