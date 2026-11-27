// 议会的历史与恢复：通知点进来（只有 runId）、老数据补会话记录、
// 席位子会话登记进协作簿（历史列表据此折叠）。
//
// 与 council_page_test 一样用内存仓库：widget 测试跑在 fake async 里，
// 真实文件 IO 会让等待永远等不到。

import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_app/collab/collab_conversations.dart';
import 'package:dsh_app/collab/collab_session_book.dart';
import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/council/collab_store.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/ui/council/council_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

final class _MemRunStore extends CollabStore {
  _MemRunStore() : super(Directory.systemTemp);

  final runs = <String, CollabRun>{};

  @override
  Future<void> save(CollabRun run) async => runs[run.id] = run;

  @override
  Future<CollabRun?> load(String id) async => runs[id];

  @override
  Future<List<CollabRun>> list() async => runs.values.toList();

  @override
  Future<void> writeVerdict(CollabRun run) async {}
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
}

final class _IdleDriver implements CollabSessionDriver {
  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async => 'sess-${seat.id}';

  @override
  Future<TurnOutcome> runTurn(String sessionId, String text, {Duration? timeout}) async =>
      const TurnOutcome(kind: TurnKind.completed, text: '好');

  @override
  Future<void> cancel(String sessionId) async {}
}

CollabRun _run(String id, String question, {String? verdict, String sessionId = 'sess-0'}) => CollabRun(
  id: id,
  spec: CouncilSpec(
    question: question,
    seats: const [
      SeatSpec(id: 's0', provider: 'deepseek', model: 'flash', label: 'V41 Flash'),
      SeatSpec(id: 's1', provider: 'deepseek', model: 'pro', label: 'V4 Pro'),
    ],
    mode: CollabMode.quick,
  ),
  phase: verdict == null ? CollabPhase.failed : CollabPhase.done,
  seats: {
    's0': SeatState(status: SeatStatus.answered, answer: '可以', sessionId: sessionId),
    's1': SeatState(status: SeatStatus.answered, answer: '再等等', sessionId: '$sessionId-b'),
  },
  verdict: verdict,
  failure: verdict == null ? '全部席位失败' : null,
  callsUsed: 3,
  createdAt: DateTime(2026, 11, 20, 10),
  updatedAt: DateTime(2026, 11, 20, 10, 5),
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory dir;
  late _MemRunStore runs;
  late _MemConversationStore conversations;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('council-history-');
    runs = _MemRunStore();
    conversations = _MemConversationStore();
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  CollabOrchestrator boot() {
    final orchestrator = CollabOrchestrator(driver: _IdleDriver(), store: runs);
    addTearDown(orchestrator.dispose);
    return orchestrator;
  }

  Future<void> pump(WidgetTester tester, CollabOrchestrator orchestrator, {String? runId, String? conversationId}) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(body: CouncilModeView(orchestrator: orchestrator, runId: runId, conversationId: conversationId)),
        overrides: [
          modelCatalogProvider.overrideWith((ref) async => _catalog()),
        // 目录已缓存：新建会话按它凑两位成员（真机上点进来时通常也已经有缓存）。
        currentModelCatalogProvider.overrideWithValue(_catalog()),
          readListLiveConnectionProvider.overrideWith((ref) => null),
          collabSessionRootProvider.overrideWithValue(() async => dir),
          councilStoreProvider.overrideWith((ref) async => conversations),
        ],
      ),
    );
    await _settle(tester);
  }

  testWidgets('只有 runId（通知点进来）：打开那次运行，并补一条会话记录', (tester) async {
    final orchestrator = boot();
    await runs.save(_run('run-notice', '要不要上线', verdict: '## 结论\n建议先灰度。'));

    await pump(tester, orchestrator, runId: 'run-notice');

    expect(find.textContaining('要不要上线'), findsWidgets);
    expect(find.text('主席裁决'), findsOneWidget);
    // 老数据只有 run，没有会话：现在补上了，历史分类能显示它。
    expect(conversations.conversations, hasLength(1));
    final saved = conversations.conversations.values.single;
    expect(saved.turns.single.runId, 'run-notice');
    expect(saved.seats, hasLength(2));
  });

  testWidgets('打开历史会话：成员与消息完整恢复，不新建', (tester) async {
    final orchestrator = boot();
    final run = _run('run-old', '旧议题', verdict: '## 结论\n按计划走。');
    await runs.save(run);
    conversations.conversations['conv-1'] = CouncilConversation(
      id: 'conv-1',
      title: '旧议题',
      seats: run.spec.seats,
      turns: [
        CouncilTurn(
          runId: 'run-old',
          question: '旧议题',
          at: run.createdAt,
          phase: CollabPhase.done.name,
          summary: '按计划走。',
        ),
      ],
      createdAt: run.createdAt,
      updatedAt: run.updatedAt,
    );

    await pump(tester, orchestrator, conversationId: 'conv-1');

    expect(find.textContaining('旧议题'), findsWidgets);
    expect(find.text('V41 Flash'), findsWidgets);
    expect(find.text('V4 Pro'), findsOneWidget);
    expect(find.text('可以'), findsOneWidget);
    expect(find.text('再等等'), findsOneWidget);
    expect(find.text('主席裁决'), findsOneWidget);
    expect(conversations.conversations, hasLength(1));
  });

  testWidgets('席位子会话登记进协作簿：普通历史里不再单列', (tester) async {
    final orchestrator = boot();
    await runs.save(_run('run-book', '登记测试', verdict: '## 结论\n好。', sessionId: 'sess-book'));

    await pump(tester, orchestrator, runId: 'run-book');

    final container = ProviderScope.containerOf(tester.element(find.byType(CouncilModeView)));
    final owners = container.read(collabSessionBookProvider);
    expect(owners.containsKey('sess-book'), isTrue);
    expect(owners['sess-book']?.kind, CollabSessionKind.council);
    expect(owners['sess-book']?.label, 'V41 Flash');
  });
}
