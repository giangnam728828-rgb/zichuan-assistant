// 页面切换动效（方案第八部分 / 阶段 F）。
//
// 三件事必须成立，且能测：
// 1. 标签页与聊天模式切换用同一套时长/曲线（一个位移源，不叠加）；
// 2. 系统「移除动画」/ 用户关动画时不做转场，直接呈现；
// 3. 模式切换只淡入、不位移——位移留给标签页那一层。

import 'package:dsh_app/performance/motion_policy.dart';
import 'package:dsh_app/ui/chat/shared/conversation_transition.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({required bool disableAnimations, required Widget child}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(size: const Size(360, 780), disableAnimations: disableAnimations),
    child: MotionPolicyScope(
      policy: MotionPolicy(systemReduced: disableAnimations, userMuted: false, lightweight: false),
      child: Scaffold(body: child),
    ),
  ),
);

/// 在当前树里取一个真实 context（上一帧的 Element context 不能拿来建新树）。
Future<BuildContext> _contextOf(WidgetTester tester, {required bool disableAnimations}) async {
  late BuildContext captured;
  await tester.pumpWidget(
    _host(
      disableAnimations: disableAnimations,
      child: Builder(
        builder: (context) {
          captured = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}

void main() {
  group('ConversationTransition 规格', () {
    testWidgets('标准档：240ms，位移 8dp', (tester) async {
      final context = await _contextOf(tester, disableAnimations: false);
      expect(ConversationTransition.duration(context), const Duration(milliseconds: 240));
      expect(ConversationTransition.reduced(context), isFalse);
      expect(ConversationTransition.shift, 8.0);
    });

    testWidgets('减少动画：时长为 0，且标记 reduced', (tester) async {
      final context = await _contextOf(tester, disableAnimations: true);
      expect(ConversationTransition.duration(context), Duration.zero);
      expect(ConversationTransition.reduced(context), isTrue);
    });

    testWidgets('减少动画时 tab()/mode() 直接返回孩子，不留半透明帧', (tester) async {
      const probe = ValueKey('reduce-probe');
      const wrapper = ValueKey('reduce-wrapper');
      await tester.pumpWidget(
        _host(
          disableAnimations: true,
          child: Builder(
            builder: (context) => Column(
              children: [
                KeyedSubtree(
                  key: wrapper,
                  child: ConversationTransition.tab(
                    context: context,
                    animation: const AlwaysStoppedAnimation<double>(0.5),
                    direction: 1,
                    child: const SizedBox(key: probe, width: 10, height: 10),
                  ),
                ),
                ConversationTransition.mode(
                  context: context,
                  animation: const AlwaysStoppedAnimation<double>(0.5),
                  child: const SizedBox(width: 10, height: 10),
                ),
              ],
            ),
          ),
        ),
      );
      // 减少动画时没有任何转场包装：直接就是那个孩子。
      expect(
        find.descendant(of: find.byKey(wrapper), matching: find.byType(FadeTransition)),
        findsNothing,
      );
      expect(
        find.descendant(of: find.byKey(wrapper), matching: find.byType(Transform)),
        findsNothing,
      );
      expect(find.byKey(probe), findsOneWidget);
    });

    testWidgets('模式切换只淡入：不产生位移变换', (tester) async {
      const wrapper = ValueKey('mode-wrapper');
      const probe = ValueKey('mode-probe');
      await tester.pumpWidget(
        _host(
          disableAnimations: false,
          child: Builder(
            builder: (context) => KeyedSubtree(
              key: wrapper,
              child: ConversationTransition.mode(
                context: context,
                animation: const AlwaysStoppedAnimation<double>(0.0),
                child: const SizedBox(key: probe, width: 40, height: 40),
              ),
            ),
          ),
        ),
      );
      // 只看这一段子树：MaterialApp 的路由与 Scaffold 自己也有 FadeTransition
      // 和 Transform，从「所有 FadeTransition」往下找会找到整页。
      expect(
        find.descendant(of: find.byKey(wrapper), matching: find.byType(Transform)),
        findsNothing,
        reason: '模式切换不位移，位移只由标签页那一层提供',
      );
      expect(
        find.descendant(of: find.byKey(wrapper), matching: find.byType(FadeTransition)),
        findsOneWidget,
        reason: '模式切换只有一层淡入',
      );
      expect(find.byKey(probe), findsOneWidget);
    });

    testWidgets('标签页：淡入 + 沿方向位移（标准档）', (tester) async {
      const wrapper = ValueKey('tab-wrapper');
      await tester.pumpWidget(
        _host(
          disableAnimations: false,
          child: Builder(
            builder: (context) => KeyedSubtree(
              key: wrapper,
              child: ConversationTransition.tab(
                context: context,
                animation: const AlwaysStoppedAnimation<double>(1.0),
                direction: 1,
                child: const SizedBox(width: 40, height: 40),
              ),
            ),
          ),
        ),
      );
      // 标签页这一层**才**有位移：终点时偏移归零，但仍有一个 Transform。
      expect(
        find.descendant(of: find.byKey(wrapper), matching: find.byType(Transform)),
        findsOneWidget,
        reason: '位移由标签页这一层提供',
      );
      final transform = tester.widget<Transform>(
        find.descendant(of: find.byKey(wrapper), matching: find.byType(Transform)),
      );
      expect(transform.transform.getTranslation().x, closeTo(0.0, 0.01));
    });
  });
}
