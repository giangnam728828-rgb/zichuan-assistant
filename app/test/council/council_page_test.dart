// 议会聊天模式的界面测试：新会话直接进聊天、发问后多模型分别作答、
// 主席裁决单独成块、成员抽屉可增删改（方案第一、二部分）。
//
// 编排器与登记表都换成内存实现：widget 测试跑在 fake async 里，真实文件 IO
// 会让「等运行结束」永远等不到；落盘另有一条纯 Dart 测试覆盖。

import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_app/collab/collab_conversations.dart';
import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/council/collab_store.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/ui/council/council_page.dart';
import 'package:dsh_app/ui/collab/collab_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show testApp;

ModelCatalog _catalog() => const ModelCatalog(
  defaultSelection: ModelSelection(provider: 'deepseek', model: 'flash'),
  routableProviders: ['deepseek'],
  groups: [
    ProviderGroup('deepseek', 'DeepSeek', [
      ModelInfo(provider: 'deepseek', id: 'flash', name: 'V41 Flash'),
      ModelInfo(provider: 'deepseek', id: 'pro', name: 'V4 Pro'),
    ]),
  ],
  failures: [],
);

/// 内存里的运行仓库：不做文件 IO，fake async 下也能跑完。
final class _MemRunStore extends CollabStore {
  _MemRunStore() : super(Directory.systemTemp);

  final runs = <String, CollabRun>{};

  @override
  Future<void> save(CollabRun run) async {
    runs[run.id] = run;
  }

  @override
  Future<CollabRun?> load(String id) async => runs[id];

  @override
  Future<List<CollabRun>> list() async => runs.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  /// 裁决正文本来会落一份 Markdown：内存仓库里没有磁盘，跳过。
  @override
  Future<void> writeVerdict(CollabRun run) async {}
}

/// 内存里的会话登记表。
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

/// 记录开了几个席位会话，回答一句话。
final class _Driver implements CollabSessionDriver {
  final opened = <String>[];

  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async {
    final id = 'sess-${seat.id}-${opened.length}';
    opened.add(id);
    return id;
  }

  @override
  Future<TurnOutcome> runTurn(String sessionId, String text, {Duration? timeout}) async =>
      const TurnOutcome(kind: TurnKind.completed, text: '我的看法是这样。');

  @override
  Future<void> cancel(String sessionId) async {}
}

/// 推进微任务与帧（内存仓库没有真实 IO，几帧就够）。
Future<void> _settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 等到会话里所有回合都跑到终态。
Future<void> _waitForTurns(WidgetTester tester, _MemConversationStore store, [_MemRunStore? runStore]) async {
  for (var i = 0; i < 200; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    final turns = store.conversations.values.expand((conversation) => conversation.turns).toList();
    if (turns.isNotEmpty && turns.every((turn) => !turn.running)) return;
  }
  final turns = store.conversations.values.expand((conversation) => conversation.turns).toList();
  final states = [
    for (final turn in turns)
      '${turn.phase}:${runStore?.runs[turn.runId]?.phase.name}:${runStore?.runs[turn.runId]?.seats.values.map((s) => s.status.name).toList()}',
  ];
  fail('议会运行没有在限定时间内结束：$states');
}

Future<void> _pump(
  WidgetTester tester,
  CollabOrchestrator orchestrator,
  _MemConversationStore store, {
  String? conversationId,
  String? runId,
  bool resumeLatest = false,
}) async {
  await tester.pumpWidget(
    testApp(
      CouncilPage(orchestrator: orchestrator, conversationId: conversationId, runId: runId, resumeLatest: resumeLatest),
      overrides: [
        modelCatalogProvider.overrideWith((ref) async => _catalog()),
        // 目录已缓存：新建会话按它凑两位成员（真机上点进来时通常也已经有缓存）。
        currentModelCatalogProvider.overrideWithValue(_catalog()),
        readListLiveConnectionProvider.overrideWith((ref) => null),
        councilStoreProvider.overrideWith((ref) async => store),
      ],
    ),
  );
  await _settle(tester);
}

void main() {
  late _MemRunStore runs;
  late _MemConversationStore conversations;

  setUp(() {
    runs = _MemRunStore();
    conversations = _MemConversationStore();
  });

  testWidgets('点进来就是一条新会话：标识、标题、空状态、输入栏', (tester) async {
    final orchestrator = CollabOrchestrator(driver: _Driver(), store: runs);
    addTearDown(orchestrator.dispose);
    await _pump(tester, orchestrator, conversations);

    expect(find.text('议会'), findsWidgets);
    expect(find.text('新议会'), findsOneWidget);
    expect(find.text('议会已就绪'), findsOneWidget);
    expect(find.textContaining('2 位成员'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(const ValueKey('council-members')), findsOneWidget);
  });

  testWidgets('模型目录一直不回来也能进议会：不转圈、直接给添加成员', (tester) async {
    // 目录请求挂住（Host 慢 / 断线）：以前这里会永远转圈、副标题停在「0 位成员」。
    final orchestrator = CollabOrchestrator(driver: _Driver(), store: runs);
    addTearDown(orchestrator.dispose);
    await tester.pumpWidget(
      testApp(
        CouncilPage(orchestrator: orchestrator),
        overrides: [
          modelCatalogProvider.overrideWith((ref) => Completer<ModelCatalog?>().future),
          readListLiveConnectionProvider.overrideWith((ref) => null),
          councilStoreProvider.overrideWith((ref) async => conversations),
        ],
      ),
    );
    await _settle(tester);

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('0 位成员'), findsOneWidget);
    expect(find.text('议会已就绪'), findsOneWidget);
    expect(find.byKey(const ValueKey('council-onboarding-add')), findsOneWidget);
    // 还能正常输入（输入栏没有因为「没成员」被禁用）。
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('发一个问题：用户气泡、各席位分别作答、主席裁决各自成块', (tester) async {
    final driver = _Driver();
    final orchestrator = CollabOrchestrator(driver: driver, store: runs);
    addTearDown(orchestrator.dispose);
    await _pump(tester, orchestrator, conversations);

    await tester.enterText(find.byType(TextField), '这个方案要不要上线？');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('composer-send')));
    await _waitForTurns(tester, conversations, runs);

    // 我的问题在消息流里。
    expect(find.byType(CollabUserBubble), findsOneWidget);
    // 标题也取自第一句，所以问题至少出现在气泡里（标题里可能也有）。
    expect(find.textContaining('这个方案要不要上线？'), findsWidgets);
    // 两位成员各一条，绝不混在一条里。
    expect(find.byType(CollabMessage), findsNWidgets(2));
    // 席位行一条，主席裁决行还有一条（主席就是第一位）。
    expect(find.text('V41 Flash'), findsNWidgets(2));
    expect(find.text('V4 Pro'), findsOneWidget);
    // 两条席位回答 + 主席的裁决（这个假驱动连裁决也回同一句）。
    expect(find.textContaining('我的看法是这样。'), findsNWidgets(3));
    // 主席裁决单独一块。
    expect(find.text('主席裁决'), findsOneWidget);

    final saved = conversations.conversations.values.single;
    expect(saved.turns, hasLength(1));
    expect(saved.title, '这个方案要不要上线？');
  });

  testWidgets('成员抽屉：紧凑列表 + 添加成员 + 运行方式', (tester) async {
    final orchestrator = CollabOrchestrator(driver: _Driver(), store: runs);
    addTearDown(orchestrator.dispose);
    await _pump(tester, orchestrator, conversations);

    await tester.tap(find.byKey(const ValueKey('council-members')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('议会成员'), findsOneWidget);
    expect(find.text('参会模型'), findsOneWidget);
    expect(find.textContaining('2/6'), findsOneWidget);
    expect(find.text('运行方式'), findsOneWidget);
    expect(find.text('添加成员'), findsOneWidget);
  });

  testWidgets('第二轮沿用上一轮的席位会话（多轮上下文不断）', (tester) async {
    final driver = _Driver();
    final orchestrator = CollabOrchestrator(driver: driver, store: runs);
    addTearDown(orchestrator.dispose);
    await _pump(tester, orchestrator, conversations);

    await tester.enterText(find.byType(TextField), '第一问');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('composer-send')));
    await _waitForTurns(tester, conversations, runs);
    expect(driver.opened, hasLength(2));

    await tester.enterText(find.byType(TextField), '第二问');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('composer-send')));
    await _waitForTurns(tester, conversations, runs);

    // 没有再开新会话：第二轮续在同一个席位会话里。
    expect(driver.opened, hasLength(2));
    final saved = conversations.conversations.values.single;
    expect(saved.turns, hasLength(2));
    expect(saved.turns.last.question, '第二问');
  });

  testWidgets('从历史打开：恢复原会话的成员与消息，不新建', (tester) async {
    final driver = _Driver();
    final orchestrator = CollabOrchestrator(driver: driver, store: runs);
    addTearDown(orchestrator.dispose);
    await _pump(tester, orchestrator, conversations);
    await tester.enterText(find.byType(TextField), '历史里的那一问');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('composer-send')));
    await _waitForTurns(tester, conversations, runs);
    final id = conversations.conversations.keys.single;

    // 换一棵树重新打开同一条。
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, orchestrator, conversations, conversationId: id);

    expect(find.textContaining('历史里的那一问'), findsWidgets);
    expect(find.textContaining('2 位成员'), findsOneWidget);
    expect(conversations.conversations, hasLength(1));
  });

  testWidgets('切换模式回来：恢复最近一条议会，不新建', (tester) async {
    final orchestrator = CollabOrchestrator(driver: _Driver(), store: runs);
    addTearDown(orchestrator.dispose);
    await _pump(tester, orchestrator, conversations);
    await tester.enterText(find.byType(TextField), '切走之前的那一问');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('composer-send')));
    await _waitForTurns(tester, conversations, runs);
    final id = conversations.conversations.keys.single;

    await tester.pumpWidget(const SizedBox());
    await _pump(tester, orchestrator, conversations, resumeLatest: true);

    expect(conversations.conversations.keys, [id]);
    expect(find.textContaining('切走之前的那一问'), findsWidgets);
    expect(find.textContaining('2 位成员'), findsOneWidget);
  });

  test('会话记录可序列化：落盘再读回来，成员与回合都在', () async {
    final dir = await Directory.systemTemp.createTemp('council-json-');
    addTearDown(() => dir.delete(recursive: true));
    final store = CouncilConversationStore(dir);
    final conversation = CouncilConversation(
      id: 'conv-1',
      title: '序列化',
      seats: const [
        SeatSpec(id: 's0', provider: 'deepseek', model: 'flash', label: 'V41 Flash'),
        SeatSpec(id: 's1', provider: 'deepseek', model: 'pro', label: 'V4 Pro'),
      ],
      turns: [
        CouncilTurn(
          runId: 'run-1',
          question: '问题',
          at: DateTime(2026, 11, 20, 10),
          phase: CollabPhase.done.name,
          summary: '结论',
        ),
      ],
      createdAt: DateTime(2026, 11, 20, 10),
      updatedAt: DateTime(2026, 11, 20, 10, 5),
    );
    await store.save({'conv-1': conversation});
    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded['conv-1']!.seats, hasLength(2));
    expect(loaded['conv-1']!.turns.single.question, '问题');
    expect(loaded['conv-1']!.turns.single.phase, CollabPhase.done.name);
  });
}
