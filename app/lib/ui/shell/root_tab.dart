// 川水 · 底部四标签的单一状态源。
//
// 3a：对话 / 历史 / 工具 / 设置。伙伴入口取消，顶栏只留标题+模型+新对话。
// switchTab 先 popUntil 回根页，再切标签，避免标签切了上面还盖着二级页。
// 跨标签意图是一次性事件：消费后清空，旋转/重建不会重复触发。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 底部四标签。顺序即左右次序，切换动画的方向由它决定。
enum RootTab { chat, history, tools, settings }

/// 一次性的跨标签意图。
enum TabIntent {
  newChat,       // 新对话并聚焦输入框
  openSession,   // 打开某个会话（payload = sessionId）
  focusSearch,   // 历史页聚焦搜索
  scrollBottom,  // 对话回到底部
}

class TabIntentEvent {
  const TabIntentEvent(this.kind, [this.payload]);
  final TabIntent kind;
  final String? payload;
}

/// 标签状态 + 一次性意图。
class RootTabController extends Notifier<RootTab> {
  @override
  RootTab build() => RootTab.chat;

  void select(RootTab tab, {bool haptic = true}) {
    if (state == tab) return;
    state = tab;
    if (haptic) HapticFeedback.selectionClick();
  }

  void jumpToChat() => state = RootTab.chat;
}

/// 一次性意图：发一次，消费后即清空。
class TabIntentController extends Notifier<TabIntentEvent?> {
  @override
  TabIntentEvent? build() => null;

  void send(TabIntent kind, [String? payload]) => state = TabIntentEvent(kind, payload);

  /// 取出并清空。返回 null 表示没有待消费的意图。
  TabIntentEvent? consume() {
    final event = state;
    if (event != null) state = null;
    return event;
  }

  /// 仅清除（页面重建时丢弃过期意图）。
  void clear() => state = null;
}

final rootTabProvider = NotifierProvider<RootTabController, RootTab>(RootTabController.new);
final tabIntentProvider = NotifierProvider<TabIntentController, TabIntentEvent?>(TabIntentController.new);

/// 先关闭所有浮层 / 二级页，再切标签。
/// 顺序不能反：5 处入口可能从弹窗/二级页里触发，先切标签会把旧页盖在上面。
void switchTab(BuildContext context, RootTab tab, {TabIntent? intent, String? payload}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  if (navigator.canPop()) navigator.popUntil((route) => route.isFirst);
  final container = ProviderScope.containerOf(context, listen: false);
  container.read(rootTabProvider.notifier).select(tab);
  if (intent != null) container.read(tabIntentProvider.notifier).send(intent, payload);
}

/// 已在根页时用这个，省掉一次 popUntil。
void selectRootTab(WidgetRef ref, RootTab tab) => ref.read(rootTabProvider.notifier).select(tab);
