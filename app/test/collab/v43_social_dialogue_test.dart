// v4.3 · 15.1 / 15.2 / 15.3 的编排级验证：真正跑到提示词那一层。
//
// 纯规则在 v43_intent_routing_test.dart；这里只问四件事：
// - 团队里说「你们好」，是不是每位成员都被叫到、主管没有被拉去出任务图、
//   提示词里没有上一次交代的方案；
// - 团队里说「按前面的方案继续」，资料是不是照样带上了（别把功能修没了）；
// - 议会里说「你们好」，是不是没有主席综合、也没把旧资料塞给成员；
// - 议会里分析一个问题，主席综合照旧。

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/council/collab_store.dart';
import 'package:dsh_app/team/team_models.dart';
import 'package:dsh_app/team/team_orchestrator.dart';
import 'package:dsh_app/team/team_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _material = '【此前的对话资料】\n[#m1] 修复 UI 层遮挡：协作时间线最后三行被输入栏盖住';

final class _Fake implements CollabSessionDriver {
  final bySeat = <String, List<String>>{};
  final _seatOf = <String, String>{};
  int _seq = 0;

  List<String> get all => [for (final list in bySeat.values) ...list];

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
    final seat = _seatOf[sessionId] ?? '';
    bySeat.putIfAbsent(seat, () => []).add(text);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    return TurnOutcome(kind: TurnKind.completed, text: '$seat：好的');
  }

  @override
  Future<void> cancel(String sessionId) async {}
}

Teammate _mate(String id, String name) => Teammate(id: id, name: name, provider: 'p', model: 'm-$id');

SeatSpec _seat(String id) => SeatSpec(id: id, provider: 'p', model: 'm-$id', label: id);

/// 等到终态（不依赖事件流，社交轮可能在订阅前就跑完了）。
Future<CollabRun> _settle(CollabOrchestrator o, String runId) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  CollabRun? last = o.peek(runId);
  while (DateTime.now().isBefore(deadline)) {
    last = o.peek(runId) ?? await o.snapshot(runId);
    if (last != null && last.phase.isTerminal) return last;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return last ?? (await o.snapshot(runId))!;
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('v43_social'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('团队 · 你们好', () {
    test('全体依次回应，不进任务规划，不带旧资料', () async {
      final driver = _Fake();
      final orchestrator = TeamOrchestrator(driver: driver, store: TeamStore(tmp));
      final team = await orchestrator.create(
        teammates: [_mate('m1', '甲'), _mate('m2', '乙'), _mate('m3', '丙')],
        leadId: 'm1',
      );

      await orchestrator.send(team.id, '你们好', context: _material);

      expect(driver.bySeat.keys.toSet(), {'m1', 'm2', 'm3'}, reason: '问候要每位成员都自然回应一句');
      expect(driver.bySeat['m1']!.length, 1, reason: '主管只答一次，没有被额外拉去出任务图');
      expect(driver.all.any((p) => p.contains('你是团队的主管')), isFalse, reason: '问候不能进 _planPrompt');
      expect(driver.all.any((p) => p.contains('修复 UI 层遮挡')), isFalse, reason: '问候不该带着上一次的方案');
      expect(driver.bySeat['m2']!.single, contains('打招呼'), reason: '成员要知道这是寒暄，别写报告');

      await orchestrator.dispose();
    });

    test('明确指代时资料照旧带上（别把功能修没了）', () async {
      final driver = _Fake();
      final orchestrator = TeamOrchestrator(driver: driver, store: TeamStore(tmp));
      final team = await orchestrator.create(teammates: [_mate('m1', '甲'), _mate('m2', '乙')], leadId: 'm1');

      await orchestrator.send(team.id, '按前面的要求继续改', context: _material);

      expect(driver.all.any((p) => p.contains('修复 UI 层遮挡')), isTrue);

      await orchestrator.dispose();
    });

    test('执行类仍然交给主管规划，指代的资料照样带上', () async {
      final driver = _Fake();
      final orchestrator = TeamOrchestrator(driver: driver, store: TeamStore(tmp));
      final team = await orchestrator.create(teammates: [_mate('m1', '甲'), _mate('m2', '乙')], leadId: 'm1');

      await orchestrator.send(team.id, '按前面的要求修复这个仓库的 UI 遮挡问题', context: _material);

      expect(driver.bySeat['m1']!.first, contains('你是团队的主管'));
      expect(driver.bySeat['m1']!.first, contains('修复 UI 层遮挡'), reason: '执行类要带着用户交代的资料');

      await orchestrator.dispose();
    });

    test('执行类但没有指代：不带旧资料（上下文策略优先）', () async {
      final driver = _Fake();
      final orchestrator = TeamOrchestrator(driver: driver, store: TeamStore(tmp));
      final team = await orchestrator.create(teammates: [_mate('m1', '甲'), _mate('m2', '乙')], leadId: 'm1');

      await orchestrator.send(team.id, '帮我修复这个仓库的 UI 遮挡问题', context: _material);

      expect(driver.bySeat['m1']!.first, contains('你是团队的主管'));
      expect(driver.all.any((p) => p.contains('修复 UI 层遮挡')), isFalse, reason: '没有指代就不注入父会话资料');

      await orchestrator.dispose();
    });
  });

  group('议会 · 你们好', () {
    test('不进主席综合，也不把旧资料塞给成员', () async {
      final driver = _Fake();
      final orchestrator = CollabOrchestrator(
        driver: driver,
        store: CollabStore(tmp),
        newId: () => 'r1',
        retryDelay: (_, _) => Duration.zero,
      );
      await orchestrator.submit(
        CouncilSpec(
          question: '你们好',
          seats: [_seat('a'), _seat('b'), _seat('c')],
          context: _material,
          sourceMessageIds: const ['m1'],
        ),
      );

      final run = await _settle(orchestrator, 'r1');
      expect(run.phase, CollabPhase.done);
      expect(run.callsUsed, 3, reason: '三位成员各一次；社交轮没有主席综合这一次');
      expect(run.verdict, isNull, reason: '社交轮不该产出结论/共识/分歧');
      expect(driver.all.any((p) => p.contains('修复 UI 层遮挡')), isFalse);
      expect(driver.all.any((p) => p.contains('200 到 400') || p.contains('200–400')), isFalse, reason: '不要求 200–400 字');

      await orchestrator.dispose();
    });

    test('分析类照常综合并带资料', () async {
      final driver = _Fake();
      final orchestrator = CollabOrchestrator(
        driver: driver,
        store: CollabStore(tmp),
        newId: () => 'r2',
        retryDelay: (_, _) => Duration.zero,
      );
      await orchestrator.submit(
        CouncilSpec(
          question: '按前面那份方案分析风险',
          seats: [_seat('a'), _seat('b')],
          context: _material,
          sourceMessageIds: const ['m1'],
        ),
      );

      final run = await _settle(orchestrator, 'r2');
      expect(run.phase, CollabPhase.done);
      expect(run.callsUsed, 3, reason: '两席 + 主席综合');
      expect(run.verdict, isNotNull);
      expect(driver.all.any((p) => p.contains('修复 UI 层遮挡')), isTrue);

      await orchestrator.dispose();
    });
  });
}
