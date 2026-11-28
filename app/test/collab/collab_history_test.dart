// 历史里的议会 / 团队分类（方案第三部分）：分类条只在没有协作会话时隐藏，
// 「议会」「团队」页各列各的，「全部」里置顶一段；长按删除只删这一条。

import 'dart:io';

import 'package:dsh_app/collab/collab_conversations.dart';
import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/state/history_kind_state.dart';
import 'package:dsh_app/team/team_models.dart';
import 'package:dsh_app/team/team_store.dart';
import 'package:dsh_app/ui/collab/collab_history.dart';
import 'package:dsh_app/ui/common/capsule_chip.dart';
import 'package:dsh_app/state/conversation_mode_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show testApp;

final class _MemTeamStore extends TeamStore {
  _MemTeamStore() : super(Directory.systemTemp);

  final teams = <String, TeamState>{};

  @override
  Future<void> save(TeamState state) async => teams[state.id] = state;

  @override
  Future<TeamState?> load(String id) async => teams[id];

  @override
  Future<List<TeamState>> list() async => teams.values.toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Future<void> delete(String id) async => teams.remove(id);
}

final class _MemConversationStore extends CouncilConversationStore {
  _MemConversationStore() : super(Directory.systemTemp);

  final conversations = <String, CouncilConversation>{};

  @override
  Future<Map<String, CouncilConversation>> load() async => Map.of(conversations);

  @override
  Future<void> save(Map<String, CouncilConversation> all) async {
    conversations
      ..clear()
      ..addAll(all);
  }

  @override
  Future<void> delete(String id) async => conversations.remove(id);
}

TeamState _team(String id, String title, DateTime at, {int mates = 2}) => TeamState(
  id: id,
  title: title,
  teammates: [
    for (var i = 0; i < mates; i++) Teammate(id: '$id-m$i', name: '队友 ${i + 1}', provider: 'deepseek', model: 'flash'),
  ],
  messages: [TeamMsg(id: '$id-x', role: TeamMsgRole.user, text: title, at: at)],
  createdAt: at,
  updatedAt: at,
  rev: 1,
);

CouncilConversation _council(String id, String title, DateTime at) => CouncilConversation(
  id: id,
  title: title,
  seats: const [
    SeatSpec(id: 's0', provider: 'deepseek', model: 'flash'),
    SeatSpec(id: 's1', provider: 'deepseek', model: 'pro'),
  ],
  turns: [
    CouncilTurn(runId: 'r-$id', question: title, at: at, phase: CollabPhase.done.name, summary: '结论'),
  ],
  createdAt: at,
  updatedAt: at,
);

Future<void> _settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required _MemTeamStore teams,
  required _MemConversationStore council,
  required Widget home,
}) async {
  await tester.pumpWidget(
    testApp(
      home,
      overrides: [
        teamStoreProvider.overrideWith((ref) async => teams),
        councilStoreProvider.overrideWith((ref) async => council),
      ],
    ),
  );
  await _settle(tester);
}

void main() {
  late _MemTeamStore teams;
  late _MemConversationStore council;
  final t0 = DateTime(2026, 3, 1, 9);

  setUp(() {
    teams = _MemTeamStore();
    council = _MemConversationStore();
  });

  testWidgets('分类条：没有议会/团队会话时不摆，有了才出现', (tester) async {
    await _pump(tester, teams: teams, council: council, home: const Scaffold(body: HistoryKindBar()));
    expect(find.byType(CapsuleChoiceChip), findsNothing);

    council.conversations['c1'] = _council('c1', '要不要上线', t0);
    teams.teams['t1'] = _team('t1', '登录页重做', t0);
    // 换一棵树，让历史列表重新读一遍。
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, teams: teams, council: council, home: const Scaffold(body: HistoryKindBar()));
    await _settle(tester);

    for (final label in ['全部', '普通', '议会', '团队']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.byKey(const ValueKey('history-kind-team')));
    await _settle(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(HistoryKindBar)));
    expect(container.read(historyKindProvider), HistoryKind.team);
  });

  testWidgets('「团队」页：只列团队，带标签和成员数；没有就给空状态', (tester) async {
    await _pump(
      tester,
      teams: teams,
      council: council,
      home: const Scaffold(body: CollabHistoryList(kind: CollabKind.team)),
    );
    expect(find.text('还没有团队会话'), findsOneWidget);

    council.conversations['c1'] = _council('c1', '要不要上线', t0);
    teams.teams['t1'] = _team('t1', '登录页重做', t0);
    teams.teams['t2'] = _team('t2', '修登录', t0.add(const Duration(hours: 1)));
    await tester.pumpWidget(const SizedBox());
    await _pump(
      tester,
      teams: teams,
      council: council,
      home: const Scaffold(body: CollabHistoryList(kind: CollabKind.team)),
    );

    expect(find.byType(CollabHistoryTile), findsNWidgets(2));
    expect(find.text('要不要上线'), findsNothing);
    expect(find.text('登录页重做'), findsOneWidget);
    expect(find.text('团队'), findsNWidgets(2));
    // v4.3 · P0-G：协作历史就是普通会话那一行 + 一枚类型标签；
    // 成员数这类细节移到长按详情面板里，不再单占一行。
    expect(find.byKey(const ValueKey('session-kind-tag')), findsNWidgets(2));
    expect(find.textContaining('2 位队友'), findsNothing);
    // 最近更新的在前。
    expect(
      tester.getTopLeft(find.text('修登录')).dy,
      lessThan(tester.getTopLeft(find.text('登录页重做')).dy),
    );
  });

  testWidgets('「全部」里置顶一段：议会 + 团队混排，最多 limit 条', (tester) async {
    council.conversations['c1'] = _council('c1', '要不要上线', t0);
    for (var i = 0; i < 5; i++) {
      teams.teams['t$i'] = _team('t$i', '团队 $i', t0.add(Duration(minutes: i)));
    }
    await _pump(
      tester,
      teams: teams,
      council: council,
      home: const Scaffold(body: CollabHistorySection(onClose: null, limit: 4)),
    );

    expect(find.text('议会与团队'), findsOneWidget);
    expect(find.byType(CollabHistoryTile), findsNWidgets(4));
    // 最老的那条（议会）被 limit 截掉了。
    expect(find.text('要不要上线'), findsNothing);
    expect(find.text('议会'), findsNothing);
    expect(find.text('团队'), findsNWidgets(4));
  });

  testWidgets('长按删除：确认后只删这一条，别的会话还在', (tester) async {
    council.conversations['c1'] = _council('c1', '要不要上线', t0);
    teams.teams['t1'] = _team('t1', '登录页重做', t0);
    teams.teams['t2'] = _team('t2', '修登录', t0.add(const Duration(hours: 1)));
    await tester.pumpWidget(const SizedBox());
    await _pump(
      tester,
      teams: teams,
      council: council,
      home: const Scaffold(body: CollabHistoryList(kind: CollabKind.team)),
    );

    // v4.3 · P0-H：长按先弹详情与操作面板，不是直接问「删不删」。
    await tester.longPress(find.text('登录页重做'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('collab-sheet-open')), findsOneWidget);
    expect(find.byKey(const ValueKey('collab-sheet-export')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('collab-sheet-delete')));
    await _settle(tester);
    expect(find.text('删除这条团队会话？'), findsOneWidget);
    expect(find.textContaining('其他会话不受影响'), findsAtLeastNWidgets(1));

    // 先取消：什么都不删。
    await tester.tap(find.text('取消'));
    await _settle(tester);
    expect(teams.teams, hasLength(2));

    await tester.longPress(find.text('登录页重做'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('collab-sheet-delete')));
    await _settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await _settle(tester);

    expect(teams.teams.keys, ['t2']);
    expect(council.conversations, hasLength(1));
    expect(find.text('登录页重做'), findsNothing);
    expect(find.text('修登录'), findsOneWidget);
  });

  testWidgets('点一条：打开那条团队会话（按 teamId 恢复，不新建）', (tester) async {
    teams.teams['t1'] = _team('t1', '登录页重做', t0);
    await _pump(
      tester,
      teams: teams,
      council: council,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => openCollabEntry(
              context,
              CollabHistoryEntry(
                id: 't1',
                kind: CollabKind.team,
                title: '登录页重做',
                subtitle: '我',
                memberCount: 2,
                createdAt: t0,
                updatedAt: t0,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // v4：不再 push 独立页面，只把「打开哪条」写进模式状态。
    final container = ProviderScope.containerOf(tester.element(find.text('open')));
    final state = container.read(conversationModeProvider);
    expect(state.mode, ConversationMode.team);
    expect(state.openId, 't1');
    expect(state.createNew, isFalse);
  });

  test('分类控制器：默认全部，切换后回传', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(historyKindProvider.notifier);
    expect(container.read(historyKindProvider), HistoryKind.all);
    controller.select(HistoryKind.council);
    expect(container.read(historyKindProvider), HistoryKind.council);
    expect(HistoryKind.values.map((k) => k.label), ['全部', '普通', '议会', '团队']);
  });
}
