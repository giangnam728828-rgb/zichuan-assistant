// 议会：统一聊天工作区里的一种模式（总方案 v4）。
//
// 不再是独立整页：ChatScreen 是唯一聊天根页面，这里只提供议会的内容——
// 消息时间线、发送/停止、成员管理、运行恢复。顶栏由 ChatScreen 的统一
// ChatHeader 渲染，本视图把标题/状态/菜单动作发布到 [header]。
//
// 启动分两段（方案八）：
// 第一段（同步）：本地立刻确定/创建会话，第一帧就是可用的聊天界面——
// 不等 Store ready、不等模型目录、不等引擎连接。
// 第二段（后台）：落盘、连编排器、登记历史席位、恢复运行快照；任何一步
// 失败只在错误行提示并可重试，不把页面打回转圈。
//
// 编排仍在 [CollabOrchestrator]（lib/council/），进程级共享：切到团队/聊天
// 不打断还在跑的席位，回来接着看。

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collab/collab_approval_banner.dart';
import '../../collab/collab_context_pack.dart';
import '../../collab/collab_task_context.dart';
import '../../collab/github_delivery.dart';
import '../../collab/collab_approvals.dart';
import '../../collab/collab_conversations.dart';
import '../../collab/collab_export.dart';
import '../../collab/collab_session_book.dart';
import '../../council/collab_models.dart';
import '../../council/collab_orchestrator.dart';
import '../../council/collab_store.dart';
import '../../council/verdict_parser.dart';
import '../../state/chat_state.dart';
import '../../state/conversation_mode_state.dart';
import '../../state/hosts_state.dart';
import '../../state/models_state.dart';
import '../../state/attachments.dart';
import '../../state/read_list_identity.dart';
import '../chat/model_brand_mark.dart';
import '../chat/widgets/attachments.dart';
import '../chat/widgets/plus_panel.dart';
import '../chat/shared/conversation_mode_host.dart';
import '../chat/shared/conversation_workspace.dart';
import '../chat/model_sheet.dart' show shortModelName;
import '../providers/provider_brand_icon.dart';
import '../shell/root_tab.dart';
import '../theme/app_icons.dart';
import '../collab/collab_members.dart';
import '../collab/collab_kit.dart';
import '../collab/collab_task_bar.dart';
import '../collab/github_credential_sheet.dart';
import '../collab/collab_timeline.dart';
import '../chat/render/markdown_body.dart';

/// 进程级共享的议会编排器：切到团队/聊天不打断还在跑的席位，回来接着看。
CollabOrchestrator? _shared;
DshClient? _sharedClient;

class CouncilModeView extends ConsumerStatefulWidget {
  const CouncilModeView({
    super.key,
    this.orchestrator,
    this.runId,
    this.conversationId,
    this.createNew = true,
    this.resumeLatest = false,
    this.header,
    this.topInset = 0,
    this.parentSessionId,
  });

  /// 测试注入用；生产为空，视图自己建实例。
  final CollabOrchestrator? orchestrator;

  /// 从通知或旧数据直接打开的那次运行；空表示新会话或 [conversationId]。
  final String? runId;

  /// 从历史记录打开的议会会话。
  final String? conversationId;

  /// 没给 [conversationId] / [runId] 时是否新建一条会话。
  final bool createNew;

  /// 没有指定的会话时，先恢复最近一条议会（冷启动恢复走这条）；
  /// 一条都没有才新建。
  final bool resumeLatest;

  /// 统一顶栏的信息通道；测试里可以不接。
  final ValueNotifier<CollabHeaderInfo?>? header;

  /// 顶栏（含状态栏）高度。
  final double topInset;

  /// 这一页所在的普通聊天会话：用户「前面那一大段方案」就在它的历史里。
  ///
  /// 议会成员各自开会话，看不见聊天页的上下文；发送时从这里检索出该带上的
  /// 资料（见 lib/collab/collab_context_pack.dart），随议题一起交给成员。
  final String? parentSessionId;

  @override
  ConsumerState<CouncilModeView> createState() => _CouncilModeViewState();
}

class _CouncilModeViewState extends ConsumerState<CouncilModeView> {
  final _draft = TextEditingController();

  CollabOrchestrator? _orchestrator;
  DshClient? _client;
  CollabApprovalInbox? _inbox;
  StreamSubscription<CollabRun>? _sub;
  CouncilConversation? _conversation;
  final _runs = <String, CollabRun>{};

  /// 这一轮对应的任务上下文 id（与 runId 同源）：阶段变化时更新它。
  String? _taskId;

  /// 已经呈现过的回合：切回旧会话时不再重播每条消息的进场。
  final _seenTurns = <String>{};
  bool _busy = false;

  /// 会话还在等本地登记表读完（冷启动恢复）：只占消息区一行小字，
  /// 顶栏和输入栏第一帧就在。
  bool _restoring = false;

  /// 已经按下发送、但编排器还没把 runId 交回来的那一问：先画在时间线上，
  /// 不让用户盯着空输入框等。
  String? _pendingQuestion;
  String? _error;

  /// S7：最后一次收到真实事件的时间。副标题据此显示「已等待 N 秒」，
  /// 让长等待有可见的凭据，而不是一直转圈。
  DateTime _lastBeatAt = DateTime.now();
  Timer? _waitTicker;
  final _scroll = ScrollController();

  /// 已选、未发送的附件（S6：与普通聊天同一套选择与预算）。
  List<DraftAttachment> _drafts = const [];

  late final String _hostKey = conversationHostKey(ref.read(activeHostProvider));

  @override
  void initState() {
    super.initState();
    _bootLocal();
    unawaited(_bootBackground());
  }

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    _sub?.cancel();
    _waitTicker?.cancel();
    _inbox?.dispose();
    _draft.dispose();
    _scroll.dispose();
    // 编排器是连接级共享的。离开视图只取消自己的订阅——还在跑的席位继续跑，
    // 回来重新订阅同一份事件即可；注入的实例归测试管。
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 第一段：本地立刻确定会话，第一帧就是聊天界面（方案 8.1 / 8.2）

  /// 各阶段耗时/错误，出问题时能一眼看出卡在哪。
  final _initTrace = <String, String>{};
  bool _backgroundBooting = false;

  /// 自己管超时：Future.timeout 的计时器在视图 dispose 后还会挂着，测试会报
  /// 「Timer still pending」。这里统一登记，dispose 时全部取消。
  final _timers = <Timer>{};

  Future<T?> _limit<T>(Future<T> future, Duration limit) {
    final completer = Completer<T?>();
    late Timer timer;
    void settle(void Function() done) {
      timer.cancel();
      _timers.remove(timer);
      if (!completer.isCompleted) done();
    }

    timer = Timer(limit, () => settle(() => completer.complete(null)));
    _timers.add(timer);
    future.then(
      (value) => settle(() => completer.complete(value)),
      onError: (Object error, StackTrace stack) => settle(() => completer.completeError(error, stack)),
    );
    return completer.future;
  }

  void _trace(String phase, Stopwatch watch, [Object? error]) {
    final line = error == null ? '${watch.elapsedMilliseconds} ms' : 'failed: $error';
    _initTrace[phase] = line;
    debugPrint('[council boot] $phase: $line');
  }

  /// 同步 boot：只做内存里能做的事，绝不 await。
  ///
  /// Riverpod 不允许在 initState 里改 provider：新建会话 / 记住 id 都推迟
  /// 一个微任务（仍在首帧之前），读表、定会话则当场完成。
  void _bootLocal() {
    final conversations = ref.read(councilConversationsProvider);
    final notifier = ref.read(councilConversationsProvider.notifier);
    CouncilConversation? conversation;
    if (widget.conversationId case final id?) {
      conversation = conversations[id];
    }
    if (conversation == null && widget.resumeLatest) {
      conversation = notifier.latest();
    }
    if (conversation != null) {
      _conversation = conversation;
      _restoring = false;
      final found = conversation;
      scheduleMicrotask(() {
        if (!mounted) return;
        _remember(found);
        _restoreDraft(found);
      });
      unawaited(_bootBackground());
      return;
    }
    if (widget.createNew && !widget.resumeLatest && widget.runId == null && widget.conversationId == null) {
      // 用户主动切到议会 = 新建一条会话：本地即时创建，后台再落盘。
      // 指定了会话 / 要恢复最近一条时不在这里建：本地表可能还没读出来，
      // 交给后台读完再定，避免把历史会话误建成新会话。
      _restoring = true;
      scheduleMicrotask(() {
        if (!mounted || _conversation != null) return;
        final created = _createLocal(notifier);
        setState(() {
          _conversation = created;
          _restoring = false;
        });
        _remember(created);
        _restoreDraft(created);
        unawaited(_bootBackground());
      });
      return;
    }
    // 指定了会话/运行但本地还没读到（Store 未 ready、深链 runId）：
    // 先出空工作区，后台读完再补，不整页转圈。
    _restoring = true;
    unawaited(_bootBackground());
  }

  /// 新会话：默认沿用上次议会的成员配置，复制成独立的一份；消息/回合为空。
  ///
  /// 不等模型目录：有上次配置就直接用；没有就用已经缓存到的目录凑两位；
  /// 连缓存都没有就先进一条空议会，成员在聊天里的初始化面板补。
  CouncilConversation _createLocal(CouncilConversationsNotifier notifier) {
    final last = notifier.latest();
    if (last != null && last.seats.length >= 2) {
      return notifier.createLocal(seats: last.seats, mode: last.mode, chairId: last.chairId);
    }
    final catalog = ref.read(currentModelCatalogProvider);
    final seats = <SeatSpec>[];
    if (catalog != null) {
      for (final group in catalog.groups) {
        for (final info in group.models) {
          if (seats.length >= 2) break;
          seats.add(SeatSpec(id: 'seat${seats.length}', provider: info.provider, model: info.id, label: info.name));
        }
        if (seats.length >= 2) break;
      }
    }
    return notifier.createLocal(seats: seats);
  }

  // ---------------------------------------------------------------------------
  // 第二段：落盘、引擎、历史运行，全部后台，失败只影响错误行

  Future<void> _bootBackground() async {
    if (_backgroundBooting) return;
    _backgroundBooting = true;
    try {
      final watch = Stopwatch()..start();
      final notifier = ref.read(councilConversationsProvider.notifier);

      // 1. 本地登记表读完（最多 3 秒）：冷启动恢复 / 历史打开在这之后补齐。
      try {
        final ready = await _limit(notifier.ready.then((_) => true), const Duration(seconds: 3));
        _trace('conversationStoreReady', watch, ready == null ? 'timeout 3s' : null);
      } on Object catch (error) {
        _trace('conversationStoreReady', watch, error);
      }
      if (!mounted) return;

      // 2. 第一段没定下来的会话，现在补：指定的 id → 最近一条 → 新建。
      if (_conversation == null) {
        CouncilConversation? conversation;
        if (widget.conversationId case final id?) {
          conversation = ref.read(councilConversationsProvider)[id];
        }
        if (conversation == null && widget.resumeLatest) conversation = notifier.latest();
        // 冷启动一条历史都没有：也建一条空的可操作会话（方案 4.2）。
        if (conversation == null && widget.runId == null) conversation = _createLocal(notifier);
        if (conversation != null) {
          setState(() {
            _conversation = conversation;
            _restoring = widget.runId != null;
          });
          _remember(conversation);
          _restoreDraft(conversation);
        }
      }

      // 3. 本地创建的会话落盘一次；失败给明确的错误行（可重试）。
      try {
        await _limit(notifier.flush(), const Duration(seconds: 4));
        _trace('persistConversation', watch);
      } on Object catch (error) {
        _trace('persistConversation', watch, error);
        if (mounted) setState(() => _error = '议会会话没能保存到本地：$error');
      }

      // 4. 引擎/编排器与历史运行。
      final orchestrator = await _ensureOrchestratorSafely(watch);
      if (orchestrator == null || !mounted) return;
      _listen();
      _watchApprovals();
      unawaited(
        _registerPastSessions(orchestrator).timeout(const Duration(seconds: 6)).catchError((Object error) {
          _trace('registerPastSessions', watch, error);
        }),
      );

      // 深链只带 runId：找回它所属的会话（可能需要编排器读运行记录）。
      if (_conversation == null && widget.runId != null) {
        try {
          final conversation = await _limit(_conversationForRun(widget.runId!), const Duration(seconds: 4));
          _trace('conversationForRun', watch);
          if (mounted && conversation != null) {
            setState(() {
              _conversation = conversation;
              _restoring = false;
            });
            _remember(conversation);
            _restoreDraft(conversation);
          }
        } on Object catch (error) {
          _trace('conversationForRun', watch, error);
        }
      }
      if (!mounted) return;
      if (_restoring) setState(() => _restoring = false);

      final conversation = _conversation;
      if (conversation != null) {
        try {
          final loaded = await _limit(_loadTurns(conversation).then((_) => true), const Duration(seconds: 8));
          _trace('loadTurns', watch, loaded == null ? 'timeout 8s' : null);
        } on Object catch (error) {
          _trace('loadTurns', watch, error);
        }
      }
      if (mounted && _error != null) setState(() {});
    } finally {
      _backgroundBooting = false;
    }
  }

  /// 连接换了：旧订阅作废，按新客户端重建编排器；正在跑的是旧连接的任务，
  /// 随旧连接一起结束，不会串到新主机。
  void _onConnectionChanged() {
    _sub?.cancel();
    _sub = null;
    _orchestrator = null;
    unawaited(_bootBackground());
  }

  Future<CollabOrchestrator?> _ensureOrchestratorSafely(Stopwatch watch) async {
    try {
      final orchestrator = await _limit(_ensureOrchestrator(), const Duration(seconds: 8));
      _trace('ensureOrchestrator', watch);
      return orchestrator;
    } on TimeoutException {
      _trace('ensureOrchestrator', watch, 'timeout 8s');
      if (mounted) setState(() => _error = '还没连上引擎，议会暂时只能看记录。');
    } on Object catch (error) {
      _trace('ensureOrchestrator', watch, error);
      if (mounted) setState(() => _error = '议会引擎没有准备好：$error');
    }
    return null;
  }

  /// 记住这是议会「上次用的那条」：冷启动恢复时直接回到它。
  void _remember(CouncilConversation conversation) {
    ref.read(conversationModeProvider.notifier).rememberCouncil(_hostKey, conversation.id);
  }

  void _restoreDraft(CouncilConversation conversation) {
    final saved = ref.read(conversationModeProvider).draftOf(ConversationMode.council, _hostKey, conversation.id);
    if (saved.isEmpty || _draft.text.isNotEmpty) return;
    _draft.text = saved;
    _draft.selection = TextSelection.collapsed(offset: saved.length);
  }

  /// 草稿按「模式 + 主机 + 会话」存：切走再切回来，没发的字还在。
  void _saveDraft(String _) {
    final conversation = _conversation;
    if (conversation == null) return;
    ref
        .read(conversationModeProvider.notifier)
        .saveDraft(ConversationMode.council, _hostKey, conversation.id, _draft.text);
  }

  /// 把已有运行的席位子会话登记进协作登记表（历史列表据此折叠）。
  Future<void> _registerPastSessions(CollabOrchestrator orchestrator) async {
    try {
      final runs = await orchestrator.store.list();
      final owners = <CollabSessionOwner>[
        for (final run in runs)
          for (final seat in run.spec.seats)
            if (run.seatOf(seat.id).sessionId case final sid? when sid.isNotEmpty)
              CollabSessionOwner(
                sessionId: sid,
                kind: CollabSessionKind.council,
                ownerId: run.id,
                label: seat.displayName,
                parentLabel: run.spec.question,
              ),
      ];
      if (owners.isNotEmpty) {
        unawaited(ref.read(collabSessionBookProvider.notifier).registerAll(owners));
      }
    } on Object {
      // 登记失败只影响历史列表的折叠，不影响议会。
    }
  }

  /// 通知点进来（或旧数据只有 runId）：找到它属于哪条会话；找不到就为它
  /// 补一条会话记录，老数据也能在历史里出现。
  Future<CouncilConversation> _conversationForRun(String runId) async {
    for (final conversation in ref.read(councilConversationsProvider).values) {
      if (conversation.turns.any((turn) => turn.runId == runId)) return conversation;
    }
    final run = await _orchestrator?.store.load(runId);
    final notifier = ref.read(councilConversationsProvider.notifier);
    if (run == null) return _createLocal(notifier);
    final created = notifier.createLocal(seats: run.spec.seats, mode: run.spec.mode, chairId: run.spec.chairId);
    return notifier.save(
      created.copyWith(
        title: run.spec.question,
        turns: [
          CouncilTurn(
            runId: run.id,
            question: run.spec.question,
            at: run.createdAt,
            phase: run.phase.name,
            summary: collabNotifierLead(run),
          ),
        ],
      ),
    );
  }

  /// 把会话里的回合对应的运行读进内存；没跑完的接着驱动。
  Future<void> _loadTurns(CouncilConversation conversation) async {
    final orchestrator = _orchestrator;
    if (orchestrator == null) {
      setState(() => _error = '还没连上引擎，稍等一下再发。');
      return;
    }
    var live = false;
    for (final turn in conversation.turns) {
      _seenTurns.add(turn.runId);
      // snapshot 先看内存：切回来时还在跑的席位、流式正文都在。
      final run = await orchestrator.snapshot(turn.runId);
      if (run == null) continue;
      if (run.phase.isTerminal) {
        // 视图不在的时候跑完了：把终态写回会话记录，历史里不会一直挂「运行中」。
        _syncTurn(run);
      } else {
        live = true;
      }
      if (mounted) setState(() => _runs[run.id] = run);
    }
    // 视图退出前发起的任务还在跑：回来时输入栏仍是停止态，不能重复提交。
    if (live && mounted) setState(() => _busy = true);
    final unfinished = conversation.turns.where((turn) => turn.running);
    for (final turn in unfinished) {
      unawaited(orchestrator.resume(turn.runId));
    }
    // 恢复旧会话时停在最新一轮，而不是列表顶部。
    _scrollToBottom();
  }

  /// 连接级共享：同一个引擎连接上复用同一个编排器，重连后重建。
  ///
  /// 视图来去只影响订阅；正在跑的 run 由编排器继续驱动，runId 不变，
  /// 也不会因为重新进视图再驱动一次（[CollabOrchestrator.resume] 有守卫）。
  Future<CollabOrchestrator> _ensureOrchestrator() async {
    final injected = widget.orchestrator;
    if (injected != null) return _orchestrator = injected;
    final conn = ref.read(readListLiveConnectionProvider);
    if (conn == null) throw StateError('还没有连上引擎');
    _client = conn.client;
    final shared = _shared;
    if (shared != null && identical(_sharedClient, conn.client)) return _orchestrator = shared;
    // 共享实例活得比视图久，回调里不能抓视图自己的 ref。
    final container = ProviderScope.containerOf(context, listen: false);
    final created = CollabOrchestrator(
      driver: DshCollabDriver(conn.client),
      store: CollabStore(await ref.read(councilRootProvider)()),
      // 返回 Future：编排器发消息前会等它落盘，内部会话不会先在历史里闪一下。
      onSession: (info) => container
          .read(collabSessionBookProvider.notifier)
          .register(
            CollabSessionOwner(
              sessionId: info.sessionId,
              kind: CollabSessionKind.council,
              ownerId: info.ownerId,
              label: info.label,
              parentLabel: info.parentLabel,
            ),
          ),
    );
    if (shared != null) unawaited(shared.dispose());
    _shared = created;
    _sharedClient = conn.client;
    return _orchestrator = created;
  }

  void _listen() {
    if (_sub != null) return;
    final orchestrator = _orchestrator;
    if (orchestrator == null) {
      setState(() => _error = '还没连上引擎，稍等一下再发。');
      return;
    }
    _sub = orchestrator.events.listen((run) {
      if (!mounted) return;
      // 编排器是连接级共享的：别的议会会话的事件不能进这一页。
      final conversation = _conversation;
      if (conversation != null && !conversation.turns.any((turn) => turn.runId == run.id)) return;
      _lastBeatAt = DateTime.now();
      setState(() {
        _runs[run.id] = run;
        if (run.phase.isTerminal) _busy = false;
      });
      _syncTurn(run);
      _armWaitTicker();
    });
  }

  /// 把运行的阶段与裁决首句写回会话记录（历史列表用）。
  ///
  /// 阶段变了就写：历史列表在**离开页面之后**也要显示「进行中」，不能等
  /// 终态才落盘（那样切走时历史里还是一条「已完成」的旧记录）。
  void _syncTurn(CollabRun run) {
    final conversation = _conversation;
    if (conversation == null) return;
    final index = conversation.turns.indexWhere((turn) => turn.runId == run.id);
    if (index < 0) return;
    final turn = conversation.turns[index];
    final phase = run.phase.name;
    final summary = run.phase == CollabPhase.done ? collabNotifierLead(run) : turn.summary;
    final failure = run.phase == CollabPhase.failed || run.phase == CollabPhase.cancelled ? run.failure : null;
    if (turn.phase == phase && turn.summary == summary && turn.failure == failure) return;
    final turns = [...conversation.turns];
    turns[index] = turn.copyWith(phase: phase, summary: summary, failure: failure);
    final next = conversation.copyWith(turns: turns);
    _conversation = next;
    unawaited(ref.read(councilConversationsProvider.notifier).save(next));
    _syncTaskProgress(run);
  }

  /// 把运行的阶段/结果写进任务上下文（方案第一部分 3.3 的持久化部分）。
  void _syncTaskProgress(CollabRun run) {
    final taskId = _taskId;
    if (taskId == null || taskId != run.id) return;
    final stage = switch (run.phase) {
      CollabPhase.queued || CollabPhase.round1 || CollabPhase.reviewing || CollabPhase.verifying => CollabTaskStage.running,
      CollabPhase.synthesizing => CollabTaskStage.running,
      CollabPhase.done => CollabTaskStage.done,
      CollabPhase.failed => CollabTaskStage.failed,
      CollabPhase.cancelled => CollabTaskStage.cancelled,
    };
    final answered = run.answeredCount;
    final total = run.spec.seats.length;
    final step = switch (run.phase) {
      CollabPhase.queued => '正在准备',
      CollabPhase.round1 => '成员作答 $answered/$total',
      CollabPhase.reviewing => '互相审议 $answered/$total',
      CollabPhase.verifying => '校验补漏 $answered/$total',
      CollabPhase.synthesizing => '主席综合',
      CollabPhase.done => '已完成',
      CollabPhase.failed => '失败：${run.failure ?? '未知原因'}',
      CollabPhase.cancelled => '已取消',
    };
    final result = run.phase == CollabPhase.done ? collabNotifierLead(run) : '';
    unawaited(
      ref.read(collabTaskProvider.notifier).patch(
        taskId,
        (current) => current.copyWith(
          stage: stage,
          currentStep: step,
          result: result.isEmpty ? null : result,
          failure: run.phase == CollabPhase.failed ? run.failure : null,
          done: [
            for (final seat in run.spec.seats)
              if (run.seatOf(seat.id).best?.isNotEmpty ?? false) '${seat.displayName} 已作答',
          ],
          pending: [
            for (final seat in run.spec.seats)
              if (run.seatOf(seat.id).best?.isEmpty ?? true) '${seat.displayName} 还没答',
          ],
        ),
      ),
    );
  }

  /// 席位子会话的审批：按 sessionId 认人，标明是哪一席在申请。
  void _watchApprovals() {
    if (_inbox != null) return;
    final client = _client;
    if (client == null) return;
    _inbox = CollabApprovalInbox(
      events: client.hostEvents,
      pending: client.mux.pendingRequests,
      labelOf: (sessionId) {
        for (final run in _runs.values) {
          final seat = run.seatBySession(sessionId);
          if (seat != null) return seat.displayName;
        }
        return null;
      },
      respond: (request, decision) => client.respondApproval(request, decision),
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _respond(String eventId, ApprovalDecision decision) async {
    final inbox = _inbox;
    if (inbox == null) return;
    try {
      await inbox.decide(eventId, decision);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('审批没送出去：$error')));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 发言

  /// 选附件（S6）：与普通聊天同一套选择器、上限与预算。
  Future<void> _attach() async {
    final room = maxAttachments - _drafts.length;
    if (room <= 0) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('一条消息最多 $maxAttachments 个附件')));
      return;
    }
    final choice = await showPlusPanel(context, files: true);
    if (!mounted || choice is! AttachChoice) return;
    final picker = ref.read(attachmentPickerProvider);
    final PickedAttachments picked;
    try {
      picked = switch (choice.source) {
        AttachSource.gallery => PickedAttachments(await picker.pickImages(limit: room)),
        AttachSource.camera => PickedAttachments([?await picker.takePhoto()]),
        AttachSource.files => await picker.pickFiles(limit: room, heldBytes: totalAttachmentBytes(_drafts)),
      };
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            error.code.contains('denied') || error.code.contains('permission') ? '没有相册或文件的访问权限' : '附件没能读出来：$error',
          ),
        ),
      );
      return;
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('附件没能读出来：$error')));
      return;
    }
    _addDrafts(picked.attachments, problem: picked.problem);
  }

  void _addDrafts(List<DraftAttachment> picked, {String? problem}) {
    final room = maxAttachments - _drafts.length;
    var heldBytes = totalAttachmentBytes(_drafts);
    final ok = <DraftAttachment>[];
    for (final attachment in picked) {
      final reason = attachmentProblem(attachment) ?? attachmentBudgetProblem(heldBytes, attachment);
      if (reason != null) {
        problem ??= reason;
      } else if (ok.length < room) {
        ok.add(attachment);
        heldBytes += attachment.size;
      } else {
        problem ??= '一条消息最多 $maxAttachments 个附件';
      }
    }
    if (ok.isNotEmpty) setState(() => _drafts = [..._drafts, ...ok]);
    if (problem != null && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(problem)));
    }
  }

  void _removeDraft(DraftAttachment attachment) {
    setState(
      () => _drafts = [
        for (final a in _drafts)
          if (a != attachment) a,
      ],
    );
  }

  /// 从父会话（普通聊天）的历史里检索这次要带上的资料。
  ///
  /// 用户只说了「按前面那一大段方案执行」时，方案本身在聊天记录里：这里把
  /// 早期资料型的长消息（方案、仓库、要求）和最近几轮一起取出来，任务记录
  /// 里留下消息编号，能追回原文。
  CollabContextPack _contextFor(String question) {
    final sessionId = widget.parentSessionId;
    if (sessionId == null || sessionId.isEmpty) return const CollabContextPack();
    ChatState? state;
    try {
      state = ref.read(chatProvider(sessionId));
    } on Object {
      // 没连上/还没加载：没有资料可带，正常发就是。
      state = null;
    }
    if (state == null) return const CollabContextPack();
    final history = <CollabContextMessage>[];
    for (final item in state.items) {
      if (item is UserChatItem) {
        history.add(
          CollabContextMessage(
            id: _contextMessageId(sessionId, item.requestId, item.seq),
            text: item.text,
            role: CollabContextRole.user,
          ),
        );
      } else if (item is AssistantChatItem) {
        history.add(
          CollabContextMessage(
            id: _contextMessageId(sessionId, null, item.seq),
            text: item.text,
            role: CollabContextRole.assistant,
          ),
        );
      }
    }
    return CollabContextPack.build(history: history, currentText: question);
  }

  /// 消息的稳定编号：请求 id 优先，其次会话 + 序号。
  static String _contextMessageId(String sessionId, String? requestId, int? seq) {
    if (requestId != null && requestId.isNotEmpty) return requestId;
    return '$sessionId#${seq ?? 'draft'}';
  }

  /// 预留一个运行 id（与 [CollabOrchestrator] 的默认格式同源：c + 时间）。
  ///
  /// 页面先拿它写进父会话的回合、落盘，再把同一个 id 交给编排器提交，
  /// 两边永远对得上。
  static String _reserveRunId() => 'c${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  Future<void> _send() async {
    final conversation = _conversation;
    final question = _draft.text.trim();
    final sending = _drafts;
    // S6：只有附件、没有正文也允许发送。
    if (conversation == null || (question.isEmpty && sending.isEmpty) || _busy) return;
    if (conversation.seats.length < 2) {
      setState(() => _error = '议会至少需要 2 位成员，先去成员管理里加两位。');
      return;
    }
    final orchestrator = _orchestrator;
    if (orchestrator == null) {
      setState(() => _error = '还没连上引擎，稍等一下再发。');
      return;
    }
    // 发送前自检：指代有没有资料、要提交有没有仓库与凭据。
    // 资料在另一条会话里时当场说清楚，而不是让成员回一句「本次没有具体事项」。
    final pack = _contextFor(question);
    final facts = CollabTaskFacts.scan(pack.promptBlock.isEmpty ? question : pack.promptBlock);
    final preflight = collabTaskPreflight(goal: question, pack: pack, repo: facts.repo, credentialRef: facts.credentialRef);
    if (preflight.blocking != null) {
      setState(() => _error = preflight.blocking);
      return;
    }
    _lastBeatAt = DateTime.now();
    setState(() {
      _busy = true;
      _error = preflight.notes.isEmpty ? null : preflight.notes.first;
      _pendingQuestion = question;
    });
    _draft.clear();
    setState(() => _drafts = const []);
    ref.read(conversationModeProvider.notifier).clearDraft(ConversationMode.council, _hostKey, conversation.id);
    try {
      // 下一轮沿用上一轮各席位的子会话：模型自己记得上文。
      final seeds = <String, String>{};
      for (final turn in conversation.turns.reversed) {
        final run = _runs[turn.runId];
        if (run == null) continue;
        for (final seat in run.spec.seats) {
          final sessionId = run.seatOf(seat.id).sessionId;
          if (sessionId != null && sessionId.isNotEmpty) {
            seeds.putIfAbsent(seat.id, () => sessionId);
          }
        }
        if (seeds.isNotEmpty) break;
      }
      // 资料在上面已经检索过（pack）：指代能不能对上，自检时就说清楚了。
      final spec = CouncilSpec(
        question: question.isEmpty ? '（附件）' : question,
        seats: conversation.seats,
        mode: conversation.mode,
        chairId: conversation.chairId,
        context: pack.promptBlock,
        sourceMessageIds: pack.sourceMessageIds,
        // 预计调用 + 2 次重试余量。
        budgetCalls: (conversation.seats.length * (conversation.mode == CollabMode.deliberative ? 2 : 1)) + 3,
      );
      // 先预留 runId、把回合连同它一起落盘，再启动运行（方案第六部分）。
      // 反过来的话，运行可能先落盘、先跑完，而父会话里还没有这条回合，
      // 历史里就会「找不到运行记录」。
      final runId = _reserveRunId();
      final turn = CouncilTurn(runId: runId, question: question, at: DateTime.now(), phase: CollabPhase.queued.name);
      final next = conversation.copyWith(
        title: conversation.title.trim().isEmpty ? question : conversation.title,
        turns: [...conversation.turns, turn],
      );
      setState(() => _conversation = next);
      await ref.read(councilConversationsProvider.notifier).save(next);

      // 先把「这件事」记下来（目标、资料编号、仓库/分支、成员）：
      // 切走页面、隔天说「继续」，都能靠它接上，而不是从零再问一遍。
      _taskId = runId;
      final task = collabTaskFromPack(
        id: runId,
        conversationId: conversation.id,
        kind: 'council',
        goal: question.isEmpty ? '（附件）' : question,
        pack: pack,
        memberIds: [for (final seat in conversation.seats) seat.id],
      );
      unawaited(ref.read(collabTaskProvider.notifier).upsert(task));

      final CollabRun run;
      try {
        run = await orchestrator.submit(
          spec,
          seedSessions: seeds,
          runId: runId,
          attachments: [
            for (final a in sending) CollabAttachment(name: a.name, bytes: a.bytes, mediaType: a.mediaType),
          ],
        );
      } on Object {
        // 启动失败：回合留在会话里并标明失败，用户能看到原因、也能重试。
        final current = _conversation;
        if (current != null) {
          final failed = current.copyWith(
            turns: [
              for (final item in current.turns)
                if (item.runId == runId) item.copyWith(phase: CollabPhase.failed.name) else item,
            ],
          );
          setState(() => _conversation = failed);
          await ref.read(councilConversationsProvider.notifier).save(failed);
        }
        rethrow;
      }
      _listen();
      setState(() {
        _runs[run.id] = run;
        _pendingQuestion = null;
      });
      _syncTurn(run);
      _scrollToBottom();
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _busy = false;
          _pendingQuestion = null;
        });
        // 发送失败：问题与附件都放回输入框，不丢字、不丢文件。
        if (_draft.text.isEmpty) {
          _draft.text = question;
          _draft.selection = TextSelection.collapsed(offset: question.length);
          _saveDraft(question);
        }
        if (_drafts.isEmpty) setState(() => _drafts = sending);
      }
    }
  }

  Future<void> _stop() async {
    final conversation = _conversation;
    if (conversation == null) return;
    final turn = conversation.turns.lastOrNull;
    if (turn == null) return;
    await _orchestrator?.cancel(turn.runId);
  }

  /// 任务条上的「继续」：按 runId 恢复那一次运行（没跑完的席位接着跑）。
  Future<void> _resumeTask(String runId) async {
    final orchestrator = _orchestrator;
    if (orchestrator == null) {
      setState(() => _error = '还没连上引擎，稍等一下再继续。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    _lastBeatAt = DateTime.now();
    try {
      final run = await orchestrator.resume(runId);
      if (!mounted) return;
      setState(() {
        if (run != null) _runs[run.id] = run;
        _busy = run != null && !run.phase.isTerminal;
      });
      if (run != null) _syncTurn(run);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  /// 正在触发 / 等待构建的 task（输入栏不被这条禁用）。
  String? _buildingTaskId;

  /// 打开凭据面板；保存成功后任务条上的「配置」会消失（下次构建读到新 token）。
  Future<void> _configureCredential() async {
    final changed = await showGitHubCredentialSheet(context);
    if (!mounted || !changed) return;
    setState(() {});
  }

  /// 在 GitHub 上触发仓库既有的 Actions，并把真实结果写回任务。
  Future<void> _triggerBuild(CollabTaskContext task) async {
    setState(() => _buildingTaskId = task.id);
    try {
      final result = await ref.read(collabDeliveryProvider).triggerBuild(
        repo: task.repo,
        branch: task.branch,
        interval: const Duration(seconds: 5),
      );
      if (!mounted) return;
      final updated = collabTaskWithDelivery(task, result);
      await ref.read(collabTaskProvider.notifier).patch(task.id, (current) => updated);
      setState(() => _error = result.error);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _buildingTaskId = null);
    }
  }

  /// 资料编号：复制到剪贴板（原文已经在任务条里展开了）。
  void _copySourceId(String id) {
    Clipboard.setData(ClipboardData(text: id));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('已复制消息编号 $id')));
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // 成员管理

  Future<void> _openMembers() async {
    // v3 · 7.2：还没有议会会话时，先建一条空议会再配置席位，而不是静默返回。
    CouncilConversation conversation;
    final existing = _conversation;
    if (existing != null) {
      conversation = existing;
    } else {
      conversation = _createLocal(ref.read(councilConversationsProvider.notifier));
      if (!mounted) return;
      setState(() => _conversation = conversation);
      _remember(conversation);
    }
    await showCouncilMembersSheet(
      context,
      seats: conversation.seats,
      mode: conversation.mode,
      chairId: conversation.chairId,
      onSave: (seats, mode, chairId) async {
        final next = conversation.copyWith(seats: seats, mode: mode, chairId: chairId);
        if (!mounted) return;
        setState(() => _conversation = next);
        await ref.read(councilConversationsProvider.notifier).save(next);
      },
    );
  }

  Future<void> _rename() async {
    final conversation = _conversation;
    if (conversation == null) return;
    final controller = TextEditingController(text: conversation.title);
    final next = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('会话名称'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '给这条议会起个名字'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text), child: const Text('保存')),
        ],
      ),
    );
    controller.dispose();
    if (next == null || next.trim().isEmpty || !mounted) return;
    final updated = conversation.copyWith(title: next.trim());
    setState(() => _conversation = updated);
    await ref.read(councilConversationsProvider.notifier).save(updated);
  }

  Future<void> _export() async {
    final conversation = _conversation;
    if (conversation == null || conversation.turns.isEmpty) return;
    final buffer = StringBuffer('# ${conversation.displayTitle}\n');
    for (final turn in conversation.turns) {
      final run = _runs[turn.runId];
      buffer.writeln('\n## 问：${turn.question}\n');
      if (run == null) {
        buffer.writeln('（这一轮的记录已经不在了）');
        continue;
      }
      buffer.writeln(councilMarkdown(run));
    }
    final stamp = collabStamp(conversation.updatedAt).replaceAll(RegExp(r'[: ]'), '-');
    try {
      await shareMarkdownFile(fileName: '议会-$stamp.md', content: buffer.toString());
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('导出失败：$error')));
      }
    }
  }

  Future<void> _newConversation() async {
    final conversation = _createLocal(ref.read(councilConversationsProvider.notifier));
    if (!mounted) return;
    setState(() {
      _conversation = conversation;
      _runs.clear();
      _seenTurns.clear();
      _error = null;
    });
    _remember(conversation);
    _restoreDraft(conversation);
    try {
      await ref.read(councilConversationsProvider.notifier).flush();
    } on Object catch (error) {
      if (mounted) setState(() => _error = '议会会话没能保存到本地：$error');
    }
  }

  // ---------------------------------------------------------------------------
  // 界面

  @override
  Widget build(BuildContext context) {
    // 引擎晚到/换连接：界面早就出来了，连上后自己补上编排器和运行状态。
    ref.listen(readListLiveConnectionProvider, (previous, next) {
      if (next == null) return;
      if (previous == null || !identical(previous.client, next.client)) _onConnectionChanged();
    });
    final conversation = _conversation;
    _publishHeader(conversation);
    return ConversationWorkspace(
      topInset: widget.topInset,
      banners: [
        if (_inbox?.pending.isNotEmpty ?? false)
          for (final approval in _inbox!.pending)
            CollabApprovalBanner(approval: approval, onDecide: (decision) => _respond(approval.eventId, decision)),
      ],
      body: conversation == null
          ? (_restoring ? const _RestoringNote() : _empty(null))
          : conversation.turns.isEmpty && _pendingQuestion == null
          ? _empty(conversation)
          : _messages(conversation),
      error: _error == null ? null : _errorRow(_error!),
      composer: CollabComposer(
        controller: _draft,
        busy: _busy,
        hint: conversation != null && conversation.seats.length < 2 ? '先添加至少两位成员' : '向议会提问，成员会各自作答',
        onSend: _send,
        onStop: _stop,
        onChanged: _saveDraft,
        enabled: conversation != null,
        sendable: (conversation?.seats.length ?? 0) >= 2 || _drafts.isNotEmpty,
        leading: AttachButton(onPressed: conversation == null || _busy ? null : _attach),
        hasAttachments: _drafts.isNotEmpty,
        tray: _drafts.isEmpty ? null : ComposerTray(items: _drafts, onRemove: _removeDraft),
      ),
    );
  }

  /// 把标题/状态/菜单动作发布给统一顶栏（帧后写，避免构建中通知）。
  void _publishHeader(CouncilConversation? conversation) {
    final notifier = widget.header;
    if (notifier == null) return;
    final info = CollabHeaderInfo(
      title: conversation?.displayTitle ?? '议会',
      subtitle: _subtitle(conversation),
      busy: _busy,
      failed: _latestRun(conversation)?.phase == CollabPhase.failed,
      onTitleTap: conversation == null ? null : _rename,
      onNew: _newConversation,
      actions: [
        CollabMenuAction(
          key: 'council-members',
          label: '管理成员',
          icon: AppIcons.team,
          onTap: _openMembers,
          enabled: conversation != null,
          disabledReason: '先新建一条议会会话',
        ),
        CollabMenuAction(
          key: 'council-export',
          label: '导出 Markdown',
          onTap: _export,
          enabled: conversation != null && conversation.turns.isNotEmpty,
          disabledReason: conversation == null ? '还没有议会会话' : '还没有可导出的回合',
        ),
        CollabMenuAction(
          key: 'council-history',
          label: '历史对话',
          icon: AppIcons.history,
          onTap: () => switchTab(context, RootTab.history),
          scope: CollabMenuScope.global,
        ),
      ],
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && notifier.value != info) notifier.value = info;
    });
  }

  /// 副标题：模式 + 成员数；正在跑时换成真实进度（几席已答、主席是否在综合）。
  String _subtitle(CouncilConversation? conversation) {
    final seats = conversation?.seats.length ?? 0;
    final mode = _modeLabel(conversation?.mode ?? CollabMode.quick);
    final run = _latestRun(conversation);
    if (run == null || run.phase.isTerminal) return '$seats 位成员 · $mode';
    final done = run.answeredCount;
    final phase = switch (run.phase) {
      CollabPhase.queued || CollabPhase.round1 => '$done/$seats 位已作答',
      CollabPhase.reviewing => '$done/$seats 位已答 · 互相审议中',
      CollabPhase.verifying => '$done/$seats 位已答 · 校验补漏中',
      CollabPhase.synthesizing => '主席综合中',
      _ => '$done/$seats 位已作答',
    };
    final waited = DateTime.now().difference(_lastBeatAt).inSeconds;
    return '$seats 位成员 · $phase${waited >= 8 ? ' · 已等待 $waited 秒' : ''}';
  }

  /// 运行中每秒刷新一次副标题里的等待秒数；结束就停。
  void _armWaitTicker() {
    final running = _latestRun(_conversation)?.phase.isTerminal == false;
    if (!running) {
      _waitTicker?.cancel();
      _waitTicker = null;
      return;
    }
    _waitTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_latestRun(_conversation)?.phase.isTerminal ?? true) {
        _waitTicker?.cancel();
        _waitTicker = null;
        return;
      }
      _publishHeader(_conversation);
    });
  }

  CollabRun? _latestRun(CouncilConversation? conversation) {
    final turn = conversation?.turns.lastOrNull;
    return turn == null ? null : _runs[turn.runId];
  }

  /// 出错时一行红字 + 重试：不把页面卡在转圈上。
  Widget _errorRow(String message) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(message, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
          ),
          TextButton(key: const ValueKey('council-retry'), onPressed: _retry, child: const Text('重试')),
        ],
      ),
    );
  }

  void _retry() {
    setState(() => _error = null);
    unawaited(_bootBackground());
  }

  Widget _empty(CouncilConversation? conversation) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.forum, size: 38, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text('议会已就绪', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              conversation == null || conversation.seats.isEmpty
                  ? '先加几位成员，再开始提问。'
                  : '${[for (final seat in conversation.seats) seat.displayName].join('、')} 会各自作答，主席最后综合。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            FilledButton.tonalIcon(
              key: const ValueKey('council-onboarding-add'),
              onPressed: conversation == null ? null : _openMembers,
              icon: const Icon(AppIcons.add, size: 18),
              label: Text(conversation == null || conversation.seats.length < 2 ? '添加成员' : '管理成员'),
            ),
            if (conversation != null && conversation.seats.length < 2) ...[
              const SizedBox(height: 8),
              Text(
                '模型目录还没读完也没关系：成员抽屉会单独加载，读完就能挑。',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _messages(CouncilConversation conversation) {
    final rows = <CollabTimelineRow>[];
    void add(Key key, Widget child, {double gap = 0}) =>
        rows.add(CollabTimelineRow(key: key, child: child, bottomGap: gap));
    // v3 · 4.1：任务详情不进主聊天，只留在任务工作台。
    for (final turn in conversation.turns) {
      final animate = !_seenTurns.contains(turn.runId);
      _seenTurns.add(turn.runId);
      add(ValueKey('q-${turn.runId}'), CollabUserBubble(text: turn.question, animate: animate));
      final run = _runs[turn.runId];
      if (run == null) {
        add(
          ValueKey('missing-${turn.runId}'),
          CollabSystemNote(text: turn.running ? '这一轮正在恢复…' : '这一轮的记录已经不在了'),
        );
        continue;
      }
      // v3 · 2.6：已完成的成员各自一条完整消息；正在运行的只画**一条**；
      // 还没开始的成员不再生成大消息气泡，只留一行「接下来：…」。
      final liveSeatIds = [
        for (final seat in run.spec.seats)
          if (run.activity[seat.id]?.isActive ?? false) seat.id,
      ];
      final liveSeatId = liveSeatIds.isEmpty ? null : liveSeatIds.first;
      final waitingNames = <String>[];
      for (final seat in run.spec.seats) {
        final state = run.seatOf(seat.id);
        final live = seat.id == liveSeatId;
        final activity = run.activity[seat.id];
        final hasAnswer = (state.best ?? '').trim().isNotEmpty;
        if (!live && !hasAnswer) {
          if (state.status == SeatStatus.pending) waitingNames.add(seat.displayName);
          continue;
        }
        final (status, color) = live
            ? (activity!.label, Theme.of(context).colorScheme.primary)
            : seatStatus(run, seat, Theme.of(context).colorScheme);
        final text = live && (activity?.text.trim().isNotEmpty ?? false) ? activity!.text : (state.best ?? '');
        add(
          ValueKey('seat-${run.id}-${seat.id}'),
          CollabMessage(
            brand: brandOf(seat.provider, seat.model),
            name: seat.displayName,
            model: '${brandLabel(brandOf(seat.provider, seat.model))} · ${shortModelName(seat.model)}',
            text: text,
            status: status,
            statusColor: color,
            failed: state.status == SeatStatus.failed || state.status == SeatStatus.timedOut,
            streaming: live,
            // 思考/工具状态属于这位成员自己的消息。
            thinking: live && activity?.phase == CollabActivityPhase.thinking,
            thoughtSummary: live ? (activity?.thoughtSummary ?? '') : '',
            toolName: live ? (activity?.toolName ?? '') : '',
            trailing: seat.id == run.spec.chairId
                ? CollabModeBadge(label: '主席', color: Theme.of(context).colorScheme.primary)
                : null,
            animate: animate,
          ),
        );
      }
      if (waitingNames.isNotEmpty && !run.phase.isTerminal)
        add(
          ValueKey('waiting-${run.id}'),
          CollabSystemNote(text: '接下来：${waitingNames.join('、')}'),
        );
      final verdict = run.verdict;
      if (verdict != null) {
        add(ValueKey('verdict-${run.id}'), _verdictCard(run, verdict), gap: 8);
      } else if (run.phase == CollabPhase.failed && run.failure != null) {
        add(ValueKey('failed-${run.id}'), CollabSystemNote(text: '议会没能完成：${run.failure}'));
      } else if (run.phase == CollabPhase.cancelled) {
        add(ValueKey('cancelled-${run.id}'), const CollabSystemNote(text: '这一轮已取消'));
      }
    }
    if (_pendingQuestion case final question?) {
      add(const ValueKey('pending-question'), CollabUserBubble(text: question));
      add(const ValueKey('pending-note'), const CollabSystemNote(text: '正在召集成员…'));
    }
    // 与团队共用同一条时间线：滚动方向、跟随、渐隐、留白只有一份实现。
    return CollabTimeline(
      key: ValueKey('council-timeline-${conversation.id}'),
      rows: rows,
      controller: _scroll,
    );
  }

  Widget _verdictCard(CollabRun run, String verdict) {
    final theme = Theme.of(context);
    final chair = run.spec.chair;
    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 4, right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ProviderBrandIcon(brand: brandOf(chair.provider, chair.model), size: 18, filled: true),
              const SizedBox(width: 8),
              Text('主席裁决', style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Text(
                chair.displayName,
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.18)),
            ),
            child: _verdictBody(context, verdict),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 裁决的结构化渲染

  Widget _verdictBody(BuildContext context, String verdict) {
    final theme = Theme.of(context);
    final parsed = parseVerdict(verdict);
    if (!parsed.isStructured) return MarkdownBody(text: verdict);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (parsed.conclusion case final conclusion?) MarkdownBody(text: conclusion, selectable: false),
        if (parsed.confidence case final confidence?) ...[const SizedBox(height: 8), _confidenceRow(theme, confidence)],
        if (parsed.consensus.isNotEmpty) _verdictSection(theme, '共识', parsed.consensus, theme.colorScheme.primary),
        if (parsed.disagreement.isNotEmpty)
          _verdictSection(theme, '分歧', parsed.disagreement, theme.colorScheme.tertiary),
        if (parsed.toVerify.isNotEmpty)
          _verdictSection(theme, '建议核实', parsed.toVerify, theme.colorScheme.onSurfaceVariant),
      ],
    );
  }

  Widget _confidenceRow(ThemeData theme, Confidence confidence) {
    final (label, active, color) = switch (confidence) {
      Confidence.high => ('置信度 高', 3, theme.colorScheme.primary),
      Confidence.mid => ('置信度 中', 2, theme.colorScheme.tertiary),
      Confidence.low => ('置信度 低', 1, theme.colorScheme.error),
    };
    return Row(
      children: [
        Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(width: 8),
        for (var i = 1; i <= 3; i++)
          Container(
            width: 20,
            height: 4,
            margin: const EdgeInsets.only(right: 3),
            decoration: BoxDecoration(
              color: i <= active ? color : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
      ],
    );
  }

  Widget _verdictSection(ThemeData theme, String title, List<String> items, Color accent) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 12,
                decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 6),
              Text(title, style: theme.textTheme.labelLarge),
            ],
          ),
          const SizedBox(height: 4),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(left: 9, top: 2),
              child: Text('\u00b7 $item', style: theme.textTheme.bodyMedium),
            ),
        ],
      ),
    );
  }
}

/// 冷启动恢复时本地登记表还没读完：一行小字，不挡顶栏和输入栏。
class _RestoringNote extends StatelessWidget {
  const _RestoringNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text('正在恢复上次的议会…', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

String _modeLabel(CollabMode mode) => switch (mode) {
  CollabMode.quick => '快速',
  CollabMode.deliberative => '审议',
  CollabMode.evidence => '循证',
};

/// 裁决首句：历史列表的副标题（与通知用同一套裁剪）。
String collabNotifierLead(CollabRun run) {
  final verdict = run.verdict;
  if (verdict == null || verdict.trim().isEmpty) {
    return run.phase == CollabPhase.failed ? '没能完成' : '议会';
  }
  for (final raw in verdict.split('\n')) {
    final line = raw.replaceAll(RegExp(r'^#+\s*'), '').replaceAll(RegExp(r'[*_`>]'), '').trim();
    if (line.isEmpty || line.startsWith('结论') && line.length <= 4) continue;
    return line.length <= 60 ? line : '${line.substring(0, 60)}…';
  }
  return '议会';
}
