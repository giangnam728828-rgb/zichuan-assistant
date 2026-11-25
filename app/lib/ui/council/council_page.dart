// 议会（C2 MVP）：把一个问题同时发给多家模型，主席综合出裁决。
//
// 页面两个形态：
// - 编辑态：议题、成员（按供应商分组的模型多选，2 到 6 个）、运行方式；
// - 运行态：席位进度（谁在答、谁答完、谁失败）、主席裁决、取消。
//
// 编排在 [CollabOrchestrator]（lib/council/），这里只管界面：
// 提交后订阅 events 流刷新，离开页面不打断运行（驱动在内存里继续，
// 回到页面时从 store 里捡回未完成的那次运行）。

import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../collab/collab_export.dart';
import '../../collab/collab_session_book.dart';
import '../../council/collab_models.dart';
import '../../council/collab_orchestrator.dart';
import '../../council/collab_store.dart';
import '../../council/verdict_parser.dart';
import '../../state/models_state.dart';
import '../../state/read_list_identity.dart';
import '../../state/sessions_state.dart';
import '../chat/model_brand_mark.dart';
import '../shell/root_tab.dart';

class CouncilPage extends ConsumerStatefulWidget {
  const CouncilPage({super.key, this.orchestrator});

  /// 测试注入用；生产为空，页面自己建实例。
  final CollabOrchestrator? orchestrator;

  @override
  ConsumerState<CouncilPage> createState() => _CouncilPageState();
}

class _CouncilPageState extends ConsumerState<CouncilPage> {
  final _question = TextEditingController();
  final _selected = <String>{}; // 'provider|model'
  final _roles = <String, SeatRole>{}; // 'provider|model' → 角色
  final _efforts = <String, String>{}; // 'provider|model' → reasoningEffort
  CollabMode _mode = CollabMode.quick;

  CollabOrchestrator? _orchestrator;
  StreamSubscription<CollabRun>? _sub;
  CollabRun? _run;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _question.dispose();
    // 注入的编排器归测试管；自建的才在离开页面时关掉。
    if (widget.orchestrator == null) unawaited(_orchestrator?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  /// 回到页面时捡回还没跑完的那次议会，并把历史运行的席位会话补登记
  /// （C6 之前跑的议会没登记过，历史列表里会一条条冒出来）。
  Future<void> _restore() async {
    try {
      final orchestrator = await _ensureOrchestrator();
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

      final unfinished = runs.where((run) => !run.phase.isTerminal).firstOrNull;
      if (unfinished == null || !mounted) return;
      _listen();
      final resumed = await orchestrator.resume(unfinished.id);
      if (mounted) setState(() => _run = resumed ?? unfinished);
    } on Object {
      // 恢复失败不挡新议题。
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
    final support = await getApplicationSupportDirectory();
    final orchestrator = CollabOrchestrator(
      driver: DshCollabDriver(conn.client),
      store: CollabStore(Directory('${support.path}/council')),
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
    _sub ??= _orchestrator?.events.listen((run) {
      if (mounted) setState(() => _run = run);
    });
  }

  Future<void> _submit() async {
    final question = _question.text.trim();
    if (question.isEmpty || _selected.length < 2) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final orchestrator = await _ensureOrchestrator();
      _listen();
      final catalog = ref.read(modelCatalogProvider).value;
      final seats = <SeatSpec>[];
      var index = 0;
      for (final key in _selected) {
        final parts = key.split('|');
        final provider = parts.first;
        final model = parts.sublist(1).join('|');
        final name = _modelName(catalog, provider, model);
        seats.add(
          SeatSpec(
            id: 'seat${index++}',
            provider: provider,
            model: model,
            label: name,
            role: _roles[key] ?? SeatRole.none,
            reasoningEffort: _efforts[key],
          ),
        );
      }
      final run = await orchestrator.submit(
        CouncilSpec(
          question: question,
          seats: seats,
          mode: _mode,
          // 预计调用 + 2 次重试余量。
          budgetCalls: (seats.length * (_mode == CollabMode.deliberative ? 2 : 1)) + 3,
        ),
      );
      if (mounted) setState(() => _run = run);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final run = _run;
    if (run == null) return;
    await _orchestrator?.cancel(run.id);
  }

  /// 历史：最近开过的议会，点一条回看（终态的运行不会再变）。
  Future<void> _openHistory() async {
    final store = _orchestrator?.store;
    if (store == null) return;
    final runs = await store.list();
    if (!mounted) return;
    if (runs.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('还没有跑过议会')));
      return;
    }
    final picked = await showModalBottomSheet<CollabRun>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.7),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('最近的议会', style: Theme.of(sheet).textTheme.titleMedium),
              ),
              for (final run in runs)
                ListTile(
                  title: Text(run.spec.question, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${collabStamp(run.createdAt)} · ${_phaseLabel(run.phase)} · '
                    '${run.answeredCount}/${run.spec.seats.length} 席',
                  ),
                  onTap: () => Navigator.pop(sheet, run),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _run = picked);
  }

  Future<void> _export() async {
    final run = _run;
    if (run == null) return;
    final stamp = collabStamp(run.createdAt).replaceAll(RegExp(r'[: ]'), '-');
    try {
      await shareMarkdownFile(fileName: '议会-$stamp.md', content: councilMarkdown(run));
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }

  /// 打开某个席位的完整对话（这些会话不在历史列表里，只从这里进）。
  void _openSession(String sessionId) {
    ref.read(currentSessionProvider.notifier).select(sessionId);
    switchTab(context, RootTab.chat);
  }

  static String _phaseLabel(CollabPhase phase) => switch (phase) {
    CollabPhase.queued => '排队中',
    CollabPhase.round1 => '作答中',
    CollabPhase.reviewing => '互评中',
    CollabPhase.verifying => '校验中',
    CollabPhase.synthesizing => '综合中',
    CollabPhase.done => '已完成',
    CollabPhase.cancelled => '已取消',
    CollabPhase.failed => '失败',
  };

  String _modelName(ModelCatalog? catalog, String provider, String model) {
    if (catalog != null) {
      for (final group in catalog.groups) {
        for (final info in group.models) {
          if (info.provider == provider && info.id == model) return info.name;
        }
      }
    }
    return model;
  }

  @override
  Widget build(BuildContext context) {
    final run = _run;
    return Scaffold(
      appBar: AppBar(
        title: const Text('议会'),
        actions: [
          if (run?.verdict != null) IconButton(tooltip: '导出裁决', icon: const Icon(Icons.ios_share), onPressed: _export),
          IconButton(tooltip: '历史议会', icon: const Icon(Icons.history), onPressed: _openHistory),
          if (run != null && !run.phase.isTerminal) TextButton(onPressed: _cancel, child: const Text('取消')),
        ],
      ),
      body: SafeArea(child: run == null ? _buildEditor(context) : _buildRun(context, run)),
    );
  }

  // ---------------------------------------------------------------------------
  // 编辑态

  Widget _buildEditor(BuildContext context) {
    final theme = Theme.of(context);
    final catalog = ref.watch(modelCatalogProvider).value;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text('向议会提问', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '同一个问题发给多家模型，各自作答后由主席综合出结论、共识与分歧。',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _question,
          minLines: 3,
          maxLines: 8,
          textInputAction: TextInputAction.newline,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(hintText: '想让大家一起判断什么？', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Text('成员', style: theme.textTheme.titleSmall),
            const SizedBox(width: 8),
            Text(
              '已选 ${_selected.length}（2 到 6 个）',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (catalog == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '还没有读到模型目录：先在聊天里连上引擎并配置模型。',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          )
        else
          for (final group in catalog.groups)
            if (group.models.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Text(
                  group.name,
                  style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final info in group.models)
                    FilterChip(
                      label: Text(info.name),
                      avatar: _brandAvatar(info.provider, info.name),
                      selected: _selected.contains('${info.provider}|${info.id}'),
                      onSelected: (on) {
                        setState(() {
                          final key = '${info.provider}|${info.id}';
                          if (on) {
                            if (_selected.length < 6) _selected.add(key);
                          } else {
                            _selected.remove(key);
                          }
                        });
                      },
                    ),
                ],
              ),
            ],
        if (_selected.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('成员与角色', style: theme.textTheme.titleSmall),
          for (final key in _selected.toList()) _seatEditRow(key, catalog),
        ],
        const SizedBox(height: 20),
        Text('运行方式', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<CollabMode>(
          segments: const [
            ButtonSegment(value: CollabMode.quick, label: Text('快速'), icon: Icon(Icons.bolt_outlined)),
            ButtonSegment(value: CollabMode.deliberative, label: Text('审议'), icon: Icon(Icons.forum_outlined)),
            ButtonSegment(value: CollabMode.evidence, label: Text('循证'), icon: Icon(Icons.fact_check_outlined)),
          ],
          selected: {_mode},
          onSelectionChanged: (set) => setState(() => _mode = set.first),
        ),
        const SizedBox(height: 8),
        Text(switch (_mode) {
          CollabMode.quick => '各席位并行作答，主席直接综合。',
          CollabMode.deliberative => '第一轮后互看匿名答案修订一轮，成本约 2 倍。',
          CollabMode.evidence => '权威席位先答，其余成员只做校验与补漏。',
        }, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _busy || _selected.length < 2 || _question.text.trim().isEmpty ? null : _submit,
          icon: const Icon(Icons.groups_outlined),
          label: Text(
            _selected.length < 2
                ? '至少选 2 个成员'
                : '提交 · ${_selected.length} 位成员 · ${_mode == CollabMode.quick ? '快速' : '审议'} · 预计 ${_selected.length * (_mode == CollabMode.deliberative ? 2 : 1) + 1} 次调用',
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 裁决的结构化渲染

  Widget _verdictBody(BuildContext context, String verdict) {
    final theme = Theme.of(context);
    final parsed = parseVerdict(verdict);
    if (!parsed.isStructured) {
      return SelectableText(verdict, style: theme.textTheme.bodyMedium);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (parsed.conclusion case final conclusion?) SelectableText(conclusion, style: theme.textTheme.bodyLarge),
        if (parsed.confidence case final c?) ...[const SizedBox(height: 8), _confidenceRow(theme, c)],
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

  // ---------------------------------------------------------------------------
  // 已选成员：角色与深度思考

  Widget _seatEditRow(String key, ModelCatalog? catalog) {
    final theme = Theme.of(context);
    final parts = key.split('|');
    final provider = parts.first;
    final model = parts.sublist(1).join('|');
    final name = _modelName(catalog, provider, model);
    var efforts = const <ReasoningEffort>[];
    if (catalog != null) {
      for (final group in catalog.groups) {
        for (final info in group.models) {
          if (info.provider == provider && info.id == model) efforts = info.efforts;
        }
      }
    }
    final brand = brandOf(provider, model);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(brandIconData(brand), size: 18, color: brandColor(brand, theme.colorScheme.primary)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
          ),
          DropdownButton<SeatRole>(
            value: _roles[key] ?? SeatRole.none,
            underline: const SizedBox.shrink(),
            style: theme.textTheme.labelMedium,
            items: [for (final role in SeatRole.values) DropdownMenuItem(value: role, child: Text(role.label))],
            onChanged: (role) => setState(() {
              if (role != null) _roles[key] = role;
            }),
          ),
          if (efforts.isNotEmpty) ...[
            const SizedBox(width: 4),
            DropdownButton<String>(
              value: _efforts[key] ?? '',
              underline: const SizedBox.shrink(),
              style: theme.textTheme.labelMedium,
              items: [
                const DropdownMenuItem(value: '', child: Text('默认思考')),
                for (final effort in efforts) DropdownMenuItem(value: effort.id, child: Text(effort.name)),
              ],
              onChanged: (value) => setState(() {
                if (value == null) return;
                if (value.isEmpty) {
                  _efforts.remove(key);
                } else {
                  _efforts[key] = value;
                }
              }),
            ),
          ],
          IconButton(
            tooltip: '移除',
            icon: const Icon(Icons.close, size: 16),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            onPressed: () => setState(() => _selected.remove(key)),
          ),
        ],
      ),
    );
  }

  Widget _brandAvatar(String provider, String name) {
    final brand = brandOf(provider, name);
    final color = brandColor(brand, Theme.of(context).colorScheme.primary);
    return Icon(brandIconData(brand), color: color, size: 18);
  }

  // ---------------------------------------------------------------------------
  // 运行态

  Widget _buildRun(BuildContext context, CollabRun run) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text('议题', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        SelectableText(run.spec.question, style: theme.textTheme.bodyLarge),
        const SizedBox(height: 16),
        Row(
          children: [
            Text(
              run.spec.mode == CollabMode.quick ? '快速 · 民主计票' : '审议 · 两轮',
              style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const Spacer(),
            Text(
              '${run.answeredCount}/${run.spec.seats.length} 席 · ${run.callsUsed} 次调用',
              style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final seat in run.spec.seats) _seatRow(context, run, seat),
        if (run.phase.isTerminal) ...[
          const SizedBox(height: 16),
          if (run.verdict != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.gavel_rounded, size: 18, color: theme.colorScheme.primary),
                        const SizedBox(width: 6),
                        Text('主席裁决', style: theme.textTheme.titleSmall),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _verdictBody(context, run.verdict!),
                  ],
                ),
              ),
            ),
          if (run.failure != null && run.verdict == null)
            Text(run.failure!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => setState(() {
              _run = null;
              _sub?.cancel();
              _sub = null;
            }),
            icon: const Icon(Icons.add_comment_outlined),
            label: const Text('再问一次'),
          ),
        ],
      ],
    );
  }

  Widget _seatRow(BuildContext context, CollabRun run, SeatSpec seat) {
    final theme = Theme.of(context);
    final state = run.seatOf(seat.id);
    final (label, color) = switch (state.status) {
      SeatStatus.pending => ('等待中', theme.colorScheme.onSurfaceVariant),
      SeatStatus.running => ('作答中…', theme.colorScheme.primary),
      SeatStatus.answered => ('已作答', theme.colorScheme.primary),
      SeatStatus.revised => ('已修订', theme.colorScheme.primary),
      SeatStatus.failed => ('失败${state.error == null ? '' : '：${state.error}'}', theme.colorScheme.error),
      SeatStatus.timedOut => ('超时${state.attempts > 1 ? '（重试后）' : ''}', theme.colorScheme.error),
      SeatStatus.cancelled => ('已取消', theme.colorScheme.onSurfaceVariant),
    };
    final brand = brandOf(seat.provider, seat.model);
    final sessionId = state.sessionId;
    return InkWell(
      // 席位会话不在历史列表里，点这一行去看它的完整对话。
      onTap: sessionId == null || sessionId.isEmpty ? null : () => _openSession(sessionId),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(brandIconData(brand), size: 18, color: brandColor(brand, theme.colorScheme.primary)),
            const SizedBox(width: 8),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      seat.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  if (seat.role != SeatRole.none)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(
                        seat.role.label,
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            ),
            if (state.tokensOut > 0)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '${state.tokensIn}/${state.tokensOut}',
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            Text(label, style: theme.textTheme.labelMedium?.copyWith(color: color)),
            if (sessionId != null && sessionId.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.chevron_right, size: 16, color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}
