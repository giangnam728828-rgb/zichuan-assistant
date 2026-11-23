// 川水 · 第 4 步验收：输入栏与顶栏。
//
// 顶栏：B1 之后是一条透明线（没有胶囊、没有纱幕），伙伴 / 子代理 / 详情收进 ⋯；
// 语音通话搬进输入栏。
// 输入栏：悬浮 float 圆角、发送键水滴形、生成中是边缘流光而不是转圈、语音通话键在
// 输入栏自己的行里，附件键仍然在（附件能力不能丢）。

import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/mention/mention_text_controller.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/common/status_dot.dart';
import 'package:dsh_app/ui/theme/glass.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  setUpAll(() async {
    await loadTestFonts();
  });

  group('第 4 步 · 顶栏', () {
    Future<void> pumpHeader(
      WidgetTester tester, {
      ValueListenable<double>? scrolledUnder,
      VoidCallback? onCompanion,
      VoidCallback? onNewChat,
    }) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: ChatHeader(
              title: '当前会话标题',
              status: const HeaderStatus(StatusTone.ok, '已连接'),
              onCompanion: onCompanion,
              onNewChat: onNewChat,
              scrolledUnder: scrolledUnder,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('顶栏零件全部无底色（B1 去色块）', (tester) async {
      await pumpHeader(tester, onCompanion: () {}, onNewChat: () {});
      final glasses = tester.widgetList<GlassSurface>(
        find.descendant(of: find.byType(ChatHeader), matching: find.byType(GlassSurface)),
      );
      expect(glasses, isNotEmpty);
      for (final g in glasses) {
        expect(g.bare, isTrue, reason: 'B1：顶栏只有图标和按下反馈，没有填充、描边或模糊');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('语音通话已搬走：顶栏没有 chat-call，伙伴收进 ⋯', (tester) async {
      await pumpHeader(tester, onCompanion: () {});
      expect(find.byKey(const ValueKey('chat-call')), findsNothing);
      expect(find.byKey(const ValueKey('chat-companion')), findsNothing, reason: 'B1：入口在 ⋯ 菜单里');
      await tester.tap(find.byKey(const ValueKey('chat-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-companion')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chat-companion')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('顶栏不再自带滚动遮罩（A1 交给列表的 EdgeFade）', (tester) async {
      final scrolled = ValueNotifier<double>(0);
      addTearDown(scrolled.dispose);
      await pumpHeader(tester, scrolledUnder: scrolled, onCompanion: () {});
      // 没有纱幕，也就没有那条 1px 细线。
      expect(find.descendant(of: find.byType(ChatHeader), matching: find.byType(ColoredBox)), findsNothing);
      scrolled.value = 1;
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('第 4 步 · 输入栏', () {
    Future<void> pumpComposer(WidgetTester tester, {required bool running, VoidCallback? onCall}) async {
      usePhoneView(tester);
      final input = MentionTextController();
      addTearDown(input.dispose);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Composer(
                    controller: input,
                    connected: true,
                    running: running,
                    waiting: running,
                    onSend: () {},
                    onStop: () {},
                    onCall: onCall,
                    leading: AttachButton(onPressed: () {}),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('悬浮 float 圆角 + 附件键仍在 + 语音通话键在输入栏里', (tester) async {
      await pumpComposer(tester, running: false, onCall: () {});
      final glass = tester.widget<GlassSurface>(
        find.ancestor(of: find.byType(TextField), matching: find.byType(GlassSurface)).first,
      );
      expect(glass.borderRadius, const BorderRadius.all(Radius.circular(AppShape.float)));
      expect(glass.blur, isNull, reason: '输入栏仍然是真模糊（同屏 ≤ 3）');
      expect(find.byType(AttachButton), findsOneWidget);
      expect(find.byKey(const ValueKey('composer-call')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('发送键是正圆（圆角超过键半径会啃出缺口）', (tester) async {
      await pumpComposer(tester, running: false);
      final key = tester.widget<AnimatedContainer>(
        find.descendant(of: find.byType(Composer), matching: find.byType(AnimatedContainer)).first,
      );
      final decoration = key.decoration! as BoxDecoration;
      expect(decoration.shape, BoxShape.circle);
      expect(decoration.borderRadius, isNull);
      expect(key.constraints?.maxWidth, 36, reason: '键 36dp：任何大于 18 的圆角都会溢出');
    });

    testWidgets('生成中：边缘流光，不再转圈', (tester) async {
      await pumpComposer(tester, running: true);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
