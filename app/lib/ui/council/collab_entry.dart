// 协作会话的深链入口：通知、横幅、历史。
//
// v2 起输入栏不再有「协作」弹层：模式切换在左上角
// （`ui/chat/conversation_mode_switcher.dart`）。这里只保留「点某条具体的
// 议会/团队会话」的打开逻辑——从通知回到那次运行，从历史回到那条会话。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collab/collab_session_book.dart';
import '../../state/conversation_mode_state.dart';
import '../../state/hosts_state.dart';
import '../chat/conversation_mode_switcher.dart';
import '../team/team_page.dart';
import 'council_page.dart';

/// 点某条协作会话（通知、横幅）：回到那次议会/团队，而不是打开一个孤立的
/// 子会话。不是协作会话就返回 false，交给原来的聊天路由。
bool openCollabSession(BuildContext context, {required HostRef host, required String sessionId}) {
  final container = ProviderScope.containerOf(context, listen: false);
  final owner = container.read(collabSessionBookProvider)[sessionId];
  if (owner == null) return false;
  container.read(activeHostProvider.notifier).select(host);
  final mode = owner.kind == CollabSessionKind.council ? ConversationMode.council : ConversationMode.team;
  final controller = container.read(conversationModeProvider.notifier);
  controller.setMode(mode);
  // 团队能直接记住主会话 id；议会的 ownerId 是某一次 run，页面启动后会
  // 找回它所属的会话并自己登记。
  if (mode == ConversationMode.team) {
    controller.rememberTeam(conversationHostKey(host), owner.ownerId);
  }
  final navigator = Navigator.of(context, rootNavigator: true);
  navigator.popUntil((route) => route.isFirst);
  navigator.push(conversationModeRoute<void>(context: context, page: _collabPage(owner)));
  return true;
}

Widget _collabPage(CollabSessionOwner owner) => owner.kind == CollabSessionKind.council
    ? CouncilPage(runId: owner.ownerId)
    : TeamPage(teamId: owner.ownerId, createNew: false);
