// 顶栏模式入口（总方案 v4）：
//
// - 顶栏只有一枚「当前模式」按钮，点开是纵向三项的悬浮面板；
// - 窄屏收起文字只留图标，触控区仍是 44；
// - 控制器按主机记住每种模式上次的会话，草稿按模式与会话隔离；
// - 切模式不再 push 独立页面：三种模式都在同一个 ChatScreen 工作区里，
//   切到议会/团队 = 新建一条对应会话，切回聊天 = 原来的聊天会话。

import 'dart:io';

import 'package:dsh_app/collab/collab_conversations.dart';
import 'package:dsh_app/state/conversation_mode_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/team/team_models.dart';
import 'package:dsh_app/team/team_store.dart';
import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/common/status_dot.dart';
import 'package:dsh_app/ui/council/council_page.dart';
import 'package:dsh_app/ui/team/team_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

final _host = const HostRef.ssh('mac-mini');

/// 内存仓库：工作区里的议会/团队视图不做真实文件 IO。
final class _MemCouncilStore extends CouncilConversationStore {
  _MemCouncilStore() : super(Directory.systemTemp);

  @override
  Future<Map<String, CouncilConversation>> load() async => const {};

  @override
  Future<void> save(Map<String, CouncilConversation> all) async {}
}

final class _MemTeamStore extends TeamStore {
  _MemTeamStore() : super(Directory.systemTemp);

  @override
  Future<void> save(TeamState state) async {}

  @override
  Future<TeamState?> load(String id) async => null;

  @override
  Future<List<TeamState>> list() async => const [];
}

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

    test('主动切模式 = 新建请求；历史打开 = 恢复请求；冷启动没有请求', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(conversationModeProvider.notifier);

      // 冷启动恢复：序号 0，不新建。
      expect(container.read(conversationModeProvider).requestNonce, 0);
      expect(container.read(conversationModeProvider).createNew, isFalse);

      controller.startNew(ConversationMode.council);
      var state = container.read(conversationModeProvider);
      expect(state.mode, ConversationMode.council);
      expect(state.createNew, isTrue);
      expect(state.requestNonce, 1);

      controller.startNew(ConversationMode.team);
      state = container.read(conversationModeProvider);
      expect(state.mode, ConversationMode.team);
      expect(state.createNew, isTrue);
      expect(state.requestNonce, 2);

      controller.openExisting(ConversationMode.council, 'c7');
      state = container.read(conversationModeProvider);
      expect(state.mode, ConversationMode.council);
      expect(state.openId, 'c7');
      expect(state.createNew, isFalse);
      expect(state.requestNonce, 3);

      controller.setMode(ConversationMode.chat);
      state = container.read(conversationModeProvider);
      expect(state.mode, ConversationMode.chat);
      expect(state.openId, isNull);
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
    expect(state.createNew, isFalse, reason: '冷启动恢复不新建会话');
  });

  group('顶栏上的会话类型徽标', () {
    Future<void> pumpHeader(WidgetTester tester, {double width = 800}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: ChatHeader(
              title: '修复登录重复提交',
              status: const HeaderStatus(StatusTone.ok, '本机'),
              mode: ConversationMode.chat,
              onOpenDrawer: () {},
              onNewChat: () {},
            ),
          ),
          overrides: ChatHarness(session: null).overrides,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('徽标只显示类型，点它不打开类型面板（D2：类型创建后不改）', (tester) async {
      await pumpHeader(tester);

      expect(find.byKey(const ValueKey('mode-chip')), findsOneWidget);
      expect(find.text('聊天'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('mode-chip')));
      await tester.pumpAndSettle();

      // 会话内没有切换入口：点徽标不会弹出任何类型面板。
      expect(find.byKey(const ValueKey('mode-option-chat')), findsNothing);
      expect(find.byKey(const ValueKey('mode-option-council')), findsNothing);
      expect(find.text('新建会话'), findsNothing);
    });

    testWidgets('窄屏收起类型文字，徽标高度仍是 44', (tester) async {
      await pumpHeader(tester, width: 360);
      expect(find.text('聊天'), findsNothing);
      final size = tester.getSize(find.byKey(const ValueKey('mode-chip')));
      expect(size.height, 44);
    });

    testWidgets('宽屏显示当前类型名字', (tester) async {
      await pumpHeader(tester, width: 800);
      expect(find.text('聊天'), findsOneWidget);
    });
  });

  group('新对话：先选类型，再建会话', () {
    testWidgets('聊天 → 议会 → 团队 → 聊天：都在 ChatScreen 里，回来还是聊天', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(430, 900);
      addTearDown(tester.view.reset);
      final harness = ChatHarness(
        session: null,
        extra: [
          readListLiveConnectionProvider.overrideWith((ref) => null),
          councilStoreProvider.overrideWith((ref) async => _MemCouncilStore()),
          teamStoreProvider.overrideWith((ref) async => _MemTeamStore()),
        ],
      );
      await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
      await tester.pumpAndSettle();

      Future<void> pick(ConversationMode mode) async {
        await tester.tap(find.byKey(const ValueKey('chat-new-chat')));
        await tester.pumpAndSettle();
        expect(find.text('新建会话'), findsOneWidget);
        await tester.tap(find.byKey(ValueKey('mode-option-${mode.name}')));
        await tester.pumpAndSettle();
      }

      await pick(ConversationMode.council);
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byType(CouncilModeView), findsOneWidget);
      expect(find.byType(TeamModeView), findsNothing);

      await pick(ConversationMode.team);
      expect(find.byType(TeamModeView), findsOneWidget);
      expect(find.byType(CouncilModeView), findsNothing, reason: '议会视图被换下，不是叠在下面');

      await pick(ConversationMode.chat);
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byType(TeamModeView), findsNothing);
      expect(find.byType(CouncilModeView), findsNothing);
    });

    testWidgets('点面板外面关闭，不新建也不改类型', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(430, 900);
      addTearDown(tester.view.reset);
      final harness = ChatHarness(session: null, extra: [readListLiveConnectionProvider.overrideWith((ref) => null)]);
      await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('chat-new-chat')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mode-option-team')), findsOneWidget);

      await tester.tapAt(const Offset(20, 780));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mode-option-team')), findsNothing);
      expect(find.byType(TeamModeView), findsNothing);
    });
  });
}
