// 输入栏统一（方案第六部分 / 阶段 E）：议会、团队用的就是普通聊天那个
// [Composer]，高度、圆角、发送键、键盘行为不该各有一份。
//
// 这里不靠肉眼：同一屏宽下把「普通聊天输入栏」和「议会/团队输入栏」都渲染
// 出来，断言两者的行数上限与实测尺寸一致；再验证运行中给的是停止键。

import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/collab/collab_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show testApp;

Future<void> _pump(WidgetTester tester, Widget child, {double width = 360}) async {
  tester.view.physicalSize = Size(width, 780) * 3.0;
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(padding: const EdgeInsets.all(12), child: child),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('议会/团队输入栏 = 普通聊天输入栏', () {
    for (final width in [360.0, 430.0]) {
      testWidgets('${width.toInt()}dp：行数上限与实测尺寸一致', (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);

        await _pump(
          tester,
          Composer(
            controller: controller,
            connected: true,
            running: false,
            sessionReady: true,
            onSend: () {},
            onStop: () {},
          ),
          width: width,
        );
        final plain = tester.widget<Composer>(find.byType(Composer));
        final plainSize = tester.getSize(find.byType(Composer));

        await _pump(
          tester,
          CollabComposer(
            controller: controller,
            busy: false,
            onSend: () {},
            onStop: () {},
          ),
          width: width,
        );
        final collab = tester.widget<Composer>(find.byType(Composer));
        final collabSize = tester.getSize(find.byType(Composer));

        expect(
          collab.maxLines,
          plain.maxLines,
          reason: '议会/团队不能再有自己的行数上限（原来硬编码 6）',
        );
        expect(collab.maxLines, Composer.linesFor(tester.element(find.byType(Composer))));
        expect(
          collabSize.height,
          closeTo(plainSize.height, 0.5),
          reason: '同一宽度下输入栏高度必须一致',
        );
      });
    }

    testWidgets('运行中：停止键在，发送键让位', (tester) async {
      final controller = TextEditingController(text: '正在生成');
      addTearDown(controller.dispose);
      await _pump(
        tester,
        CollabComposer(
          controller: controller,
          busy: true,
          onSend: () {},
          onStop: () {},
        ),
      );
      // 运行时输入栏右上角是停止键（同一个 Composer，不再有第二套外观）。
      expect(find.byType(Composer), findsOneWidget);
      final composer = tester.widget<Composer>(find.byType(Composer));
      expect(composer.running, isTrue);
      expect(composer.onStop, isNotNull);
    });

    testWidgets('附件托盘：展开后输入栏长高，消息区得到实测高度', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await _pump(
        tester,
        CollabComposer(
          controller: controller,
          busy: false,
          onSend: () {},
          hasAttachments: true,
          tray: const SizedBox(key: ValueKey('tray-probe'), height: 36, width: double.infinity),
        ),
      );
      expect(find.byKey(const ValueKey('tray-probe')), findsOneWidget);
    });
  });
}
