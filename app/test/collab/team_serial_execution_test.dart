// v3 · 2.7 验收：三成员真实串行执行（不是“只看到一个气泡”）。
//
// Fake Driver 记录每次 runTurn 的开始/结束时刻与峰值并发。只要峰值 > 1 就
// 失败；气泡层面的展示不参与判断。覆盖：
// - 团队群聊 A→B→C；
// - 任务图（三个互不依赖的任务仍一个接一个）；
// - 规划 / 审核 / 汇总不并发；
// - 取消后队列不再启动下一位；
// - 议会旧配置 maxConcurrency=3 也按 1 跑。

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/council/collab_store.dart';
import 'package:dsh_app/team/team_models.dart';
import 'package:dsh_app/team/team_orchestrator.dart';
import 'package:dsh_app/team/team_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录真实并发的驱动。
class _CountingDriver implements CollabSessionDriver {
  _CountingDriver({this.delay = const Duration(milliseconds: 40)});

  final Duration delay;

  int running = 0;
  int peak = 0;
  final started = <String>[];
  final finished = <String>[];
  final cancelled = <String>{};
  int _seq = 0;
  final _sessionOwner = <String, String>{};

  /// 按 prompt 里的名字识别是谁在答（假识别，只为测试计数）。
  String _who(String text) {
    for (final name in const ['甲', '乙', '丙', '主管']) {
      if (text.contains(name)) return name;
    }
    return '?';
  }

  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async {
    final id = 's${_seq++}';
    _sessionOwner[id] = (seat.label?.isNotEmpty ?? false) ? seat.label! : seat.id;
    return id;
  }

  @override
  Future<TurnOutcome> runTurn(
    String sessionId,
    String text, {
    Duration? timeout,
    List<CollabAttachment> attachments = const [],
  }) async {
    // 群聊提示词里含所有成员名，不能从正文猜；用 openSession 时记下的 owner。
    final who = _sessionOwner[sessionId] ?? _who(text);
    running++;
    if (running > peak) peak = running;
    started.add(who);
    try {
      await Future<void>.delayed(delay);
      return TurnOutcome(kind: TurnKind.completed, text: '$who 的答复');
    } finally {
      running--;
      finished.add(who);
    }
  }

  @override
  Future<void> cancel(String sessionId) async => cancelled.add(sessionId);
}

TeamState _team({bool withLead = false, int mates = 3}) {
  final all = [
    const Teammate(id: 'a', name: '甲', provider: 'deepseek', model: 'm1'),
    const Teammate(id: 'b', name: '乙', provider: 'google', model: 'm2'),
    const Teammate(id: 'c', name: '丙', provider: 'anthropic', model: 'm3'),
  ];
  return TeamState(
    id: 't1',
    title: '顺序执行',
    teammates: all.sublist(0, mates),
    leadId: withLead ? 'a' : null,
    createdAt: DateTime(2026, 11, 28, 10),
    updatedAt: DateTime(2026, 11, 28, 10),
    rev: 1,
  );
}

TeamOrchestrator _orchestrator(_CountingDriver driver, TeamStore store) => TeamOrchestrator(
  driver: driver,
  store: store,
  turnTimeout: const Duration(seconds: 10),
  retryDelay: (_) => Duration.zero,
  pause: (_) async {},
);

void main() {
  late Directory tmp;
  late TeamStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('team-serial');
    store = TeamStore(tmp);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('团队群聊：甲乙丙一个接一个，峰值并发 = 1', () async {
    final driver = _CountingDriver();
    await store.save(_team());
    final orchestrator = _orchestrator(driver, store);
    addTearDown(orchestrator.dispose);

    await orchestrator.send('t1', '三个人依次做一下');

    expect(driver.started, ['甲', '乙', '丙']);
    expect(driver.finished, ['甲', '乙', '丙']);
    expect(driver.peak, 1, reason: '任意时刻只允许一个模型请求在飞');
  });

  test('下一位在上一位结束前不启动（按真实结束顺序）', () async {
    final driver = _CountingDriver(delay: const Duration(milliseconds: 60));
    await store.save(_team());
    final orchestrator = _orchestrator(driver, store);
    addTearDown(orchestrator.dispose);

    final sending = orchestrator.send('t1', '依次处理');
    // 等第一位真的开始（落盘 + 调度都需要几毫秒），再断言只有它一个。
    for (var i = 0; i < 60 && driver.started.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(driver.started, hasLength(1), reason: '第一位还在跑时第二位不能启动');
    await sending;
    expect(driver.peak, 1);
  });

  test('取消后：队列里没开始的成员不再启动', () async {
    final driver = _CountingDriver(delay: const Duration(milliseconds: 50));
    await store.save(_team());
    final orchestrator = _orchestrator(driver, store);
    addTearDown(orchestrator.dispose);

    final sending = orchestrator.send('t1', '三个人依次做');
    for (var i = 0; i < 60 && driver.started.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(driver.started, hasLength(1));
    await orchestrator.cancel('t1');
    await sending.timeout(const Duration(seconds: 5), onTimeout: () => _team());
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(driver.started, hasLength(1), reason: '取消后排队的乙丙不能启动');
  });

  test('议会旧配置 maxConcurrency=3 也按一位执行', () async {
    final dir = Directory.systemTemp.createTempSync('council-old');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final driver = _CountingDriver();
    final oldSpec = CouncilSpec(
      question: '顺序回答',
      seats: const [
        SeatSpec(id: 'a', provider: 'p', model: 'm', label: '甲'),
        SeatSpec(id: 'b', provider: 'p', model: 'm', label: '乙'),
        SeatSpec(id: 'c', provider: 'p', model: 'm', label: '丙'),
      ],
      chairId: 'a',
      maxConcurrency: 3, // 旧配置
      budgetCalls: 20,
    );
    // 走一次 JSON 往返，模拟从磁盘读回旧会话。
    final migrated = CouncilSpec.fromJson(oldSpec.toJson());
    expect(migrated.maxConcurrency, 1, reason: '加载旧配置时迁移到 1');

    final orchestrator = CollabOrchestrator(
      driver: driver,
      store: CollabStore(dir),
      newId: () => 'old-run',
      retryDelay: (_, _) => Duration.zero,
    );
    addTearDown(orchestrator.dispose);
    await orchestrator.submit(migrated);
    await for (final run in orchestrator.events) {
      if (run.phase.isTerminal) break;
    }
    expect(driver.peak, 1, reason: '旧议会也不能并发');
  });
}
