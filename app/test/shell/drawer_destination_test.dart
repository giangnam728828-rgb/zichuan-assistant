// 抽屉里的「设置 / 全部功能」：切标签之前必须先收起抽屉（2026-11-22 用户实测反馈）。
//
// 现象：抽屉浮在上面时点这两个圆按钮，只看到抽屉下面的页面被换掉，像在底部导航上
// 自己点了一下；抽屉本身没走。修法在 `HomeShell._closeOverlays()`（抽屉/快捷面板归零 +
// 退出多选），然后 `switchTab`。
//
//   flutter test test/shell/drawer_destination_test.dart

import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/root_tab.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show loadTestFonts, mockClipboard, pumpFrames;
import 'adaptive/support.dart';

ProviderContainer _c(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(HomeShell)));

RootTab _tab(WidgetTester tester) => _c(tester).read(rootTabProvider);

/// 抽屉从左边滑出来（手机布局下的手势）。
Future<void> _openDrawer(WidgetTester tester) async {
  await tester.dragFrom(const Offset(6, 420), const Offset(220, 0));
  await pumpFrames(tester, 12);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    freezeClocks();
  });
  tearDown(thawClocks);

  testWidgets('抽屉里点「设置」：抽屉收起，标签切到设置', (tester) async {
    useWindow(tester, const Size(390, 844));
    mockClipboard(tester);
    await tester.pumpWidget(homeApp());
    await pumpFrames(tester, 8);
    await _openDrawer(tester);
    expect(find.byType(SessionsDrawer), findsWidgets, reason: '抽屉应该已经滑出来');

    await tester.tap(find.byIcon(AppIcons.settings).last);
    await pumpFrames(tester, 14);

    expect(_tab(tester), RootTab.settings, reason: '切到设置标签');
    // 抽屉必须走了：再等几帧也不该还挂着可见的抽屉。
    await pumpFrames(tester, 12);
    final drawers = find.byType(SessionsDrawer);
    if (drawers.evaluate().isNotEmpty) {
      final rect = tester.getRect(drawers.first);
      expect(rect.right, lessThanOrEqualTo(1), reason: '抽屉应已收到屏幕外，不能盖在设置页上面');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('抽屉里点「全部功能」：抽屉收起，标签切到工具', (tester) async {
    useWindow(tester, const Size(390, 844));
    mockClipboard(tester);
    await tester.pumpWidget(homeApp());
    await pumpFrames(tester, 8);
    await _openDrawer(tester);

    await tester.tap(find.byIcon(AppIcons.allFeatures).last);
    await pumpFrames(tester, 14);

    expect(_tab(tester), RootTab.tools);
    await pumpFrames(tester, 12);
    final drawers = find.byType(SessionsDrawer);
    if (drawers.evaluate().isNotEmpty) {
      expect(tester.getRect(drawers.first).right, lessThanOrEqualTo(1));
    }
    expect(tester.takeException(), isNull);
  });
}
