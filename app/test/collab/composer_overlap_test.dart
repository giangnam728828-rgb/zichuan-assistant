// 输入栏遮挡（方案第二部分 · P0-2）：布局几何断言，不靠肉眼。
//
// 用户截图里，团队/议会的消息列表一直画到屏幕底部，底部输入栏压在成员
// 状态和最后一条消息上。这里用真实布局量三个东西的矩形：
//   - 消息区（conversation-body）
//   - 输入栏（conversation-composer）
//   - 成员状态行（最后一行里的文字）
// 断言：消息区底边 ≤ 输入栏顶边；最后一行滚到底后完整落在消息区里。
//
// 覆盖 360dp / 430dp、键盘弹起、多行输入（输入栏长高）、附件托盘展开。

import 'package:dsh_app/ui/chat/shared/conversation_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一条「消息」：固定高度的块，方便断言最后一项的完整可见性。
Widget _row(String label, {double height = 72}) => SizedBox(
  key: ValueKey('row-$label'),
  height: height,
  child: Align(alignment: Alignment.centerLeft, child: Text(label)),
);

/// 把工作区装进一个给定尺寸的屏幕里（键盘弹起用 viewInsets 模拟）。
Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required Widget composer,
  double topInset = 60,
  double keyboard = 0,
  int rows = 30,
}) async {
  tester.view.physicalSize = size * 3.0;
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          padding: EdgeInsets.zero,
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: Scaffold(
          body: ConversationWorkspace(
            topInset: topInset,
            body: ListView(
              key: const ValueKey('messages'),
              children: [for (var i = 0; i < rows; i++) _row('消息 $i')],
            ),
            composer: composer,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Rect _rect(WidgetTester tester, String key) => tester.getRect(find.byKey(ValueKey(key)));

void main() {
  group('消息区与输入栏的几何边界', () {
    for (final width in [360.0, 430.0]) {
      for (final height in [640.0, 780.0]) {
        testWidgets('${width.toInt()}×${height.toInt()}：消息区底边不进输入栏', (tester) async {
          await _pump(
            tester,
            size: Size(width, height),
            composer: const SizedBox(key: ValueKey('composer-card'), height: 96),
          );
          final body = _rect(tester, 'conversation-body');
          final composer = _rect(tester, 'conversation-composer');
          expect(
            body.bottom,
            lessThanOrEqualTo(composer.top + 0.5),
            reason: '消息区底边 ${body.bottom} 不得越过输入栏顶边 ${composer.top}',
          );
          expect(composer.bottom, lessThanOrEqualTo(height + 0.5));
        });
      }
    }

    testWidgets('多行输入栏长高，消息区自动让位', (tester) async {
      await _pump(
        tester,
        size: const Size(360, 780),
        composer: const SizedBox(key: ValueKey('composer-card'), height: 80),
      );
      final before = _rect(tester, 'conversation-body');
      // 输入栏长到 200dp（多行 + 托盘展开）。
      await _pump(
        tester,
        size: const Size(360, 780),
        composer: const SizedBox(key: ValueKey('composer-card'), height: 200),
      );
      final after = _rect(tester, 'conversation-body');
      final composer = _rect(tester, 'conversation-composer');
      expect(after.height, lessThan(before.height));
      expect(after.bottom, lessThanOrEqualTo(composer.top + 0.5));
    });

    testWidgets('键盘弹起时输入栏在消息区下方，不压住内容', (tester) async {
      await _pump(
        tester,
        size: const Size(360, 780),
        keyboard: 300,
        composer: const SizedBox(key: ValueKey('composer-card'), height: 96),
      );
      final body = _rect(tester, 'conversation-body');
      final composer = _rect(tester, 'conversation-composer');
      expect(body.bottom, lessThanOrEqualTo(composer.top + 0.5));
      // 键盘区（300dp）不得被两者中任何一个占用。
      expect(composer.bottom, lessThanOrEqualTo(780 - 300 + 0.5));
    });

    testWidgets('输入栏封顶：横屏大字号下也给消息区留出空间', (tester) async {
      await _pump(
        tester,
        size: const Size(780, 360),
        composer: const SizedBox(key: ValueKey('composer-card'), height: 400),
      );
      final body = _rect(tester, 'conversation-body');
      expect(body.height, greaterThanOrEqualTo(ConversationWorkspace.minBodyHeight - 0.5));
    });
  });

  group('最后一行完整可见', () {
    testWidgets('滚到底后最后一条消息的整行都在消息区内', (tester) async {
      await _pump(
        tester,
        size: const Size(360, 780),
        composer: const SizedBox(key: ValueKey('composer-card'), height: 120),
      );
      final list = find.byKey(const ValueKey('messages'));
      await tester.drag(list, const Offset(0, -4000));
      await tester.pumpAndSettle();
      final last = _rect(tester, 'row-消息 29');
      final body = _rect(tester, 'conversation-body');
      final composer = _rect(tester, 'conversation-composer');
      expect(last.bottom, lessThanOrEqualTo(body.bottom + 0.5));
      expect(last.bottom, lessThanOrEqualTo(composer.top + 0.5));
      expect(last.top, greaterThanOrEqualTo(body.top - 0.5));
    });
  });
}
