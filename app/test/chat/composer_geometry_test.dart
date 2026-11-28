// B2: the composer is one card of two rows — the text on its own line, and
// under it a control row with the + and the mode pill at the left, the ring /
// call / voice-send at the right. Every key is the same 36 circle on one
// centre line, 6 in from the card's edges. The mic takes the send key's seat
// on an empty draft; while dictating the ✕ takes the +'s. A new line grows the
// card upward from its bottom edge, and a pinned list follows it.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/mention/mention_text_controller.dart';
import 'package:dsh_app/ui/chat/voice/voice_controller.dart';
import 'package:dsh_app/ui/chat/voice/voice_widgets.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/composer_fakes.dart';
import 'support/harness.dart';
import 'support/sample_chat.dart';

Future<TextEditingController> _pump(
  WidgetTester tester, {
  String text = '',
  double textScale = 1,
  VoiceInputController? voice,
  bool running = false,
  bool stopping = false,
  bool waiting = false,
  String? waitHint,
  VoidCallback? onStop,
  TextEditingController? input,
}) async {
  usePhoneView(tester);
  final controller = input ?? TextEditingController(text: text);
  await tester.pumpWidget(
    testApp(
      MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        // As in the chat screen: a bottom column of intrinsic height.
        child: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Composer(
                  controller: controller,
                  connected: true,
                  running: running,
                  stopping: stopping,
                  waiting: waiting,
                  waitHint: waitHint,
                  onSend: () {},
                  onStop: onStop ?? () {},
                  leading: AttachButton(onPressed: () {}),
                  voice: voice,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

Rect _capsule(WidgetTester tester) => tester.getRect(find.byType(Composer));
Rect _plus(WidgetTester tester) =>
    tester.getRect(find.ancestor(of: find.byIcon(AppIcons.add), matching: find.byType(Container)).first);
Rect _send(WidgetTester tester) => _round(tester, AppIcons.send);

Rect _round(WidgetTester tester, IconData icon) =>
    tester.getRect(find.ancestor(of: find.byIcon(icon), matching: find.byType(AnimatedContainer)).first);

Rect _cancel(WidgetTester tester) =>
    tester.getRect(find.ancestor(of: find.byIcon(AppIcons.close), matching: find.byType(Container)).first);

/// 控制行：所有键同一中心线，两端离卡片 6、离底边 6。
void _expectControlRow(WidgetTester tester, Rect left, Rect right) {
  final card = _capsule(tester);
  expect(left.size, const Size(36, 36));
  expect(right.size, left.size);
  expect(left.left - card.left, moreOrLessEquals(6, epsilon: 0.5));
  expect(card.right - right.right, moreOrLessEquals(6, epsilon: 0.5));
  expect(card.bottom - left.bottom, moreOrLessEquals(6, epsilon: 0.5));
  expect(left.center.dy, moreOrLessEquals(right.center.dy, epsilon: 0.5));
}

VoiceInputController _voice(TextEditingController input) {
  final voice = VoiceInputController(
    input: input,
    bridge: FakeVoiceBridge(),
    client: () => null,
    observeLifecycle: false,
  );
  addTearDown(voice.dispose);
  return voice;
}

void main() {
  testWidgets('stopping keeps a symmetric 36dp key', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, running: true, stopping: true);
    final busy = find
        .ancestor(of: find.byType(CircularProgressIndicator), matching: find.byType(AnimatedContainer))
        .first;
    _expectControlRow(tester, _plus(tester), tester.getRect(busy));
    expect(find.bySemanticsLabel('正在停止'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a waiting stop key is quiet and still stops', (tester) async {
    var stops = 0;
    await _pump(tester, running: true, waiting: true, onStop: () => stops++);
    // The approval card and the header say what waits; the hint is the plain
    // one, not 「生成中」.
    expect(tester.widget<TextField>(find.byType(TextField)).decoration!.hintText, '给知川发消息…');
    final key = find.ancestor(of: find.byIcon(AppIcons.stopGenerating), matching: find.byType(AnimatedContainer)).first;
    final decoration = tester.widget<AnimatedContainer>(key).decoration! as BoxDecoration;
    final colors = Theme.of(tester.element(find.byType(Composer))).colorScheme;
    expect(decoration.color, colors.onSurface.withValues(alpha: 0.06));
    await tester.tap(find.byIcon(AppIcons.stopGenerating));
    expect(stops, 1);
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('the control row: keys 6 from the edges, + mirrors send (text ×$scale)', (tester) async {
      await _pump(tester, textScale: scale);
      final plus = _plus(tester);
      _expectControlRow(tester, plus, _send(tester));
      // 输入区在控制行上方，从 14 起，不占键的位置。
      final card = _capsule(tester);
      final field = tester.getRect(find.byType(TextField));
      expect(field.left - card.left, moreOrLessEquals(14, epsilon: 0.5));
      expect(field.bottom, lessThanOrEqualTo(plus.top));
    });
  }

  testWidgets('several lines: the card grows upward, the keys keep their row', (tester) async {
    await _pump(tester, text: '第一行\n第二行\n第三行');
    final card = _capsule(tester);
    final plus = _plus(tester);
    expect(card.height, greaterThan(plus.height + 2 * 6 + 20));
    _expectControlRow(tester, plus, _send(tester));
  });

  testWidgets('a new line grows the capsule; the keys and the bottom edge stay put', (tester) async {
    final input = await _pump(tester);
    final one = _capsule(tester);
    final key = _plus(tester);

    input.text = '第一行\n第二行';
    await tester.pump();
    expect(_capsule(tester), one);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final growing = _capsule(tester);
    expect(growing.height, greaterThan(one.height));
    expect(growing.bottom, one.bottom);
    expect(_plus(tester), key);

    await tester.pump(const Duration(milliseconds: 81));
    final two = _capsule(tester);
    expect(two.height, greaterThan(growing.height));
    expect(two.bottom, one.bottom);
    expect(_plus(tester), key);

    // Fewer lines: the same way back.
    input.text = '第一行';
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(_capsule(tester).height, lessThan(two.height));
    expect(_capsule(tester).height, greaterThan(one.height));
    await tester.pump(const Duration(milliseconds: 81));
    expect(_capsule(tester), one);
  });

  testWidgets('reduced motion: a new line is simply there', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final input = await _pump(tester);
    final one = _capsule(tester);
    input.text = '第一行\n第二行';
    await tester.pump();
    expect(find.byType(AnimatedSize), findsNothing);
    expect(_capsule(tester).height, greaterThan(one.height));
  });

  testWidgets('a list pinned to the bottom stays on the capsule while it grows', (tester) async {
    usePhoneView(tester);
    final harness = ChatHarness(
      session: 's1',
      states: {
        's1': ChatState(
          title: '测试',
          loading: false,
          items: [for (var i = 0; i < 30; i++) assistant(i + 1, '第 $i 段回答')],
        ),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);
    double gap() => tester.getTopLeft(find.byType(Composer)).dy - tester.getBottomLeft(find.text('第 29 段回答')).dy;
    final resting = gap();
    final top = tester.getTopLeft(find.byType(Composer)).dy;

    tester.widget<TextField>(find.byType(TextField)).controller!.text = '第一行\n第二行';
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      // 列表的底部留白走 veilHeight，比输入栏晚一帧（布局阶段不能 setState），
      // 一帧最多差几个 dp；不许出现真正能看见的跳。
      expect(gap(), greaterThan(resting - 8), reason: 'frame $i');
    }
    await tester.pumpAndSettle();
    expect(gap(), moreOrLessEquals(resting, epsilon: 0.5));
    expect(tester.getTopLeft(find.byType(Composer)).dy, lessThan(top));
  });

  testWidgets('the send key eases its new icon in', (tester) async {
    await _pump(tester);
    final swap = find.ancestor(of: find.byIcon(AppIcons.send), matching: find.byType(AnimatedSwitcher)).first;
    expect(tester.widget<AnimatedSwitcher>(swap).switchInCurve, AppMotion.enter);
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('the mic mirrors the + on an empty draft (text ×$scale)', (tester) async {
      final input = MentionTextController();
      await _pump(tester, input: input, voice: _voice(input), textScale: scale);
      await tester.pump();
      final mic = _round(tester, AppIcons.voice);
      _expectControlRow(tester, _plus(tester), mic);
    });
  }

  testWidgets('dictating: ✕ and ■ in the same seats, the level bars lower '
      'than the keys and centred on them', (tester) async {
    final input = MentionTextController();
    final voice = _voice(input);
    await _pump(tester, input: input, voice: voice);
    await tester.pump();
    final empty = _capsule(tester);
    final plus = _plus(tester);
    await voice.start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(voice.phase, VoicePhase.listening);

    final cancel = _cancel(tester);
    final stop = _round(tester, AppIcons.stopGenerating);
    expect(cancel, plus);
    _expectControlRow(tester, cancel, stop);
    expect(_capsule(tester), empty);

    final bars = tester.getRect(find.byType(VoiceWaveform));
    expect(bars.height, 36);
    expect(bars.center.dy, moreOrLessEquals(stop.center.dy, epsilon: 0.5));
    expect(VoiceWaveform.maxHeight, lessThan(stop.height));
    // The bars sit next to the stop key like the context ring does.
    expect(stop.left - bars.right, moreOrLessEquals(2, epsilon: 0.5));
  });
}
