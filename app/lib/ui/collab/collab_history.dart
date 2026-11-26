// 历史里的协作会话：议会与团队在历史页的分类、条目与整段列表。
//
// 方案第三部分：历史对话增加「全部 / 普通 / 议会 / 团队」；议会与团队各自
// 独立成段，点开恢复原会话（不新建），长按只删这一条。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collab/collab_conversations.dart';
import '../../collab/collab_export.dart';
import '../../state/conversation_mode_state.dart';
import '../../state/history_kind_state.dart';
import '../../state/hosts_state.dart';
import '../chat/conversation_mode_switcher.dart';
import '../common/capsule_chip.dart';
import '../council/council_page.dart';
import '../team/team_page.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

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

/// 历史里的一条协作会话：模式图标 + 标题 + 成员数/时间。
class CollabHistoryTile extends StatelessWidget {
  const CollabHistoryTile({super.key, required this.entry, required this.onTap, this.onLongPress});

  final CollabHistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isCouncil = entry.kind == CollabKind.council;
    final accent = isCouncil ? colors.primary : colors.tertiary;
    final icon = isCouncil ? AppIcons.team : AppIcons.groupChat;
    final subtitle = [entry.subtitle, if (entry.running) '进行中' else collabStamp(entry.updatedAt)].join(' · ');
    return Semantics(
      button: true,
      label: '${entry.title}，$subtitle',
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(AppShape.panel),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Icon(icon, size: 18, color: accent),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                          const SizedBox(width: 6),
                          CollabKindTag(kind: entry.kind),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${entry.memberLabel} · $subtitle',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (entry.running)
                  Padding(
                    padding: const EdgeInsets.only(left: 6, top: 10),
                    child: SizedBox(
                      width: 8,
                      height: 8,
                      child: CircularProgressIndicator(strokeWidth: 1.6, color: accent),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
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
        kind == CollabKind.council ? '议会' : '团队',
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
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
      children: [
        for (final entry in shown)
          CollabHistoryTile(
            key: ValueKey('collab-${entry.kind.name}-${entry.id}'),
            entry: entry,
            onTap: () => openCollabEntry(context, entry, onClose: onClose),
            onLongPress: () => confirmDeleteCollab(context, ref, entry),
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
            onTap: () => openCollabEntry(context, entry, onClose: onClose),
            onLongPress: () => confirmDeleteCollab(context, ref, entry),
          ),
        const Divider(height: 20, indent: 10, endIndent: 10),
      ],
    );
  }
}

/// 打开一条协作会话：恢复原会话，不新建。
void openCollabEntry(BuildContext context, CollabHistoryEntry entry, {VoidCallback? onClose}) {
  onClose?.call();
  final container = ProviderScope.containerOf(context, listen: false);
  final mode = entry.kind == CollabKind.council ? ConversationMode.council : ConversationMode.team;
  final controller = container.read(conversationModeProvider.notifier);
  controller.setMode(mode);
  // 从历史打开的这条就是该模式「上次用的那条」，再切回来还是它。
  final hostKey = conversationHostKey(container.read(activeHostProvider));
  if (mode == ConversationMode.council) {
    controller.rememberCouncil(hostKey, entry.id);
  } else {
    controller.rememberTeam(hostKey, entry.id);
  }
  Navigator.of(context, rootNavigator: true).push(
    conversationModeRoute<void>(
      context: context,
      page: switch (entry.kind) {
        CollabKind.council => CouncilPage(conversationId: entry.id, createNew: false),
        CollabKind.team => TeamPage(teamId: entry.id, createNew: false),
      },
    ),
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
