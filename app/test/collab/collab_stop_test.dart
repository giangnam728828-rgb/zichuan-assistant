// 停止键真的停（方案第六部分「运行中行为」）。
//
// 输入栏运行中是停止键，不是发送键；按下必须真的取消当前任务，而不是假装
// 停了、让席位继续在后面烧钱。这里用假驱动记下 cancel 调用，跑一遍两端：
// 议会取消 run、团队取消 running。

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_store.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/team/team_models.dart';
import 'package:dsh_app/team/team_orchestrator.dart';
import 'package:dsh_app/team/team_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 议会侧：慢驱动，让 run 停在中间；取消时记一笔。
final class _SlowCouncilDriver implements CollabSessionDriver {
  final cancelled = <String>{};
  final calls = <String>[];
  final _pending = <String, Completer<void>>{};

  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async => 's-${seat.id}';

  @override
  Future<TurnOutcome> runTurn(
    String sessionId,
    String text, {
    Duration? timeout,
    List<CollabAttachment> attachments = const [],
  }) async {
    calls.add(sessionId);
    // 真实驱动被 cancel 时会掐断流并回 aborted；这里用 Completer 复现同一语义：
    // 不靠超时兜底，否则测到的是「等超时」而不是「停止」。
    final gate = Completer<void>();
    _pending[sessionId] = gate;
    await gate.future;
    return const TurnOutcome(kind: TurnKind.aborted);
  }

  @override
  Future<void> cancel(String sessionId) async {
    cancelled.add(sessionId);
    _pending.remove(sessionId)?.complete();
  }
}

/// 团队侧：同样慢，记下被取消的队友会话。
final class _SlowTeamDriver implements CollabSessionDriver {
  final cancelled = <String>{};
  final _pending = <String, Completer<void>>{};

  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async => 's-${seat.id}';

  @override
  Future<TurnOutcome> runTurn(
    String sessionId,
    String text, {
    Duration? timeout,
    List<CollabAttachment> attachments = const [],
  }) async {
    final gate = Completer<void>();
    _pending[sessionId] = gate;
    await gate.future;
    return const TurnOutcome(kind: TurnKind.aborted);
  }

  @override
  Future<void> cancel(String sessionId) async {
    cancelled.add(sessionId);
    _pending.remove(sessionId)?.complete();
  }
}

/// 议会：一席一个问题，够复现「跑着的时候按停止」。
CouncilSpec _councilSpec() => CouncilSpec(
  question: '把输入栏挡住的内容修掉',
  seats: const [
    SeatSpec(id: 'seat0', provider: 'p', model: 'm', label: '甲'),
    SeatSpec(id: 'seat1', provider: 'p', model: 'm', label: '乙'),
  ],
  chairId: 'seat0',
  seatTimeout: const Duration(seconds: 20),
  budgetCalls: 8,
);

TeamState _team() => TeamState(
  id: 't1',
  title: '输入栏',
  teammates: const [
    Teammate(id: 'm1', name: '队友甲', provider: 'p', model: 'm'),
    Teammate(id: 'm2', name: '队友乙', provider: 'p', model: 'm'),
  ],
  leadId: 'm1',
  createdAt: DateTime(2026, 11, 28, 8),
  updatedAt: DateTime(2026, 11, 28, 8),
  rev: 1,
);

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('collab-stop');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('议会：停止把这一轮的席位取消掉，run 收成 cancelled', () async {
    final driver = _SlowCouncilDriver();
    final orchestrator = CollabOrchestrator(
      driver: driver,
      store: CollabStore(tmp),
      newId: () => 'run-stop',
      retryDelay: (_, _) => Duration.zero,
    );
    addTearDown(orchestrator.dispose);

    final run = await orchestrator.submit(_councilSpec());
    // 等它真的开跑（有一个席位在飞）。轮询而不是死等 80ms：CI 上磁盘
    // 落盘慢一点就会偶发「还没开始」，那是测试脆弱，不是停止失效。
    for (var i = 0; i < 80 && driver.calls.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(driver.calls, isNotEmpty, reason: '先确认真的在跑，否则「停止」测不到东西');

    await orchestrator.cancel(run.id);

    var last = await orchestrator.snapshot(run.id);
    for (var i = 0; i < 40 && last?.phase != CollabPhase.cancelled; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      last = await orchestrator.snapshot(run.id);
    }
    expect(last?.phase, CollabPhase.cancelled);
    expect(driver.cancelled, isNotEmpty, reason: '交给驱动的 cancel 必须真的调用');
  });

  test('团队：停止会取消正在跑的队友会话', () async {
    final driver = _SlowTeamDriver();
    final store = TeamStore(tmp);
    await store.save(_team());
    final orchestrator = TeamOrchestrator(
      driver: driver,
      store: store,
      turnTimeout: const Duration(seconds: 20),
      retryDelay: (_) => Duration.zero,
      pause: (_) async {},
    );
    addTearDown(orchestrator.dispose);

    // 不 await：send 会一直等人答完。
    final sending = orchestrator.send('t1', '把挡住的内容修掉');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await orchestrator.cancel('t1');
    // cancel 之后这一轮会自己收尾（驱动回 aborted），不需要等超时。
    await sending.timeout(const Duration(seconds: 5), onTimeout: () => _team());

    expect(driver.cancelled, isNotEmpty, reason: '停止要落到驱动层');
  });
}
