// 川水 3a 的四个验收测试：
//   ① 切标签聊天状态保留  ② 返回键行为  ③ 历史页入口切回对话  ④ 键盘收起导航
//
//   flutter test test/shell/tab_shell_test.dart

import 'package:dsh_app/state/adaptive_layout_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/sessions/sessions_page.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/shell/bottom_nav.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/root_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show loadTestFonts, mockClipboard, pumpFrames;
import 'adaptive/support.dart';

ProviderContainer _c(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(HomeShell)));

RootTab _tab(WidgetTester tester) => _c(tester).read(rootTabProvider);

Future<void> _tapTab(WidgetTester tester, RootTab tab) async {
  final key = find.descendant(of: find.byType(BottomNav), matching: find.text(_label(tab)));
  if (key.evaluate().isNotEmpty) {
    await tester.tap(key);
  } else {
    // v4.2 IA：历史已从底栏移到「历史抽屉」，不再是底部入口。
    // 这类用例只关心「切过去以后状态对不对」，直接切标签即可。
    _c(tester).read(rootTabProvider.notifier).select(tab);
  }
  await pumpFrames(tester, 8);
}

String _label(RootTab tab) => switch (tab) {
  RootTab.chat => '对话',
  RootTab.tasks => '任务',
  RootTab.history => '历史',
  RootTab.tools => '工具',
  RootTab.settings => '设置',
};

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    freezeClocks();
  });
  tearDown(thawClocks);

  testWidgets('① 切标签：聊天状态保留，回来还是同一个会话', (tester) async {
    useWindow(tester, const Size(390, 844));
    mockClipboard(tester);
    await tester.pumpWidget(homeApp());
    await pumpFrames(tester, 8);
    expect(_tab(tester), RootTab.chat);

    await _tapTab(tester, RootTab.history);
    expect(_tab(tester), RootTab.history);
    expect(find.byType(SessionsPage), findsOneWidget);

    await _tapTab(tester, RootTab.settings);
    expect(_tab(tester), RootTab.settings);

    await _tapTab(tester, RootTab.chat);
    expect(_tab(tester), RootTab.chat);
    // 保活：会话仍是原来那个，没有被重置成新对话。
    expect(_c(tester).read(currentSessionProvider), 's1');
  });

  testWidgets('①b 切走再切回：内容不透明、输入栏还在（回归：曾因 Opacity 不监听而空白）', (tester) async {
    useWindow(tester, const Size(390, 844));
    mockClipboard(tester);
    await tester.pumpWidget(homeApp());
    await pumpFrames(tester, 8);

    await _tapTab(tester, RootTab.history);
    await _tapTab(tester, RootTab.chat);
    await pumpFrames(tester, 10);

    // 内容层必须回到不透明。
    final opacity = tester
        .widgetList<Opacity>(find.byType(Opacity))
        .map((o) => o.opacity)
        .where((o) => o < 1)
        .toList();
    expect(opacity, isEmpty, reason: '切标签后不应有内容层停在半透明');
    // 输入栏还在（用组件本身，不依赖文案）。
    expect(find.byType(Composer), findsOneWidget);
  });

  testWidgets('② 返回键：非对话标签先回对话，不退出', (tester) async {
    useWindow(tester, const Size(390, 844));
    mockClipboard(tester);
    await tester.pumpWidget(homeApp());
    await pumpFrames(tester, 8);

    await _tapTab(tester, RootTab.history);
    await tester.binding.handlePopRoute();
    await pumpFrames(tester, 8);
    // 回到对话标签，应用还在。
    expect(_tab(tester), RootTab.chat);
    expect(find.byType(HomeShell), findsOneWidget);
  });

  testWidgets('③ 历史页点会话 → 切回对话标签', (tester) async {
    useWindow(tester, const Size(390, 844));
    mockClipboard(tester);
    await tester.pumpWidget(homeApp());
    await pumpFrames(tester, 8);

    await _tapTab(tester, RootTab.history);
    expect(_tab(tester), RootTab.history);
    // 点第一行会话：读屏找到的会话标题，或直接点列表里的任意一行。
    final row = find.descendant(of: find.byType(SessionsPage), matching: find.byType(InkWell)).first;
    await tester.tap(row);
    await pumpFrames(tester, 10);
    expect(_tab(tester), RootTab.chat);
  });

  testWidgets('④ 键盘弹起时导航收起，收起 120ms 后再出现', (tester) async {
    useWindow(tester, const Size(390, 844));
    mockClipboard(tester);
    await tester.pumpWidget(homeApp());
    await pumpFrames(tester, 8);
    expect(find.byType(BottomNav), findsOneWidget);

    // 键盘弹起（viewInsets.bottom > 0）。
    tester.view.viewInsets = const FakeViewPadding(bottom: 300 * 2);
    addTearDown(tester.view.resetViewInsets);
    await pumpFrames(tester, 6);
    // 收起：Opacity 走到 0。
    final navOpacity = tester.widget<Opacity>(
      find.descendant(of: find.byType(BottomNav), matching: find.byType(Opacity)).first,
    );
    expect(navOpacity.opacity, lessThan(0.2));

    // 键盘收起：等 120ms 延迟 + 动画。
    tester.view.resetViewInsets();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 200));
    await pumpFrames(tester, 6);
    final back = tester.widget<Opacity>(
      find.descendant(of: find.byType(BottomNav), matching: find.byType(Opacity)).first,
    );
    expect(back.opacity, greaterThan(0.8));
  });

  testWidgets('⑤ 往下翻时导航收起，往上翻/停下后回来（方案第 3 步 IA）', (tester) async {
    // 窗口压矮一点，历史列表才有可滚的余量：外壳已经把页面抬到导航之上，
    // 页面自己不再额外垫一整条导航高度（v4.3 · P0-E）。
    useWindow(tester, const Size(390, 620));
    mockClipboard(tester);
    await tester.pumpWidget(homeApp());
    await pumpFrames(tester, 8);

    double navOpacity() => tester
        .widget<Opacity>(find.descendant(of: find.byType(BottomNav), matching: find.byType(Opacity)).first)
        .opacity;
    expect(navOpacity(), greaterThan(0.8));

    // 历史页的会话列表够长，能真正滚动（对话页那条会话已经滚到底了）。
    await _tapTab(tester, RootTab.history);
    await pumpFrames(tester, 8);

    // 往下翻：导航让位。
    await tester.drag(find.byType(SessionsPage), const Offset(0, -260));
    await pumpFrames(tester, 10);
    expect(navOpacity(), lessThan(0.3), reason: '往下读时导航收起');

    // 停下不弹回来（往下读时保持让位）。
    await pumpFrames(tester, 12);
    expect(navOpacity(), lessThan(0.3), reason: '停住时导航不回弹');

    // 往上翻：回来（先走 120ms 延迟，再等动画）。
    await tester.drag(find.byType(SessionsPage), const Offset(0, 160));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 220));
    await pumpFrames(tester, 8);
    expect(navOpacity(), greaterThan(0.8), reason: '往上翻就回来');
  });

  testWidgets('⑥ 导航收起再展开后还点得动', (tester) async {
    useWindow(tester, const Size(390, 844));
    mockClipboard(tester);
    await tester.pumpWidget(homeApp());
    await pumpFrames(tester, 8);
    expect(_tab(tester), RootTab.chat);

    // 键盘弹起：导航收起。等动画彻底走完（真机上键盘弹完还会再推一帧
    // MediaQuery，外壳就在那一刻重建）。
    tester.view.viewInsets = const FakeViewPadding(bottom: 300 * 2);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump(const Duration(milliseconds: 320));

    // 收起期间键盘还在推：viewInsets 变化让外壳和导航一起重建。
    tester.view.viewInsets = const FakeViewPadding(bottom: 320 * 2);
    await tester.pump(const Duration(milliseconds: 40));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300 * 2);
    await tester.pump(const Duration(milliseconds: 40));

    // 键盘收起：导航回到 1。
    tester.view.resetViewInsets();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 220));
    await pumpFrames(tester, 8);

    // 看得见就必须点得着：切到设置。
    await _tapTab(tester, RootTab.settings);
    expect(_tab(tester), RootTab.settings, reason: '收起再展开后导航不能失联');
  });
}
