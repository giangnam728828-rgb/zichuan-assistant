// v4.2 · P0-B / P0-E：整页 widget 级保活回归。
//
// 真实挂载 CouncilModeView → 发问 → 第一位答完、第二位在跑时把整棵视图
// 卸载（模拟切到普通聊天）→ 运行继续 → 再挂回来（同一 conversationId）→
// 断言：runId 不变、已生成正文还在、没有重复调用已经答过的席位、最终跑完。

import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_app/collab/collab_conversations.dart';
import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/council/collab_store.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/ui/chat/shared/conversation_mode_host.dart';
import 'package:dsh_app/ui/council/council_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show testApp;
import '../collab/mode_view_harness.dart';

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

  @override
  Future<void> delete(String id) async => conversations.remove(id);
}

/// 慢驱动：每个席位停 120ms，记下每席调用次数。
final class _SlowDriver implements CollabSessionDriver {
  final calls = <String, int>{};
  int _seq = 0;
  final _seatOf = <String, String>{};

  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async {
    final id = 's${_seq++}';
    _seatOf[id] = seat.id;
    return id;
  }

  @override
  Future<TurnOutcome> runTurn(
    String sessionId,
    String text, {
    Duration? timeout,
    List<CollabAttachment> attachments = const [],
  }) async {
    final seat = _seatOf[sessionId] ?? '?';
    calls[seat] = (calls[seat] ?? 0) + 1;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    return TurnOutcome(kind: TurnKind.completed, text: '${_nameOf(seat)} 的完整回答');
  }

  @override
  Future<void> cancel(String sessionId) async {}

  static String _nameOf(String seat) => switch (seat) {
    'seat0' => '甲',
    'seat1' => '乙',
    _ => '丙',
  };
}

Future<void> _settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _pump(
  WidgetTester tester,
  CollabOrchestrator orchestrator,
  _MemConversationStore store, {
  String? conversationId,
}) async {
  final header = ValueNotifier<CollabHeaderInfo?>(null);
  addTearDown(header.dispose);
  await tester.pumpWidget(
    testApp(
      ModeViewHarness(
        header: header,
        newLabel: '新议会',
        child: CouncilModeView(
          orchestrator: orchestrator,
          conversationId: conversationId,
          header: header,
        ),
      ),
      overrides: [
        modelCatalogProvider.overrideWith((ref) async => _catalog()),
        currentModelCatalogProvider.overrideWithValue(_catalog()),
        readListLiveConnectionProvider.overrideWith((ref) => null),
        councilStoreProvider.overrideWith((ref) async => store),
      ],
    ),
  );
  await _settle(tester);
}

/// 等编排器把这一轮跑完。
///
/// 判据是**运行仓库里的 run**（编排器自己的状态），不是会话记录里的 turn：
/// 页面卸载后没有视图去回写 turn 的 phase，用它当判据会永远等不到。
Future<void> _waitForTerminal(
  WidgetTester tester,
  _MemRunStore runs,
  CollabOrchestrator orchestrator, {
  int frames = 300,
}) async {
  final runId = runs.runs.keys.isEmpty ? null : runs.runs.keys.first;
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (runId == null) {
      if (runs.runs.isNotEmpty) return _waitForTerminal(tester, runs, orchestrator, frames: frames - i);
      continue;
    }
    final snap = await orchestrator.snapshot(runId);
    if (snap?.phase.isTerminal ?? false) return;
  }
  final detail = [
    for (final run in runs.runs.values)
      '${run.phase.name} seats=${run.seats.values.map((s) => s.status.name).toList()}',
  ];
  fail('运行没有在限定时间内结束：$detail');
}

void main() {
  late _MemRunStore runs;
  late _MemConversationStore conversations;

  setUp(() {
    runs = _MemRunStore();
    conversations = _MemConversationStore();
  });

  testWidgets('第一位答完时卸载整页：运行继续，回来后正文还在、不重复调用', (tester) async {
    final driver = _SlowDriver();
    final orchestrator = CollabOrchestrator(driver: driver, store: runs);
    addTearDown(orchestrator.dispose);

    await _pump(tester, orchestrator, conversations);
    await tester.enterText(find.byType(TextField), '按方案修输入栏');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('composer-send')));

    // 第一位（甲）答完、第二位（乙）刚开始。
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (driver.calls['seat0'] == 1) break;
    }
    await _settle(tester);
    final conversationId = conversations.conversations.keys.single;
    final runId = conversations.conversations.values.single.turns.single.runId;
    expect(find.textContaining('甲 的完整回答'), findsWidgets, reason: '第一位的结果已经在时间线里');
    final callsBeforeCut = Map.of(driver.calls);

    // 切走：整棵视图卸载（页面 State dispose）。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    // 没有页面在看：运行必须自己跑完。
    await _waitForTerminal(tester, runs, orchestrator);
    final finished = runs.runs[runId]!;
    expect(finished.phase, CollabPhase.done, reason: '页面卸载不能取消运行');
    expect(driver.calls['seat0'], callsBeforeCut['seat0'], reason: '已答过的席位不重复调用');
    expect(driver.calls['seat1'], 1);
    expect(driver.calls['seat2'] ?? 1, 1);

    // 回来：按原 conversationId 重新挂载同一个视图。
    await _pump(tester, orchestrator, conversations, conversationId: conversationId);
    await _settle(tester, frames: 20);

    final again = conversations.conversations.values.single;
    expect(again.id, conversationId);
    expect(again.turns.single.runId, runId, reason: 'runId 不能变');
    expect(find.textContaining('甲 的完整回答'), findsWidgets, reason: '已生成的正文必须恢复');
    expect(driver.calls['seat0'], callsBeforeCut['seat0'], reason: '重新进入不能再调一次');
    expect(conversations.conversations, hasLength(1), reason: '不能新建第二条议会');
  });

  testWidgets('运行中卸载再回来：不会重复触发同一轮', (tester) async {
    final driver = _SlowDriver();
    final orchestrator = CollabOrchestrator(driver: driver, store: runs);
    addTearDown(orchestrator.dispose);

    await _pump(tester, orchestrator, conversations);
    await tester.enterText(find.byType(TextField), '第二问');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('composer-send')));
    await _settle(tester, frames: 6);
    final conversationId = conversations.conversations.keys.single;
    final runId = conversations.conversations.values.single.turns.single.runId;

    // 还在跑的时候就切走并立刻回来（典型的「切模式又切回来」）。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await _pump(tester, orchestrator, conversations, conversationId: conversationId);
    await _waitForTerminal(tester, runs, orchestrator);

    expect(runs.runs[runId]?.phase, CollabPhase.done);
    expect(conversations.conversations.values.single.turns, hasLength(1), reason: '不能多出第二个回合');
    // 每个席位只被问过一次（没有因为重新挂载再跑一轮）。
    for (final entry in driver.calls.entries) {
      expect(entry.value, 1, reason: '${entry.key} 被调用了 ${entry.value} 次');
    }
  });
}
