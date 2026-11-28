// 议会请求类型（v4.3 · P0-A · 2.6）。
//
// `_roundPrompt()` 曾经对每一条议题都写死同一套要求：直接给答案、不要客套、
// 200 到 400 字、结论/共识/分歧/建议核实。这套要求适合分析任务，但用户只说
// 「你们好」时，成员被逼着写一篇「裁决」，或者干脆接着上一次的工程任务往下
// 发挥。
//
// 这里按当前问题分出三类，提示词与后续流程都跟着变：
// - social：只回应当前问候，不展开旧任务，不要求字数，也不进主席综合；
// - discussion：各成员围绕最新问题独立作答，复杂问题由主席综合；
// - execution：可以用相关任务上下文，按当前要求分析或组织任务。
//
// 纯函数：只读这句话本身，不依赖运行状态，恢复旧会话时判定也一样。

import '../collab/collab_intent.dart';

/// 一轮议会请求的类型。
enum CouncilRequestKind {
  /// 问候、闲聊、简短互动。
  social,

  /// 分析、讨论、咨询。
  discussion,

  /// 明确要求执行或交付任务。
  execution;

  /// 要不要主席综合出结构化裁决。
  ///
  /// 社交轮不进综合：成员各自回应完就结束，不再生成「结论 / 共识 / 分歧」。
  bool get synthesizes => this != CouncilRequestKind.social;

  /// 提示词里要不要写「直接给答案、不要客套、200 到 400 字」这一套。
  bool get wantsLongAnswer => this != CouncilRequestKind.social;

  String get label => switch (this) {
    CouncilRequestKind.social => '互动',
    CouncilRequestKind.discussion => '讨论',
    CouncilRequestKind.execution => '执行',
  };
}

/// 判定入口：与团队共用同一套意图规则，避免两处结论打架。
abstract final class CouncilRequestRules {
  static CouncilRequestKind of(String question) =>
      switch (CollabIntentRules.of(question)) {
        CollabIntent.social => CouncilRequestKind.social,
        // 只有标点/半个字的短消息：让成员自然问清楚，同样不要长篇裁决。
        CollabIntent.clarification => CouncilRequestKind.social,
        CollabIntent.discussion => CouncilRequestKind.discussion,
        CollabIntent.execution => CouncilRequestKind.execution,
      };
}
