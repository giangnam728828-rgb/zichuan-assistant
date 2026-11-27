// 新建会话类型面板的定位（方案第七部分 / 阶段 A）。
//
// 用户点顶栏「新对话」，类型面板却固定跑到屏幕左上角。这里用真实布局
// 验证：面板贴着按钮、优先在下方、右对齐不溢出、下方放不下就翻到上方，
// 窄屏 / 横屏 / 大字号都不出界，点外面能关。

import 'package:dsh_app/state/conversation_mode_state.dart';
import 'package:dsh_app/ui/chat/conversation_mode_switcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show testApp;

const _panel = ValueKey('conversation-mode-panel');

/// 一张 360×780 的屏：右上角一枚「新对话」按钮，点开面板。
Future<({GlobalKey anchor, ConversationMode? picked})> _openPanel(
  WidgetTester tester, {
  Size size = const Size(360, 780),
  double top = 0,
  double right = 12,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size * 3.0;
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final anchor = GlobalKey(debugLabel: 'anchor');
  ConversationMode? picked;
  await tester.pumpWidget(
    testApp(
      MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: Builder(
            builder: (context) => Stack(
              children: [
                Positioned(
                  top: top,
                  right: right,
                  child: SizedBox(
                    key: anchor,
                    width: 44,
                    height: 44,
                    child: TextButton(
                      onPressed: () async {
                        picked = await pickConversationType(
                          context,
                          current: ConversationMode.chat,
                          anchor: anchor,
                        );
                      },
                      child: const Text('新对话'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byType(TextButton));
  await tester.pumpAndSettle();
  return (anchor: anchor, picked: picked);
}

void main() {
  group('面板锚到「新对话」按钮', () {
    testWidgets('按钮在顶部时，面板出现在按钮下方而不是左上角', (tester) async {
      final handle = await _openPanel(tester);
      final anchorRect = tester.getRect(find.byKey(handle.anchor));
      final panelRect = tester.getRect(find.byKey(_panel));
      expect(panelRect.top, greaterThanOrEqualTo(anchorRect.bottom - 0.5));
      // 右缘对齐按钮附近，而不是贴着左边。
      expect(panelRect.right, greaterThan(220));
      expect(panelRect.right, lessThanOrEqualTo(360 - 12 + 0.5));
    });

    testWidgets('按钮靠下时面板翻到按钮上方', (tester) async {
      final handle = await _openPanel(tester, top: 700);
      final anchorRect = tester.getRect(find.byKey(handle.anchor));
      final panelRect = tester.getRect(find.byKey(_panel));
      expect(panelRect.bottom, lessThanOrEqualTo(anchorRect.top + 0.5));
      expect(panelRect.top, greaterThanOrEqualTo(0));
    });

    testWidgets('窄屏 320dp：面板宽度不超 272dp 且不出界', (tester) async {
      final handle = await _openPanel(tester, size: const Size(320, 640));
      final panelRect = tester.getRect(find.byKey(_panel));
      expect(panelRect.width, lessThanOrEqualTo(272.0 + 0.5));
      expect(panelRect.left, greaterThanOrEqualTo(0));
      expect(panelRect.right, lessThanOrEqualTo(320 + 0.5));
      expect(handle.anchor, isNotNull);
    });

    testWidgets('横屏 + 大字号：面板不出界', (tester) async {
      await _openPanel(tester, size: const Size(780, 360), textScale: 1.4);
      final panelRect = tester.getRect(find.byKey(_panel));
      expect(panelRect.left, greaterThanOrEqualTo(0));
      expect(panelRect.right, lessThanOrEqualTo(780 + 0.5));
      expect(panelRect.top, greaterThanOrEqualTo(0));
      expect(panelRect.bottom, lessThanOrEqualTo(360 + 0.5));
    });

    testWidgets('没有锚点（按钮已失效）也不落进左上角死角', (tester) async {
      tester.view.physicalSize = const Size(360, 780) * 3.0;
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        testApp(
          MediaQuery(
            data: const MediaQueryData(size: Size(360, 780)),
            child: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showConversationModePanel(
                    context,
                    current: ConversationMode.chat,
                    onSelect: (_) {},
                  ),
                  child: const Text('无锚点'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('无锚点'));
      await tester.pumpAndSettle();
      final panelRect = tester.getRect(find.byKey(_panel));
      expect(panelRect.left, greaterThanOrEqualTo(12 - 0.5));
      expect(panelRect.right, lessThanOrEqualTo(360 - 12 + 0.5));
    });

    testWidgets('选中类型后带出结果并关闭面板', (tester) async {
      await _openPanel(tester);
      await tester.tap(find.byKey(const ValueKey('mode-option-team')));
      await tester.pumpAndSettle();
      expect(find.byKey(_panel), findsNothing);
    });

    testWidgets('点面板外面关闭', (tester) async {
      await _openPanel(tester);
      expect(find.byKey(_panel), findsOneWidget);
      await tester.tapAt(const Offset(20, 700));
      await tester.pumpAndSettle();
      expect(find.byKey(_panel), findsNothing);
    });
  });
}
