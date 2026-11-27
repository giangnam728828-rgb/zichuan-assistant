// 协作会话的深链入口：通知、横幅、历史。
//
// v4：三种模式共用同一个 ChatScreen 工作区，这里不再 push 独立页面——
// 只把「要打开哪条」写进模式状态，再切到聊天标签，工作区自己恢复原会话。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collab/collab_session_book.dart';
import '../../state/conversation_mode_state.dart';
import '../../state/hosts_state.dart';
import '../shell/root_tab.dart';

/// 点某条协作会话（通知、横幅）：回到那次议会/团队，而不是打开一个孤立的
/// 子会话。不是协作会话就返回 false，交给原来的聊天路由。
bool openCollabSession(BuildContext context, {required HostRef host, required String sessionId}) {
  final container = ProviderScope.containerOf(context, listen: false);
  final owner = container.read(collabSessionBookProvider)[sessionId];
  if (owner == null) return false;
  container.read(activeHostProvider.notifier).select(host);
  final controller = container.read(conversationModeProvider.notifier);
  final hostKey = conversationHostKey(host);
  if (owner.kind == CollabSessionKind.council) {
    // 议会的 ownerId 是某一次 run：视图启动后找回它所属的会话并自己登记。
    controller.openRun(owner.ownerId);
  } else {
    controller.rememberTeam(hostKey, owner.ownerId);
    controller.openExisting(ConversationMode.team, owner.ownerId);
  }
  final navigator = Navigator.of(context, rootNavigator: true);
  navigator.popUntil((route) => route.isFirst);
  switchTab(context, RootTab.chat);
  return true;
}