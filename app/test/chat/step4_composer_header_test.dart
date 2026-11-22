// 川水 · 第 4 步验收：输入栏与顶栏。
//
// 顶栏：不再模糊（三处零件 blur: false）、滚动时底色与细线渐显、语音通话搬走、
// 换成「伙伴」入口。
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

    testWidgets('顶栏零件全部不模糊', (tester) async {
      await pumpHeader(tester, onCompanion: () {}, onNewChat: () {});
      final glasses = tester.widgetList<GlassSurface>(
        find.descendant(of: find.byType(ChatHeader), matching: find.byType(GlassSurface)),
      );
      expect(glasses, isNotEmpty);
      for (final g in glasses) {
        expect(g.blur, isFalse, reason: '顶栏不模糊（第 4 步）');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('语音通话已搬走：顶栏没有 chat-call，有 chat-companion', (tester) async {
      await pumpHeader(tester, onCompanion: () {});
      expect(find.byKey(const ValueKey('chat-call')), findsNothing);
      expect(find.byKey(const ValueKey('chat-companion')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chat-companion')));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('滚动时底色与细线渐显', (tester) async {
      final scrolled = ValueNotifier<double>(0);
      addTearDown(scrolled.dispose);
      await pumpHeader(tester, scrolledUnder: scrolled, onCompanion: () {});
      double scrim() => tester
          .widgetList<Opacity>(find.descendant(of: find.byType(ChatHeader), matching: find.byType(Opacity)))
          .map((o) => o.opacity)
          .reduce((a, b) => a > b ? a : b);
      expect(scrim(), 0);
      scrolled.value = 1;
      await tester.pump();
      expect(scrim(), 1);
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

    testWidgets('发送键是水滴形', (tester) async {
      await pumpComposer(tester, running: false);
      final drop = tester.widget<AnimatedContainer>(
        find.descendant(of: find.byType(Composer), matching: find.byType(AnimatedContainer)).first,
      );
      final radius = (drop.decoration! as BoxDecoration).borderRadius;
      expect(radius, isNotNull, reason: '水滴不是正圆');
      expect(radius, isNot(isA<CircleBorder>()));
    });

    testWidgets('生成中：边缘流光，不再转圈', (tester) async {
      await pumpComposer(tester, running: true);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
