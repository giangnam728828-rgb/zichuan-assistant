// 议会页的 C6 部分：历史列表、从历史回看裁决、席位会话补登记、席位预设。

import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_app/collab/collab_session_book.dart';
import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/council/collab_store.dart';
import 'package:dsh_app/state/features_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/ui/council/council_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

/// 推进真实的文件 IO（widget 测试跑在 fake async 里）。
Future<void> _settleIo(WidgetTester tester, {int rounds = 20}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 8)));
    await tester.pump();
  }
}

/// 面板 / 弹窗的转场：用固定步长推进（页面上可能有一直转的进度圈）。
Future<void> _settleAnim(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _pump(WidgetTester tester, CollabOrchestrator orchestrator, Directory dir) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        modelCatalogProvider.overrideWith((ref) async => _catalog()),
        agentPresetsProvider.overrideWith((ref) async => const <AgentPresetInfo>[]),
        readListLiveConnectionProvider.overrideWith((ref) => null),
        collabSessionRootProvider.overrideWithValue(() async => dir),
      ],
      child: MaterialApp(home: CouncilPage(orchestrator: orchestrator)),
    ),
  );
  await tester.pump();
  await _settleIo(tester);
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('council-page-');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  CollabOrchestrator boot() {
    final orchestrator = CollabOrchestrator(driver: _IdleDriver(), store: CollabStore(dir));
    addTearDown(orchestrator.dispose);
    return orchestrator;
  }

  testWidgets('没有历史时点历史：提示还没跑过', (tester) async {
    await _pump(tester, boot(), dir);

    await tester.tap(find.byTooltip('历史议会'));
    // 历史是异步读盘的：推进真实 IO 再断言。
    await _settleIo(tester);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('还没有跑过议会'), findsOneWidget);
  });

  testWidgets('历史列表：按时间倒序，点一条回看裁决', (tester) async {
    final orchestrator = boot();
    await tester.runAsync(() async {
      await orchestrator.store.save(_run('r1', '要不要上线', verdict: '## 结论\n可以上线'));
      await orchestrator.store.save(
        _run('r2', '换不换框架', verdict: null).copyWithDate(DateTime(2026, 11, 22, 9)),
      );
    });

    await _pump(tester, orchestrator, dir);
    await tester.tap(find.byTooltip('历史议会'));
    await _settleIo(tester);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('最近的议会'), findsOneWidget);
    expect(find.text('要不要上线'), findsOneWidget);
    expect(find.text('换不换框架'), findsOneWidget);
    // 最近的在上面。
    final newer = tester.getTopLeft(find.text('换不换框架'));
    final older = tester.getTopLeft(find.text('要不要上线'));
    expect(newer.dy, lessThan(older.dy));

    await tester.tap(find.text('要不要上线'));
    await _settleIo(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('主席裁决'), findsOneWidget);
    expect(find.text('可以上线'), findsOneWidget);
  });

  testWidgets('席位预设：选过的席位提交时带着它（决定工具，如联网）', (tester) async {
    final orchestrator = CollabOrchestrator(driver: _IdleDriver(), store: CollabStore(dir));
    addTearDown(orchestrator.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          modelCatalogProvider.overrideWith((ref) async => _catalog()),
          readListLiveConnectionProvider.overrideWith((ref) => null),
          collabSessionRootProvider.overrideWithValue(() async => dir),
          agentPresetsProvider.overrideWith(
            (ref) async => const [
              AgentPresetInfo(id: 'standard', name: '标准', isDefault: true),
              AgentPresetInfo(id: 'research', name: '研究（联网）'),
            ],
          ),
        ],
        child: MaterialApp(home: CouncilPage(orchestrator: orchestrator)),
      ),
    );
    await tester.pump();
    await _settleIo(tester);

    await tester.tap(find.widgetWithText(FilterChip, 'V41 Flash'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip, 'V4 Pro'));
    await tester.pump();

    // 第一个席位选「研究（联网）」。
    await tester.tap(find.byTooltip('预设：Host 默认').first);
    await _settleAnim(tester);
    expect(find.text('这一席的预设'), findsOneWidget);
    await tester.tap(find.text('研究（联网）'));
    await _settleAnim(tester);
    expect(find.byTooltip('预设：研究（联网）'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '要不要上线');
    await tester.pump();
    await tester.scrollUntilVisible(find.byType(FilledButton), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byType(FilledButton));
    await _settleIo(tester, rounds: 40);

    final runs = await tester.runAsync(() => orchestrator.store.list());
    expect(runs, isNotEmpty);
    expect(runs!.first.spec.seats.map((seat) => seat.agentPreset).toList(), ['research', null]);
  });

  testWidgets('打开页面就把历史运行的席位会话补登记（不再冒进历史列表）', (tester) async {
    final orchestrator = boot();
    await tester.runAsync(() async {
      await orchestrator.store.save(_run('r1', '要不要上线', verdict: '可以', sessionId: 'sess-x'));
    });

    await _pump(tester, orchestrator, dir);

    final container = ProviderScope.containerOf(tester.element(find.byType(CouncilPage)));
    // 等登记写完盘再断言。
    await _settleIo(tester);
    final owners = container.read(collabSessionBookProvider);
    expect(owners.keys, containsAll(['sess-x', 'sess-x-b']));
    expect(owners['sess-x']!.kind, CollabSessionKind.council);
    expect(owners['sess-x']!.label, 'V41 Flash');
    expect(owners['sess-x']!.parentLabel, '要不要上线');
    // 真的落盘了：新实例读得到。
    final saved = await tester.runAsync(() => CollabSessionBook(dir).load());
    expect(saved!.keys, containsAll(['sess-x', 'sess-x-b']));
  });
}

extension on CollabRun {
  CollabRun copyWithDate(DateTime at) => CollabRun(
    id: id,
    spec: spec,
    phase: phase,
    seats: seats,
    verdict: verdict,
    failure: failure,
    callsUsed: callsUsed,
    cancelRequested: cancelRequested,
    createdAt: at,
    updatedAt: at,
    rev: rev,
  );
}
