// 历史里的协作会话：议会与团队在历史页的分类、条目与整段列表。
//
// 方案第三部分：历史对话增加「全部 / 普通 / 议会 / 团队」；议会与团队各自
// 独立成段，点开恢复原会话（不新建），长按只删这一条。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collab/collab_conversations.dart';
import '../../collab/collab_export.dart';
import '../common/app_sheet.dart';
import '../shell/drawer/session_tile.dart' show SessionTile;
import '../workspace/text_prompt.dart' show showTextPrompt;
import '../../state/history_kind_state.dart';
import '../common/capsule_chip.dart';
import 'conversation_nav.dart';
import '../theme/app_icons.dart';

/// 一行分类胶囊：全部 | 普通 | 议会 | 团队。
class HistoryKindBar extends ConsumerWidget {
  const HistoryKindBar({super.key});

  /// Gap between capsules.
  static const gap = 8.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = ref.watch(historyKindProvider);
    // 一条议会/团队会话都没有、也没选分类：不摆这一行（和状态筛选同一约定）。
    final collab = ref.watch(collabHistoryProvider).value ?? const <CollabHistoryEntry>[];
    if (collab.isEmpty && kind == HistoryKind.all) return const SizedBox(width: double.infinity);
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(canvasColor: Colors.transparent),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
        child: Row(
          children: [
            for (final (index, value) in HistoryKind.values.indexed) ...[
              if (index > 0) const SizedBox(width: gap),
              Semantics(
                key: ValueKey('history-kind-${value.name}'),
                label: '类型 ${value.label}',
                selected: value == kind,
                excludeSemantics: true,
                button: true,
                onTap: () => ref.read(historyKindProvider.notifier).select(value),
                child: CapsuleChoiceChip(
                  label: value.label,
                  selected: value == kind,
                  onSelected: () => ref.read(historyKindProvider.notifier).select(value),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 历史里的一条协作会话：**就是普通会话那一行**，只多一枚类型标签。
///
/// v4.3 · P0-G：以前这里是一张独立的大图标卡片（图标更大、行高不同、
/// 描述另占一行，选中高亮也没有同步过来）。现在直接复用 [SessionTile]：
/// 三类记录同一行高、同一字号与基线、同一标题位置、同一选中背景。
class CollabHistoryTile extends StatelessWidget {
  const CollabHistoryTile({super.key, required this.entry, required this.onTap, this.onLongPress, this.current = false});

  final CollabHistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// 是不是当前打开的那一条（历史页里也用同一套高亮）。
  final bool current;

  @override
  Widget build(BuildContext context) {
    return SessionTile(
      title: entry.title,
      kindTag: collabKindLabel(entry.kind),
      running: entry.status == CollabRunStatus.running,
      current: current,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

/// 「议会」/「团队」小标签。
class CollabKindTag extends StatelessWidget {
  const CollabKindTag({super.key, required this.kind});

  final CollabKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = kind == CollabKind.council ? theme.colorScheme.primary : theme.colorScheme.tertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
      child: Text(
        collabKindLabel(kind),
        style: theme.textTheme.labelSmall?.copyWith(color: color, height: 1.4),
      ),
    );
  }
}

/// 某一种协作会话的整页列表（历史页切到「议会」/「团队」时）。
class CollabHistoryList extends ConsumerWidget {
  const CollabHistoryList({super.key, required this.kind, this.onClose});

  final CollabKind kind;

  /// 打开一条后关掉抽屉/切回聊天。
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final entries = ref.watch(collabHistoryProvider).value ?? const <CollabHistoryEntry>[];
    final shown = [
      for (final entry in entries)
        if (entry.kind == kind) entry,
    ];
    if (shown.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                kind == CollabKind.council ? AppIcons.team : AppIcons.groupChat,
                size: 34,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(height: 10),
              Text(
                kind == CollabKind.council ? '还没有议会会话' : '还没有团队会话',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }
    final currentRef = currentConversationRef(ref);
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
      children: [
        for (final entry in shown)
          CollabHistoryTile(
            key: ValueKey('collab-${entry.kind.name}-${entry.id}'),
            entry: entry,
            current: _isCurrent(currentRef, entry),
            onTap: () => openCollabEntry(context, entry, onClose: onClose),
            onLongPress: () => showCollabEntrySheet(context, ref, entry),
          ),
      ],
    );
  }
}

/// 「全部」里置顶的一段：议会 + 团队，最近的几条。
class CollabHistorySection extends ConsumerWidget {
  const CollabHistorySection({super.key, required this.onClose, this.limit = 6});

  final VoidCallback? onClose;
  final int limit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(collabHistoryProvider).value ?? const <CollabHistoryEntry>[];
    if (entries.isEmpty) return const SizedBox.shrink();
    final shown = entries.take(limit).toList();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
          child: Text('议会与团队', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        for (final entry in shown)
          CollabHistoryTile(
            key: ValueKey('collab-${entry.kind.name}-${entry.id}'),
            entry: entry,
            current: _isCurrent(currentConversationRef(ref), entry),
            onTap: () => openCollabEntry(context, entry, onClose: onClose),
            onLongPress: () => showCollabEntrySheet(context, ref, entry),
          ),
        const Divider(height: 20, indent: 10, endIndent: 10),
      ],
    );
  }
}

/// 长按一条协作记录：详情 + 操作面板（v4.3 · P0-H）。
///
/// 与普通会话同一个 [showAppSheet] 容器、圆角与按压反馈，只换数据与操作项：
/// 标题、类型、成员数、创建/更新时间、当前状态、最近一条提问与回答，以及
/// 打开、重命名、导出 Markdown、继续运行、删除（二次确认）。
Future<void> showCollabEntrySheet(BuildContext context, WidgetRef ref, CollabHistoryEntry entry) async {
  final theme = Theme.of(context);
  final action = await showAppSheet<String>(
    context,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.82),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SheetHeader(entry.title, maxLines: 2),
              _DetailBlock(entry: entry),
              SheetGroup(
                children: [
                  ListTile(
                    key: const ValueKey('collab-sheet-open'),
                    leading: const Icon(AppIcons.chat),
                    title: const Text('打开原会话'),
                    subtitle: Text(entry.status == CollabRunStatus.running ? '正在运行，打开就能接着看' : '恢复原来的会话，不新建'),
                    onTap: () => Navigator.pop(sheet, 'open'),
                  ),
                  ListTile(
                    key: const ValueKey('collab-sheet-rename'),
                    leading: const Icon(AppIcons.rename),
                    title: const Text('重命名'),
                    onTap: () => Navigator.pop(sheet, 'rename'),
                  ),
                  ListTile(
                    key: const ValueKey('collab-sheet-export'),
                    leading: const Icon(AppIcons.share),
                    title: const Text('导出 Markdown'),
                    onTap: () => Navigator.pop(sheet, 'export'),
                  ),
                  if (entry.resumable)
                    ListTile(
                      key: const ValueKey('collab-sheet-resume'),
                      leading: const Icon(AppIcons.play),
                      title: const Text('继续未完成的运行'),
                      subtitle: const Text('已完成的成员不会重跑，原问题不会重发'),
                      onTap: () => Navigator.pop(sheet, 'resume'),
                    ),
                  ListTile(
                    key: const ValueKey('collab-sheet-delete'),
                    leading: Icon(AppIcons.delete, color: theme.colorScheme.error),
                    title: Text('删除', style: TextStyle(color: theme.colorScheme.error)),
                    subtitle: const Text('需要再确认一次；其他会话不受影响'),
                    onTap: () => Navigator.pop(sheet, 'delete'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    ),
  );
  if (!context.mounted || action == null) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  switch (action) {
    case 'open':
      openCollabEntry(context, entry);
    case 'rename':
      final next = await showTextPrompt(
        context,
        title: '重命名${collabKindLabel(entry.kind)}会话',
        initial: entry.title,
        hint: '会话名称',
        maxLength: 80,
      );
      if (next == null || next.trim().isEmpty || next.trim() == entry.title) return;
      await renameCollabEntry(ref, entry, next);
    case 'export':
      try {
        final content = await collabMarkdownFor(ref, entry);
        await shareMarkdownFile(fileName: '${collabKindLabel(entry.kind)}-${entry.title}.md', content: content);
      } on Object catch (error) {
        messenger?.showSnackBar(SnackBar(content: Text('导出失败：$error')));
      }
    case 'resume':
      final ok = await resumeCollabEntry(ref, entry);
      if (!ok) messenger?.showSnackBar(const SnackBar(content: Text('还连不上引擎，稍后再试。')));
    case 'delete':
      if (!context.mounted) return;
      await confirmDeleteCollab(context, ref, entry);
  }
}

/// 详情面板里的事实区：类型、成员、时间、状态、最近一问一答。
class _DetailBlock extends StatelessWidget {
  const _DetailBlock({required this.entry});

  final CollabHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final rows = <(String, String)>[
      ('类型', collabKindLabel(entry.kind)),
      ('成员', entry.memberLabel),
      ('创建时间', collabStamp(entry.createdAt)),
      ('最近更新', collabStamp(entry.updatedAt)),
      ('当前状态', entry.status.label),
      if (entry.failure case final failure? when failure.trim().isNotEmpty) ('上次的问题', failure.trim()),
    ];
    Widget label(String text) => SizedBox(
      width: 64,
      child: Text(text, style: theme.textTheme.labelSmall?.copyWith(color: muted)),
    );
    Widget body(String text) => Expanded(
      child: Text(text, style: theme.textTheme.bodySmall, maxLines: 3, overflow: TextOverflow.ellipsis),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (name, value) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [label(name), body(value)]),
            ),
          if (entry.lastQuestion.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('最近的提问', style: theme.textTheme.labelSmall?.copyWith(color: muted)),
            const SizedBox(height: 2),
            Text(
              entry.lastQuestion.trim(),
              key: const ValueKey('collab-sheet-question'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (entry.lastAnswer.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('最近的回答', style: theme.textTheme.labelSmall?.copyWith(color: muted)),
            const SizedBox(height: 2),
            Text(
              entry.lastAnswer.trim(),
              key: const ValueKey('collab-sheet-answer'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ],
      ),
    );
  }
}

/// 打开一条协作会话：在同一个聊天工作区里恢复原会话，不新建、不 push 页面。
void openCollabEntry(BuildContext context, CollabHistoryEntry entry, {VoidCallback? onClose}) {
  onClose?.call();
  // v4.2 · P0-C：与普通历史、任务中心共用同一个类型化入口。
  openConversationWith(
    ProviderScope.containerOf(context, listen: false),
    context,
    ConversationRef.fromCollab(entry),
  );
}

/// 长按删除：只删这一条，别的会话不动。
Future<void> confirmDeleteCollab(BuildContext context, WidgetRef ref, CollabHistoryEntry entry) async {
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '删除这条${entry.kind == CollabKind.council ? '议会' : '团队'}会话？',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '「${entry.title}」的记录与成员配置会一起删掉，其他会话不受影响。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
              onPressed: () => Navigator.pop(sheetContext, true),
              child: const Text('删除'),
            ),
            TextButton(onPressed: () => Navigator.pop(sheetContext, false), child: const Text('取消')),
          ],
        ),
      ),
    ),
  );
  if (confirmed != true) return;
  await deleteCollabEntry(ref, entry);
}

/// 这一条是不是当前打开的协作会话（类型 + id 同时对上才算）。
bool _isCurrent(ConversationRef? ref, CollabHistoryEntry entry) {
  if (ref == null) return false;
  return switch ((ref.kind, entry.kind)) {
    (ConversationKind.team, CollabKind.team) => ref.conversationId == entry.id,
    (ConversationKind.council, CollabKind.council) => ref.conversationId == entry.id,
    _ => false,
  };
}
