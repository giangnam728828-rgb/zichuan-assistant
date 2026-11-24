// 底部导航的收放：看得见就必须点得着。
//
// 键盘/滚动共用一条 reveal 动画。收起期间外壳还会重建（键盘稳定、角标变化），
// 旧实现把「不可点」定格在重建那一刻，展开后导航回到屏幕上却点不动。

import 'package:dsh_app/ui/shell/bottom_nav.dart';
import 'package:dsh_app/ui/shell/root_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show testTheme;

Widget _app(ProviderContainer container, Widget child) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: testTheme(Brightness.light),
    home: Scaffold(body: child),
  ),
);

void main() {
  testWidgets('收起期间重建，展开后仍可点', (tester) async {
    final controller = AnimationController(vsync: tester, duration: const Duration(milliseconds: 200), value: 1);
    addTearDown(controller.dispose);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    Widget app() => _app(
      container,
      Align(
        alignment: Alignment.bottomCenter,
        child: BottomNav(reveal: controller, compact: false),
      ),
    );

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(container.read(rootTabProvider), RootTab.chat);

    // 键盘弹起：导航收起。
    controller.reverse();
    await tester.pumpAndSettle();

    // 收起状态下外壳重建一次（真机上键盘完全展开还会再推一帧 MediaQuery）。
    await tester.pumpWidget(app());
    await tester.pump();

    // 键盘收起：导航展开。
    controller.forward();
    await tester.pumpAndSettle();

    // 看得见就要点得着。
    await tester.tap(find.text('设置'));
    await tester.pump();
    expect(container.read(rootTabProvider), RootTab.settings, reason: '收起再展开后导航不能失联');
  });

  testWidgets('收起时触摸穿透不到导航', (tester) async {
    final controller = AnimationController(vsync: tester, duration: const Duration(milliseconds: 200), value: 1);
    addTearDown(controller.dispose);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _app(
        container,
        Align(
          alignment: Alignment.bottomCenter,
          child: BottomNav(reveal: controller, compact: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    controller.value = 0;
    await tester.pump();

    await tester.tap(find.text('设置'), warnIfMissed: false);
    await tester.pump();
    expect(container.read(rootTabProvider), RootTab.chat, reason: '收起后底部点击应穿透给内容');
  });
}
