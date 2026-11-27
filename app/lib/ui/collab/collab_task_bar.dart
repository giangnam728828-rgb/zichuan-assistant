// 任务上下文条：把「这件事是什么、做到哪」放在聊天里（方案第一部分 3.3）。
//
// 用户在群里说的是一句话，真正要干的事（方案、仓库、分支、谁负责、哪几步
// 做完了）记在 [CollabTaskContext] 里。这里把它收成一条可折叠的行：
// 平时一行小字（目标 · 仓库 · 阶段），点开看到资料编号、成员、任务项与结果。
//
// 它进的是共享时间线（[CollabTimelineRow]），议会和团队长得一样。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../collab/collab_task_context.dart';
import '../theme/app_icons.dart';
import '../theme/motion.dart';

class CollabTaskBar extends StatefulWidget {
  const CollabTaskBar({super.key, required this.task, this.onOpenSource});

  final CollabTaskContext task;

  /// 点「资料 #m1」时回到那条历史消息（可选）。
  final ValueChanged<String>? onOpenSource;

  @override
  State<CollabTaskBar> createState() => _CollabTaskBarState();
}

class _CollabTaskBarState extends State<CollabTaskBar> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final task = widget.task;
    final accent = switch (task.stage) {
      CollabTaskStage.failed => colors.error,
      CollabTaskStage.done => colors.primary,
      CollabTaskStage.waiting => colors.tertiary,
      _ => colors.primary,
    };
    final line = [
      task.goal.isEmpty ? '这件事' : _clip(task.goal, 28),
      if (task.repo case final repo?) repo,
      if (task.branch case final branch?) '分支 $branch',
      task.progressLabel,
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const ValueKey('collab-task-bar'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
              child: Row(
                children: [
                  Icon(AppIcons.queued, size: 15, color: accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: AppMotion.of(context, AppMotion.quick),
                    child: Icon(AppIcons.expand, size: 15, color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: AppMotion.of(context, AppMotion.standard),
            curve: AppMotion.std,
            alignment: Alignment.topCenter,
            child: _open ? _details(context, task) : const SizedBox(width: double.infinity, height: 0),
          ),
        ],
      ),
    );
  }

  Widget _details(BuildContext context, CollabTaskContext task) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final row = theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (task.goal.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(task.goal, style: theme.textTheme.bodySmall),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (task.repo case final repo?) _Fact(label: '仓库', value: repo, onCopy: () => _copy(repo)),
              if (task.branch case final branch?) _Fact(label: '分支', value: branch, onCopy: () => _copy(branch)),
              if (task.credentialRef case final ref?) _Fact(label: '凭据', value: '$ref（安全存储）'),
              _Fact(label: '阶段', value: task.stage.label),
              if (task.memberIds.isNotEmpty) _Fact(label: '成员', value: '${task.memberIds.length} 位'),
            ],
          ),
          if (task.sourceMessageIds.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                Text('资料：', style: row),
                for (final id in task.sourceMessageIds.take(6))
                  InkWell(
                    onTap: widget.onOpenSource == null ? null : () => widget.onOpenSource!(id),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      child: Text('#$id', style: row?.copyWith(color: colors.primary)),
                    ),
                  ),
              ],
            ),
          ],
          if (task.items.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final item in task.items) _ItemRow(item: item),
          ],
          if (task.done.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('已完成：${task.done.length} 项', style: row),
          ],
          if (task.pending.isNotEmpty) Text('还差：${task.pending.take(3).join('、')}', style: row),
          if (task.testStatus.isNotEmpty) Text('测试：${task.testStatus}', style: row),
          if (task.buildStatus.isNotEmpty) Text('构建：${task.buildStatus}', style: row),
          if (task.result.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('结果：${_clip(task.result, 160)}', style: theme.textTheme.bodySmall),
          ],
          if (task.failure case final failure?) ...[
            const SizedBox(height: 6),
            Text('失败：$failure', style: theme.textTheme.bodySmall?.copyWith(color: colors.error)),
          ],
        ],
      ),
    );
  }

  void _copy(String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('已复制 $value')));
  }

  static String _clip(String text, int max) {
    final body = text.trim().replaceAll('\n', ' ');
    return body.length <= max ? body : '${body.substring(0, max)}…';
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.onCopy});

  final String label;
  final String value;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onCopy,
      borderRadius: BorderRadius.circular(6),
      child: Text(
        '$label $value',
        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item});

  final CollabTaskItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (icon, tone) = switch (item.status) {
      CollabTaskStage.done => (AppIcons.done, colors.primary),
      CollabTaskStage.failed => (AppIcons.info, colors.error),
      CollabTaskStage.cancelled => (AppIcons.close, colors.onSurfaceVariant),
      CollabTaskStage.running => (AppIcons.inProgress, colors.primary),
      _ => (AppIcons.queued, colors.onSurfaceVariant),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: tone),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${item.title}${item.owner == null ? '' : ' · ${item.owner}'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: colors.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}
