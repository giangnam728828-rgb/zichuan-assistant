// 启动画面: the overlay sampled frame by frame. Its first frame must be the system picture
// (same square, same pixels' place), it follows Android 12+'s measured splash before the
// splash fades, it plays only after the hand-over, and it goes the moment the app is ready —
// never waiting for the motion.

import 'dart:ui' as ui;

import 'package:dsh_app/launch/launch_motion.dart';
import 'package:dsh_app/launch/custom_launch.dart';
import 'package:dsh_app/launch/launch_state.dart';
import 'package:dsh_app/ui/launch/launch_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final _icon = find.byKey(LaunchMark.iconKey);

/// How much of the icon shows (it comes in when the system's picture had none).
double _iconOpacity(WidgetTester tester) =>
    tester.widget<Opacity>(find.ancestor(of: _icon, matching: find.byType(Opacity)).first).opacity;
final _wordmark = find.byKey(LaunchMark.wordmarkKey);

/// Where the system centres a 320 px icon on the 780 × 1688 px phone: (230, 684) px.
const _systemRect = Rect.fromLTWH(115, 342, 160, 160);

/// Lets a test end mid-launch: the layer leaves and nothing is left waiting.
Future<void> _finish(WidgetTester tester, LaunchController c) async {
  c.ready();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  late ui.Image icon;
  late FakeLaunchChannel channel;

  setUp(() => channel = FakeLaunchChannel());

  Future<LaunchController> start(
    WidgetTester tester, {
    int sdk = 35,
    bool systemSplash = true,
    bool dark = false,
    bool reduceMotion = false,
    bool motionAfterReady = false,
    bool coldEngine = false,
  }) async {
    usePhone(tester);
    icon = (await tester.runAsync(() => flatImage(320, 320, const Color(0xFF4F68B7))))!;
    final controller = LaunchController(
      snapshot: snapshotFor(
        icon: icon,
        sdk: sdk,
        systemSplash: systemSplash,
        dark: dark,
        motionAfterReady: motionAfterReady,
        coldEngine: coldEngine,
      ),
      channel: channel,
    );
    await tester.pumpWidget(launchApp(controller, reduceMotion: reduceMotion));
    return controller;
  }

  group('first frame', () {
    testWidgets('第一帧是纯色 + 一条尚未展开的细线，没有图标也没有方框', (tester) async {
      final c = await start(tester);
      final screen = tester.getRect(find.byType(LaunchOverlay));
      // 细线：此帧 scaleX 与 opacity 都是 0，所以看不见；它居中、1px 高。
      final scale = tester.widget<Transform>(
        find.ancestor(of: _icon, matching: find.byType(Transform)).first,
      );
      expect(scale.transform.storage[0], 0); // scaleX
      expect(tester.widget<Container>(_icon).constraints!.maxHeight, 1);
      expect(_iconOpacity(tester), 0);
      expect(_wordmark, findsNothing);
      expect(c.phase, LaunchPhase.cover);
      expect(channel.marks, ['firstFrame']);
      await _finish(tester, c);
    });

    testWidgets('lays the flat page colour on Android 12+, the gradient before', (tester) async {
      final c = await start(tester);
      final flat = tester.widget<ColoredBox>(
        find.descendant(of: find.byType(LaunchBackground), matching: find.byType(ColoredBox)),
      );
      expect(flat.color, LaunchColors.mistTop);
      await _finish(tester, c);
    });

    testWidgets('Android 8–11: gradient, and the motion starts at once', (tester) async {
      final c = await start(tester, sdk: 30, systemSplash: false);
      // 知川助手：8–11 与 12+ 用同一个纯色（不再有渐变），立绘从 0 淡入。
      final flat = tester.widget<ColoredBox>(
        find.descendant(of: find.byType(LaunchBackground), matching: find.byType(ColoredBox)),
      );
      expect(flat.color, LaunchColors.mistTop);
      expect(_iconOpacity(tester), 0);
      await tester.pump();
      expect(c.phase, LaunchPhase.playing);
      await tester.pump(const Duration(milliseconds: 500));
      expect(_iconOpacity(tester), closeTo(1, 0.02));
    });

    testWidgets('HarmonyOS: the still picture holds until the app is ready, then the motion plays', (tester) async {
      // A cold start of the in-process engine, as every HarmonyOS cold start is.
      final c = await start(tester, sdk: 26, systemSplash: false, motionAfterReady: true, coldEngine: true);
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.phase, LaunchPhase.cover);
      expect(_iconOpacity(tester), 0);
      c.ready();
      await tester.pump();
      expect(c.phase, LaunchPhase.playing);
      await tester.pump(const Duration(milliseconds: 500));
      expect(_iconOpacity(tester), closeTo(1, 0.02));
      c.engineReady();
      await _finish(tester, c);
    });

    testWidgets('HarmonyOS: an app not ready in 1.2 s gets the motion anyway', (tester) async {
      final c = await start(tester, sdk: 26, systemSplash: false, motionAfterReady: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100));
      expect(c.phase, LaunchPhase.cover);
      await tester.pump(const Duration(milliseconds: 150));
      expect(c.phase, LaunchPhase.playing);
      await _finish(tester, c);
    });

    testWidgets('built anew after the motion started (HarmonyOS): it still plays', (tester) async {
      final c = await start(tester, sdk: 26, systemSplash: false);
      await tester.pump();
      expect(c.phase, LaunchPhase.playing);
      // A parent of another type remounts the layer, as MaterialApp's Theme / AnimatedTheme swap did.
      await tester.pumpWidget(KeyedSubtree(key: UniqueKey(), child: launchApp(c)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(_iconOpacity(tester), closeTo(1, 0.02));
      await _finish(tester, c);
    });

    testWidgets('dark: 深墨底上用浅字', (tester) async {
      final c = await start(tester, dark: true, sdk: 30, systemSplash: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(c.phase, LaunchPhase.playing);
      final texts = tester
          .widgetList<Text>(find.descendant(of: _wordmark, matching: find.byType(Text)))
          .toList();
      expect(texts.map((t) => t.data).join(), '知川');
      expect(texts.first.style!.color, LaunchColors.paper);
    });
  });

  group('hand-over (Android 12+)', () {
    testWidgets('holds still until the splash is handed over', (tester) async {
      final c = await start(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.phase, LaunchPhase.cover);
      expect(_iconOpacity(tester), 0);
      expect(channel.calls, isNot(contains('reveal')));
      await _finish(tester, c);
    });

    testWidgets('follows the measured splash before it fades, then plays', (tester) async {
      final c = await start(tester);
      // A vendor's splash: a little higher and smaller than AOSP's.
      const vendor = Rect.fromLTWH(125, 300, 140, 140);
      final handing = c.handOver(vendor);
      await tester.pump();
      // 立绘铺满整屏，与 splash 量到的方框无关；此时仍不可见。
      expect(_iconOpacity(tester), 0);
      expect(channel.calls, isNot(contains('reveal')));
      await tester.pump();
      await tester.pump();
      await handing;
      expect(channel.calls, contains('reveal'));
      expect(c.phase, LaunchPhase.playing);
      await tester.pump(const Duration(milliseconds: 500));
      // v3：细线与系统图标的方框无关；落定时它展开到固定宽度。
      final screen = tester.getRect(find.byType(LaunchOverlay));
      final r = tester.getRect(_icon);
      expect(r.width, closeTo(screen.width * LaunchMotion.lineSpread, 0.5));
      expect(r.height, 1);
      expect(_iconOpacity(tester), closeTo(1, 0.02));
    });

    testWidgets('a splash exactly where the first frame drew it: no redraw, no fade, plays at once', (tester) async {
      final c = await start(tester);
      await c.handOver(_systemRect, removed: true);
      expect(c.phase, LaunchPhase.playing);
      expect(channel.calls, isNot(contains('reveal')));
      await tester.pump();
      // 第一帧就是立绘（透明），不是系统图标的方框。
      expect(_iconOpacity(tester), 0);
      await tester.pump(const Duration(milliseconds: 500));
      expect(_iconOpacity(tester), closeTo(1, 0.02));
      await _finish(tester, c);
    });

    testWidgets('a splash measured without an icon: the page alone, then the icon comes in', (tester) async {
      final c = await start(tester);
      final handing = c.handOver(null);
      await tester.pump();
      expect(_iconOpacity(tester), 0);
      await tester.pump();
      await tester.pump();
      await handing;
      expect(c.phase, LaunchPhase.playing);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(_iconOpacity(tester), 1);
      expect(_wordmark, findsOneWidget);
      await _finish(tester, c);
    });

    testWidgets('a system that never hands over: plays after 700 ms anyway', (tester) async {
      final c = await start(tester);
      await tester.pump(const Duration(milliseconds: 690));
      expect(c.phase, LaunchPhase.cover);
      await tester.pump(const Duration(milliseconds: 20));
      expect(c.phase, LaunchPhase.playing);
    });
  });

  group('keyframes after the hand-over', () {
    Future<LaunchController> played(WidgetTester tester, {bool dark = false}) async {
      final c = await start(tester, dark: dark);
      final handing = c.handOver(_systemRect);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await handing;
      await tester.pump();
      return c;
    }

    testWidgets('0 / 150 / 300 / 500 / 860 / 1100 ms（细线展开 → 两字上浮 → 涟漪）', (tester) async {
      await played(tester);
      final screen = tester.getRect(find.byType(LaunchOverlay));
      final samples = <int, double>{};
      var t = 0;
      for (final ms in [0, 150, 300, 500, 860, 1100]) {
        await tester.pump(Duration(milliseconds: ms - t));
        t = ms;
        samples[ms] = _iconOpacity(tester);
      }
      // 细线：从无到有，300 ms 展开到位。
      expect(samples[0]!, 0);
      expect(samples[150]!, greaterThan(0.0));
      expect(samples[300]!, closeTo(1, 0.02));
      expect(samples[1100]!, closeTo(1, 0.02));
      // 字标：屏幕正中。
      final word = tester.getRect(_wordmark);
      expect(word.center.dx, closeTo(screen.width / 2, 0.5));
      expect(word.center.dy, closeTo(screen.height / 2, 2.0));
    });

    testWidgets('ready leaves at once, mid-motion, and lets taps through while fading', (tester) async {
      final c = await played(tester);
      await tester.pump(const Duration(milliseconds: 200));
      c.ready();
      await tester.pump();
      expect(c.phase, LaunchPhase.leaving);
      expect(channel.marks, containsAllInOrder(['firstFrame', 'handedOver', 'ready']));
      // The home under it already takes taps.
      final ignore = tester.widget<IgnorePointer>(
        find.descendant(of: find.byType(LaunchOverlay), matching: find.byType(IgnorePointer)).first,
      );
      expect(ignore.ignoring, isTrue);
      final fade = tester.widget<FadeTransition>(
        find.descendant(of: find.byType(LaunchOverlay), matching: find.byType(FadeTransition)).first,
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(fade.opacity.value, inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 160));
      expect(c.phase, LaunchPhase.gone);
      expect(channel.calls, contains('done'));
      await tester.pump();
      expect(_icon, findsNothing);
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('ready, and the splash never handed over: gone after 200 ms more, not 700', (tester) async {
      final c = await start(tester);
      await tester.pump(const Duration(milliseconds: 100));
      c.ready();
      await tester.pump(const Duration(milliseconds: 190));
      expect(c.phase, LaunchPhase.cover);
      await tester.pump(const Duration(milliseconds: 20));
      expect(c.phase, LaunchPhase.leaving);
      await tester.pump(const Duration(milliseconds: 320));
      await tester.pump();
      expect(c.phase, LaunchPhase.gone);
      expect(channel.calls, contains('done'));
    });

    testWidgets('ready before the hand-over: the splash still fades first, then straight out', (tester) async {
      final c = await start(tester);
      c.ready();
      await tester.pump();
      expect(c.phase, LaunchPhase.cover);
      final handing = c.handOver(_systemRect);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await handing;
      expect(channel.calls, contains('reveal'));
      expect(c.phase, LaunchPhase.leaving);
      await tester.pump(const Duration(milliseconds: 320));
      expect(c.phase, LaunchPhase.gone);
    });
  });

  testWidgets('减少动画: 立绘与品牌字直接停在终点，不等动画', (tester) async {
    final c = await start(tester, sdk: 30, systemSplash: false, reduceMotion: true);
    await tester.pump();
    expect(c.phase, LaunchPhase.playing);
    await tester.pump(const Duration(milliseconds: 800));
    // 细线与字标停在终点。
    expect(_iconOpacity(tester), 1);
    final screen = tester.getRect(find.byType(LaunchOverlay));
    expect(tester.getRect(_icon).width, closeTo(screen.width * LaunchMotion.lineSpread, 1));
    expect(_wordmark, findsOneWidget);
    c.ready();
    await tester.pump();
    expect(c.phase, LaunchPhase.gone);
  });

  testWidgets('the app under it is laid out but not painted until the layer leaves', (tester) async {
    final c = await start(tester, sdk: 30, systemSplash: false);
    await tester.pump();
    expect(c.phase, LaunchPhase.playing);
    LaunchController.active.value = c;
    addTearDown(() => LaunchController.active.value = null);
    await tester.pumpWidget(const Directionality(textDirection: TextDirection.ltr, child: LaunchUnder(child: Text('app'))));
    expect(find.text('app'), findsNothing);
    expect(find.text('app', skipOffstage: false), findsOneWidget);
    c.skip();
    await tester.pump();
    expect(c.phase, LaunchPhase.leaving);
    expect(find.text('app'), findsOneWidget);
  });

  testWidgets('the home under it is built all along and keeps its state', (tester) async {
    final c = await start(tester, sdk: 30, systemSplash: false);
    expect(find.text('home', skipOffstage: false), findsOneWidget);
    await tester.pump();
    c.ready();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('home'), findsOneWidget);
  });
}
