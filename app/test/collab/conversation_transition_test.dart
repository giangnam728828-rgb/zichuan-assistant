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

void main() {
  group('ConversationTransition 规格', () {
    testWidgets('标准档：240ms，非零位移', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        _host(
          disableAnimations: false,
          child: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(ConversationTransition.duration(captured), const Duration(milliseconds: 240));
      expect(ConversationTransition.reduced(captured), isFalse);
      expect(ConversationTransition.shift, 8.0);
    });

    testWidgets('减少动画：时长为 0，且标记 reduced', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        _host(
          disableAnimations: true,
          child: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(ConversationTransition.duration(captured), Duration.zero);
      expect(ConversationTransition.reduced(captured), isTrue);
    });

    testWidgets('减少动画时 tab()/mode() 直接返回孩子，不留半透明帧', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        _host(
          disableAnimations: true,
          child: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final animation = const AlwaysStoppedAnimation<double>(0.5);
      final key = ValueKey('probe');
      final tabbed = ConversationTransition.tab(
        context: captured,
        animation: animation,
        direction: 1,
        child: const SizedBox(key: ValueKey('probe'), width: 10, height: 10),
      );
      expect(tabbed.key, key, reason: '减少动画时原样返回，没有动画包装');
      final moded = ConversationTransition.mode(
        context: captured,
        animation: animation,
        child: const SizedBox(key: ValueKey('probe'), width: 10, height: 10),
      );
      expect(moded.key, key);
    });

    testWidgets('模式切换只淡入：不产生位移变换', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        _host(
          disableAnimations: false,
          child: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final animation = const AlwaysStoppedAnimation<double>(0.0);
      const probe = ValueKey('mode-probe');
      await tester.pumpWidget(
        _host(
          disableAnimations: false,
          child: ConversationTransition.mode(
            context: captured,
            animation: animation,
            child: const SizedBox(key: probe, width: 40, height: 40),
          ),
        ),
      );
      // 只看这一段子树：MaterialApp/Scaffold 自己也有 Transform，全树找不到
      // 并不能说明什么。模式切换里应当没有位移，只有一个淡入。
      final transforms = find.descendant(
        of: find.byType(FadeTransition),
        matching: find.byType(Transform),
      );
      expect(transforms, findsNothing, reason: '模式切换不位移，位移只由标签页那一层提供');
      expect(find.byKey(probe), findsOneWidget);
    });
  });
}
