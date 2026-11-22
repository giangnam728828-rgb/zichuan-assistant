// The app-wide push transition: the new page slides in from the right while
// the one underneath drifts left; the back gesture (in-app edge swipe or
// Android's predictive back) moves the page with the finger and either pops it
// or settles it back.
//
//   flutter test test/shell/page_transition_test.dart

import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app() => MaterialApp(
  theme: buildLightTheme(),
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Center(child: Text('page b'))),
            ),
          ),
          child: const Text('push'),
        ),
      ),
    ),
  ),
);

Future<void> _push(WidgetTester tester) async {
  await tester.pumpWidget(_app());
  await tester.tap(find.text('push'));
  await tester.pumpAndSettle();
  expect(find.text('page b'), findsOneWidget);
}

Future<void> _backGesture(WidgetTester tester, String method, [Map<String, dynamic>? args]) async {
  final message = const StandardMethodCodec().encodeMethodCall(MethodCall(method, args));
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage('flutter/backgesture', message, (_) {});
}

void main() {
  testWidgets('push: the new page fades in while rising 2%, the old one stays put', (tester) async {
    // 川水第 6 步：推入改成淡入 + 小位移（300ms），不再是整页从右边滑过来。
    // 返回手势仍然是横向跟随手指（见下面几条）。
    await tester.pumpWidget(_app());
    final width = tester.getSize(find.byType(MaterialApp)).width;
    final pushStart = tester.getCenter(find.text('push'));
    await tester.tap(find.text('push'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // 新页已经在屏幕里（不是从右侧滑进来），但还没完全淡入。
    final incoming = tester.getCenter(find.text('page b'));
    expect(incoming.dx, closeTo(width / 2, 1), reason: '横向不再位移');
    final fade = tester.widgetList<FadeTransition>(find.byType(FadeTransition));
    final incomingFade = fade.where((f) => f.opacity.value < 1).toList();
    expect(incomingFade, isNotEmpty, reason: '淡入还没走完');
    // 下面的页面只按它自己的「后退」处理向左让一点（_Recede），不会跟着从右边进来的那一页移动。
    expect(tester.getCenter(find.text('push')).dx, lessThanOrEqualTo(pushStart.dx + 0.01));
    await tester.pumpAndSettle();
    expect(tester.getCenter(find.text('page b')).dx, closeTo(width / 2, 0.01));
  });

  testWidgets('an edge swipe past the middle pops the page', (tester) async {
    await _push(tester);
    final width = tester.getSize(find.byType(MaterialApp)).width;
    final gesture = await tester.startGesture(const Offset(6, 300));
    for (var x = 0; x < 24; x++) {
      await gesture.moveBy(Offset(width * 0.7 / 24, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Mid-gesture the page follows the finger.
    expect(tester.getTopLeft(find.byType(Scaffold).last).dx, greaterThan(width * 0.5));
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsNothing);
    expect(find.text('push'), findsOneWidget);
  });

  testWidgets('a short, slow edge swipe settles the page back', (tester) async {
    await _push(tester);
    final gesture = await tester.startGesture(const Offset(6, 300));
    for (var x = 0; x < 10; x++) {
      await gesture.moveBy(const Offset(8, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsOneWidget);
    expect(tester.getTopLeft(find.byType(Scaffold).last).dx, closeTo(0, 0.01));
  });

  double pageLeft(WidgetTester tester) => tester.getTopLeft(find.byType(Scaffold).last).dx;

  /// Swipes from the edge [distance] across at [speed] px/s, and lets go.
  Future<void> swipe(WidgetTester tester, double distance, double speed) async {
    var time = Duration.zero;
    final step = Duration(microseconds: (distance / 24 / speed * 1e6).round());
    final gesture = await tester.startGesture(const Offset(6, 300));
    for (var x = 0; x < 24; x++) {
      time += step;
      await gesture.moveBy(Offset(distance / 24, 0), timeStamp: time);
      await tester.pump(step);
    }
    await gesture.up(timeStamp: time);
  }

  testWidgets('a fling leaves at the finger\'s speed, a slow release from a standstill', (tester) async {
    await _push(tester);
    await swipe(tester, 200, 1600);
    await tester.pump();
    var from = pageLeft(tester);
    await tester.pump(const Duration(milliseconds: 16));
    expect(pageLeft(tester) - from, greaterThan(16), reason: '1600 px/s is 25 px a frame');
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsNothing);

    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    await swipe(tester, 500, 500);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    from = pageLeft(tester);
    await tester.pump(const Duration(milliseconds: 16));
    expect(pageLeft(tester) - from, lessThan(16));
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsNothing);
  });

  testWidgets('a flick back lands on the page\'s place, with no hard stop', (tester) async {
    await _push(tester);
    final gesture = await tester.startGesture(const Offset(6, 300));
    var time = Duration.zero;
    for (var x = 0; x < 10; x++) {
      time += const Duration(milliseconds: 40);
      await gesture.moveBy(const Offset(10, 0), timeStamp: time);
      await tester.pump(const Duration(milliseconds: 40));
    }
    for (var x = 0; x < 8; x++) {
      time += const Duration(milliseconds: 4);
      await gesture.moveBy(const Offset(-4, 0), timeStamp: time);
    }
    await gesture.up(timeStamp: time);
    await tester.pump();
    var last = pageLeft(tester);
    var step = double.infinity;
    expect(last, greaterThan(0));
    while (last > 0) {
      await tester.pump(const Duration(milliseconds: 16));
      final now = pageLeft(tester);
      expect(now, greaterThanOrEqualTo(0));
      expect(last - now, lessThanOrEqualTo(step + 1), reason: 'slower every frame, all the way in');
      step = last - now;
      last = now;
    }
    await tester.pumpAndSettle();
    expect(pageLeft(tester), 0);
  });

  testWidgets('remove animations: a release lands within the frame', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _push(tester);
    await swipe(tester, 80, 100);
    await tester.pump();
    expect(pageLeft(tester), 0);
    await swipe(tester, 300, 1600);
    await tester.pump();
    expect(find.text('page b'), findsNothing);
  });

  testWidgets('Android predictive back drives the same transition', (tester) async {
    await _push(tester);
    final width = tester.getSize(find.byType(MaterialApp)).width;
    await _backGesture(tester, 'startBackGesture', {
      'touchOffset': <double>[5.0, 300.0],
      'progress': 0.0,
      'swipeEdge': 0,
    });
    await tester.pump();
    await _backGesture(tester, 'updateBackGestureProgress', {'x': 200.0, 'y': 300.0, 'progress': 0.5, 'swipeEdge': 0});
    await tester.pump();
    // Linear while the finger is down: half way along, half way across.
    expect(tester.getTopLeft(find.byType(Scaffold).last).dx, closeTo(width / 2, 1));
    await _backGesture(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsNothing);
  });

  testWidgets('an external pop during edge-swipe cancellation releases the home page', (tester) async {
    await _push(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final gesture = await tester.startGesture(const Offset(6, 300));
    await gesture.moveBy(const Offset(40, 0));
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    expect(navigator.userGestureInProgress, isTrue);

    await gesture.cancel();
    await tester.pump(const Duration(milliseconds: 16));
    expect(navigator.userGestureInProgress, isTrue, reason: 'the cancelled swipe is still settling');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('page b'), findsNothing);
    expect(navigator.userGestureInProgress, isFalse);
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsOneWidget, reason: 'the home page accepts touch again');
  });

  testWidgets('removing a route during an edge swipe releases the home page', (tester) async {
    await _push(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final route = ModalRoute.of(tester.element(find.text('page b')))!;
    final gesture = await tester.startGesture(const Offset(6, 300));
    await gesture.moveBy(const Offset(40, 0));
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    expect(navigator.userGestureInProgress, isTrue);

    navigator.removeRoute(route);
    await tester.pumpAndSettle();
    await gesture.up();

    expect(find.text('page b'), findsNothing);
    expect(navigator.userGestureInProgress, isFalse);
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsOneWidget, reason: 'the home page accepts touch again');
  });

  testWidgets('removing a route during predictive back releases the home page', (tester) async {
    await _push(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final route = ModalRoute.of(tester.element(find.text('page b')))!;
    await _backGesture(tester, 'startBackGesture', {
      'touchOffset': <double>[5.0, 300.0],
      'progress': 0.0,
      'swipeEdge': 0,
    });
    await _backGesture(tester, 'updateBackGestureProgress', {'progress': 0.3, 'swipeEdge': 0});
    await tester.pump();
    expect(navigator.userGestureInProgress, isTrue);

    navigator.removeRoute(route);
    await tester.pumpAndSettle();
    await _backGesture(tester, 'cancelBackGesture');

    expect(find.text('page b'), findsNothing);
    expect(navigator.userGestureInProgress, isFalse);
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsOneWidget, reason: 'the home page accepts touch again');
  });

  testWidgets('predictive cancellation finishes its gesture before a later pop', (tester) async {
    await _push(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await _backGesture(tester, 'startBackGesture', {
      'touchOffset': <double>[5.0, 300.0],
      'progress': 0.0,
      'swipeEdge': 0,
    });
    await _backGesture(tester, 'updateBackGestureProgress', {'progress': 0.3, 'swipeEdge': 0});
    await _backGesture(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();
    expect(navigator.userGestureInProgress, isFalse);
    expect(find.text('page b'), findsOneWidget);

    navigator.pop();
    await tester.pumpAndSettle();
    expect(navigator.userGestureInProgress, isFalse);
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsOneWidget);
  });

  testWidgets('disposing the navigator during a settling swipe is safe', (tester) async {
    await _push(tester);
    final gesture = await tester.startGesture(const Offset(6, 300));
    await gesture.moveBy(const Offset(40, 0));
    await gesture.moveBy(const Offset(80, 0));
    await gesture.cancel();
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.state<NavigatorState>(find.byType(Navigator)).userGestureInProgress, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
