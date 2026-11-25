// 议会与团队的成员管理：紧凑列表 + 展开编辑，不再是一整页配置表单。
//
// 方案要求：
// - 成员行显示真实品牌图、名字、模型、Provider、角色/任务；
// - 点开才展开编辑（换模型、改角色、改思考深度、移除）；
// - 增删改都要立刻存进当前会话，关掉抽屉回到聊天，记录不丢；
// - 保留 2～6 人的上限与主席/主管/只读等既有能力。

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../council/collab_models.dart';
import '../../state/models_state.dart';
import '../../team/team_models.dart';
import '../chat/model_brand_mark.dart';
import '../chat/model_sheet.dart' show effortLabel, shortModelName;
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../providers/provider_brand_icon.dart';
import '../theme/app_icons.dart';
import 'collab_kit.dart';

/// 目录里这条路由的展示名；找不到就用模型 id。
String modelDisplayName(ModelCatalog? catalog, String provider, String model) {
  if (catalog != null) {
    for (final group in catalog.groups) {
      for (final info in group.models) {
        if (info.provider == provider && info.id == model) return info.name;
      }
    }
  }
  return shortModelName(model);
}

/// 目录里这条路由的 Provider 名（「DeepSeek」「自定义中转」）。
String providerDisplayName(ModelCatalog? catalog, String provider) {
  if (catalog != null) {
    for (final group in catalog.groups) {
      if (group.id == provider) return group.name;
    }
  }
  final brand = brandOf(provider);
  if (brand != ModelBrand.other) return brandLabel(brand);
  return provider;
}

/// 模型卡的思考深度选项。
List<ReasoningEffort> effortsOf(ModelCatalog? catalog, String provider, String model) {
  if (catalog != null) {
    for (final group in catalog.groups) {
      for (final info in group.models) {
        if (info.provider == provider && info.id == model) return info.efforts;
      }
    }
  }
  return const [];
}

/// 挑一个模型（成员换模型 / 加成员共用）。确认后才回调。
Future<ModelSelection?> pickCollabModel(
  BuildContext context, {
  ModelSelection? current,
  String title = '选择模型',
}) async {
  final picked = await showModalBottomSheet<ModelSelection>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => _ModelPickSheet(current: current, title: title),
  );
  return picked;
}

class _ModelPickSheet extends ConsumerWidget {
  const _ModelPickSheet({required this.current, required this.title});

  final ModelSelection? current;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(currentModelCatalogProvider);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetTitleBar(title),
            Flexible(
              child: _ModelPickList(
                catalog: catalog,
                selected: current,
                onPick: (selection) => Navigator.of(context).pop(selection),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 成员用的模型列表：按 Provider 分段 + 搜索，点一条就选中。
class _ModelPickList extends StatefulWidget {
  const _ModelPickList({required this.catalog, required this.selected, required this.onPick});

  final ModelCatalog? catalog;
  final ModelSelection? selected;
  final ValueChanged<ModelSelection> onPick;

  @override
  State<_ModelPickList> createState() => _ModelPickListState();
}

class _ModelPickListState extends State<_ModelPickList> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final catalog = widget.catalog;
    final groups = [
      for (final group in catalog?.groups ?? const <ProviderGroup>[])
        if (group.models.isNotEmpty) group,
    ];
    final query = _query.trim().toLowerCase();
    final shown = [
      for (final group in groups)
        if (query.isEmpty || group.name.toLowerCase().contains(query))
          (
            group: group,
            models: [
              for (final model in group.models)
                if (query.isEmpty ||
                    model.name.toLowerCase().contains(query) ||
                    model.id.toLowerCase().contains(query))
                  model,
            ],
          ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            autofocus: false,
            decoration: InputDecoration(
              hintText: '搜索模型或 Provider',
              prefixIcon: const Icon(AppIcons.search, size: 18),
              isDense: true,
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        Flexible(
          child: shown.every((entry) => entry.models.isEmpty)
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      catalog == null ? '还没有读到模型目录' : '没有匹配的模型',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                  children: [
                    for (final entry in shown) ...[
                      if (entry.models.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(6, 10, 6, 4),
                          child: Text(
                            entry.group.name,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      for (final model in entry.models)
                        _ModelPickRow(
                          model: model,
                          providerName: entry.group.name,
                          selected: widget.selected?.provider == model.provider && widget.selected?.model == model.id,
                          onTap: () => widget.onPick(
                            ModelSelection(
                              provider: model.provider,
                              model: model.id,
                              reasoningEffort: startingEffort(model),
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _ModelPickRow extends StatelessWidget {
  const _ModelPickRow({
    required this.model,
    required this.providerName,
    required this.selected,
    required this.onTap,
  });

  final ModelInfo model;
  final String providerName;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final brand = brandOf(model.provider, model.id);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: selected ? colors.primary.withValues(alpha: 0.08) : Colors.transparent,
        ),
        child: Row(
          children: [
            ProviderBrandIcon(brand: brand, size: 26, filled: true),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shortModelName(model.name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    providerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (selected) Icon(AppIcons.done, size: 18, color: colors.primary),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 议会成员

/// 议会的成员管理抽屉。改动即存，关掉就回到当前聊天。
Future<void> showCouncilMembersSheet(
  BuildContext context, {
  required List<SeatSpec> seats,
  required CollabMode mode,
  required String? chairId,
  required Future<void> Function(List<SeatSpec> seats, CollabMode mode, String? chairId) onSave,
}) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (_) => _CouncilMembersSheet(seats: seats, mode: mode, chairId: chairId, onSave: onSave),
  );
}

class _CouncilMembersSheet extends ConsumerStatefulWidget {
  const _CouncilMembersSheet({
    required this.seats,
    required this.mode,
    required this.chairId,
    required this.onSave,
  });

  final List<SeatSpec> seats;
  final CollabMode mode;
  final String? chairId;
  final Future<void> Function(List<SeatSpec> seats, CollabMode mode, String? chairId) onSave;

  @override
  ConsumerState<_CouncilMembersSheet> createState() => _CouncilMembersSheetState();
}

class _CouncilMembersSheetState extends ConsumerState<_CouncilMembersSheet> {
  late List<SeatSpec> _seats = List.of(widget.seats);
  late CollabMode _mode = widget.mode;
  late String? _chairId = widget.chairId;
  String? _error;

  Future<void> _commit() async {
    try {
      await widget.onSave(List.of(_seats), _mode, _chairId);
      if (mounted) setState(() => _error = null);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  void _update(SeatSpec seat) {
    setState(() {
      _seats = [for (final s in _seats) s.id == seat.id ? seat : s];
      if (_chairId == seat.id && seat.role == SeatRole.none) {
        // 角色清空不影响主席身份。
      }
    });
    unawaited(_commit());
  }

  void _remove(String id) {
    if (_seats.length <= 2) return;
    setState(() {
      _seats = [for (final s in _seats) if (s.id != id) s];
      if (_chairId == id) _chairId = _seats.first.id;
    });
    unawaited(_commit());
  }

  Future<void> _add() async {
    if (_seats.length >= 6) return;
    final picked = await pickCollabModel(context, title: '添加议会成员');
    if (picked == null || !mounted) return;
    final catalog = ref.read(modelCatalogProvider).value;
    setState(() {
      _seats = [
        ..._seats,
        SeatSpec(
          id: 'seat${DateTime.now().microsecondsSinceEpoch}',
          provider: picked.provider,
          model: picked.model,
          label: modelDisplayName(catalog, picked.provider, picked.model),
          reasoningEffort: picked.reasoningEffort,
        ),
      ];
    });
    unawaited(_commit());
  }

  Future<void> _changeModel(SeatSpec seat) async {
    final picked = await pickCollabModel(
      context,
      current: ModelSelection(provider: seat.provider, model: seat.model, reasoningEffort: seat.reasoningEffort),
      title: '更换模型',
    );
    if (picked == null || !mounted) return;
    final catalog = ref.read(modelCatalogProvider).value;
    _update(
      seat.copyWith(
        provider: picked.provider,
        model: picked.model,
        label: modelDisplayName(catalog, picked.provider, picked.model),
        reasoningEffort: picked.reasoningEffort,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final catalog = ref.watch(modelCatalogProvider).value;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.86),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar('议会成员'),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                    child: Row(
                      children: [
                        Text('参会模型', style: theme.textTheme.titleSmall),
                        const SizedBox(width: 8),
                        Text(
                          '${_seats.length}/6（至少 2 位）',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  for (final seat in _seats)
                    _SeatRow(
                      seat: seat,
                      catalog: catalog,
                      isChair: _chairId == seat.id,
                      canRemove: _seats.length > 2,
                      onChair: () {
                        setState(() => _chairId = seat.id);
                        unawaited(_commit());
                      },
                      onRemove: () => _remove(seat.id),
                      onChanged: _update,
                      onChangeModel: () => _changeModel(seat),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
                      child: Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
                    ),
                  const Divider(height: 24),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                    child: Text('运行方式', style: theme.textTheme.titleSmall),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: SegmentedButton<CollabMode>(
                      segments: const [
                        ButtonSegment(value: CollabMode.quick, label: Text('快速')),
                        ButtonSegment(value: CollabMode.deliberative, label: Text('审议')),
                        ButtonSegment(value: CollabMode.evidence, label: Text('循证')),
                      ],
                      selected: {_mode},
                      onSelectionChanged: (set) {
                        setState(() => _mode = set.first);
                        unawaited(_commit());
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
                    child: Text(
                      switch (_mode) {
                        CollabMode.quick => '各席位并行作答，主席直接综合。',
                        CollabMode.deliberative => '第一轮后互看匿名答案修订一轮，成本约 2 倍。',
                        CollabMode.evidence => '权威席位先答，其余成员只做校验与补漏。',
                      },
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: FilledButton.tonalIcon(
                onPressed: _seats.length >= 6 ? null : _add,
                icon: const Icon(AppIcons.add, size: 18),
                label: Text(_seats.length >= 6 ? '已满 6 位' : '添加成员'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一位议会成员：紧凑一行，点开才展开编辑。
class _SeatRow extends StatefulWidget {
  const _SeatRow({
    required this.seat,
    required this.catalog,
    required this.isChair,
    required this.canRemove,
    required this.onChair,
    required this.onRemove,
    required this.onChanged,
    required this.onChangeModel,
  });

  final SeatSpec seat;
  final ModelCatalog? catalog;
  final bool isChair;
  final bool canRemove;
  final VoidCallback onChair;
  final VoidCallback onRemove;
  final ValueChanged<SeatSpec> onChanged;
  final VoidCallback onChangeModel;

  @override
  State<_SeatRow> createState() => _SeatRowState();
}

class _SeatRowState extends State<_SeatRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final seat = widget.seat;
    final brand = brandOf(seat.provider, seat.model);
    final efforts = effortsOf(widget.catalog, seat.provider, seat.model);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Row(
              children: [
                CollabAvatar(brand: brand, size: 34),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              seat.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                          if (widget.isChair) ...[
                            const SizedBox(width: 6),
                            _Tag('主席', colors.primary),
                          ],
                          if (seat.role != SeatRole.none) ...[
                            const SizedBox(width: 6),
                            _Tag(seat.role.label, colors.onSurfaceVariant),
                          ],
                        ],
                      ),
                      Text(
                        [
                          providerDisplayName(widget.catalog, seat.provider),
                          modelDisplayName(widget.catalog, seat.provider, seat.model),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Icon(AppIcons.expand, size: 16, color: colors.onSurfaceVariant),
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: widget.onChangeModel,
                      icon: ProviderBrandIcon(brand: brand, size: 14),
                      label: Text(
                        modelDisplayName(widget.catalog, seat.provider, seat.model),
                        overflow: TextOverflow.ellipsis,
                      ),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                    ),
                    DropdownButton<SeatRole>(
                      value: seat.role,
                      underline: const SizedBox.shrink(),
                      style: theme.textTheme.labelMedium,
                      items: [
                        for (final role in SeatRole.values)
                          DropdownMenuItem(value: role, child: Text(role.label)),
                      ],
                      onChanged: (role) {
                        if (role != null) widget.onChanged(seat.copyWith(role: role));
                      },
                    ),
                    if (efforts.isNotEmpty)
                      DropdownButton<String>(
                        value: seat.reasoningEffort ?? '',
                        underline: const SizedBox.shrink(),
                        style: theme.textTheme.labelMedium,
                        items: [
                          const DropdownMenuItem(value: '', child: Text('默认思考')),
                          for (final effort in efforts)
                            DropdownMenuItem(
                              value: effort.id,
                              child: Text(effortLabel(effort.id, effort.name)),
                            ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          widget.onChanged(
                            seat.copyWith(
                              reasoningEffort: value.isEmpty ? null : value,
                            ),
                          );
                        },
                      ),
                    if (!widget.isChair)
                      TextButton(
                        onPressed: widget.onChair,
                        child: const Text('设为主席'),
                      ),
                    if (widget.canRemove)
                      TextButton(
                        onPressed: widget.onRemove,
                        style: TextButton.styleFrom(foregroundColor: colors.error),
                        child: const Text('移除'),
                      ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, this.color);

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: color, height: 1.3),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 团队成员

/// 团队的成员管理抽屉：主管、只读、负责什么、模型都在这里改。
Future<void> showTeamMembersSheet(
  BuildContext context, {
  required TeamState team,
  required Future<void> Function(List<Teammate> teammates, String? leadId) onSave,
}) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (_) => _TeamMembersSheet(team: team, onSave: onSave),
  );
}

class _TeamMembersSheet extends ConsumerStatefulWidget {
  const _TeamMembersSheet({required this.team, required this.onSave});

  final TeamState team;
  final Future<void> Function(List<Teammate> teammates, String? leadId) onSave;

  @override
  ConsumerState<_TeamMembersSheet> createState() => _TeamMembersSheetState();
}

class _TeamMembersSheetState extends ConsumerState<_TeamMembersSheet> {
  late List<Teammate> _mates = List.of(widget.team.teammates);
  late String? _leadId = widget.team.leadId;
  String? _error;

  Future<void> _commit() async {
    try {
      await widget.onSave(List.of(_mates), _leadId);
      if (mounted) setState(() => _error = null);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  void _update(Teammate mate) {
    setState(() => _mates = [for (final m in _mates) m.id == mate.id ? mate : m]);
    unawaited(_commit());
  }

  void _remove(String id) {
    setState(() {
      _mates = [for (final m in _mates) if (m.id != id) m];
      if (_leadId == id) _leadId = null;
    });
    unawaited(_commit());
  }

  Future<void> _add() async {
    if (_mates.length >= 6) return;
    final picked = await pickCollabModel(context, title: '添加队友');
    if (picked == null || !mounted) return;
    final index = _mates.length + 1;
    setState(() {
      _mates = [
        ..._mates,
        Teammate(
          id: 'mate-${DateTime.now().microsecondsSinceEpoch}',
          name: '队友 $index',
          provider: picked.provider,
          model: picked.model,
          reasoningEffort: picked.reasoningEffort,
        ),
      ];
    });
    unawaited(_commit());
    // 名字留空不好认：直接展开改名。
    final added = _mates.last;
    if (!mounted) return;
    final name = await _askName(added.name, added.brief);
    if (name != null && mounted) _update(added.copyWith(name: name.$1, brief: name.$2));
  }

  Future<(String, String)?> _askName(String name, String brief) async {
    final nameController = TextEditingController(text: name);
    final briefController = TextEditingController(text: brief);
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('队友资料'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: '名字'),
              autofocus: true,
            ),
            TextField(
              controller: briefController,
              decoration: const InputDecoration(labelText: '负责什么（可选）'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, (nameController.text, briefController.text)),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    nameController.dispose();
    briefController.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final catalog = ref.watch(modelCatalogProvider).value;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.86),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar('团队成员'),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                    child: Row(
                      children: [
                        Text('队友', style: theme.textTheme.titleSmall),
                        const SizedBox(width: 8),
                        Text(
                          '${_mates.length}/6（至少 2 位）',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (_mates.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
                      child: Text(
                        '还没有队友：加两位，各用各的模型和上下文。',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  for (final mate in _mates)
                    _MateRow(
                      mate: mate,
                      catalog: catalog,
                      isLead: _leadId == mate.id,
                      canRemove: _mates.length > 2,
                      onLead: () {
                        setState(() => _leadId = _leadId == mate.id ? null : mate.id);
                        unawaited(_commit());
                      },
                      onRemove: () => _remove(mate.id),
                      onChanged: _update,
                      onEdit: () async {
                        final result = await _askName(mate.name, mate.brief);
                        if (result != null) _update(mate.copyWith(name: result.$1, brief: result.$2));
                      },
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
                      child: Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: FilledButton.tonalIcon(
                onPressed: _mates.length >= 6 ? null : _add,
                icon: const Icon(AppIcons.add, size: 18),
                label: Text(_mates.length >= 6 ? '已满 6 位' : '添加队友'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MateRow extends StatefulWidget {
  const _MateRow({
    required this.mate,
    required this.catalog,
    required this.isLead,
    required this.canRemove,
    required this.onLead,
    required this.onRemove,
    required this.onChanged,
    required this.onEdit,
  });

  final Teammate mate;
  final ModelCatalog? catalog;
  final bool isLead;

  /// 只剩两位时不能再减：发消息至少要点得动人。
  final bool canRemove;
  final VoidCallback onLead;
  final VoidCallback onRemove;
  final ValueChanged<Teammate> onChanged;
  final VoidCallback onEdit;

  @override
  State<_MateRow> createState() => _MateRowState();
}

class _MateRowState extends State<_MateRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final mate = widget.mate;
    final brand = brandOf(mate.provider, mate.model);
    final efforts = effortsOf(widget.catalog, mate.provider, mate.model);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Row(
              children: [
                CollabAvatar(brand: brand, size: 34),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              mate.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                          if (widget.isLead) ...[
                            const SizedBox(width: 6),
                            _Tag('主管', colors.primary),
                          ],
                          if (mate.readOnly) ...[
                            const SizedBox(width: 6),
                            _Tag('只读', colors.onSurfaceVariant),
                          ],
                        ],
                      ),
                      Text(
                        [
                          if (mate.brief.trim().isNotEmpty) mate.brief.trim(),
                          providerDisplayName(widget.catalog, mate.provider),
                          modelDisplayName(widget.catalog, mate.provider, mate.model),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Icon(AppIcons.expand, size: 16, color: colors.onSurfaceVariant),
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await pickCollabModel(
                      context,
                      current: ModelSelection(
                        provider: mate.provider,
                        model: mate.model,
                        reasoningEffort: mate.reasoningEffort,
                      ),
                      title: '更换模型',
                    );
                    if (picked == null) return;
                    widget.onChanged(
                      mate.copyWith(
                        provider: picked.provider,
                        model: picked.model,
                        reasoningEffort: picked.reasoningEffort,
                      ),
                    );
                  },
                  icon: ProviderBrandIcon(brand: brand, size: 14),
                  label: Text(
                    modelDisplayName(widget.catalog, mate.provider, mate.model),
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
                TextButton(onPressed: widget.onEdit, child: const Text('名字/任务')),
                FilterChip(
                  label: const Text('只读'),
                  selected: mate.readOnly,
                  visualDensity: VisualDensity.compact,
                  onSelected: (on) => widget.onChanged(mate.copyWith(readOnly: on)),
                ),
                if (efforts.isNotEmpty)
                  DropdownButton<String>(
                    value: mate.reasoningEffort ?? '',
                    underline: const SizedBox.shrink(),
                    style: theme.textTheme.labelMedium,
                    items: [
                      const DropdownMenuItem(value: '', child: Text('默认思考')),
                      for (final effort in efforts)
                        DropdownMenuItem(
                          value: effort.id,
                          child: Text(effortLabel(effort.id, effort.name)),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      widget.onChanged(
                        mate.copyWith(reasoningEffort: value.isEmpty ? null : value),
                      );
                    },
                  ),
                if (!widget.isLead)
                  TextButton(onPressed: widget.onLead, child: const Text('设为主管'))
                else
                  TextButton(onPressed: widget.onLead, child: const Text('取消主管')),
                if (widget.canRemove)
                  TextButton(
                    onPressed: widget.onRemove,
                    style: TextButton.styleFrom(foregroundColor: colors.error),
                    child: const Text('移除'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
