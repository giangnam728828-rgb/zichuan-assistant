// 左上角模式切换器（总方案 v2 第一、二阶段）：
//
// - 三个页面共用一份菜单：聊天 / 议会 / 团队，当前项打勾；
// - 窄屏先收起模式文字，只留图标和箭头，触控区仍是 44；
// - 控制器按主机记住每种模式上次的会话，草稿按模式与会话隔离；
// - 从聊天切到协作页、再切另一种、再切回聊天，路由栈不堆第二张协作页。

import 'package:dsh_app/state/conversation_mode_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/conversation_mode_switcher.dart';
import 'package:dsh_app/ui/common/status_dot.dart';
import 'package:dsh_app/ui/council/council_page.dart';
import 'package:dsh_app/ui/team/team_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

final _host = const HostRef.ssh('mac-mini');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('控制器', () {
    test('按主机记住上次的议会与团队，互不串线', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(conversationModeProvider.notifier);
      final mac = conversationHostKey(_host);
      final phone = conversationHostKey(HostRef.local);

      controller.rememberCouncil(mac, 'c1');
      controller.rememberTeam(mac, 't1');
      controller.rememberCouncil(phone, 'c9');

      final state = container.read(conversationModeProvider);
      expect(state.councilIdFor(mac), 'c1');
      expect(state.teamIdFor(mac), 't1');
      expect(state.councilIdFor(phone), 'c9');
      expect(state.teamIdFor(phone), isNull);
    });

    test('草稿按模式与会话隔离，发出去后清空', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(conversationModeProvider.notifier);
      final host = conversationHostKey(_host);

      controller.saveDraft(ConversationMode.council, host, 'c1', '还差一句');
      controller.saveDraft(ConversationMode.team, host, 't1', '另一个草稿');

      final state = container.read(conversationModeProvider);
      expect(state.draftOf(ConversationMode.council, host, 'c1'), '还差一句');
      expect(state.draftOf(ConversationMode.team, host, 't1'), '另一个草稿');
      expect(state.draftOf(ConversationMode.council, host, 'c2'), isEmpty);

      controller.clearDraft(ConversationMode.council, host, 'c1');
      expect(container.read(conversationModeProvider).draftOf(ConversationMode.council, host, 'c1'), isEmpty);
    });
  });

  test('落盘：重启后模式、会话与草稿都回来', () async {
    final host = conversationHostKey(_host);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(conversationModeProvider.notifier);
    controller.setMode(ConversationMode.council);
    controller.rememberCouncil(host, 'c7');
    controller.rememberTeam(host, 't7');
    controller.saveDraft(ConversationMode.council, host, 'c7', '没发完的问题');

    // 控制器把写入延后 300ms，等它落盘。
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final saved = await ConversationModeStore.load();
    expect(saved.mode, ConversationMode.council);
    expect(saved.councilIdFor(host), 'c7');
    expect(saved.teamIdFor(host), 't7');
    expect(saved.draftOf(ConversationMode.council, host, 'c7'), '没发完的问题');

    // 模拟进程重启：新容器拿存档当初始状态。
    final restarted = ProviderContainer(overrides: [conversationModeInitialProvider.overrideWithValue(saved)]);
    addTearDown(restarted.dispose);
    final state = restarted.read(conversationModeProvider);
    expect(state.mode, ConversationMode.council, reason: '第一帧就是上次的模式');
    expect(state.idFor(ConversationMode.council, host), 'c7');
    expect(state.draftOf(ConversationMode.council, host, 'c7'), '没发完的问题');
  });

  group('顶栏上的切换器', () {
    Future<ConversationMode?> pumpHeader(WidgetTester tester, {double width = 800}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.reset);
      ConversationMode? picked;
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: ChatHeader(
              title: '修复登录重复提交',
              status: const HeaderStatus(StatusTone.ok, '本机'),
              mode: ConversationMode.chat,
              onModeSelected: (mode) => picked = mode,
              onOpenDrawer: () {},
              onNewChat: () {},
            ),
          ),
          overrides: ChatHarness(session: null).overrides,
        ),
      );
      await tester.pumpAndSettle();
      return picked;
    }

    testWidgets('三段常驻：点哪个就切哪个，当前项有选中语义', (tester) async {
      ConversationMode? picked;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: ChatHeader(
              title: '今天的安排',
              status: const HeaderStatus(StatusTone.ok, '本机'),
              mode: ConversationMode.chat,
              onModeSelected: (mode) => picked = mode,
              onOpenDrawer: () {},
              onNewChat: () {},
            ),
          ),
          overrides: ChatHarness(session: null).overrides,
        ),
      );
      await tester.pumpAndSettle();

      // 不点开任何菜单，三段都在。
      expect(find.byKey(const ValueKey('mode-chat')), findsOneWidget);
      expect(find.byKey(const ValueKey('mode-council')), findsOneWidget);
      expect(find.byKey(const ValueKey('mode-team')), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('mode-chat'))),
        matchesSemantics(label: '聊天', isButton: true, isSelected: true, hasSelectedState: true),
      );

      await tester.tap(find.byKey(const ValueKey('mode-team')));
      await tester.pumpAndSettle();
      expect(picked, ConversationMode.team);
      // 三段不会收起。
      expect(find.byKey(const ValueKey('mode-team')), findsOneWidget);
    });

    testWidgets('窄屏收起模式文字，触控区仍是 44', (tester) async {
      await pumpHeader(tester, width: 360);
      expect(find.text('聊天'), findsNothing);
      // 每段自己就是 44dp 的触控区。
      for (final mode in ConversationMode.values) {
        final size = tester.getSize(find.byKey(ValueKey('mode-${mode.name}')));
        expect(size.height, 44);
        expect(size.width, 44);
      }
    });

    testWidgets('宽屏显示模式名字', (tester) async {
      await pumpHeader(tester, width: 800);
      expect(find.text('聊天'), findsOneWidget);
      expect(find.text('议会'), findsOneWidget);
      expect(find.text('团队'), findsOneWidget);
    });
  });

  group('模式路由', () {
    testWidgets('聊天 → 议会 → 团队 → 聊天：只有一张协作页，回来还是聊天', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(430, 900);
      addTearDown(tester.view.reset);
      final harness = ChatHarness(session: null, extra: [readListLiveConnectionProvider.overrideWith((ref) => null)]);
      await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
      await tester.pumpAndSettle();

      // 输入栏不再有协作键。
      expect(find.byKey(const ValueKey('composer-collab')), findsNothing);
      expect(find.byKey(const ValueKey('mode-chat')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('mode-council')));
      await tester.pumpAndSettle();
      expect(find.byType(CouncilPage), findsOneWidget);
      expect(find.byType(TeamPage), findsNothing);

      // 议会页顶栏也是同一枚切换器。
      await tester.tap(find.byKey(const ValueKey('mode-team')));
      await tester.pumpAndSettle();
      expect(find.byType(TeamPage), findsOneWidget);
      expect(find.byType(CouncilPage), findsNothing, reason: '议会页被替换，不是叠在下面');

      await tester.tap(find.byKey(const ValueKey('mode-chat')));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byType(TeamPage), findsNothing);
      expect(find.byType(CouncilPage), findsNothing);
    });
  });
}
