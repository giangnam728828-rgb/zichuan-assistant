// 团队请求分流（v4.3 · P0-B）。
//
// 旧行为：只要没 @ 人、团队又设了主管，消息就先交给主管进 `_planPrompt()`，
// 让他输出一份任务 JSON。于是「你们好」也会被当成一件要拆分的活：主管回一段
// 「没有具体任务」，或者干脆接着上一次的工程任务往下写。
//
// 这里把「这条消息该谁答、要不要出任务图」做成一个纯函数，编排器只执行结论：
//
// | 用户消息              | 处理方式                     |
// | --------------------- | ---------------------------- |
// | 你们好                | 全体成员依次自然回应         |
// | 你们都能干什么        | 没设主管时全体分别介绍       |
// | 分析一下这个方案      | 有主管时主管先答，不建任务图 |
// | 帮我修复这个仓库      | 主管进入任务规划             |
// | @A 帮我看看           | 仅 A 回答                    |
// | @A 和 @B 分别分析     | A 完成后 B 再开始（串行）    |
//
// 默认消息**不能**因为没有任务关键词就进任务规划；设了主管时由主管作为普通
// 成员先接一句，只有执行类才拆任务图。

import '../collab/collab_intent.dart';
import 'team_models.dart';

/// 一轮群聊消息的处理方式。
enum TeamRequestKind {
  /// 问候、寒暄：全体自然回应，不规划、不输出结构化格式。
  social,

  /// 讨论/分析/能力介绍：有主管时主管先答，没设主管时全体逐一作答；不规划。
  discussion,

  /// 明确要求执行：有主管就由主管拆任务图，没有就全体分工。
  execution,

  /// 用户点名了：只让被点名的人答，按点名顺序串行。
  mentioned,

  /// 没看懂要干什么：先问清楚，不要让全体瞎猜。
  clarification;

  /// 这一轮是否应该生成任务图。
  bool get plans => this == TeamRequestKind.execution;

  /// 这一轮是否只由部分成员回答。
  bool get isMention => this == TeamRequestKind.mentioned;

  String get label => switch (this) {
    TeamRequestKind.social => '问候',
    TeamRequestKind.discussion => '讨论',
    TeamRequestKind.execution => '执行',
    TeamRequestKind.mentioned => '点名',
    TeamRequestKind.clarification => '确认',
  };
}

/// 分流结果：谁答、要不要出任务图。
final class TeamRequestPlan {
  const TeamRequestPlan({
    required this.kind,
    required this.intent,
    required this.targetIds,
    required this.plan,
  });

  final TeamRequestKind kind;

  /// 更细的意图（社交/讨论/执行/确认），提示词按它换语气。
  final CollabIntent intent;

  /// 这一轮要回答的成员 id，顺序就是团队配置顺序（点名时是用户点名的顺序）。
  final List<String> targetIds;

  /// 是否交给主管出任务图。
  final bool plan;

  bool get isSocial => intent.isSocial;

  /// 是否全员参与（不是点名）。
  bool get allMembers => kind != TeamRequestKind.mentioned;

  @override
  String toString() => 'TeamRequestPlan(${kind.name}, targets: $targetIds, plan: $plan)';
}

/// 按当前消息、成员配置与点名结果决定这一轮怎么跑。
///
/// [mentioned] 是解析 @ 之后被点到的成员（按消息里出现的顺序）。
/// 没有点名时，执行类消息交给主管（如果有）；其余消息给全体。
TeamRequestPlan routeTeamRequest({
  required String text,
  required List<Teammate> teammates,
  String? leadId,
  List<Teammate> mentioned = const [],
}) {
  final intent = CollabIntentRules.of(text);
  if (mentioned.isNotEmpty) {
    // 用户点了名：严格按点名范围与顺序，不让其他人插话。
    return TeamRequestPlan(
      kind: TeamRequestKind.mentioned,
      intent: intent,
      targetIds: [for (final mate in mentioned) mate.id],
      plan: false,
    );
  }
  if (intent == CollabIntent.social) {
    // 问候/寒暄：全体成员依次自然回应，谁也不进任务规划（v4.3 · P0-B）。
    return TeamRequestPlan(
      kind: TeamRequestKind.social,
      intent: intent,
      targetIds: [for (final mate in teammates) mate.id],
      plan: false,
    );
  }
  // 设了主管：其余消息先由主管作为普通成员接（**不**进 `_planPrompt()`），
  // 这是团队一直以来的交互；只有执行类才会被拆成任务图。
  final lead = _lead(teammates, leadId);
  if (lead != null) {
    return TeamRequestPlan(
      kind: intent == CollabIntent.execution
          ? TeamRequestKind.execution
          : intent == CollabIntent.clarification
          ? TeamRequestKind.clarification
          : TeamRequestKind.discussion,
      intent: intent,
      targetIds: [lead.id],
      plan: intent == CollabIntent.execution,
    );
  }
  // 没有主管：全体按顺序各答一份，不建任务图。
  return TeamRequestPlan(
    kind: switch (intent) {
      CollabIntent.execution => TeamRequestKind.execution,
      CollabIntent.clarification => TeamRequestKind.clarification,
      _ => TeamRequestKind.discussion,
    },
    intent: intent,
    targetIds: [for (final mate in teammates) mate.id],
    plan: false,
  );
}

/// 找主管：只有 [leadId] 真的在这个团队里才算。
Teammate? _lead(List<Teammate> teammates, String? leadId) {
  if (leadId == null) return null;
  for (final mate in teammates) {
    if (mate.id == leadId) return mate;
  }
  return null;
}
