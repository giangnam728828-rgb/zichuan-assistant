// 模式视图的测试脚手架：视图不再自带顶栏（顶栏是统一的 ChatHeader），
// 这里用一条最小的「标题 + 状态 + 成员键 + ⋯」代替，动作与生产一致：
// 成员键直接触发第一个菜单动作，⋯ 里是其余动作和「新会话」。

import 'package:dsh_app/ui/chat/shared/conversation_mode_host.dart';
import 'package:flutter/material.dart';

class ModeViewHarness extends StatelessWidget {
  const ModeViewHarness({super.key, required this.header, required this.child, this.newLabel = '新会话'});

  final ValueNotifier<CollabHeaderInfo?> header;
  final Widget child;
  final String newLabel;

  @override
  Widget build(BuildContext context) {
    // 视图不再自带 Scaffold（生产里由 ChatScreen 提供）；测试脚手架补上。
    return Scaffold(
      body: Column(
      children: [
        ValueListenableBuilder<CollabHeaderInfo?>(
          valueListenable: header,
          builder: (context, info, _) {
            final actions = info?.actions ?? const <CollabMenuAction>[];
            return SizedBox(
              height: 60,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(info?.title ?? '', key: const ValueKey('harness-title')),
                        Text(info?.subtitle ?? '', key: const ValueKey('harness-subtitle')),
                      ],
                    ),
                  ),
                  if (actions.isNotEmpty)
                    IconButton(
                      key: ValueKey(actions.first.key),
                      onPressed: actions.first.onTap,
                      icon: const Icon(Icons.group),
                    ),
                  PopupMenuButton<VoidCallback>(
                    tooltip: '更多',
                    onSelected: (fn) => fn(),
                    itemBuilder: (_) => [
                      for (final action in actions.skip(1))
                        PopupMenuItem(value: action.onTap, child: Text(action.label)),
                      if (info?.onNew case final onNew?) PopupMenuItem(value: onNew, child: Text(newLabel)),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
        Expanded(child: child),
      ],
      ),
    );
  }
}