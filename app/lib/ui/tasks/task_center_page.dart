// 任务工作台（v3 · 第四步）。
//
// 从底部「任务」标签进入。数据完全来自现有 collabTaskProvider 与
// CollabTaskContext——不另建一套任务数据库。主聊天区不再展示任务详情卡片，
// 所有目标、子任务、测试与构建结果都集中在这里。
//
// 任务卡片点开的是**原会话**（按 kind + conversationId），不是新建一条。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collab/collab_task_context.dart';
import '../../state/conversation_mode_state.dart';
import '../shell/root_tab.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// 顶部七档：与方案 4.2 一致的分组。
const _sections = <CollabTaskStage>[
  CollabTaskStage.running,
  CollabTaskStage.planning,
  CollabTaskStage.waiting,
  CollabTaskStage.testing,
  CollabTaskStage.building,
  CollabTaskStage.failed,
  CollabTaskStage.cancelled,
  CollabTaskStage.done,
];

final class _Group {
  const _Group({required this.stage, required this.tasks});

  final CollabTaskStage stage;
  final List<CollabTaskContext> tasks;
}

class TaskCenterPage extends ConsumerStatefulWidget {
  const TaskCenterPage({super.key});

  @override
  ConsumerState<TaskCenterPage> createState() => _TaskCenterPageState();
}

class _TaskCenterPageState extends ConsumerState<TaskCenterPage> {
  final _open = <String>{};

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(collabTaskProvider);
    final theme = Theme.of(context);
    final ordered = tasks.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final groups = [
      for (final stage in _sections)
        _Group(stage: stage, tasks: [for (final task in ordered) if (task.stage == stage) task]),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('任务工作台')),
      body: ordered.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(AppIcons.queued, size: 38, color: theme.colorScheme.outline),
                    const SizedBox(height: 12),
                    Text(
                      '还没有协作任务',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '在团队或议会里交代一件事后，目标、进度、测试与构建结果都会集中到这里。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                for (final group in groups)
                  if (group.tasks.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
                      child: Text(
                        '${group.stage.label} · ${group.tasks.length}',
                        style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                    for (final task in group.tasks)
                      _TaskCard(
                        task: task,
                        expanded: _open.contains(task.id),
                        onToggle: () => setState(() {
                          if (_open.contains(task.id)) {
                            _open.remove(task.id);
                          } else {
                            _open.add(task.id);
                          }
                        }),
                        onOpenConversation: () => _openConversation(context, ref, task),
                      ),
                  ],
              ],
            ),
    );
  }

  /// 打开原会话（议会用 conversationId，团队用 teamId 存在 conversationId 里）。
  void _openConversation(BuildContext context, WidgetRef ref, CollabTaskContext task) {
    final controller = ref.read(conversationModeProvider.notifier);
    if (task.kind == 'council') {
      controller.rememberCouncil('', task.conversationId);
    } else {
      controller.rememberTeam('', task.conversationId);
    }
    controller.openExisting(
      task.kind == 'council' ? ConversationMode.council : ConversationMode.team,
      task.conversationId,
    );
    switchTab(context, RootTab.chat);
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.expanded,
    required this.onToggle,
    required this.onOpenConversation,
  });

  final CollabTaskContext task;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onOpenConversation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final total = task.items.length;
    final done = total - task.openCount;
    final owner = _currentOwner(task);
    return Card(
      key: ValueKey('task-card-${task.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const ValueKey('task-open'),
            onTap: onToggle,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: colors.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          task.kind == 'council' ? '议会' : '团队',
                          style: theme.textTheme.labelSmall?.copyWith(color: colors.primary),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          task.goal.isEmpty ? '（没有标题的任务）' : task.goal,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    [
                      if (owner != null) '负责人 $owner',
                      if (task.currentStep.isNotEmpty) task.currentStep,
                      if (total > 0) '$done/$total',
                      task.stage.label,
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
                  ),
                  if (task.repo != null)
                    Text(
                      '${task.repo}${task.branch == null ? '' : ' · ${task.branch}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  const SizedBox(height: 2),
                  Text(
                    '更新 ${_time(task.updatedAt)}',
                    style: theme.textTheme.labelSmall?.copyWith(color: colors.outline),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: AppMotion.of(context, AppMotion.standard),
            curve: AppMotion.std,
            child: expanded ? _details(context, task) : const SizedBox(height: 0),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: FilledButton.tonal(
              key: const ValueKey('task-open-conversation'),
              onPressed: onOpenConversation,
              child: const Text('打开原会话'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _details(BuildContext context, CollabTaskContext task) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('完整目标', style: theme.textTheme.labelLarge),
          const SizedBox(height: 2),
          Text(task.goal.isEmpty ? '（无）' : task.goal, style: small),
          if (task.sourceMessageIds.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('来源消息：${task.sourceMessageIds.take(6).map((id) => '#$id').join('、')}', style: small),
          ],
          if (task.excerpts.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final entry in task.excerpts.entries)
              Text('${entry.key} ${entry.value}', maxLines: 3, overflow: TextOverflow.ellipsis, style: small),
          ],
          if (task.items.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('子任务', style: theme.textTheme.labelLarge),
            for (final item in task.items)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  '${item.status.label} · ${item.title}${item.owner == null ? '' : ' · ${item.owner}'}'
                  '${item.result.isEmpty ? '' : '\n${item.result}'}',
                  style: small,
                ),
              ),
          ],
          if (task.done.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('已完成：${task.done.join('、')}', style: small),
            ),
          if (task.pending.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('未完成：${task.pending.join('、')}', style: small),
            ),
          if (task.testStatus.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text('测试：${task.testStatus}', style: small)),
          if (task.buildStatus.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text('构建：${task.buildStatus}', style: small)),
          if (task.commitSha != null)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text('Commit ${task.commitSha}', style: small)),
          if (task.runUrl case final url?)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text('Actions $url', style: small)),
          if (task.artifactUrl case final url?)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text('APK $url', style: small)),
          if (task.result.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text('最终交付：${task.result}', style: small)),
          if (task.failure case final failure?)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('失败原因：$failure', style: small?.copyWith(color: colors.error)),
            ),
        ],
      ),
    );
  }

  static String? _currentOwner(CollabTaskContext task) {
    for (final item in task.items) {
      if (item.isOpen) return item.owner;
    }
    return null;
  }

  static String _time(DateTime at) {
    final local = at.toLocal();
    return '${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}
