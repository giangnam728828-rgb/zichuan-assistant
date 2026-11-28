// v4.3 · 15.6：协作时间线的滚动跟随与底部遮挡。
//
// 故障现场：最后几条消息被输入栏盖住，且只在「同一条消息继续变长」时出现
// （Markdown 渲染、代码块、表格、思考行、工具行都会让它长高）。旧实现只在
// 「行数变了」时跟随，行数没变就停在原地。
//
// 这里断言三件事：
// - 行数不变、只把同一行加高，列表仍然贴住底部；
// - 用户往上翻时，内容变长绝不抢滚动；
// - 协作时间线的底部渐隐不再按「输入栏高度 + 48dp」整段淡化（已经铺到输入栏
//   上沿了），并且用的是与普通聊天同一套 FollowScrollPhysics。

import 'package:dsh_app/ui/chat/shared/follow_scroll.dart';
import 'package:dsh_app/ui/collab/collab_timeline.dart';
import 'package:dsh_app/ui/theme/edge_fade.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({required ScrollController controller, required double height}) => ProviderScope(
  child: MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: 300,
        child: CollabTimeline(
          controller: controller,
          rows: [
            CollabTimelineRow(
              key: const ValueKey('row-1'),
              child: Container(height: height, color: const Color(0xFF223344)),
            ),
          ],
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('行数不变、同一条消息变长：仍然贴底', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller: controller, height: 600));
    await tester.pumpAndSettle();
    expect(controller.position.maxScrollExtent, greaterThan(0));
    expect(controller.position.pixels, closeTo(controller.position.maxScrollExtent, 0.5));

    // 正文继续长高（Markdown 表格/代码块展开），行数不变。
    await tester.pumpWidget(_host(controller: controller, height: 900));
    await tester.pumpAndSettle();

    expect(
      controller.position.pixels,
      closeTo(controller.position.maxScrollExtent, 0.5),
      reason: '同一条消息变长时最后几行不能被推到输入栏下面',
    );
  });

  testWidgets('用户往上翻看历史：内容变长不抢滚动', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller: controller, height: 900));
    await tester.pumpAndSettle();
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(controller.position.pixels, 0);

    await tester.pumpWidget(_host(controller: controller, height: 1200));
    await tester.pumpAndSettle();

    expect(controller.position.pixels, 0, reason: '用户正在看上面的内容，不许把他拉回底部');
  });

  testWidgets('用的是三种会话共用的跟随物理，底部渐隐不整段淡化', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller: controller, height: 600));
    await tester.pumpAndSettle();

    expect(controller.position.physics, isA<FollowScrollPhysics>());

    final fade = tester.widgetList<EdgeFade>(find.byType(EdgeFade)).first;
    expect(fade.bottomTail, 0, reason: '视口已停在输入栏上沿，再留 48dp 尾巴会把合法正文淡掉');
  });
}
