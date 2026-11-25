// 团队（C4）：几位队友在一个群里，谁被 @ 谁回答。
//
// 页面两个形态：
// - 建队：给每位队友起名字、写一句角色说明、选一个模型（2 到 6 位）；
// - 群聊：消息流（我 / 队友 / 系统）、@ 点名、停止、成员管理、导出。
//
// 编排在 [TeamOrchestrator]（lib/team/），这里只管界面。页面的编排器是
// 进程级共享的：退出页面不打断正在答的队友，回来还能接着看。
// 队友的审批请求在这里标出「是谁在申请」——子会话的审批卡原本只在
// 单独打开那个子会话时才看得到。

import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../council/collab_orchestrator.dart';
import '../../notify/chat_alerts.dart' show approvalText;
import '../../state/models_state.dart';
import '../../state/read_list_identity.dart';
import '../../team/team_models.dart';
import '../../team/team_orchestrator.dart';
import '../../team/team_store.dart';
import '../chat/model_brand_mark.dart';

/// 进程级共享的团队编排器：离开页面不打断在跑的队友。
TeamOrchestrator? _shared;
DshClient? _sharedClient;

/// 模型下拉里的一项。
typedef _ModelChoice = ({String key, String label, String provider, String id});

/// 建队时一位队友的草稿（输入框要活着，所以用 controller）。
class _MateDraft {
  _MateDraft({String name = '', String brief = '', this.modelKey})
    : nameController = TextEditingController(text: name),
      briefController = TextEditingController(text: brief);

  final TextEditingController nameController;
  final TextEditingController briefController;
  String? modelKey;

  void dispose() {
    nameController.dispose();
    briefController.dispose();
  }
}

class TeamPage extends ConsumerStatefulWidget {
  const TeamPage({super.key, this.orchestrator});

  /// 测试注入用；生产为空，页面自己建（进程级共享）实例。
  final TeamOrchestrator? orchestrator;

  @override
  ConsumerState<TeamPage> createState() => _TeamPageState();
}

class _TeamPageState extends ConsumerState<TeamPage> {
  final _draft = TextEditingController();
  final _mates = <_MateDraft>[];
  final _pending = <String, ({String mate, ApprovalRequest request})>{};

  TeamOrchestrator? _orchestrator;
  StreamSubscription<TeamState>? _sub;
  StreamSubscription<HostEvent>? _hostSub;
  TeamState? _team;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 先摆好两位队友的空位：模型目录晚到也没关系，build 时补默认模型。
    _seedDrafts();
    _boot();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _hostSub?.cancel();
    _draft.dispose();
    for (final draft in _mates) {
      draft.dispose();
    }
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
      });
      final latest = await orchestrator.latest();
      if (!mounted) return;
      setState(() {
        _team = latest;
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

  /// 共享实例：同一个引擎连接上复用，重连后重建。
  Future<TeamOrchestrator> _ensureOrchestrator() async {
    final injected = widget.orchestrator;
    if (injected != null) return injected;
    final conn = ref.read(readListLiveConnectionProvider);
    if (conn == null) throw StateError('还没有连上引擎');
    final existing = _shared;
    if (existing != null && identical(_sharedClient, conn.client)) return existing;
    final support = await getApplicationSupportDirectory();
    final created = TeamOrchestrator(
      driver: DshCollabDriver(conn.client),
      store: TeamStore(Directory('${support.path}/team')),
    );
    if (existing != null) unawaited(existing.dispose());
    _shared = created;
    _sharedClient = conn.client;
    return created;
  }

  /// 队友子会话的审批：按 sessionId 认人，标明「谁在申请」。
  void _watchApprovals() {
    final client = _sharedClient;
    if (client == null) return;
    _hostSub = client.hostEvents.listen((event) {
      final team = _team;
      if (team == null || !mounted) return;
      if (event is ApprovalRequestedEvent) {
        final mate = team.mateBySession(event.request.sessionId);
        if (mate == null) return; // 不是这个团队的会话
        setState(() {
          _pending[event.request.eventId] = (mate: mate.name, request: event.request);
        });
      } else if (event is HostRequestCancelledEvent) {
        if (_pending.remove(event.eventId) != null) setState(() {});
      }
    });
  }

  // ---------------------------------------------------------------------------
  // 建队

  List<_ModelChoice> _models() {
    // 非 build 期间也要能用（加队友、建队），所以读；build 里另外 watch 一次。
    final catalog = ref.read(modelCatalogProvider).value;
    if (catalog == null) return const [];
    return [
      for (final group in catalog.groups)
        for (final info in group.models)
          (
            key: '${info.provider}|${info.id}',
            label: '${group.name} · ${info.name}',
            provider: info.provider,
            id: info.id,
          ),
    ];
  }

  void _seedDrafts() {
    if (_mates.isNotEmpty) return;
    final models = _models();
    for (var i = 0; i < 2; i++) {
      _mates.add(_MateDraft(modelKey: models.isEmpty ? null : models[i % models.length].key));
    }
  }

  /// 模型目录晚到：给还没选模型的草稿补一个默认值。
  void _fillDefaultModels(List<_ModelChoice> models) {
    if (models.isEmpty) return;
    var changed = false;
    for (var i = 0; i < _mates.length; i++) {
      if (_mates[i].modelKey == null) {
        _mates[i].modelKey = models[i % models.length].key;
        changed = true;
      }
    }
    if (changed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  Future<void> _create(List<_ModelChoice> models) async {
    final byKey = {for (final model in models) model.key: model};
    final mates = <Teammate>[];
    for (var i = 0; i < _mates.length; i++) {
      final draft = _mates[i];
      final key = draft.modelKey;
      final model = key == null ? null : byKey[key];
      if (model == null) {
        setState(() => _error = '每位队友都要选一个模型');
        return;
      }
      mates.add(
        Teammate(
          id: 'mate-${DateTime.now().microsecondsSinceEpoch}-$i',
          name: draft.nameController.text.trim(),
          brief: draft.briefController.text.trim(),
          provider: model.provider,
          model: model.id,
        ),
      );
    }
    if (mates.length < 2) {
      setState(() => _error = '至少两位队友');
      return;
    }
    final orchestrator = _orchestrator;
    if (orchestrator == null) {
      setState(() => _error = '还没有连上引擎：先去聊天里连上引擎');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final team = await orchestrator.create(teammates: mates);
      if (!mounted) return;
      for (final draft in _mates) {
        draft.dispose();
      }
      _mates.clear();
      setState(() {
        _team = team;
        _busy = false;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _busy = false;
        });
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 群聊

  Future<void> _send() async {
    final team = _team;
    final text = _draft.text.trim();
    if (team == null || text.isEmpty || _busy) return;
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
    }
  }

  Future<void> _stop() async {
    final team = _team;
    if (team == null) return;
    await _orchestrator?.cancel(team.id);
  }

  Future<void> _respond(String eventId, ApprovalDecision decision) async {
    final entry = _pending[eventId];
    final client = _sharedClient;
    if (entry == null || client == null) return;
    setState(() => _pending.remove(eventId));
    try {
      await client.respondApproval(entry.request, decision);
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
    if (team == null) return;
    final orchestrator = _orchestrator;
    if (orchestrator == null) return;
    try {
      await orchestrator.store.writeMarkdown(team);
      final root = orchestrator.store.root;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导出到 ${root.path}/${team.id}.md')),
        );
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  void _newTeam() {
    for (final draft in _mates) {
      draft.dispose();
    }
    _mates.clear();
    setState(() {
      _team = null;
      _error = null;
    });
    _seedDrafts();
  }

  // ---------------------------------------------------------------------------
  // 成员管理

  Future<void> _openMembers() async {
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Text('队友', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(width: 8),
                      Text(
                        '${current.teammates.length}/6（至少 2 位）',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                for (final mate in current.teammates)
                  ListTile(
                    leading: Icon(
                      brandIconData(brandOf(mate.provider, mate.model)),
                      color: brandColor(brandOf(mate.provider, mate.model), Theme.of(context).colorScheme.primary),
                    ),
                    title: Text(mate.name),
                    subtitle: Text(
                      [
                        if (mate.brief.trim().isNotEmpty) mate.brief.trim(),
                        mate.model,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: '移除',
                      icon: const Icon(Icons.person_remove_outlined),
                      onPressed: current.teammates.length <= 2
                          ? null
                          : () async {
                              await _orchestrator?.removeMate(current.id, mate.id);
                              setSheetState(() {});
                            },
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: OutlinedButton.icon(
                    onPressed: current.teammates.length >= 6
                        ? null
                        : () async {
                            final added = await _addMateDialog();
                            if (added) setSheetState(() {});
                          },
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('加一位队友'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<bool> _addMateDialog() async {
    final models = _models();
    final name = TextEditingController();
    final brief = TextEditingController();
    var key = models.isEmpty ? null : models.first.key;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('加一位队友'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: '名字'),
              ),
              TextField(
                controller: brief,
                decoration: const InputDecoration(labelText: '负责什么（可选）'),
              ),
              const SizedBox(height: 12),
              _modelPicker(
                value: key,
                models: models,
                onChanged: (value) => setDialogState(() => key = value),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
            FilledButton(
              onPressed: key == null ? null : () async {
                final model = models.firstWhere((m) => m.key == key);
                final team = _team;
                if (team == null) {
                  Navigator.of(dialogContext).pop(false);
                  return;
                }
                final orchestrator = _orchestrator;
                if (orchestrator == null) {
                  Navigator.of(dialogContext).pop(false);
                  return;
                }
                try {
                  await orchestrator.addMate(
                    team.id,
                    Teammate(
                      id: 'mate-${DateTime.now().microsecondsSinceEpoch}',
                      name: name.text.trim(),
                      brief: brief.text.trim(),
                      provider: model.provider,
                      model: model.id,
                    ),
                  );
                  if (dialogContext.mounted) Navigator.of(dialogContext).pop(true);
                } on Object catch (error) {
                  if (mounted) setState(() => _error = '$error');
                  if (dialogContext.mounted) Navigator.of(dialogContext).pop(false);
                }
              },
              child: const Text('加入'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    brief.dispose();
    return result ?? false;
  }

  // ---------------------------------------------------------------------------
  // 界面

  @override
  Widget build(BuildContext context) {
    // 模型目录晚到时重建建队表单（默认模型/下拉选项都靠它）。
    ref.watch(modelCatalogProvider);
    final team = _team;
    return Scaffold(
      appBar: AppBar(
        title: Text(team == null ? '组个队' : '团队'),
        actions: [
          if (team != null) ...[
            IconButton(
              tooltip: '队友',
              icon: const Icon(Icons.group_outlined),
              onPressed: _openMembers,
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'export') _export();
                if (value == 'new') _newTeam();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'export', child: Text('导出 Markdown')),
                PopupMenuItem(value: 'new', child: Text('新建团队')),
              ],
            ),
          ],
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : team == null
            ? _buildSetup()
            : _buildChat(team),
      ),
    );
  }

  Widget _buildSetup() {
    final theme = Theme.of(context);
    final models = _models();
    _fillDefaultModels(models);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text('几位队友，一个群', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '每位队友各用各的模型、各记各的上下文。发消息时 @ 谁，谁回答；不点名就大家一起答。',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        if (models.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '还没有读到模型目录：先在聊天里连上引擎并配置模型。',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        for (var i = 0; i < _mates.length; i++) _mateEditor(i, models),
        const SizedBox(height: 4),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _mates.length >= 6
                  ? null
                  : () => setState(() => _mates.add(_MateDraft())),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('加一位'),
            ),
            const SizedBox(width: 8),
            Text(
              '${_mates.length}/6（至少 2 位）',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _busy || models.isEmpty || _orchestrator == null ? null : () => _create(models),
          icon: const Icon(Icons.groups_2_outlined),
          label: const Text('建队'),
        ),
      ],
    );
  }

  Widget _mateEditor(int index, List<_ModelChoice> models) {
    final theme = Theme.of(context);
    final draft = _mates[index];
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
        child: Column(
          children: [
            Row(
              children: [
                Text('队友 ${index + 1}', style: theme.textTheme.labelMedium),
                const Spacer(),
                IconButton(
                  tooltip: '移除',
                  icon: const Icon(Icons.close, size: 16),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                  style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  onPressed: _mates.length <= 2
                      ? null
                      : () => setState(() {
                          _mates.removeAt(index).dispose();
                        }),
                ),
              ],
            ),
            TextField(
              controller: draft.nameController,
              decoration: const InputDecoration(
                labelText: '名字',
                hintText: '留空就自动起名',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: draft.briefController,
              decoration: const InputDecoration(
                labelText: '负责什么',
                hintText: '比如：前端实现、接口设计、挑毛病',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            _modelPicker(
              value: draft.modelKey,
              models: models,
              onChanged: (value) => setState(() => draft.modelKey = value),
            ),
          ],
        ),
      ),
    );
  }

  /// 受控的模型下拉：草稿被程序改动（补默认值）时显示也能跟上。
  Widget _modelPicker({
    required String? value,
    required List<_ModelChoice> models,
    required ValueChanged<String?> onChanged,
  }) {
    final theme = Theme.of(context);
    final valid = models.any((model) => model.key == value) ? value : null;
    return InputDecorator(
      decoration: const InputDecoration(labelText: '模型', isDense: true),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: valid,
          isExpanded: true,
          isDense: true,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface),
          items: [
            for (final model in models)
              DropdownMenuItem(value: model.key, child: Text(model.label, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildChat(TeamState team) {
    final messages = team.messages;
    return Column(
      children: [
        for (final eventId in _pending.keys.toList()) _approvalBanner(eventId),
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
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _error!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
        _composer(team),
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
            Icon(Icons.forum_outlined, size: 40, color: theme.colorScheme.outline),
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
          Text(
            '队友在想…',
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _bubble(TeamState team, TeamMsg msg) {
    final theme = Theme.of(context);
    if (msg.role == TeamMsgRole.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Text(
            msg.text,
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final mine = msg.role == TeamMsgRole.user;
    final mate = msg.teammateId == null ? null : team.mate(msg.teammateId!);
    final brand = mate == null ? ModelBrand.other : brandOf(mate.provider, mate.model);
    final background = mine
        ? theme.colorScheme.primaryContainer
        : msg.failed
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.surfaceContainerHighest;
    final foreground = mine
        ? theme.colorScheme.onPrimaryContainer
        : msg.failed
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSurface;

    final content = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.76),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(14)),
      child: Text(msg.text, style: theme.textTheme.bodyMedium?.copyWith(color: foreground)),
    );

    if (mine) {
      return Padding(
        padding: const EdgeInsets.only(top: 6, left: 40),
        child: Align(alignment: Alignment.centerRight, child: content),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6, right: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 6),
            child: Icon(
              brandIconData(brand),
              size: 16,
              color: msg.failed
                  ? theme.colorScheme.error
                  : brandColor(brand, theme.colorScheme.primary),
            ),
          ),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mate?.name ?? '队友',
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 2),
                content,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _approvalBanner(String eventId) {
    final theme = Theme.of(context);
    final entry = _pending[eventId];
    if (entry == null) return const SizedBox.shrink();
    return Material(
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.shield_outlined, size: 18, color: theme.colorScheme.onTertiaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${entry.mate} 需要你的授权',
                    style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onTertiaryContainer),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    approvalText(entry.request),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onTertiaryContainer),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => _respond(eventId, ApprovalDecision.reject),
              child: const Text('拒绝'),
            ),
            FilledButton.tonal(
              onPressed: () => _respond(eventId, ApprovalDecision.allowOnce),
              child: const Text('允许一次'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _composer(TeamState team) {
    final theme = Theme.of(context);
    final canSend = _draft.text.trim().isNotEmpty && !_busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          PopupMenuButton<Teammate>(
            tooltip: '点名',
            icon: const Icon(Icons.alternate_email),
            onSelected: _insertMention,
            itemBuilder: (_) => [
              for (final mate in team.teammates)
                PopupMenuItem(value: mate, child: Text(mate.name)),
            ],
          ),
          Expanded(
            child: TextField(
              controller: _draft,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.newline,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '说点什么，@ 一位队友',
                hintStyle: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          if (_busy)
            IconButton.filledTonal(
              tooltip: '停止',
              onPressed: _stop,
              icon: const Icon(Icons.stop_rounded),
            )
          else
            IconButton.filled(
              tooltip: '发送',
              onPressed: canSend ? _send : null,
              icon: const Icon(Icons.arrow_upward_rounded),
            ),
        ],
      ),
    );
  }
}
