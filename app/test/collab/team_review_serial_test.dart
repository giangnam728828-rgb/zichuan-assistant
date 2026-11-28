// v3 · 2.4/2.7：规划、执行、审核、返工、汇总都走同一条单飞通道。
//
// 这里用一个会「看提示词回不同东西」的假驱动，跑完整条任务图链路：
// 规划 → 任务 A → 任务 B → 审核（第一次要求返工）→ 重做 → 再审核 → 汇总。
// 断言：任意时刻只有一个请求在飞；顺序固定；返工不会并发；汇总在审核之后。

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/team/team_models.dart';
import 'package:dsh_app/team/team_orchestrator.dart';
import 'package:dsh_app/team/team_store.dart';
import 'package:dsh_app/team/team_tasks.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ScriptedDriver implements CollabSessionDriver {
  _ScriptedDriver();

  int running = 0;
  int peak = 0;
  final started = <String>[]; // 阶段名
  int _seq = 0;
  final _owner = <String, String>{};
  int reviewRounds = 0;

  String _phaseOf(String text) {
    if (text.contains('拆成任务图')) return '规划';
    if (text.contains('审核队友交回的结果')) return '审核';
    if (text.contains('汇总成一条给用户的完整答复')) return '汇总';
    return '执行';
  }

  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async {
    final id = 's${_seq++}';
    _owner[id] = (seat.label?.isNotEmpty ?? false) ? seat.label! : seat.id;
    return id;
  }

  @override
  Future<TurnOutcome> runTurn(
    String sessionId,
    String text, {
    Duration? timeout,
    List<CollabAttachment> attachments = const [],
  }) async {
    final phase = _phaseOf(text);
    running++;
    if (running > peak) peak = running;
    started.add(phase);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      switch (phase) {
        case '规划':
          return const TurnOutcome(
            kind: TurnKind.completed,
            text: '{"tasks":['
                '{"id":"t1","title":"改布局","owner":"乙","deps":[],"input":"改输入栏"},'
                '{"id":"t2","title":"补测试","owner":"丙","deps":["t1"],"input":"补一组测试"}'
                '],"summary":""}',
          );
        case '审核':
          reviewRounds++;
          // 第一次审核要求把 t1 重做；第二次全部通过。
          if (reviewRounds == 1) {
            return const TurnOutcome(
              kind: TurnKind.completed,
              text: '{"reviews":[{"taskId":"t1","verdict":"revise","note":"没改完"},'
                  '{"taskId":"t2","verdict":"pass","note":"可以"}]}',
            );
          }
          return const TurnOutcome(
            kind: TurnKind.completed,
            text: '{"reviews":[{"taskId":"t1","verdict":"pass","note":"这次可以"},'
                '{"taskId":"t2","verdict":"pass","note":"可以"}]}',
          );
        case '汇总':
          return const TurnOutcome(kind: TurnKind.completed, text: '全部完成，输入栏不再遮挡。');
        default:
          return TurnOutcome(kind: TurnKind.completed, text: '${_owner[sessionId] ?? '队友'} 做完了');
      }
    } finally {
      running--;
    }
  }

  @override
  Future<void> cancel(String sessionId) async {}
}

TeamState _team() => TeamState(
  id: 't1',
  title: '任务图串行',
  teammates: const [
    Teammate(id: 'lead', name: '主管', provider: 'p', model: 'm'),
    Teammate(id: 'b', name: '乙', provider: 'p', model: 'm'),
    Teammate(id: 'c', name: '丙', provider: 'p', model: 'm'),
  ],
  leadId: 'lead',
  createdAt: DateTime(2026, 11, 28, 12),
  updatedAt: DateTime(2026, 11, 28, 12),
  rev: 1,
);

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('team-review-serial');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('规划→执行→审核→返工→再审核→汇总：全程峰值并发 = 1', () async {
    final driver = _ScriptedDriver();
    final store = TeamStore(tmp);
    await store.save(_team());
    final orchestrator = TeamOrchestrator(
      driver: driver,
      store: store,
      turnTimeout: const Duration(seconds: 10),
      retryDelay: (_) => Duration.zero,
      pause: (_) async {},
    );
    addTearDown(orchestrator.dispose);

    await orchestrator.send('t1', '把输入栏修好并补测试');

    expect(driver.peak, 1, reason: '任意时刻只能有一个模型请求');
    // 顺序：规划 → t1 → t2 → 审核(revise) → t1 重做 → 审核(pass) → 汇总
    expect(driver.started.first, '规划');
    expect(driver.started.where((p) => p == '审核').length, 2, reason: '返工后要再审一次');
    expect(driver.started.last, '汇总', reason: '汇总必须在审核之后');
    expect(driver.started.where((p) => p == '汇总').length, 1);

    final state = await orchestrator.load('t1');
    expect(state?.run?.status, TeamRunStatus.done);
    expect(state?.run?.summary, contains('输入栏'));
  });

  test('审核与汇总不会互相重叠', () async {
    final driver = _ScriptedDriver();
    final store = TeamStore(tmp);
    await store.save(_team());
    final orchestrator = TeamOrchestrator(
      driver: driver,
      store: store,
      turnTimeout: const Duration(seconds: 10),
      retryDelay: (_) => Duration.zero,
      pause: (_) async {},
    );
    addTearDown(orchestrator.dispose);

    await orchestrator.send('t1', '把输入栏修好');
    // 找到审核与汇总在 started 里的位置，确认它们是相邻且互不包裹。
    final reviewIndex = driver.started.indexOf('审核');
    final summaryIndex = driver.started.lastIndexOf('汇总');
    expect(reviewIndex, greaterThan(-1));
    expect(summaryIndex, greaterThan(reviewIndex));
    expect(driver.peak, 1);
  });
}
