// 川水 3a 的四个验收测试：
//   ① 切标签聊天状态保留  ② 返回键行为  ③ 历史页入口切回对话  ④ 键盘收起导航
//
//   flutter test test/shell/tab_shell_test.dart

import 'package:dsh_app/state/adaptive_layout_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/sessions/sessions_page.dart';
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
  await tester.tap(find.descendant(of: find.byType(BottomNav), matching: find.text(_label(tab))));
  await pumpFrames(tester, 8);
}

String _label(RootTab tab) => switch (tab) {
  RootTab.chat => '对话',
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
}
