// 团队：统一聊天工作区里的一种模式（总方案 v4）。
//
// 不再是独立整页：ChatScreen 是唯一聊天根页面，这里只提供团队的内容——
// 群聊时间线、@ 点名、成员管理、运行恢复。顶栏由统一的 ChatHeader 渲染，
// 本视图把标题/状态/菜单动作发布到 [header]。
//
// 启动分两段（方案九）：
// 第一段：只读本地 TeamStore，确定/创建团队，立刻呈现时间线和输入栏——
// 不等 TeamOrchestrator、不等引擎连接、不等历史登记。
// 第二段：后台连编排器、订阅队友状态、登记内部子会话、恢复运行/审批。
//
// 编排在 [TeamOrchestrator]（lib/team/），进程级共享：切到议会/聊天不打断
// 正在答的队友，回来还能接着看。

import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collab/collab_approval_banner.dart';
import '../../collab/collab_context_pack.dart';
import '../../collab/collab_approvals.dart';
import '../../collab/collab_export.dart';
import '../../collab/collab_session_book.dart';
import '../../council/collab_models.dart';
import '../../council/collab_orchestrator.dart';
import '../../state/attachments.dart';
import '../../state/chat_state.dart';
import '../../state/conversation_mode_state.dart';
import '../../state/hosts_state.dart';
import '../../state/models_state.dart';
import '../../state/read_list_identity.dart';
import '../../team/team_models.dart';
import '../../team/team_tasks.dart';
import '../../team/team_store.dart';
import '../../team/team_orchestrator.dart';
import '../chat/model_brand_mark.dart';
import '../chat/widgets/attachments.dart';
import '../chat/widgets/plus_panel.dart';
import '../chat/shared/conversation_mode_host.dart';
import '../chat/shared/conversation_workspace.dart';
import '../chat/model_sheet.dart' show shortModelName;
import '../shell/root_tab.dart';
import '../theme/app_icons.dart';
import '../collab/collab_kit.dart';
import '../collab/collab_timeline.dart';
import 'team_run_card.dart';
import '../collab/collab_members.dart';
import '../../collab/collab_conversations.dart' show collabHistoryProvider, teamRootProvider, teamStoreProvider;

/// 进程级共享的团队编排器：离开视图不打断在跑的队友。
TeamOrchestrator? _shared;
DshClient? _sharedClient;

class TeamModeView extends ConsumerStatefulWidget {
  const TeamModeView({
    super.key,
    this.orchestrator,
    this.teamId,
    this.createNew = true,
    this.resumeLatest = false,
    this.teamStoreRoot,
    this.header,
    this.topInset = 0,
    this.parentSessionId,
  });

  /// 测试注入用；生产为空，视图自己建（进程级共享）实例。
  final TeamOrchestrator? orchestrator;

  /// 从历史记录或通知打开的那个团队；空表示新会话。
  final String? teamId;

  /// 没给 [teamId] 时是否新建一条团队会话。
  final bool createNew;

  /// 没有指定的团队时，先恢复最近一条（冷启动恢复走这条）；
  /// 一条都没有才新建。
  final bool resumeLatest;

  /// 测试注入的团队目录；生产为空，走 [teamRootProvider]。
  final Future<Directory> Function()? teamStoreRoot;

  /// 统一顶栏的信息通道；测试里可以不接。
  final ValueNotifier<CollabHeaderInfo?>? header;

  /// 顶栏（含状态栏）高度。
  final double topInset;

  /// 这一页所在的普通聊天会话：用户「前面那一大段方案」就在它的历史里。
  /// 团队队友各自开会话，发送时从这里检索资料一并带给主管。
  final String? parentSessionId;

  @override
  ConsumerState<TeamModeView> createState() => _TeamModeViewState();
}

class _TeamModeViewState extends ConsumerState<TeamModeView> {
  final _draft = TextEditingController();

  TeamOrchestrator? _orchestrator;
  TeamStore? _store;
  StreamSubscription<TeamState>? _sub;
  CollabApprovalInbox? _inbox;
  TeamState? _team;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  /// S7：最后一次收到真实事件的时间；副标题据此显示「已等待 N 秒」。
  DateTime _lastBeatAt = DateTime.now();
  Timer? _waitTicker;

  /// 已选、未发送的附件（S6：与普通聊天同一套选择与预算）。
  List<DraftAttachment> _drafts = const [];

  /// 已经呈现过的消息：切回旧团队时不再重播每条消息的进场。
  final _seenMessages = <String>{};

  /// 时间线的滚动控制器：恢复会话后停在最新一轮，跟随规则由时间线管。
  final _scroll = ScrollController();

  late final String _hostKey = conversationHostKey(ref.read(activeHostProvider));

  @override
  void initState() {
    super.initState();
    unawaited(_bootLocal());
  }

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    _waitTicker?.cancel();
    _sub?.cancel();
    _inbox?.dispose();
    _draft.dispose();
    _scroll.dispose();
    super.dispose();
  }

  final _timers = <Timer>{};
  final _initTrace = <String, String>{};
  bool _engineBooting = false;

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
    debugPrint('[team boot] $phase: $line');
  }

  // ---------------------------------------------------------------------------
  // 第一段：只读本地 TeamStore，立刻出聊天界面（方案九）

  Future<void> _bootLocal() async {
    final watch = Stopwatch()..start();
    try {
      // 测试注入的编排器自带仓库（内存实现）；生产走本地 TeamStore。
      final override = widget.teamStoreRoot;
      final TeamStore store =
          widget.orchestrator?.store ??
          (override != null ? TeamStore(await override()) : await ref.read(teamStoreProvider.future));
      _store = store;
      _trace('teamStoreReady', watch);

      TeamState? team;
      if (widget.teamId case final id?) team = await store.load(id);
      if (team == null && widget.resumeLatest) team = await store.latest();
      if (team == null) team = await _createLocal(store);
      if (!mounted) return;
      setState(() {
        _team = team;
        _loading = false;
      });
      _remember(team);
      _restoreDraft(team);
      _seenMessages.addAll([for (final msg in team.messages) msg.id]);
      _trace('showTeam', watch);
    } on Object catch (error) {
      _trace('bootLocal', watch, error);
      if (mounted) {
        setState(() {
          _error = '团队记录没能读出来：$error';
          _loading = false;
        });
      }
    }
    // 第二段：引擎/编排器，全部后台。
    unawaited(_bootEngine());
  }

  /// 新团队：默认沿用上一个团队的队友配置（复制成独立的一份），没有就按
  /// 已缓存的模型目录给两位；目录还没到就先建一条空会话，聊天里再补。
  /// 不复制旧团队的消息与运行任务，两个团队不共享可变消息列表。
  Future<TeamState> _createLocal(TeamStore store) async {
    final mates = <Teammate>[];
    final past = await store.list();
    if (past.isNotEmpty) {
      final source = past.first;
      var index = 0;
      for (final mate in source.teammates) {
        mates.add(
          Teammate(
            id: 'mate-${DateTime.now().microsecondsSinceEpoch}-${index++}',
            name: mate.name,
            brief: mate.brief,
            provider: mate.provider,
            model: mate.model,
            reasoningEffort: mate.reasoningEffort,
            readOnly: mate.readOnly,
            agentPreset: mate.agentPreset,
          ),
        );
      }
    }
    if (mates.isEmpty) {
      final catalog = ref.read(currentModelCatalogProvider);
      if (catalog != null) {
        for (final group in catalog.groups) {
          for (final info in group.models) {
            if (mates.length >= 2) break;
            mates.add(
              Teammate(
                id: 'mate-${DateTime.now().microsecondsSinceEpoch}-${mates.length}',
                name: '队友 ${mates.length + 1}',
                provider: info.provider,
                model: info.id,
              ),
            );
          }
          if (mates.length >= 2) break;
        }
      }
    }
    final normalized = normalizeTeammates(mates);
    final now = DateTime.now();
    final state = TeamState(
      id: 't${now.microsecondsSinceEpoch.toRadixString(36)}',
      teammates: normalized,
      leadId: normalized.isNotEmpty ? normalized.first.id : null,
      createdAt: now,
      updatedAt: now,
      rev: 1,
    );
    await store.save(state);
    return state;
  }

  // ---------------------------------------------------------------------------
  // 第二段：编排器、订阅、历史登记、运行恢复（全部不挡首帧）

  Future<void> _bootEngine() async {
    if (_engineBooting) return;
    _engineBooting = true;
    try {
      final watch = Stopwatch()..start();
      final orchestrator = await _ensureOrchestratorSafely(watch);
      if (orchestrator == null || !mounted) return;
      _listen();
      // 把已经建过的团队会话补登记进协作登记表：老会话不再单列在历史里。
      unawaited(
        _registerPastSessions(orchestrator).timeout(const Duration(seconds: 6)).catchError((Object error) {
          _trace('registerPastSessions', watch, error);
        }),
      );
      // 让编排器认一遍当前团队：擦掉上次进程留下的「在跑」残影、接上定时唤醒。
      final team = _team;
      if (team != null) {
        try {
          final loaded = await _limit(orchestrator.load(team.id), const Duration(seconds: 4));
          _trace('loadTeam', watch);
          if (mounted && loaded != null && loaded.rev >= team.rev) {
            setState(() => _team = loaded);
          }
        } on Object catch (error) {
          _trace('loadTeam', watch, error);
        }
      }
      _watchApprovals();
    } finally {
      _engineBooting = false;
    }
  }

  Future<TeamOrchestrator?> _ensureOrchestratorSafely(Stopwatch watch) async {
    try {
      final orchestrator = await _limit(_ensureOrchestrator(), const Duration(seconds: 8));
      _trace('ensureOrchestrator', watch);
      return orchestrator;
    } on Object catch (error) {
      _trace('ensureOrchestrator', watch, error);
      if (mounted) setState(() => _error = '还没连上引擎，团队暂时只能看记录。');
    }
    return null;
  }

  /// 连接换了：旧订阅作废，按新客户端重建编排器。
  void _onConnectionChanged() {
    _sub?.cancel();
    _sub = null;
    _orchestrator = null;
    unawaited(_bootEngine());
  }

  void _listen() {
    if (_sub != null) return;
    final orchestrator = _orchestrator;
    if (orchestrator == null) return;
    _sub = orchestrator.events.listen((state) {
      final current = _team;
      if (!mounted || current == null || current.id != state.id) return;
      _lastBeatAt = DateTime.now();
      setState(() => _team = state);
      _invalidateHistory();
      _armWaitTicker();
    });
  }

  /// 记住这是团队「上次用的那个」：冷启动恢复时直接回到它。
  void _remember(TeamState team) {
    ref.read(conversationModeProvider.notifier).rememberTeam(_hostKey, team.id);
  }

  void _restoreDraft(TeamState team) {
    final saved = ref.read(conversationModeProvider).draftOf(ConversationMode.team, _hostKey, team.id);
    if (saved.isEmpty || _draft.text.isNotEmpty) return;
    _draft.text = saved;
    _draft.selection = TextSelection.collapsed(offset: saved.length);
  }

  /// 草稿按「模式 + 主机 + 团队」存：切走再切回来，没发的字还在。
  void _saveDraft(String _) {
    final team = _team;
    if (team == null) return;
    ref.read(conversationModeProvider.notifier).saveDraft(ConversationMode.team, _hostKey, team.id, _draft.text);
  }

  /// 把队友子会话登记进协作登记表（历史列表据此折叠）。
  Future<void> _registerPastSessions(TeamOrchestrator orchestrator) async {
    try {
      final past = await orchestrator.store.list();
      final owners = <CollabSessionOwner>[
        for (final state in past)
          for (final entry in state.sessions.entries)
            if (entry.value case final sid? when sid.isNotEmpty)
              CollabSessionOwner(
                sessionId: sid,
                kind: CollabSessionKind.team,
                ownerId: state.id,
                label: state.mate(entry.key)?.name ?? '队友',
                parentLabel: state.messages.where((m) => m.role == TeamMsgRole.user).firstOrNull?.text,
              ),
      ];
      if (owners.isNotEmpty) {
        unawaited(ref.read(collabSessionBookProvider.notifier).registerAll(owners));
      }
    } on Object {
      // 登记失败只影响历史列表的折叠。
    }
  }

  void _invalidateHistory() => ref.invalidate(collabHistoryProvider);

  /// 共享实例：同一个引擎连接上复用，重连后重建。
  Future<TeamOrchestrator> _ensureOrchestrator() async {
    final injected = widget.orchestrator;
    if (injected != null) return _orchestrator = injected;
    final conn = ref.read(readListLiveConnectionProvider);
    if (conn == null) throw StateError('还没有连上引擎');
    final existing = _shared;
    if (existing != null && identical(_sharedClient, conn.client)) return _orchestrator = existing;
    final override = widget.teamStoreRoot;
    final root = override != null ? await override() : await ref.read(teamRootProvider)();
    // 共享实例活得比视图久，回调里不能抓视图自己的 ref。
    final container = ProviderScope.containerOf(context, listen: false);
    final created = TeamOrchestrator(
      driver: DshCollabDriver(conn.client),
      store: TeamStore(root),
      // 返回 Future：编排器发消息前会等它落盘，内部会话不会先在历史里闪一下。
      onSession: (info) => container
          .read(collabSessionBookProvider.notifier)
          .register(
            CollabSessionOwner(
              sessionId: info.sessionId,
              kind: CollabSessionKind.team,
              ownerId: info.ownerId,
              label: info.label,
              parentLabel: info.parentLabel,
            ),
          ),
    );
    if (existing != null) unawaited(existing.dispose());
    _shared = created;
    _sharedClient = conn.client;
    return _orchestrator = created;
  }

  /// 队友子会话的审批：按 sessionId 认人，标明「谁在申请」。
  void _watchApprovals() {
    if (_inbox != null) return;
    final client = _sharedClient;
    if (client == null) return;
    _inbox = CollabApprovalInbox(
      events: client.hostEvents,
      // 打开视图时已经挂着的请求（通知点进来、重连）也要接住。
      pending: client.mux.pendingRequests,
      labelOf: (sessionId) => _team?.mateBySession(sessionId)?.name,
      respond: (request, decision) => client.respondApproval(request, decision),
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 群聊

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
  /// 队友的会话里只有群聊的新消息，看不见用户此前贴的方案/仓库/要求；用户
  /// 一句「按前面那个方案做」时，资料只在聊天记录里，这里补上（带消息编号）。
  CollabContextPack _contextFor(String text) {
    final sessionId = widget.parentSessionId;
    if (sessionId == null || sessionId.isEmpty) return const CollabContextPack();
    ChatState? state;
    try {
      state = ref.read(chatProvider(sessionId));
    } on Object {
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
    return CollabContextPack.build(history: history, currentText: text);
  }

  /// 消息的稳定编号：请求 id 优先，其次会话 + 序号。
  static String _contextMessageId(String sessionId, String? requestId, int? seq) {
    if (requestId != null && requestId.isNotEmpty) return requestId;
    return '$sessionId#${seq ?? 'draft'}';
  }

  Future<void> _send() async {
    final team = _team;
    final text = _draft.text.trim();
    final sending = _drafts;
    // S6：只有附件、没有正文也允许发送。
    if (team == null || (text.isEmpty && sending.isEmpty) || _busy || team.running.isNotEmpty) return;
    if (team.teammates.length < 2) {
      setState(() => _error = '团队至少需要两位队友，先去成员管理里加两位。');
      return;
    }
    final orchestrator = _orchestrator;
    if (orchestrator == null) {
      setState(() => _error = '还没连上引擎，稍等一下再发。');
      return;
    }
    _draft.clear();
    setState(() => _drafts = const []);
    ref.read(conversationModeProvider.notifier).clearDraft(ConversationMode.team, _hostKey, team.id);
    _lastBeatAt = DateTime.now();
    setState(() {
      _busy = true;
      _error = null;
    });
    _armWaitTicker();
    try {
      await orchestrator.send(
        team.id,
        text,
        context: _contextFor(text).promptBlock,
        attachments: [for (final a in sending) CollabAttachment(name: a.name, bytes: a.bytes, mediaType: a.mediaType)],
      );
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _busy = false;
        });
        // 发送失败：把话与附件都放回输入框，不丢字、不丢文件。
        if (_draft.text.isEmpty) {
          _draft.text = text;
          _draft.selection = TextSelection.collapsed(offset: text.length);
          _saveDraft(text);
        }
        if (_drafts.isEmpty) setState(() => _drafts = sending);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      _invalidateHistory();
    }
  }

  /// 应用被杀/引擎断开后从落盘的任务图继续：已完成的不会重跑。
  Future<void> _resumeRun(TeamState team) async {
    final orchestrator = _orchestrator;
    if (orchestrator == null) {
      setState(() => _error = '还没连上引擎，稍等一下再继续。');
      return;
    }
    setState(() => _busy = true);
    _lastBeatAt = DateTime.now();
    try {
      await orchestrator.resumeRun(team.id);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    final team = _team;
    if (team == null) return;
    await _orchestrator?.cancel(team.id);
  }

  Future<void> _respond(String eventId, ApprovalDecision decision) async {
    final inbox = _inbox;
    if (inbox == null) return;
    try {
      await inbox.decide(eventId, decision);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  void _insertMention(Teammate mate) {
    final text = _draft.text;
    final separator = text.isEmpty || text.endsWith(' ') ? '' : ' ';
    _draft.text = '$text$separator@${mate.name} ';
    _draft.selection = TextSelection.collapsed(offset: _draft.text.length);
    _saveDraft(_draft.text);
    setState(() {});
  }

  Future<void> _export() async {
    final team = _team;
    final store = _store;
    if (team == null || store == null) return;
    try {
      await store.writeMarkdown(team);
      await shareMarkdownFile(fileName: '团队-${team.displayTitle}.md', content: team.toMarkdown());
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  /// 点名字看这位队友的配置。
  ///
  /// 不直接跳进他的子会话——那是执行任务用的内部会话，提示词里塞着群聊背景
  /// 和角色说明，当普通聊天打开会让人以为自己在跟模型对话。这里只展示成员
  /// 信息，主记录仍是群聊。
  Future<void> _openMateInfo(TeamState team, String mateId) async {
    final mate = team.mate(mateId);
    if (mate == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CollabAvatar(brand: brandOf(mate.provider, mate.model), size: 36),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(mate.name, style: theme.textTheme.titleMedium),
                          const SizedBox(height: 2),
                          Text(
                            '${brandLabel(brandOf(mate.provider, mate.model))} · ${shortModelName(mate.model)}',
                            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    if (mate.readOnly) CollabModeBadge(label: '只读', color: theme.colorScheme.outline),
                    if (team.leadId == mate.id) CollabModeBadge(label: '主管', color: theme.colorScheme.primary),
                  ],
                ),
                if (mate.brief.trim().isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(mate.brief, style: theme.textTheme.bodyMedium),
                ],
                const SizedBox(height: 16),
                Text(
                  '他收到的任务背景只属于这个群聊；这里不单独打开他的执行会话。',
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonal(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_openMembers());
                    },
                    child: const Text('在成员管理里编辑'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _rename() async {
    final team = _team;
    if (team == null) return;
    final controller = TextEditingController(text: team.title);
    final next = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('会话名称'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text), child: const Text('保存')),
        ],
      ),
    );
    controller.dispose();
    if (next == null || next.trim().isEmpty || !mounted) return;
    final orchestrator = _orchestrator;
    if (orchestrator != null) {
      await orchestrator.rename(team.id, next.trim());
    } else {
      // 引擎还没连上：标题先落本地，连上后编排器读到的就是新标题。
      final updated = team.copyWith(title: next.trim(), updatedAt: DateTime.now());
      await _store?.save(updated);
      if (mounted) setState(() => _team = updated);
    }
    _invalidateHistory();
  }

  Future<void> _newTeam() async {
    final store = _store;
    if (store == null) return;
    final team = await _createLocal(store);
    if (!mounted) return;
    setState(() {
      _team = team;
      _error = null;
    });
    _seenMessages.clear();
    _remember(team);
    _restoreDraft(team);
    _invalidateHistory();
  }

  // ---------------------------------------------------------------------------
  // 成员管理

  Future<void> _openMembers() async {
    final team = _team;
    if (team == null) return;
    await showTeamMembersSheet(
      context,
      team: team,
      onSave: (mates, leadId) async {
        final orchestrator = _orchestrator;
        if (orchestrator == null) {
          if (mounted) setState(() => _error = '还没连上引擎，稍等一下再改成员。');
          return;
        }
        // 逐个应用：改过的队友用 updateMate，新加的用 addMate，少掉的 removeMate。
        final current = await orchestrator.load(team.id) ?? team;
        final byId = {for (final mate in mates) mate.id: mate};
        for (final mate in mates) {
          final existing = current.mate(mate.id);
          if (existing == null) {
            await orchestrator.addMate(team.id, mate);
          } else if (existing != mate) {
            await orchestrator.updateMate(team.id, mate);
          }
        }
        for (final existing in current.teammates) {
          if (!byId.containsKey(existing.id)) await orchestrator.removeMate(team.id, existing.id);
        }
        final after = await orchestrator.load(team.id) ?? current;
        if (after.leadId != leadId) await orchestrator.setLead(team.id, leadId);
        final latest = await orchestrator.load(team.id) ?? after;
        if (mounted) setState(() => _team = latest);
        _invalidateHistory();
      },
    );
  }

  Future<void> _openSettings() async {
    final team = _team;
    if (team == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final current = _team;
          if (current == null) return const SizedBox.shrink();
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text('团队设置', style: Theme.of(context).textTheme.titleMedium),
                ),
                SwitchListTile(
                  value: current.exclusiveWrite,
                  title: const Text('可写的队友排队执行'),
                  subtitle: const Text('同一时刻只让一个人动文件；只读顾问不受影响'),
                  onChanged: (on) async {
                    await _orchestrator?.setExclusiveWrite(current.id, on);
                    setSheetState(() {});
                  },
                ),
                ListTile(
                  leading: const Icon(AppIcons.history),
                  title: const Text('定时唤醒'),
                  subtitle: Text(
                    current.wakeMinutes == null ? '到点自动在群里催一句，让队友接着干' : '每 ${_wakeLabel(current.wakeMinutes!)} 催一次',
                  ),
                  trailing: DropdownButton<int?>(
                    value: current.wakeMinutes,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: null, child: Text('关')),
                      DropdownMenuItem(value: 5, child: Text('5 分钟')),
                      DropdownMenuItem(value: 10, child: Text('10 分钟')),
                      DropdownMenuItem(value: 30, child: Text('30 分钟')),
                      DropdownMenuItem(value: 60, child: Text('1 小时')),
                    ],
                    onChanged: (value) async {
                      await _orchestrator?.setWake(current.id, value);
                      setSheetState(() {});
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  static String _wakeLabel(int minutes) => minutes >= 60 && minutes % 60 == 0 ? '${minutes ~/ 60} 小时' : '$minutes 分钟';

  // ---------------------------------------------------------------------------
  // 界面

  @override
  Widget build(BuildContext context) {
    // 引擎晚到/换连接：界面早就出来了，连上后自己补上编排器和运行状态。
    ref.listen(readListLiveConnectionProvider, (previous, next) {
      if (next == null) return;
      if (previous == null || !identical(previous.client, next.client)) _onConnectionChanged();
    });
    final theme = Theme.of(context);
    final team = _team;
    _publishHeader(team);
    return ConversationWorkspace(
      topInset: widget.topInset,
      banners: [
        if (_inbox?.pending.isNotEmpty ?? false)
          for (final approval in _inbox!.pending)
            CollabApprovalBanner(
              key: ValueKey('team-approval-${approval.eventId}'),
              approval: approval,
              onDecide: (decision) => _respond(approval.eventId, decision),
            ),
      ],
      body: _loading
          ? Center(
              child: Text(
                '正在恢复上次的团队…',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            )
          : team == null
          ? const SizedBox.shrink()
          : team.teammates.isEmpty
          ? _onboarding(team)
          : _buildChat(team),
      error: _error == null
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
                  ),
                  TextButton(
                    key: const ValueKey('team-retry'),
                    onPressed: () {
                      setState(() => _error = null);
                      unawaited(_bootEngine());
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
      composer: CollabComposer(
        controller: _draft,
        // 后台还有队友在答（切走再回来）：仍显示停止键，不能重复发。
        busy: _busy || (team?.running.isNotEmpty ?? false),
        hint: '说点什么，@ 一位队友',
        onSend: _send,
        onStop: _stop,
        onChanged: _saveDraft,
        enabled: team != null,
        sendable: (team?.teammates.length ?? 0) >= 2 || _drafts.isNotEmpty,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AttachButton(onPressed: team == null || _busy ? null : _attach),
            if (team != null && team.teammates.isNotEmpty)
              PopupMenuButton<Teammate>(
                key: const ValueKey('team-mention'),
                tooltip: '点名',
                icon: const Icon(AppIcons.mention, size: 20),
                onSelected: _insertMention,
                itemBuilder: (_) => [
                  for (final mate in team.teammates) PopupMenuItem(value: mate, child: Text(mate.name)),
                ],
              ),
          ],
        ),
        hasAttachments: _drafts.isNotEmpty,
        tray: _drafts.isEmpty ? null : ComposerTray(items: _drafts, onRemove: _removeDraft),
      ),
    );
  }

  /// 运行中每秒刷新副标题里的等待秒数；没有队友在跑就停。
  void _armWaitTicker() {
    final running = _busy || (_team?.running.isNotEmpty ?? false);
    if (!running) {
      _waitTicker?.cancel();
      _waitTicker = null;
      return;
    }
    _waitTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!_busy && (_team?.running.isEmpty ?? true)) {
        _waitTicker?.cancel();
        _waitTicker = null;
        return;
      }
      _publishHeader(_team);
    });
  }

  /// 把标题/状态/菜单动作发布给统一顶栏（帧后写，避免构建中通知）。
  void _publishHeader(TeamState? team) {
    final notifier = widget.header;
    if (notifier == null) return;
    final running = team?.running.isNotEmpty ?? false;
    final waited = DateTime.now().difference(_lastBeatAt).inSeconds;
    final info = CollabHeaderInfo(
      title: team?.displayTitle ?? '团队',
      subtitle:
          ['${team?.teammates.length ?? 0} 位队友', if (team?.lead case final lead?) '主管 ${lead.name}'].join(' · ') +
          (running && waited >= 8 ? ' · 已等待 $waited 秒' : ''),
      busy: _busy || running,
      onTitleTap: team == null ? null : _rename,
      onNew: _newTeam,
      actions: [
        CollabMenuAction(key: 'team-members', label: '管理成员', icon: AppIcons.team, onTap: _openMembers),
        CollabMenuAction(key: 'team-settings', label: '团队设置', onTap: _openSettings),
        CollabMenuAction(key: 'team-export', label: '导出 Markdown', onTap: _export),
        CollabMenuAction(key: 'team-history', label: '历史团队', onTap: () => switchTab(context, RootTab.history)),
      ],
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && notifier.value != info) notifier.value = info;
    });
  }

  /// 首次进来还没有队友：聊天区里一块紧凑的初始化面板，加完就地回到聊天。
  Widget _onboarding(TeamState team) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.team, size: 38, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text('先加两位队友', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              '每位队友各用各的模型、各记各的上下文。发消息时 @ 谁，谁回答；不点名就大家一起答。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            FilledButton.tonalIcon(
              key: const ValueKey('team-onboarding-add'),
              onPressed: _openMembers,
              icon: const Icon(AppIcons.add, size: 18),
              label: const Text('添加队友'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChat(TeamState team) {
    final messages = team.messages;
    // 正在说的那一位：默认顺序分派，同一时刻只会有一位（方案第五部分）。
    // 万一底层还留着并发（旧版本的可选并行），这里也只挑最靠前的一位显示
    // 成活动气泡，其余的内容仍会随落盘消息出现，不会堆在聊天顶部。
    final active = [
      for (final id in team.running)
        if (team.activity[id] case final activity? when activity.isActive) id,
    ];
    final liveId = active.firstOrNull;
    final rows = <CollabTimelineRow>[];
    // 任务图是辅助详情：放在时间线最上面，默认收起。
    if (team.run case final run?) {
      rows.add(
        CollabTimelineRow(
          key: const ValueKey('team-run-row'),
          child: TeamRunCard(
            team: team,
            run: run,
            busy: _busy,
            onResume: () => unawaited(_resumeRun(team)),
            onCancel: _stop,
          ),
        ),
      );
    }
    for (final msg in messages) {
      rows.add(CollabTimelineRow(key: ValueKey('team-msg-${msg.id}'), child: _bubble(team, msg)));
    }
    if (liveId != null) {
      final activity = team.activity[liveId]!;
      rows.add(
        CollabTimelineRow(
          key: ValueKey('live-${team.id}-$liveId'),
          child: _liveBubble(team, liveId, activity),
        ),
      );
    }
    if (rows.isEmpty) return _emptyChat(team);
    // 与议会共用同一条时间线：滚动、跟随、渐隐、留白只有一份实现。
    return CollabTimeline(
      key: ValueKey('team-timeline-${team.id}'),
      rows: rows,
      controller: _scroll,
      footer: active.length > 1
          // 旧数据里可能还有多位同时在跑：只留一句提示，不再让它们各占一个
          // 活动气泡（方案：同一时间只有一个活动成员的主聊天流）。
          ? CollabSystemNote(text: '还有 ${active.length - 1} 位队友在后台收尾')
          : null,
    );
  }

  /// 一位队友正在跑的那一行：头像、名字、真实阶段，正文边收边长。
  Widget _liveBubble(TeamState team, String mateId, CollabActivity activity) {
    final mate = team.mate(mateId);
    final brand = mate == null ? ModelBrand.other : brandOf(mate.provider, mate.model);
    return CollabMessage(
      key: ValueKey('live-${team.id}-$mateId'),
      brand: brand,
      name: mate?.name ?? '队友',
      model: mate == null ? null : '${brandLabel(brand)} · ${shortModelName(mate.model)}',
      text: activity.text,
      status: activity.label,
      statusColor: Theme.of(context).colorScheme.primary,
      streaming: true,
    );
  }

  Widget _emptyChat(TeamState team) {
    final theme = Theme.of(context);
    final names = [for (final mate in team.teammates) mate.name].join('、');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.team, size: 38, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              '$names 都在群里了。',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              '直接说事，或者 @ 其中一位。',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(TeamState team, TeamMsg msg) {
    final animate = !_seenMessages.contains(msg.id);
    _seenMessages.add(msg.id);
    if (msg.role == TeamMsgRole.system) return CollabSystemNote(text: msg.text);
    if (msg.role == TeamMsgRole.user) return CollabUserBubble(text: msg.text, animate: animate);

    final mate = msg.teammateId == null ? null : team.mate(msg.teammateId!);
    final handoff = msg.handoffTo == null ? null : team.mate(msg.handoffTo!);
    final text = handoff == null ? msg.text : '${msg.text}\n\n> 交给 ${handoff.name} 接着做';
    return CollabMessage(
      key: ValueKey('team-msg-${msg.id}'),
      brand: mate == null ? ModelBrand.other : brandOf(mate.provider, mate.model),
      name: mate?.name ?? '队友',
      text: text,
      failed: msg.failed,
      animate: animate,
      model: mate == null ? null : '${brandLabel(brandOf(mate.provider, mate.model))} · ${shortModelName(mate.model)}',
      onNameTap: mate == null ? null : () => _openMateInfo(team, mate.id),
    );
  }

}
