// 团队：几位队友在一个群里，谁被 @ 谁回答（方案第二部分）。
//
// 点「团队」= 新建一条团队会话并直接进群聊：顶部是模式标识、标题和成员入口，
// 中间是群聊记录，底部是和普通聊天一样的输入栏。建队表单不再占满整页——
// 第一次进来若还没有队友，聊天区里给一块紧凑的初始化面板，加完就地回到聊天。
//
// 编排在 [TeamOrchestrator]（lib/team/），这里只管界面。页面的编排器是
// 进程级共享的：退出页面不打断正在答的队友，回来还能接着看。队友的审批请求
// 在这里标出「是谁在申请」。

import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collab/collab_approval_banner.dart';
import '../../collab/collab_approvals.dart';
import '../../collab/collab_export.dart';
import '../../collab/collab_session_book.dart';
import '../../council/collab_orchestrator.dart';
import '../../state/models_state.dart';
import '../../state/read_list_identity.dart';
import '../../state/sessions_state.dart';
import '../../team/team_models.dart';
import '../../team/team_store.dart';
import '../../team/team_orchestrator.dart';
import '../chat/model_brand_mark.dart';
import '../chat/model_sheet.dart' show shortModelName;
import '../shell/root_tab.dart';
import '../theme/app_icons.dart';
import '../collab/collab_kit.dart';
import '../collab/collab_members.dart';
import '../../collab/collab_conversations.dart' show collabHistoryProvider, teamRootProvider;

/// 进程级共享的团队编排器：离开页面不打断在跑的队友。
TeamOrchestrator? _shared;
DshClient? _sharedClient;

class TeamPage extends ConsumerStatefulWidget {
  const TeamPage({
    super.key,
    this.orchestrator,
    this.teamId,
    this.createNew = true,
    this.teamStoreRoot,
  });

  /// 测试注入用；生产为空，页面自己建（进程级共享）实例。
  final TeamOrchestrator? orchestrator;

  /// 从历史记录或通知打开的那个团队；空表示新会话。
  final String? teamId;

  /// 没给 [teamId] 时是否新建一条团队会话。
  final bool createNew;

  /// 测试注入的团队目录；生产为空，走 [teamRootProvider]。
  final Future<Directory> Function()? teamStoreRoot;

  @override
  ConsumerState<TeamPage> createState() => _TeamPageState();
}

class _TeamPageState extends ConsumerState<TeamPage> {
  final _draft = TextEditingController();

  TeamOrchestrator? _orchestrator;
  StreamSubscription<TeamState>? _sub;
  CollabApprovalInbox? _inbox;
  TeamState? _team;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _inbox?.dispose();
    _draft.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final orchestrator = await _ensureOrchestrator();
      _orchestrator = orchestrator;
      _sub = orchestrator.events.listen((state) {
        final current = _team;
        if (!mounted || current == null || current.id != state.id) return;
        setState(() => _team = state);
        _invalidateHistory();
      });
      // 把已经建过的团队会话补登记进协作登记表：老会话不再单列在历史里。
      await _registerPastSessions(orchestrator);

      TeamState? team;
      if (widget.teamId case final id?) team = await orchestrator.load(id);
      if (team == null && widget.createNew) team = await _createDefaultTeam(orchestrator);
      team ??= await orchestrator.latest();
      if (!mounted) return;
      setState(() {
        _team = team;
        _loading = false;
      });
      _watchApprovals();
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _loading = false;
        });
      }
    }
  }

  /// 新团队：默认沿用上一个团队的队友配置（复制成独立的一份），没有就按
  /// 模型目录给两位；目录还没到就先建一条空会话，聊天里再补。
  Future<TeamState> _createDefaultTeam(TeamOrchestrator orchestrator) async {
    final mates = <Teammate>[];
    final past = await orchestrator.store.list();
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
      final ModelCatalog? catalog = await ref.read(modelCatalogProvider.future).catchError((_) => null);
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
    return orchestrator.create(teammates: mates, leadId: mates.isNotEmpty ? mates.first.id : null, allowEmpty: true);
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
    if (injected != null) return injected;
    final conn = ref.read(readListLiveConnectionProvider);
    if (conn == null) throw StateError('还没有连上引擎');
    final existing = _shared;
    if (existing != null && identical(_sharedClient, conn.client)) return existing;
    final override = widget.teamStoreRoot;
    final root = override != null ? await override() : await ref.read(teamRootProvider)();
    final created = TeamOrchestrator(
      driver: DshCollabDriver(conn.client),
      store: TeamStore(root),
      onSession: (info) {
        unawaited(
          ref
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
      },
    );
    if (existing != null) unawaited(existing.dispose());
    _shared = created;
    _sharedClient = conn.client;
    return created;
  }

  /// 队友子会话的审批：按 sessionId 认人，标明「谁在申请」。
  void _watchApprovals() {
    if (_inbox != null) return;
    final client = _sharedClient;
    if (client == null) return;
    _inbox = CollabApprovalInbox(
      events: client.hostEvents,
      // 打开页面时已经挂着的请求（通知点进来、重连）也要接住。
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

  Future<void> _send() async {
    final team = _team;
    final text = _draft.text.trim();
    if (team == null || text.isEmpty || _busy) return;
    if (team.teammates.length < 2) {
      setState(() => _error = '团队至少需要两位队友，先去成员管理里加两位。');
      return;
    }
    _draft.clear();
    setState(() {
      _busy = true;
      _error = null;
    });
    final orchestrator = _orchestrator;
    if (orchestrator == null) return;
    try {
      await orchestrator.send(team.id, text);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
      _invalidateHistory();
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
    setState(() {});
  }

  Future<void> _export() async {
    final team = _team;
    final orchestrator = _orchestrator;
    if (team == null || orchestrator == null) return;
    try {
      await orchestrator.store.writeMarkdown(team);
      await shareMarkdownFile(fileName: '团队-${team.displayTitle}.md', content: team.toMarkdown());
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  /// 打开某位队友的完整对话（这些会话不在历史列表里，只从这里进）。
  void _openMateSession(TeamState team, String mateId) {
    final sessionId = team.sessions[mateId];
    if (sessionId == null || sessionId.isEmpty) return;
    ref.read(currentSessionProvider.notifier).select(sessionId);
    switchTab(context, RootTab.chat);
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
    await _orchestrator?.rename(team.id, next.trim());
    _invalidateHistory();
  }

  Future<void> _newTeam() async {
    final orchestrator = _orchestrator;
    if (orchestrator == null) return;
    final team = await _createDefaultTeam(orchestrator);
    if (!mounted) return;
    setState(() {
      _team = team;
      _error = null;
    });
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
        if (orchestrator == null) return;
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
    final theme = Theme.of(context);
    final team = _team;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            CollabHeader(
              title: team?.displayTitle ?? '团队',
              subtitle: [
                '${team?.teammates.length ?? 0} 位队友',
                if (team?.lead case final lead?) '主管 ${lead.name}',
              ].join(' · '),
              badge: CollabModeBadge(label: '团队', color: theme.colorScheme.tertiary),
              onTitleTap: team == null ? null : _rename,
              actions: [
                IconButton(
                  key: const ValueKey('team-members'),
                  tooltip: '成员',
                  icon: const Icon(AppIcons.team, size: 21),
                  onPressed: team == null ? null : _openMembers,
                ),
                PopupMenuButton<String>(
                  tooltip: '更多',
                  icon: const Icon(AppIcons.more, size: 20),
                  onSelected: (value) {
                    switch (value) {
                      case 'settings':
                        unawaited(_openSettings());
                      case 'export':
                        unawaited(_export());
                      case 'new':
                        unawaited(_newTeam());
                      case 'history':
                        switchTab(context, RootTab.history);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'settings', child: Text('团队设置')),
                    PopupMenuItem(value: 'export', child: Text('导出 Markdown')),
                    PopupMenuItem(value: 'new', child: Text('新团队')),
                    PopupMenuItem(value: 'history', child: Text('历史团队')),
                  ],
                ),
              ],
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : team == null
                  ? const SizedBox.shrink()
                  : team.teammates.isEmpty
                  ? _onboarding(team)
                  : _buildChat(team),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            CollabComposer(
              controller: _draft,
              busy: _busy,
              hint: '说点什么，@ 一位队友',
              onSend: _send,
              onStop: _stop,
              enabled: team != null,
              leading: team == null || team.teammates.isEmpty
                  ? null
                  : PopupMenuButton<Teammate>(
                      tooltip: '点名',
                      icon: const Icon(AppIcons.mention, size: 20),
                      onSelected: _insertMention,
                      itemBuilder: (_) => [
                        for (final mate in team.teammates) PopupMenuItem(value: mate, child: Text(mate.name)),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
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
    return Column(
      children: [
        if (_inbox?.pending.isNotEmpty ?? false)
          for (final approval in _inbox!.pending)
            CollabApprovalBanner(
              key: ValueKey('team-approval-${approval.eventId}'),
              approval: approval,
              onDecide: (decision) => _respond(approval.eventId, decision),
            ),
        if (team.running.isNotEmpty) _runningBar(team),
        Expanded(
          child: messages.isEmpty && !_busy
              ? _emptyChat(team)
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  itemCount: messages.length + (_busy ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (_busy && index == 0) return _typingRow();
                    final offset = _busy ? 1 : 0;
                    return _bubble(team, messages[messages.length - 1 - (index - offset)]);
                  },
                ),
        ),
      ],
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

  Widget _typingRow() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 8),
          Text('队友在想…', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _bubble(TeamState team, TeamMsg msg) {
    if (msg.role == TeamMsgRole.system) return CollabSystemNote(text: msg.text);
    if (msg.role == TeamMsgRole.user) return CollabUserBubble(text: msg.text);

    final mate = msg.teammateId == null ? null : team.mate(msg.teammateId!);
    final handoff = msg.handoffTo == null ? null : team.mate(msg.handoffTo!);
    final text = handoff == null ? msg.text : '${msg.text}\n\n> 交给 ${handoff.name} 接着做';
    return CollabMessage(
      key: ValueKey('team-msg-${msg.id}'),
      brand: mate == null ? ModelBrand.other : brandOf(mate.provider, mate.model),
      name: mate?.name ?? '队友',
      text: text,
      failed: msg.failed,
      onNameTap: mate == null ? null : () => _openMateSession(team, mate.id),
      status: mate == null
          ? null
          : '${brandLabel(brandOf(mate.provider, mate.model))} · ${shortModelName(mate.model)}',
    );
  }

  /// 「谁在跑」：状态每步落盘，切走再回来、乃至重开 App 都看得到。
  Widget _runningBar(TeamState team) {
    final theme = Theme.of(context);
    final names = [for (final id in team.running) team.mate(id)?.name ?? '队友'];
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(AppIcons.queued, size: 14, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${names.join('、')} 正在跑…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
