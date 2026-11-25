// 议会：一个真正的聊天模式（方案第一部分）。
//
// 点「议会」= 新建一条议会会话并直接进聊天：顶部是模式标识、标题和成员入口，
// 中间是消息流（我的问题 → 各席位的独立回答 → 主席裁决），底部是和普通聊天
// 一样的输入栏。可以一直追问：下一轮沿用同一批席位的子会话，所以模型记得上文。
//
// 编排仍在 [CollabOrchestrator]（lib/council/），页面只管界面与「这条会话
// 有哪些回合」。成员配置收进成员抽屉（ui/collab/collab_members.dart），
// 关掉抽屉回到聊天，不重建、不清空记录。

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collab/collab_approval_banner.dart';
import '../../collab/collab_approvals.dart';
import '../../collab/collab_conversations.dart';
import '../../collab/collab_export.dart';
import '../../collab/collab_session_book.dart';
import '../../council/collab_models.dart';
import '../../council/collab_orchestrator.dart';
import '../../council/collab_store.dart';
import '../../council/verdict_parser.dart';
import '../../state/models_state.dart';
import '../../state/read_list_identity.dart';
import '../providers/provider_brand_icon.dart';
import '../shell/root_tab.dart';
import '../theme/app_icons.dart';
import '../collab/collab_members.dart';
import '../collab/collab_kit.dart';
import '../chat/render/markdown_body.dart';

class CouncilPage extends ConsumerStatefulWidget {
  const CouncilPage({
    super.key,
    this.orchestrator,
    this.runId,
    this.conversationId,
    this.createNew = true,
  });

  /// 测试注入用；生产为空，页面自己建实例。
  final CollabOrchestrator? orchestrator;

  /// 从通知或旧数据直接打开的那次运行；空表示新会话或 [conversationId]。
  final String? runId;

  /// 从历史记录打开的议会会话。
  final String? conversationId;

  /// 没给 [conversationId] / [runId] 时是否新建一条会话。
  final bool createNew;

  @override
  ConsumerState<CouncilPage> createState() => _CouncilPageState();
}

class _CouncilPageState extends ConsumerState<CouncilPage> {
  final _draft = TextEditingController();

  CollabOrchestrator? _orchestrator;
  DshClient? _client;
  CollabApprovalInbox? _inbox;
  StreamSubscription<CollabRun>? _sub;
  CouncilConversation? _conversation;
  final _runs = <String, CollabRun>{};
  bool _busy = false;
  bool _loading = true;
  String? _error;
  final _scroll = ScrollController();

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
    _scroll.dispose();
    // 注入的编排器归测试管；自建的才在离开页面时关掉。
    if (widget.orchestrator == null) unawaited(_orchestrator?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 启动：开一条会话（或恢复给定的那条）

  Future<void> _boot() async {
    try {
      final orchestrator = await _ensureOrchestrator();
      // 先等登记表把盘上的旧会话读进来：从历史打开时才找得到那条。
      await ref.read(councilConversationsProvider.notifier).ready;
      _listen();
      // 历史运行的席位会话补登记：否则会一条条冒进普通聊天历史。
      await _registerPastSessions(orchestrator);

      CouncilConversation? conversation;
      if (widget.conversationId case final id?) {
        conversation = ref.read(councilConversationsProvider)[id];
      }
      if (conversation == null) {
        final runId = widget.runId;
        if (runId != null) conversation = await _conversationForRun(runId);
      }
      conversation ??= widget.createNew ? await _createConversation() : null;
      if (!mounted) return;
      setState(() {
        _conversation = conversation;
        _loading = false;
      });
      if (conversation != null) await _loadTurns(conversation);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _loading = false;
        });
      }
    } finally {
      _watchApprovals();
    }
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
    if (run == null) return _createConversation();
    final notifier = ref.read(councilConversationsProvider.notifier);
    final created = await notifier.create(seats: run.spec.seats, mode: run.spec.mode, chairId: run.spec.chairId);
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

  /// 新会话：默认沿用上次议会的成员配置，复制成独立的一份。
  Future<CouncilConversation> _createConversation() async {
    final notifier = ref.read(councilConversationsProvider.notifier);
    final last = notifier.latest();
    if (last != null && last.seats.length >= 2) {
      return notifier.create(seats: last.seats, mode: last.mode, chairId: last.chairId);
    }
    final ModelCatalog? catalog = await ref.read(modelCatalogProvider.future).catchError((_) => null);
    final seats = <SeatSpec>[];
    if (catalog != null) {
      for (final group in catalog.groups) {
        for (final info in group.models) {
          if (seats.length >= 2) break;
          seats.add(
            SeatSpec(
              id: 'seat${seats.length}',
              provider: info.provider,
              model: info.id,
              label: info.name,
            ),
          );
        }
        if (seats.length >= 2) break;
      }
    }
    return notifier.create(seats: seats);
  }

  /// 把会话里的回合对应的运行读进内存；没跑完的接着驱动。
  Future<void> _loadTurns(CouncilConversation conversation) async {
    final orchestrator = _orchestrator;
    if (orchestrator == null) return;
    for (final turn in conversation.turns) {
      final run = await orchestrator.store.load(turn.runId);
      if (run != null && mounted) setState(() => _runs[run.id] = run);
    }
    final unfinished = conversation.turns.where((turn) => turn.running);
    for (final turn in unfinished) {
      unawaited(orchestrator.resume(turn.runId));
    }
  }

  Future<CollabOrchestrator> _ensureOrchestrator() async {
    final existing = _orchestrator ?? widget.orchestrator;
    if (existing != null) {
      _orchestrator = existing;
      return existing;
    }
    final conn = ref.read(readListLiveConnectionProvider);
    if (conn == null) throw StateError('还没有连上引擎');
    _client = conn.client;
    final orchestrator = CollabOrchestrator(
      driver: DshCollabDriver(conn.client),
      store: CollabStore(await ref.read(councilRootProvider)()),
      onSession: (info) {
        unawaited(
          ref
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
      },
    );
    _orchestrator = orchestrator;
    return orchestrator;
  }

  void _listen() {
    if (_sub != null) return;
    final orchestrator = _orchestrator;
    if (orchestrator == null) return;
    _sub = orchestrator.events.listen((run) {
      if (!mounted) return;
      setState(() {
        _runs[run.id] = run;
        if (run.phase.isTerminal) _busy = false;
      });
      _syncTurn(run);
    });
  }

  /// 运行结束时把阶段与裁决首句写回会话记录（历史列表用）。
  void _syncTurn(CollabRun run) {
    final conversation = _conversation;
    if (conversation == null) return;
    final index = conversation.turns.indexWhere((turn) => turn.runId == run.id);
    if (index < 0) return;
    if (!run.phase.isTerminal) return;
    final turns = [...conversation.turns];
    turns[index] = turns[index].copyWith(phase: run.phase.name, summary: collabNotifierLead(run));
    final next = conversation.copyWith(turns: turns);
    _conversation = next;
    unawaited(ref.read(councilConversationsProvider.notifier).save(next));
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

  Future<void> _send() async {
    final conversation = _conversation;
    final question = _draft.text.trim();
    if (conversation == null || question.isEmpty || _busy) return;
    if (conversation.seats.length < 2) {
      setState(() => _error = '议会至少需要 2 位成员，先去成员管理里加两位。');
      return;
    }
    final orchestrator = _orchestrator;
    if (orchestrator == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    _draft.clear();
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
      final spec = CouncilSpec(
        question: question,
        seats: conversation.seats,
        mode: conversation.mode,
        chairId: conversation.chairId,
        // 预计调用 + 2 次重试余量。
        budgetCalls: (conversation.seats.length * (conversation.mode == CollabMode.deliberative ? 2 : 1)) + 3,
      );
      final run = await orchestrator.submit(spec, seedSessions: seeds);
      _listen();
      final turn = CouncilTurn(runId: run.id, question: question, at: DateTime.now(), phase: run.phase.name);
      final next = conversation.copyWith(
        title: conversation.title.trim().isEmpty ? question : conversation.title,
        turns: [...conversation.turns, turn],
      );
      setState(() {
        _conversation = next;
        _runs[run.id] = run;
      });
      await ref.read(councilConversationsProvider.notifier).save(next);
      // 跑得快的运行可能在回合写进会话之前就已经结束：用最新快照补一次阶段。
      _syncTurn(_runs[run.id] ?? run);
      _scrollToBottom();
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _busy = false;
        });
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
    final conversation = _conversation;
    if (conversation == null) return;
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
    final conversation = await _createConversation();
    if (!mounted) return;
    setState(() {
      _conversation = conversation;
      _runs.clear();
      _error = null;
    });
  }

  // ---------------------------------------------------------------------------
  // 界面

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final conversation = _conversation;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            CollabHeader(
              title: conversation?.displayTitle ?? '议会',
              subtitle: [
                _modeLabel(conversation?.mode ?? CollabMode.quick),
                '${conversation?.seats.length ?? 0} 位成员',
              ].join(' · '),
              badge: CollabModeBadge(label: '议会', color: theme.colorScheme.primary),
              onTitleTap: _rename,
              actions: [
                IconButton(
                  key: const ValueKey('council-members'),
                  tooltip: '成员',
                  icon: const Icon(AppIcons.team, size: 21),
                  onPressed: conversation == null ? null : _openMembers,
                ),
                PopupMenuButton<String>(
                  tooltip: '更多',
                  icon: const Icon(AppIcons.more, size: 20),
                  onSelected: (value) {
                    switch (value) {
                      case 'export':
                        unawaited(_export());
                      case 'new':
                        unawaited(_newConversation());
                      case 'history':
                        switchTab(context, RootTab.history);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'export', child: Text('导出 Markdown')),
                    PopupMenuItem(value: 'new', child: Text('新议会')),
                    PopupMenuItem(value: 'history', child: Text('历史议会')),
                  ],
                ),
              ],
            ),
            if (_inbox?.pending.isNotEmpty ?? false)
              for (final approval in _inbox!.pending)
                CollabApprovalBanner(
                  approval: approval,
                  onDecide: (decision) => _respond(approval.eventId, decision),
                ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : conversation == null || conversation.turns.isEmpty
                  ? _empty(conversation)
                  : _messages(conversation),
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
              hint: '向议会提问，成员会各自作答',
              onSend: _send,
              onStop: _stop,
              enabled: conversation != null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(CouncilConversation? conversation) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.team, size: 38, color: theme.colorScheme.outline),
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
            OutlinedButton.icon(
              onPressed: conversation == null ? null : _openMembers,
              icon: const Icon(AppIcons.team, size: 18),
              label: const Text('管理成员'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _messages(CouncilConversation conversation) {
    final children = <Widget>[];
    for (final turn in conversation.turns) {
      children.add(CollabUserBubble(key: ValueKey('q-${turn.runId}'), text: turn.question));
      final run = _runs[turn.runId];
      if (run == null) {
        children.add(
          CollabSystemNote(
            key: ValueKey('missing-${turn.runId}'),
            text: turn.running ? '这一轮正在恢复…' : '这一轮的记录已经不在了',
          ),
        );
        continue;
      }
      // 各席位独立作答：一位一条，绝不混在一条消息里。
      for (final seat in run.spec.seats) {
        final state = run.seatOf(seat.id);
        final (status, color) = seatStatus(run, seat, Theme.of(context).colorScheme);
        final text = state.best ?? '';
        children.add(
          CollabMessage(
            key: ValueKey('seat-${run.id}-${seat.id}'),
            brand: brandOf(seat.provider, seat.model),
            name: seat.displayName,
            text: text.isEmpty ? (state.status == SeatStatus.pending ? '等待作答' : '（没有产出内容）') : text,
            status: status,
            statusColor: color,
            failed: state.status == SeatStatus.failed || state.status == SeatStatus.timedOut,
            streaming: state.status == SeatStatus.running,
            trailing: seat.id == run.spec.chairId
                ? CollabModeBadge(label: '主席', color: Theme.of(context).colorScheme.primary)
                : null,
          ),
        );
      }
      final verdict = run.verdict;
      if (verdict != null) {
        children.add(const SizedBox(height: 4));
        children.add(_verdictCard(run, verdict));
      } else if (run.phase == CollabPhase.failed && run.failure != null) {
        children.add(CollabSystemNote(text: '议会没能完成：${run.failure}'));
      } else if (run.phase == CollabPhase.cancelled) {
        children.add(const CollabSystemNote(text: '这一轮已取消'));
      }
    }
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      children: children,
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
        if (parsed.confidence case final confidence?) ...[
          const SizedBox(height: 8),
          _confidenceRow(theme, confidence),
        ],
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
      final line = raw
          .replaceAll(RegExp(r'^#+\s*'), '')
          .replaceAll(RegExp(r'[*_`>]'), '')
          .trim();
      if (line.isEmpty || line.startsWith('结论') && line.length <= 4) continue;
      return line.length <= 60 ? line : '${line.substring(0, 60)}…';
    }
  return '议会';
}
