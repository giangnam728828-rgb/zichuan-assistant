// S8 任务图的单元测试：计划解析、依赖校验、调度顺序、审核与汇总。
//
// 用 Fake 驱动按提示词返回不同的脚本，不经过网络。

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/team/team_models.dart';
import 'package:dsh_app/team/team_orchestrator.dart';
import 'package:dsh_app/team/team_store.dart';
import 'package:dsh_app/team/team_tasks.dart';
import 'package:flutter_test/flutter_test.dart';

final class PlanDriver implements CollabSessionDriver {
  PlanDriver({this.plan = defaultPlan});

  static const defaultPlan = '''
```json
{"tasks":[
  {"id":"t1","title":"调研","owner":"研究员","deps":[],"input":"查清楚现状"},
  {"id":"t2","title":"写作","owner":"写手","deps":["t1"],"input":"把结论写成一页"}
]}
```
''';

  String plan;
  final prompts = <String>[];
  var _sessions = 0;

  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async => 's${_sessions++}';

  @override
  Future<TurnOutcome> runTurn(
    String sessionId,
    String text, {
    Duration? timeout,
    List<CollabAttachment> attachments = const [],
  }) async {
    prompts.add(text);
    if (text.contains('把用户这件事拆成任务图')) {
      return TurnOutcome(kind: TurnKind.completed, text: plan);
    }
    if (text.contains('审核队友交回的结果')) {
      return const TurnOutcome(
        kind: TurnKind.completed,
        text: '```json\n{"reviews":[{"taskId":"t1","verdict":"pass","note":"可以"},{"taskId":"t2","verdict":"pass","note":"可以"}]}\n```',
      );
    }
    if (text.contains('汇总成一条给用户的完整答复')) {
      return const TurnOutcome(kind: TurnKind.completed, text: '这是最终汇总。');
    }
    if (text.contains('「调研」')) {
      return const TurnOutcome(kind: TurnKind.completed, text: '调研结果：现状有三点。');
    }
    if (text.contains('「写作」')) {
      return const TurnOutcome(kind: TurnKind.completed, text: '写作结果：一页稿子。');
    }
    return const TurnOutcome(kind: TurnKind.completed, text: '答案');
  }

  @override
  Future<void> cancel(String sessionId) async {}
}

Teammate _mate(String id, String name, {String brief = ''}) =>
    Teammate(id: id, name: name, brief: brief, provider: 'prov', model: 'mod-$id');

void main() {
  group('计划解析', () {
    test('解析 tasks 数组，带代码块围栏', () {
      final plan = parseTeamPlan(PlanDriver.defaultPlan);
      expect(plan, isNotNull);
      expect(plan!.tasks, hasLength(2));
      expect(plan.tasks.first.title, '调研');
      expect(plan.tasks.last.deps, ['t1']);
      expect(plan.summary, isEmpty);
    });

    test('解析 actions 形式（兼容方案里的主管协议）', () {
      final plan = parseTeamPlan('{"actions":[{"type":"assign","task":"查资料","owner":"研究员","deps":[]}],"summary":""}');
      expect(plan, isNotNull);
      expect(plan!.tasks.single.title, '查资料');
      expect(plan.tasks.single.owner, '研究员');
    });

    test('普通回答不当计划', () {
      expect(parseTeamPlan('我觉得这件事可以这样做……'), isNull);
      expect(parseTeamPlan(''), isNull);
    });

    test('空任务 + summary 是「不用拆分」', () {
      final plan = parseTeamPlan('{"tasks":[],"summary":"直接答案"}');
      expect(plan, isNotNull);
      expect(plan!.tasks, isEmpty);
      expect(plan.summary, '直接答案');
    });
  });

  group('计划校验', () {
    final idOfName = {'研究员': 'r1', '写手': 'w1'};

    test('负责人必须存在', () {
      final bound = bindPlan(
        const TeamPlan(
          tasks: [PlannedTask(id: 't1', title: '调研', owner: '不存在的人')],
        ),
        idOfName: idOfName,
      );
      expect(bound.tasks, isNull);
      expect(bound.problem, contains('不在团队里'));
    });

    test('依赖必须存在', () {
      final bound = bindPlan(
        const TeamPlan(
          tasks: [
            PlannedTask(id: 't1', title: '调研', owner: '研究员', deps: ['t9']),
          ],
        ),
        idOfName: idOfName,
      );
      expect(bound.tasks, isNull);
      expect(bound.problem, contains('不存在'));
    });

    test('依赖成环会被拒绝', () {
      final bound = bindPlan(
        const TeamPlan(
          tasks: [
            PlannedTask(id: 't1', title: 'A', owner: '研究员', deps: ['t2']),
            PlannedTask(id: 't2', title: 'B', owner: '写手', deps: ['t1']),
          ],
        ),
        idOfName: idOfName,
      );
      expect(bound.tasks, isNull);
      expect(bound.problem, contains('成环'));
    });

    test('正常图绑定到队友 id', () {
      final bound = bindPlan(
        const TeamPlan(
          tasks: [
            PlannedTask(id: 't1', title: 'A', owner: '研究员'),
            PlannedTask(id: 't2', title: 'B', owner: '写手', deps: ['t1']),
          ],
        ),
        idOfName: idOfName,
      );
      expect(bound.problem, isNull);
      expect(bound.tasks!.first.ownerId, 'r1');
      expect(bound.tasks!.last.deps, ['t1']);
    });
  });

  group('调度', () {
    TeamTask task(String id, TeamTaskStatus status, {List<String> deps = const []}) =>
        TeamTask(id: id, title: id, ownerId: 'r1', status: status, deps: deps);

    test('只放行依赖已完成的任务', () {
      final ready = readyTasks([
        task('t1', TeamTaskStatus.done),
        task('t2', TeamTaskStatus.pending, deps: ['t1']),
        task('t3', TeamTaskStatus.pending, deps: ['t2']),
      ]);
      expect(ready.map((t) => t.id), ['t2']);
    });

    test('依赖未满足标 blocked，上游完成后转 ready', () {
      final blocked = settleBlocked([
        task('t1', TeamTaskStatus.running),
        task('t2', TeamTaskStatus.pending, deps: ['t1']),
      ]);
      expect(blocked.last.status, TeamTaskStatus.blocked);

      final freed = settleBlocked([
        task('t1', TeamTaskStatus.done),
        task('t2', TeamTaskStatus.blocked, deps: ['t1']),
      ]);
      expect(freed.last.status, TeamTaskStatus.ready);
    });

    test('上游失败时下游标记失败', () {
      final settled = settleBlocked([
        task('t1', TeamTaskStatus.failed),
        task('t2', TeamTaskStatus.blocked, deps: ['t1']),
      ]);
      expect(settled.last.status, TeamTaskStatus.failed);
    });
  });

  group('状态往返', () {
    test('TeamRun 与 TeamState 一起落盘再读回来', () {
      final now = DateTime(2026, 11, 27, 12);
      final run = TeamRun(
        id: 'run1',
        sessionId: 'team1',
        status: TeamRunStatus.reviewing,
        supervisorId: 'lead',
        goal: '做调研',
        tasks: const [
          TeamTask(id: 't1', title: '调研', ownerId: 'r1', status: TeamTaskStatus.done, result: '结果', attempts: 1),
        ],
        createdAt: now,
        updatedAt: now,
      );
      final state = TeamState(
        id: 'team1',
        teammates: [_mate('lead', '主管'), _mate('r1', '研究员')],
        leadId: 'lead',
        run: run,
        createdAt: now,
        updatedAt: now,
      );
      final back = TeamState.fromJson(state.toJson());
      expect(back.run, isNotNull);
      expect(back.run!.status, TeamRunStatus.reviewing);
      expect(back.run!.tasks.single.result, '结果');
      expect(back.run!.goal, '做调研');
    });
  });

  group('编排', () {
    late Directory dir;
    late TeamStore store;
    late PlanDriver driver;
    late TeamOrchestrator orch;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('team_run');
      store = TeamStore(dir);
      driver = PlanDriver();
      orch = TeamOrchestrator(driver: driver, store: store);
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Future<TeamState> team() =>
        orch.create(teammates: [_mate('lead', '主管'), _mate('r1', '研究员'), _mate('w1', '写手')], leadId: 'lead');

    test('主管出图 → 依赖顺序执行 → 审核 → 汇总', () async {
      final created = await team();
      await orch.send(created.id, '调研并写一页');
      final state = await orch.load(created.id);

      expect(state!.run, isNotNull);
      expect(state.run!.status, TeamRunStatus.done);
      expect(state.run!.tasks, hasLength(2));
      expect(state.run!.tasks.every((t) => t.status == TeamTaskStatus.done), isTrue);
      expect(state.run!.summary, contains('最终汇总'));

      // 写手的提示词里带上了上游「调研」的结果。
      final writePrompt = driver.prompts.firstWhere((p) => p.contains('「写作」'));
      expect(writePrompt, contains('调研结果：现状有三点。'));

      // 汇总作为主管的一条消息落在群里。
      expect(state.messages.where((m) => m.teammateId == 'lead').last.text, contains('最终汇总'));
    });

    test('主管不拆分时直接给答案，不建任务', () async {
      driver.plan = '{"tasks":[],"summary":"这个问题不用分工，直接答。"}';
      final created = await team();
      await orch.send(created.id, '今天几号');
      final state = await orch.load(created.id);

      expect(state!.run, isNotNull);
      expect(state.run!.tasks, isEmpty);
      expect(state.run!.status, TeamRunStatus.done);
      expect(state.messages.last.text, contains('不用分工'));
    });

    test('计划不合法时退回群聊分派，并留一句说明', () async {
      driver.plan = '{"tasks":[{"id":"t1","title":"调研","owner":"查无此人","deps":[]}]}';
      final created = await team();
      await orch.send(created.id, '调研一下');
      final state = await orch.load(created.id);

      expect(state!.run, isNull);
      expect(state.messages.any((m) => m.text.contains('改按群聊分派')), isTrue);
    });

    test('取消后任务图标记取消，不再继续跑', () async {
      final created = await team();
      final sending = orch.send(created.id, '调研并写一页');
      await orch.cancel(created.id);
      await sending;
      final state = await orch.load(created.id);

      if (state!.run case final run?) {
        expect(run.status, TeamRunStatus.cancelled);
        expect(run.tasks.any((t) => t.status == TeamTaskStatus.cancelled), isTrue);
      }
    });

    test('中断后继续：已完成的任务不重跑', () async {
      final created = await team();
      await orch.send(created.id, '调研并写一页');
      final done = await orch.load(created.id);

      // 模拟进程重启：把 run 改回执行中、第一个任务已完成、第二个还挂着。
      var run = done!.run!;
      run = run.copyWith(
        status: TeamRunStatus.running,
        tasks: [
          run.tasks.first,
          run.tasks.last.copyWith(status: TeamTaskStatus.running),
        ],
      );
      await store.save(done.copyWith(run: run, running: const []));

      // 模拟进程重启：内存快照清空，只能从盘上读。
      orch = TeamOrchestrator(driver: driver, store: store);
      final before = driver.prompts.length;
      await orch.resumeRun(created.id);
      // resumeRun 把执行放到后台，返回的是「已经重新开跑」那一刻的快照；
      // 轮询到终态为止，别拿固定睡眠去赌这台机器多快。
      TeamState? resumed;
      for (var i = 0; i < 300; i++) {
        resumed = await orch.load(created.id);
        if (resumed?.run?.isTerminal ?? false) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(resumed!.run!.status, TeamRunStatus.done);
      final newPrompts = driver.prompts.sublist(before);
      expect(newPrompts.any((p) => p.contains('你负责的任务「调研」')), isFalse, reason: '已完成的任务不该重跑');
      expect(newPrompts.any((p) => p.contains('你负责的任务「写作」')), isTrue);
    });
  });
}
