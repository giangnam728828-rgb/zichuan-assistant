// 川水 · 「历史」标签页。
//
// 内容是原抽屉的主体（搜索、工作区、过滤器、会话列表），去掉与底部导航重复的
// 设置 / 全部功能按钮。点会话或新对话都会切回「对话」标签（新对话并聚焦输入框），
// 否则切了标签还停在历史页，像是没反应。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shell/root_tab.dart';
import '../shell/sessions_drawer.dart';
import '../shell/shell_insets.dart';

class SessionsPage extends ConsumerWidget {
  const SessionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final insets = ShellInsets.maybeOf(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          Expanded(
            child: SessionsDrawer(
              embedded: true,
              // 点会话 / 新对话：切回对话标签，并让列表回到最新。
              onClose: () => switchTab(context, RootTab.chat, intent: TabIntent.scrollBottom),
              onOpen: (destination) {
                // 历史页里不再放这些入口，但保留回调以复用组件。
              },
            ),
          ),
          // 外壳（TabShell）已经把整页抬到「导航 + 间隙 + 安全区」之上，
          // 这里再加一份同样的高度就是重复计算：历史列表底部会空出一整条
          // 导航高度的空白（v4.3 · P0-E · 6.2）。只留 8dp 呼吸位。
          if (insets != null) const SizedBox(height: 8),
        ],
      ),
    );
  }
}
