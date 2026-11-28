// 统一的「打开一条会话」入口（v4.2 · P0-A / P0-C）。
//
// 之前历史抽屉点普通会话只做了 `currentSessionProvider.select(id)`，没有把浏览
// 模式切回聊天：如果用户当时停在议会/团队，点进去看到的仍是议会/团队页面，
// 于是「普通历史被打开了团队/议会」。反过来，协作记录走的是另一条
// `openCollabEntry`，两套逻辑互不相干。
//
// 现在只有一条路：调用方给出 [ConversationRef]（明确的 kind + id），这里负责
// 切模式、选会话、恢复运行、回到聊天标签。谁都不许再靠「当前模式」猜类型。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/conversation_mode_state.dart';
import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import '../shell/root_tab.dart';
import '../../collab/collab_conversations.dart';

/// 会话的真实类型。**永远**由数据源给出，不由当前模式推断。
enum ConversationKind {
  normal('聊天'),
  team('团队'),
  council('议会');

  const ConversationKind(this.label);

  final String label;
}

/// 一条会话的类型化引用。
@immutable
final class ConversationRef {
  const ConversationRef({
    required this.kind,
    required this.conversationId,
    this.title = '',
    this.updatedAt,
    this.runId,
  });

  final ConversationKind kind;

  /// 普通会话是 Host sessionId；团队是 TeamState.id；议会是 CouncilConversation.id。
  final String conversationId;
  final String title;
  final DateTime? updatedAt;

  /// 协作运行 id（有就按它恢复那一次运行）。
  final String? runId;

  /// 从协作历史条目构造（kind 由条目自己带）。
  factory ConversationRef.fromCollab(CollabHistoryEntry entry) => ConversationRef(
    kind: entry.kind == CollabKind.council ? ConversationKind.council : ConversationKind.team,
    conversationId: entry.id,
    title: entry.title,
    updatedAt: entry.updatedAt,
  );

  @override
  bool operator ==(Object other) =>
      other is ConversationRef &&
      other.kind == kind &&
      other.conversationId == conversationId &&
      other.runId == runId;

  @override
  int get hashCode => Object.hash(kind, conversationId, runId);

  @override
  String toString() => 'ConversationRef(${kind.name}:$conversationId)';
}

/// 打开一条会话：按它自己的类型走，不覆盖别的会话。
///
/// - normal：切回聊天模式 + 选中原 sessionId（不新建、不清空）。
/// - council / team：记住这条会话、发一次「打开它」的请求。
/// - 全程不取消任何正在跑的运行。
void openConversation(BuildContext context, WidgetRef ref, ConversationRef target) =>
    openConversationWith(ref.container, context, target);

/// 同一个入口的 container 版本：历史抽屉里只有 ProviderContainer。
void openConversationWith(
  ProviderContainer container,
  BuildContext? context,
  ConversationRef target, {
  bool goToChatTab = true,
}) {
  final controller = container.read(conversationModeProvider.notifier);
  final hostKey = conversationHostKey(container.read(activeHostProvider));
  switch (target.kind) {
    case ConversationKind.normal:
      // 关键：先回聊天模式，否则页面仍是议会/团队，用户以为「普通历史变成团队了」。
      controller.setMode(ConversationMode.chat);
      container.read(currentSessionProvider.notifier).select(target.conversationId);
    case ConversationKind.council:
      controller.rememberCouncil(hostKey, target.conversationId);
      controller.openExisting(ConversationMode.council, target.conversationId);
    case ConversationKind.team:
      controller.rememberTeam(hostKey, target.conversationId);
      controller.openExisting(ConversationMode.team, target.conversationId);
  }
  if (goToChatTab && context != null) switchTab(context, RootTab.chat);
}

/// 当前模式对应的会话引用（给「最近会话」这类入口用）。
ConversationRef? currentConversationRef(WidgetRef ref) {
  final mode = ref.read(conversationModeProvider).mode;
  if (mode == ConversationMode.chat) {
    final id = ref.read(currentSessionProvider);
    return id == null ? null : ConversationRef(kind: ConversationKind.normal, conversationId: id);
  }
  final hostKey = conversationHostKey(ref.read(activeHostProvider));
  final id = ref.read(conversationModeProvider).idFor(mode, hostKey);
  if (id == null) return null;
  return ConversationRef(
    kind: mode == ConversationMode.council ? ConversationKind.council : ConversationKind.team,
    conversationId: id,
  );
}
