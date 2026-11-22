// 川水 · 「历史」标签页。
//
// 内容是原抽屉的主体（搜索、工作区、过滤器、会话列表），去掉与底部导航重复的
// 设置 / 全部功能按钮。点会话或新对话都会切回「对话」标签（新对话并聚焦输入框），
// 否则切了标签还停在历史页，像是没反应。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/sessions_state.dart' show currentSessionProvider;
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
          // 底部留白随导航高度连续变化，最后一行不会被悬浮导航盖住。
          if (insets != null)
            AnimatedBuilder(
              animation: insets.progress,
              builder: (context, _) => SizedBox(
                height:
                    insets.extentAt(insets.progress.value, safeBottom: MediaQuery.paddingOf(context).bottom) + 8,
              ),
            ),
        ],
      ),
    );
  }
}
