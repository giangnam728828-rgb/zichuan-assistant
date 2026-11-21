// 启动画面 goldens, light and dark: 知川助手第 1 步之后只有三帧 ——
// 立绘开始淡入、细光扫过品牌字、以及静止的立绘 + 品牌字。系统启动页不再有图标。
//
//   flutter test --update-goldens test/launch/launch_golden_test.dart

import 'dart:ui' as ui;

import 'package:dsh_app/launch/launch_motion.dart';
import 'package:dsh_app/launch/launch_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';

    Future<LaunchController> handedOver(WidgetTester tester) async {
      usePhone(tester);
      final ui.Image icon = (await tester.runAsync(() => shippedIcon(320)))!;
      final c = LaunchController(
        snapshot: snapshotFor(icon: icon, dark: dark),
        channel: FakeLaunchChannel(),
      );
      await tester.pumpWidget(launchApp(c, brightness: dark ? Brightness.dark : Brightness.light));
      // 立绘要真的解出像素，金图才有内容。
      await tester.runAsync(() async {
        await precacheImage(
          const AssetImage(LaunchMotion.artAsset),
          tester.element(find.byType(MaterialApp)),
        );
      });
      await tester.pump();
      final handing = c.handOver(const Rect.fromLTWH(115, 342, 160, 160));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await handing;
      await tester.pump();
      return c;
    }

    testWidgets('hand-over frame: 立绘开始淡入 ($mode)', (tester) async {
      await handedOver(tester);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/launch_handover_$mode.png'));
    });

    testWidgets('light across the wordmark ($mode)', (tester) async {
      await handedOver(tester);
      await tester.pump(const Duration(milliseconds: 920));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/launch_sweep_$mode.png'));
    });

    testWidgets('at rest: 立绘 + 品牌字 ($mode)', (tester) async {
      await handedOver(tester);
      await tester.pump(const Duration(milliseconds: 1400));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/launch_rest_$mode.png'));
    });
  }
}
