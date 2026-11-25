// 输入栏的「协作」入口：议会与团队。
//
// 两者都是「一次让多个模型参与」，但形态不同：议会是一次性的裁决（问完
// 就散），团队是长期群聊（队友有自己的会话与记忆）。所以合成一个键，
// 点开再选，输入栏不为了多一个功能再长一排键。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collab/collab_session_book.dart';
import '../../state/hosts_state.dart';
import '../team/team_page.dart';
import 'council_page.dart';

/// 点某条协作会话（通知、横幅）：回到那次议会/团队，而不是打开一个孤立的
/// 子会话。不是协作会话就返回 false，交给原来的聊天路由。
bool openCollabSession(BuildContext context, {required HostRef host, required String sessionId}) {
  final container = ProviderScope.containerOf(context, listen: false);
  final owner = container.read(collabSessionBookProvider)[sessionId];
  if (owner == null) return false;
  container.read(activeHostProvider.notifier).select(host);
  final navigator = Navigator.of(context, rootNavigator: true);
  navigator.popUntil((route) => route.isFirst);
  navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => owner.kind == CollabSessionKind.council
          ? CouncilPage(runId: owner.ownerId)
          : TeamPage(teamId: owner.ownerId),
    ),
  );
  return true;
}

Future<void> showCollabSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.groups_outlined),
            title: const Text('议会'),
            subtitle: const Text('同一个问题发给多家模型，主席综合出结论、共识与分歧'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CouncilPage()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.forum_outlined),
            title: const Text('团队'),
            subtitle: const Text('几位队友一个群，各用各的模型，@ 谁谁答'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TeamPage()));
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
