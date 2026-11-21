// 启动画面 goldens, light and dark: v3 极简字标只有三帧 ——
// 细线展开 + 字上浮中、涟漪扩散、以及静止的字标。系统启动页不再有图标。
//
//   flutter test --update-goldens test/launch/launch_golden_test.dart

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
      final c = LaunchController(
        snapshot: snapshotFor(dark: dark),
        channel: FakeLaunchChannel(),
      );
      await tester.pumpWidget(launchApp(c, brightness: dark ? Brightness.dark : Brightness.light));
      await tester.pump();
      final handing = c.handOver(const Rect.fromLTWH(115, 342, 160, 160));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await handing;
      await tester.pump();
      return c;
    }

    testWidgets('hand-over frame: 细线开始展开 ($mode)', (tester) async {
      await handedOver(tester);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/launch_handover_$mode.png'));
    });

    testWidgets('wordmark rising ($mode)', (tester) async {
      await handedOver(tester);
      await tester.pump(const Duration(milliseconds: 500));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/launch_wordmark_$mode.png'));
    });

    testWidgets('ripple behind the wordmark ($mode)', (tester) async {
      await handedOver(tester);
      await tester.pump(const Duration(milliseconds: 860));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/launch_ripple_$mode.png'));
    });

    testWidgets('at rest: 静态字标 ($mode)', (tester) async {
      await handedOver(tester);
      await tester.pump(LaunchMotion.total);
      await tester.pump(const Duration(milliseconds: 100));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/launch_rest_$mode.png'));
    });
  }
}
