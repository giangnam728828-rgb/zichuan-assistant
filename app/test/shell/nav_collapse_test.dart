// V4.4 · S1 底部导航收缩判定（任务书 2.10 / 18.1）。
//
// 这些用例只测纯判定逻辑，不依赖整页布局：把真实滚动会发出的
// ScrollNotification 序列喂给 [NavigationCollapseController]，断言目标状态。
// 页面级联动另见 test/shell/tab_shell_test.dart。

import 'package:dsh_app/ui/shell/nav_collapse.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FixedScrollMetrics _m(double pixels, {double max = 2000, double viewport = 600}) => FixedScrollMetrics(
  minScrollExtent: 0,
  maxScrollExtent: max,
  pixels: pixels,
  viewportDimension: viewport,
  axisDirection: AxisDirection.down,
  devicePixelRatio: 3,
);

void main() {
  late BuildContext ctx;
  late List<bool> changes;
  late NavigationCollapseController c;

  /// 造一个真 BuildContext（通知的 context 参数在 3.50 是非空的）。
  Future<void> boot(WidgetTester tester) async {
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          ctx = context;
          return const SizedBox.shrink();
        },
      ),
    );
    changes = [];
    c = NavigationCollapseController(onChange: changes.add);
    addTearDown(c.dispose);
  }

  /// 手指拖动的一小段。
  ScrollUpdateNotification drag(double pixels, double delta, {double max = 2000}) => ScrollUpdateNotification(
    metrics: _m(pixels, max: max),
    context: ctx,
    dragDetails: DragUpdateDetails(delta: Offset(0, -delta), globalPosition: Offset.zero),
  );

  /// 程序滚动（流式跟随 / animateTo / jumpTo）：没有 dragDetails。
  ScrollUpdateNotification auto(double pixels, {double max = 2000}) =>
      ScrollUpdateNotification(metrics: _m(pixels, max: max), context: ctx);

  ScrollStartNotification start(double pixels, {bool finger = true, double max = 2000}) =>
      ScrollStartNotification(
        metrics: _m(pixels, max: max),
        context: ctx,
        dragDetails: finger ? DragStartDetails(globalPosition: Offset.zero) : null,
      );

  ScrollEndNotification end(double pixels, {double max = 2000}) =>
      ScrollEndNotification(metrics: _m(pixels, max: max), context: ctx);

  testWidgets('用户向下拖 24dp：收起', (tester) async {
    await boot(tester);
    c.handle(start(100));
    c.handle(drag(112, 12));
    expect(c.collapsed, isFalse, reason: '12dp 还没到阈值');
    c.handle(drag(124, 12));
    c.handle(drag(130, 6));
    expect(c.collapsed, isTrue);
    expect(changes, [true]);
  });

  testWidgets('反向拖 12dp：延迟 120ms 后展开', (tester) async {
    await boot(tester);
    c.handle(start(300));
    c.handle(drag(340, 40));
    expect(c.collapsed, isTrue);
    c.handle(drag(334, -6));
    expect(c.collapsed, isTrue, reason: '6dp 不够 12dp');
    c.handle(drag(326, -8));
    expect(c.collapsed, isTrue, reason: '还在 120ms 延迟里');
    await tester.pump(const Duration(milliseconds: 160));
    expect(c.collapsed, isFalse);
    expect(changes, [true, false]);
  });

  testWidgets('1–3dp 抖动不改变状态', (tester) async {
    await boot(tester);
    c.handle(start(300));
    for (var i = 0; i < 8; i++) {
      c.handle(drag(300 + (i.isEven ? 2 : -2), i.isEven ? 2 : -2));
    }
    expect(c.collapsed, isFalse);
    expect(changes, isEmpty);
  });

  testWidgets('流式输出自动滚动（无 dragDetails）：永不收起', (tester) async {
    await boot(tester);
    c.handle(start(1200, finger: false));
    for (var i = 0; i < 40; i++) {
      c.handle(auto(1200 + i * 20));
    }
    c.handle(end(1980));
    expect(c.collapsed, isFalse);
    expect(changes, isEmpty);
  });

  testWidgets('animateTo / jumpTo（无 dragDetails）：不收起', (tester) async {
    await boot(tester);
    c.handle(start(200, finger: false));
    for (var i = 1; i <= 10; i++) {
      c.handle(auto(200 + i * 60));
    }
    c.handle(end(800));
    expect(c.collapsed, isFalse);
  });

  testWidgets('恢复滚动位置：从 0 直接跳到 900 也不收起', (tester) async {
    await boot(tester);
    c.handle(auto(0));
    c.handle(auto(900));
    expect(c.collapsed, isFalse);
  });

  testWidgets('距离底部小于 48dp：强制展开', (tester) async {
    await boot(tester);
    c.handle(start(100));
    c.handle(drag(160, 60));
    expect(c.collapsed, isTrue);
    // 继续往下读到离末尾 30dp：即使还没反向，也要展开。
    c.handle(drag(1970, 1810, max: 2000));
    expect(c.collapsed, isFalse, reason: '已经到最新消息，导航必须回来');
  });

  testWidgets('拖到顶（overscroll）：展开', (tester) async {
    await boot(tester);
    c.handle(start(300));
    c.handle(drag(360, 60));
    expect(c.collapsed, isTrue);
    c.handle(
      OverscrollNotification(
        metrics: _m(0),
        context: ctx,
        overscroll: -20,
        velocity: -100,
        dragDetails: DragUpdateDetails(delta: const Offset(0, 20), globalPosition: Offset.zero),
      ),
    );
    await tester.pump(const Duration(milliseconds: 160));
    expect(c.collapsed, isFalse);
  });

  testWidgets('键盘弹起立刻收起，收起后 120ms 展开', (tester) async {
    await boot(tester);
    c.setKeyboard(true);
    expect(c.collapsed, isTrue);
    c.setKeyboard(false);
    expect(c.collapsed, isTrue, reason: '避开输入法动画');
    await tester.pump(const Duration(milliseconds: 60));
    expect(c.collapsed, isTrue);
    await tester.pump(const Duration(milliseconds: 120));
    expect(c.collapsed, isFalse);
  });

  testWidgets('键盘开着时拖动不算数', (tester) async {
    await boot(tester);
    c.setKeyboard(true);
    c.handle(start(100));
    for (var i = 1; i <= 10; i++) {
      c.handle(drag(100 + i * 30, 30));
    }
    expect(c.collapsed, isTrue, reason: '键盘期间的滚动不该改判定');
  });

  testWidgets('收起后继续往下滚：不会被待展开的定时器拉回来', (tester) async {
    await boot(tester);
    c.handle(start(100));
    c.handle(drag(140, 40)); // 收起
    c.handle(drag(130, -10)); // 想展开，但只走了 10dp，不够 12
    c.handle(drag(200, 70)); // 又往下：取消待展开
    await tester.pump(const Duration(milliseconds: 180));
    expect(c.collapsed, isTrue);
    expect(changes.where((e) => !e), isEmpty);
  });

  testWidgets('reset 立即展开并清空手势累计', (tester) async {
    await boot(tester);
    c.handle(start(100));
    c.handle(drag(140, 40));
    expect(c.collapsed, isTrue);
    c.reset();
    expect(c.collapsed, isFalse);
  });
}
