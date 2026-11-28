// v4.2 · P0-B 验收：运行不依赖页面的订阅者。
//
// 页面离开只会取消它自己的 stream subscription；编排器继续驱动、继续落盘。
// 重新进入时按 runId 找回同一次运行，已完成的成员不重复调用。

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/council/collab_store.dart';
import 'package:dsh_app/team/team_models.dart';
import 'package:dsh_app/team/team_orchestrator.dart';
import 'package:dsh_app/team/team_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 慢驱动：记下每个会话被调用的次数与并发峰值。
final class _SlowDriver implements CollabSessionDriver {
  _SlowDriver({this.delay = const Duration(milliseconds: 50)});

  final Duration delay;
  final calls = <String, int>{};
  int running = 0;
  int peak = 0;
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
    running++;
    if (running > peak) peak = running;
    calls[seat] = (calls[seat] ?? 0) + 1;
    try {
      await Future<void>.delayed(delay);
      return TurnOutcome(kind: TurnKind.completed, text: '$seat 的答案');
    } finally {
      running--;
    }
  }

  @override
  Future<void> cancel(String sessionId) async {}
}

CouncilSpec _spec() => const CouncilSpec(
  question: '按方案执行',
  seats: [
    SeatSpec(id: 'a', provider: 'p', model: 'm', label: '甲'),
    SeatSpec(id: 'b', provider: 'p', model: 'm', label: '乙'),
    SeatSpec(id: 'c', provider: 'p', model: 'm', label: '丙'),
  ],
  chairId: 'a',
  budgetCalls: 12,
  seatTimeout: Duration(seconds: 5),
);

void main() {
  late Directory tmp;
  late CollabStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('keepalive');
    store = CollabStore(tmp);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('议会：订阅者退出后运行继续推进，最后仍是 done', () async {
    final driver = _SlowDriver();
    final orchestrator = CollabOrchestrator(
      driver: driver,
      store: store,
      newId: () => 'run-keep',
      retryDelay: (_, _) => Duration.zero,
    );
    addTearDown(orchestrator.dispose);

    final run = await orchestrator.submit(_spec());
    // 模拟「页面打开后又切走」：订阅一小会儿就取消。
    final sub = orchestrator.events.listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel();

    // 没有任何订阅者时，运行必须继续（最多 5 秒）。
    CollabRun? last;
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      last = await orchestrator.snapshot(run.id);
      if (last?.phase.isTerminal ?? false) break;
    }
    expect(last?.phase, CollabPhase.done, reason: '运行不应因为没人看而停住');
    expect(driver.calls.length, 3, reason: '三位席位各答一次');
    expect(driver.calls.values.every((n) => n >= 1), isTrue);
    expect(driver.peak, 1);
  });

  test('议会：重新订阅同一个 runId 不重复调用已完成席位', () async {
    final driver = _SlowDriver();
    final orchestrator = CollabOrchestrator(
      driver: driver,
      store: store,
      newId: () => 'run-again',
      retryDelay: (_, _) => Duration.zero,
    );
    addTearDown(orchestrator.dispose);

    final run = await orchestrator.submit(_spec());
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final state = await orchestrator.snapshot(run.id);
      if (state?.phase.isTerminal ?? false) break;
    }
    final before = Map.of(driver.calls);
    // 页面重新进入：再 resume 一次（视图就是这么做的）。
    await orchestrator.resume(run.id);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(driver.calls, before, reason: '已完成的运行再 resume 不应该再调模型');
  });

  test('团队：没人监听时也会把这一轮跑完', () async {
    final driver = _SlowDriver(delay: const Duration(milliseconds: 30));
    final teamStore = TeamStore(tmp);
    await teamStore.save(
      TeamState(
        id: 't1',
        title: '保活',
        teammates: const [
          Teammate(id: 'a', name: '甲', provider: 'p', model: 'm'),
          Teammate(id: 'b', name: '乙', provider: 'p', model: 'm'),
        ],
        leadId: 'a',
        createdAt: DateTime(2026, 11, 28, 14),
        updatedAt: DateTime(2026, 11, 28, 14),
        rev: 1,
      ),
    );
    final orchestrator = TeamOrchestrator(
      driver: driver,
      store: teamStore,
      turnTimeout: const Duration(seconds: 5),
      retryDelay: (_) => Duration.zero,
      pause: (_) async {},
    );
    addTearDown(orchestrator.dispose);

    final sending = orchestrator.send('t1', '依次处理');
    final sub = orchestrator.events.listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await sub.cancel();

    await sending.timeout(const Duration(seconds: 8));
    final state = await orchestrator.load('t1');
    expect(state?.messages.where((m) => m.role == TeamMsgRole.teammate).length, greaterThanOrEqualTo(1));
    expect(driver.peak, 1);
  });
}
