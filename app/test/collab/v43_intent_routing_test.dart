// v4.3 · 15.1 / 15.2 / 15.3：问候不带旧上下文、团队请求分流、议会请求类型。
//
// 三个现场故障：
// 1. 普通聊天里交代过一整份方案，切到议会/团队说「你们好」，成员却拿着那份
//    方案和仓库地址作答；
// 2. 团队里说「你们好」，因为有主管，消息先被送进任务规划，主管回一段
//    「没有具体任务」或接着上次的工程任务往下写；
// 3. 议会里说「你们好」，成员被要求写 200–400 字裁决，主席还要综合。
//
// 这里只测规则本身（意图 ⇒ 要不要历史 / 谁答 / 要不要综合），不经过网络。

import 'package:dsh_app/collab/collab_context_pack.dart';
import 'package:dsh_app/collab/collab_intent.dart';
import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/council/council_request.dart';
import 'package:dsh_app/team/team_models.dart';
import 'package:dsh_app/team/team_request.dart';
import 'package:flutter_test/flutter_test.dart';

CollabContextMessage _msg(String id, String text, {CollabContextRole role = CollabContextRole.user}) =>
    CollabContextMessage(id: id, text: text, role: role);

String _long(String seed, int chars) {
  final buffer = StringBuffer(seed);
  while (buffer.length < chars) {
    buffer.write('。${seed}要求第 ${buffer.length} 字');
  }
  return buffer.toString();
}

Teammate _mate(String id, String name) => Teammate(id: id, name: name, provider: 'p', model: 'm-$id');

SeatSpec _seat(String id) => SeatSpec(id: id, provider: 'p', model: 'm-$id', label: id);

void main() {
  group('15.1 问候不带旧上下文', () {
    test('只有明确指代此前内容才允许带历史', () {
      // 问候、道谢、确认：一律不带。
      expect(CollabContextPolicy.allowsHistory('你们好'), isFalse);
      expect(CollabContextPolicy.allowsHistory('你们好呀'), isFalse);
      expect(CollabContextPolicy.allowsHistory('谢谢，辛苦了'), isFalse);
      expect(CollabContextPolicy.allowsHistory('在吗？'), isFalse);
      expect(CollabContextPolicy.allowsHistory('好的，收到'), isFalse);
      // 独立提问/讨论：没有指代，同样不带。
      expect(CollabContextPolicy.allowsHistory('这个方案怎么样'), isFalse);
      expect(CollabContextPolicy.allowsHistory('你们各自擅长什么'), isFalse);
      // 明确指代：带。
      expect(CollabContextPolicy.allowsHistory('按前面那一大段方案执行'), isTrue);
      expect(CollabContextPolicy.allowsHistory('继续上一轮的任务'), isTrue);
      expect(CollabContextPolicy.allowsHistory('用刚才那个仓库'), isTrue);
      expect(CollabContextPolicy.allowsHistory('消息 #3 里那份要求照做'), isTrue);
      expect(CollabContextPolicy.allowsHistory('照旧'), isTrue);
    });

    test('gate 只在允许时放行资料，空资料保持空', () {
      const material = '【此前的对话资料】\n[#m1] 修复 UI 层遮挡';
      expect(CollabContextPolicy.gate('你们好', material), isEmpty);
      expect(CollabContextPolicy.gate('按前面的要求修复', material), material);
      expect(CollabContextPolicy.gate('按前面的要求修复', '   '), isEmpty);
    });

    test('explain 说清为什么带/不带', () {
      expect(CollabContextPolicy.explain('你们好'), contains('问候'));
      expect(CollabContextPolicy.explain('这个方案怎么样'), contains('没有指代'));
      expect(CollabContextPolicy.explain('继续上面的方案'), contains('明确指代'));
    });

    test('上下文包：问候给空包，指代才带上方案', () {
      final history = [
        _msg('m1', _long('【完整修改方案】', 900)),
        _msg('m2', 'https://github.com/giangnam728828-rgb/zichuan-assistant'),
      ];
      final greeting = CollabContextPack.build(history: history, currentText: '你们好');
      expect(greeting.isEmpty, isTrue, reason: '问候不该把上一次的方案塞进提示词');
      expect(greeting.promptBlock, isEmpty);
      expect(greeting.sourceMessageIds, isEmpty);

      final follow = CollabContextPack.build(history: history, currentText: '按前面那份方案执行');
      expect(follow.isEmpty, isFalse);
      expect(follow.promptBlock, contains('【此前的对话资料】'));
      expect(follow.sourceMessageIds, isNotEmpty);

      // 显式覆盖（测试与特殊入口）仍然有效。
      final forced = CollabContextPack.build(history: history, currentText: '你们好', allowHistory: true);
      expect(forced.isEmpty, isFalse);
    });

    test('议会提交前清掉不允许的历史与来源编号', () {
      final spec = CouncilSpec(
        question: '你们好',
        seats: [_seat('a'), _seat('b')],
        context: '【此前的对话资料】\n[#m1] 修复 UI 层遮挡',
        sourceMessageIds: const ['m1'],
      );
      final gated = CollabOrchestrator.withGatedContext(spec);
      expect(gated.context, isEmpty);
      expect(gated.sourceMessageIds, isEmpty);
      expect(gated.question, '你们好');
      expect(gated.seats.length, 2);

      final next = _withQuestion(spec, '按前面的要求继续改 UI 层');
      final kept = CollabOrchestrator.withGatedContext(next);
      expect(kept.context, contains('修复 UI 层遮挡'));
      expect(kept.sourceMessageIds, ['m1']);
    });
  });

  group('15.2 团队请求分流', () {
    final mates = [_mate('m1', '甲'), _mate('m2', '乙'), _mate('m3', '丙')];

    test('你们好：全体自然回应，不进任务规划', () {
      final plan = routeTeamRequest(text: '你们好', teammates: mates, leadId: 'm1');
      expect(plan.kind, TeamRequestKind.social);
      expect(plan.plan, isFalse, reason: '问候绝不能交给主管拆任务');
      expect(plan.targetIds, ['m1', 'm2', 'm3'], reason: '全体成员依次回应');
      expect(plan.allMembers, isTrue);
      expect(plan.isSocial, isTrue);
    });

    test('讨论类：设了主管由主管先答，不建任务图', () {
      final plan = routeTeamRequest(text: '分析一下这个方案的风险', teammates: mates, leadId: 'm1');
      expect(plan.kind, TeamRequestKind.discussion);
      expect(plan.plan, isFalse, reason: '讨论不是派活，不能出任务图');
      expect(plan.targetIds, ['m1'], reason: '主管作为普通成员先接一句');
    });

    test('讨论类但没有主管：全体作答', () {
      final plan = routeTeamRequest(text: '分析一下这个方案的风险', teammates: mates);
      expect(plan.kind, TeamRequestKind.discussion);
      expect(plan.plan, isFalse);
      expect(plan.targetIds, ['m1', 'm2', 'm3']);
    });

    test('能力介绍：没设主管时全体分别介绍', () {
      final plan = routeTeamRequest(text: '你们都能干什么', teammates: mates);
      expect(plan.kind, TeamRequestKind.discussion);
      expect(plan.plan, isFalse);
      expect(plan.targetIds.length, 3);
    });

    test('「这周做什么」这类开放提问不算派活', () {
      final plan = routeTeamRequest(text: '这周做什么', teammates: mates, leadId: 'm1');
      expect(plan.plan, isFalse, reason: '没有执行动作，绝不进任务规划');
      expect(plan.kind, TeamRequestKind.discussion);
    });

    test('执行类：有主管就交给主管规划', () {
      final plan = routeTeamRequest(text: '帮我修复这个仓库的 UI 遮挡问题', teammates: mates, leadId: 'm2');
      expect(plan.kind, TeamRequestKind.execution);
      expect(plan.plan, isTrue);
      expect(plan.targetIds, ['m2'], reason: '只有主管先接活');
    });

    test('执行类但没有主管：全体分工，仍不出任务图', () {
      final plan = routeTeamRequest(text: '帮我修复这个仓库的 UI 遮挡问题', teammates: mates);
      expect(plan.kind, TeamRequestKind.execution);
      expect(plan.plan, isFalse);
      expect(plan.targetIds, ['m1', 'm2', 'm3']);
    });

    test('点名：只答被点名的人，顺序按消息', () {
      final plan = routeTeamRequest(
        text: '@丙 和 @甲 分别说说',
        teammates: mates,
        leadId: 'm1',
        mentioned: [mates[2], mates[0]],
      );
      expect(plan.kind, TeamRequestKind.mentioned);
      expect(plan.plan, isFalse);
      expect(plan.targetIds, ['m3', 'm1']);
      expect(plan.allMembers, isFalse);
    });

    test('只有标点：先问清楚，不让全体瞎猜', () {
      final plan = routeTeamRequest(text: '？', teammates: mates, leadId: 'm1');
      expect(plan.kind, TeamRequestKind.clarification);
      expect(plan.plan, isFalse);
    });

    test('问候里带执行动作就不再是问候', () {
      final plan = routeTeamRequest(text: '你好，帮我修复这个仓库的 bug', teammates: mates, leadId: 'm1');
      expect(plan.kind, TeamRequestKind.execution);
      expect(plan.plan, isTrue);
    });
  });

  group('15.3 议会请求类型', () {
    test('你们好：社交轮，不综合、不要求长文', () {
      final kind = CouncilRequestRules.of('你们好');
      expect(kind, CouncilRequestKind.social);
      expect(kind.synthesizes, isFalse, reason: '社交轮不进主席综合');
      expect(kind.wantsLongAnswer, isFalse, reason: '不要求 200–400 字');
    });

    test('短到看不懂：也算社交轮，让成员自然问一句', () {
      final kind = CouncilRequestRules.of('…');
      expect(kind, CouncilRequestKind.social);
      expect(kind.synthesizes, isFalse);
    });

    test('分析类与执行类照常综合', () {
      expect(CouncilRequestRules.of('分析一下这个方案的风险'), CouncilRequestKind.discussion);
      expect(CouncilRequestRules.of('这套架构的优劣如何'), CouncilRequestKind.discussion);
      expect(CouncilRequestRules.of('帮我修复这个仓库的 UI 遮挡'), CouncilRequestKind.execution);
      for (final kind in [CouncilRequestRules.of('分析一下这个方案的风险'), CouncilRequestRules.of('帮我修复这个仓库的 UI 遮挡')]) {
        expect(kind.synthesizes, isTrue);
        expect(kind.wantsLongAnswer, isTrue);
      }
    });
  });
}

/// 复制一份 spec，只换问题（测试里读起来更直白）。
CouncilSpec _withQuestion(CouncilSpec base, String question) => CouncilSpec(
  question: question,
  seats: base.seats,
  mode: base.mode,
  chairId: base.chairId,
  maxConcurrency: base.maxConcurrency,
  seatTimeout: base.seatTimeout,
  budgetCalls: base.budgetCalls,
  workspaceId: base.workspaceId,
  context: base.context,
  sourceMessageIds: base.sourceMessageIds,
);
