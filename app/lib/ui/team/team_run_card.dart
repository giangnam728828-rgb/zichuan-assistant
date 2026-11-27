// 团队进展卡（S8）：把任务图如实画出来。
//
// 显示的每一行都来自 [TeamRun] 的落盘状态：谁负责、依赖谁、做到哪一步、
// 主管有没有打回。没有的字段不编（当前动作来自 activity，没有就不写）。
//
// 卡片默认收起成一行，点开才展开任务列表；任务多的团队不会一进来就占满屏。

import 'package:flutter/material.dart';

import '../../council/collab_models.dart';
import '../../team/team_models.dart';
import '../../team/team_tasks.dart';
import '../theme/app_icons.dart';
import '../theme/surfaces.dart';

class TeamRunCard extends StatefulWidget {
  const TeamRunCard({
    super.key,
    required this.team,
    required this.run,
    this.busy = false,
    this.onResume,
    this.onCancel,
  });

  final TeamState team;
  final TeamRun run;

  /// 这一轮还在后台跑（页面自己的 busy）：运行中不显示「继续」。
  final bool busy;
  final VoidCallback? onResume;
  final VoidCallback? onCancel;

  @override
  State<TeamRunCard> createState() => _TeamRunCardState();
}

class _TeamRunCardState extends State<TeamRunCard> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final run = widget.run;
    final tone = _toneOf(run.status, colors);
    final done = run.doneCount;
    final total = run.tasks.length;
    final paused = !run.isTerminal && !widget.busy && widget.team.running.isEmpty;

    return Container(
      key: const ValueKey('team-run-card'),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(
                children: [
                  Icon(AppIcons.team, size: 18, color: tone),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('任务图', style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
                            const SizedBox(width: 8),
                            Text(
                              _statusLabel(run.status),
                              style: theme.textTheme.labelSmall?.copyWith(color: tone, fontWeight: FontWeight.w600),
                            ),
                            if (total > 0) ...[
                              const SizedBox(width: 8),
                              Text(
                                '$done/$total',
                                style: theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
                              ),
                            ],
                          ],
                        ),
                        if (run.goal.trim().isNotEmpty)
                          Text(
                            run.goal.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                  if (run.note.trim().isNotEmpty)
                    Tooltip(
                      message: run.note,
                      child: Icon(AppIcons.info, size: 16, color: colors.onSurfaceVariant),
                    ),
                  const SizedBox(width: 4),
                  Icon(_open ? AppIcons.collapse : AppIcons.expand, size: 16, color: colors.onSurfaceVariant),
                ],
              ),
            ),
          ),
          if (_open) ...[
            if (run.tasks.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: Column(
                  children: [
                    for (final task in _ordered(run.tasks))
                      _TaskRow(
                        task: task,
                        owner: widget.team.mate(task.ownerId)?.name ?? '队友',
                        depth: _depthOf(run.tasks, task),
                        activity: widget.team.activity[task.ownerId],
                      ),
                  ],
                ),
              ),
            if (run.summary.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
                child: Text(
                  run.summary.trim(),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (paused && widget.onResume != null)
                    TextButton(
                      key: const ValueKey('team-run-resume'),
                      onPressed: widget.onResume,
                      child: const Text('继续'),
                    ),
                  if (!run.isTerminal && !paused && widget.onCancel != null)
                    TextButton(
                      key: const ValueKey('team-run-cancel'),
                      onPressed: widget.onCancel,
                      child: const Text('停止'),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TaskRow extends StatefulWidget {
  const _TaskRow({required this.task, required this.owner, required this.depth, this.activity});

  final TeamTask task;
  final String owner;
  final int depth;
  final CollabActivity? activity;

  @override
  State<_TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<_TaskRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final task = widget.task;
    final tone = _taskTone(task.status, colors);
    final running = task.status == TeamTaskStatus.running;
    return Padding(
      padding: EdgeInsets.only(left: widget.depth * 14.0, bottom: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: task.result.trim().isEmpty && widget.activity == null ? null : () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_taskIcon(task.status), size: 15, color: tone),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: running ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ),
                  Text(widget.owner, style: theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant)),
                  if (task.attempts > 1) ...[
                    const SizedBox(width: 6),
                    Text('第 ${task.attempts} 次', style: theme.textTheme.labelSmall?.copyWith(color: colors.error)),
                  ],
                ],
              ),
              if (running && widget.activity != null)
                Padding(
                  padding: const EdgeInsets.only(left: 21, top: 2),
                  child: Text(
                    widget.activity!.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(color: colors.primary),
                  ),
                ),
              if (task.status == TeamTaskStatus.blocked)
                Padding(
                  padding: const EdgeInsets.only(left: 21, top: 2),
                  child: Text('等待上游任务', style: theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant)),
                ),
              if (_open && (task.review.trim().isNotEmpty || task.result.trim().isNotEmpty))
                Padding(
                  padding: const EdgeInsets.only(left: 21, top: 4),
                  child: Text(
                    task.review.trim().isNotEmpty ? task.review.trim() : task.result.trim(),
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _statusLabel(TeamRunStatus status) => switch (status) {
  TeamRunStatus.planning => '规划中',
  TeamRunStatus.running => '执行中',
  TeamRunStatus.reviewing => '审核中',
  TeamRunStatus.summarizing => '汇总中',
  TeamRunStatus.done => '已完成',
  TeamRunStatus.failed => '未完成',
  TeamRunStatus.cancelled => '已停止',
};

Color _toneOf(TeamRunStatus status, ColorScheme colors) => switch (status) {
  TeamRunStatus.done => colors.primary,
  TeamRunStatus.failed => colors.error,
  TeamRunStatus.cancelled => colors.onSurfaceVariant,
  _ => colors.primary,
};

IconData _taskIcon(TeamTaskStatus status) => switch (status) {
  TeamTaskStatus.done => AppIcons.done,
  TeamTaskStatus.failed => AppIcons.warning,
  TeamTaskStatus.cancelled => AppIcons.close,
  TeamTaskStatus.running => AppIcons.loading,
  TeamTaskStatus.reviewing => AppIcons.preview,
  TeamTaskStatus.blocked => AppIcons.lock,
  _ => AppIcons.pending,
};

Color _taskTone(TeamTaskStatus status, ColorScheme colors) => switch (status) {
  TeamTaskStatus.done => colors.primary,
  TeamTaskStatus.failed => colors.error,
  TeamTaskStatus.running => colors.primary,
  TeamTaskStatus.cancelled => colors.onSurfaceVariant,
  _ => colors.outline,
};

/// 按依赖顺序排列，让上游任务总在依赖它的任务前面。
List<TeamTask> _ordered(List<TeamTask> tasks) {
  final out = <TeamTask>[];
  final seen = <String>{};
  void visit(TeamTask task) {
    if (!seen.add(task.id)) return;
    for (final dep in task.deps) {
      final upstream = tasks.where((t) => t.id == dep).firstOrNull;
      if (upstream != null) visit(upstream);
    }
    if (tasks.contains(task)) out.add(task);
  }

  for (final task in tasks) {
    visit(task);
  }
  return out;
}

int _depthOf(List<TeamTask> tasks, TeamTask task) {
  if (task.deps.isEmpty) return 0;
  var depth = 0;
  for (final dep in task.deps) {
    final upstream = tasks.where((t) => t.id == dep).firstOrNull;
    if (upstream != null) depth = depth > _depthOf(tasks, upstream) ? depth : _depthOf(tasks, upstream);
  }
  return depth + 1;
}
