// 多 AI 协作（议会 / 团队）的纯数据层：一次协作运行的完整状态。
//
// 这一层不碰 Flutter、不碰网络、不碰磁盘 IO——可序列化成一份 JSON，
// 由 [CollabStore] 原样落盘、由 [CollabOrchestrator] 驱动转移。
// 「先写盘再执行」：任何一步开始前，run 的最新状态都已存好，进程被杀
// 后从盘上的 phase 与各席位状态继续，已经答过的席位不会重复提问。

import 'dart:typed_data';

/// 随一条消息一起发出的附件（议会/团队与普通聊天共用同一套选择与预算规则）。
///
/// 只带发送需要的最小字段：图片用 base64 内联，文件先上传拿 receipt 或落到
/// 工作区；具体怎么交给引擎由驱动决定，编排层不关心。
final class CollabAttachment {
  const CollabAttachment({required this.name, required this.bytes, this.mediaType});

  final String name;
  final Uint8List bytes;

  /// 图片的 MIME；文件为 null。
  final String? mediaType;

  bool get isImage => mediaType != null;
  int get size => bytes.length;
}

/// 议会/团队的运行方式。
enum CollabMode {
  /// 民主：各席位并行作答，主席计票汇总。
  quick,

  /// 审议：第一轮后互看匿名答案，修订一轮再汇总（成本约 2 倍）。
  deliberative,

  /// 循证：指定一个权威席位先答，其余席位只做校验与补漏。
  evidence,
}

/// 席位角色预设（也可以不分配）。
enum SeatRole {
  contrarian('唱反调者', '你专门找漏洞：指出方案、事实或论证里最可能出错的地方，不要附和。'),
  optimist('乐观者', '你关注可行的部分与收益，但必须指出你忽略了什么风险。'),
  skeptic('怀疑者', '你对证据要求苛刻：区分事实与推测，明确标注不确定的地方。'),
  engineer('技术专家', '你从工程实现角度回答：可行性、复杂度、边界条件、失败模式。'),
  strategist('商业策略师', '你从成本、收益、时机与竞争角度回答。'),
  creative('创意者', '你提出别人没想到的角度，允许发散，但最后要收敛到可执行的建议。'),
  none('无角色', '');

  const SeatRole(this.label, this.briefing);

  /// 界面上显示的名字。
  final String label;

  /// 拼进提示词的角色说明。
  final String briefing;
}

/// 一次运行走到哪一步。终态：[done]、[cancelled]、[failed]。
/// 一个执行单元此刻的阶段。
enum CollabActivityPhase {
  /// 刚开始 / 模型在想（含只收到 reasoning 增量）。
  thinking,

  /// 正在调工具（[CollabActivity.detail] 是真实工具名）。
  tool,

  /// 正在写正文（[CollabActivity.text] 是已经收到的部分）。
  replying,

  /// 这一轮结束。
  done,

  /// 失败 / 超时 / 中断。
  failed,
}

/// 一次工具调用的真实状态（名称来自事件，不编造）。
enum CollabToolStatus {
  /// 已开始调用（模型发出了 tool/call）。
  calling,

  /// 执行完成。
  done,

  /// 执行失败，[CollabToolStep.detail] 是真实错误。
  failed;

  String get label => switch (this) {
    CollabToolStatus.calling => '执行中',
    CollabToolStatus.done => '完成',
    CollabToolStatus.failed => '失败',
  };
}

/// 成员消息下面的一行工具记录（v4.3 · P0-C · 4.3）。
final class CollabToolStep {
  const CollabToolStep({
    required this.id,
    required this.name,
    this.status = CollabToolStatus.calling,
    this.detail = '',
  });

  /// 事件里的 callId（同一次调用的开始与结果靠它对上）。
  final String id;

  /// 真实工具名（tool/call 事件的 name）。
  final String name;
  final CollabToolStatus status;

  /// 真实补充：失败原因等。
  final String detail;

  CollabToolStep copyWith({String? name, CollabToolStatus? status, String? detail}) => CollabToolStep(
    id: id,
    name: name ?? this.name,
    status: status ?? this.status,
    detail: detail ?? this.detail,
  );

  String get label => switch (status) {
    CollabToolStatus.calling => '正在调用 $name',
    CollabToolStatus.done => '$name · 完成',
    CollabToolStatus.failed => detail.isEmpty ? '$name · 失败' : '$name · 失败：$detail',
  };
}

/// 一位成员此刻的执行状态（不落盘）。
final class CollabActivity {
  const CollabActivity({
    required this.phase,
    this.detail = '',
    this.text = '',
    this.attemptId = '',
    this.thoughtSummary = '',
    this.toolName = '',
    this.toolStatus = '',
    this.reasoning = '',
    this.tools = const [],
    this.at,
  });

  final CollabActivityPhase phase;

  /// 工具名之类的补充说明（保留字段，兼容旧调用）。
  final String detail;

  /// 已经收到的**回答正文**（只来自 assistant 的 TextDeltaChunk）。
  ///
  /// 思考摘要绝不写进这里：两者从数据结构上就是分开的（v3 · 3.2）。
  final String text;

  /// Host 的 attemptId：换了一次重试就换一个，用来丢弃旧请求的尾巴。
  final String attemptId;

  /// 提供方明确标为「用户可见」的思考摘要。
  ///
  /// 只有这个字段可以喂给 ThinkingPill；没有公开摘要时就留空，
  /// 界面只显示真实的阶段状态（v3 · 3.3）。
  final String thoughtSummary;

  /// 与普通聊天同源的思考正文（reasoning 增量累积）。
  ///
  /// 普通聊天把 reasoning 直接交给 ThinkingPill 展示；协作模式以前把它压成
  /// 一个「思考中」标记，用户看不到内容。这里保存同一份数据，界面用同一个
  /// ThinkingPill 渲染——既不多透一点，也不少透一点（v4.3 · P0-C · 4.2）。
  final String reasoning;

  /// 这一轮真实发生过的工具调用（按发生顺序，同一 callId 就地更新状态）。
  final List<CollabToolStep> tools;

  /// 当前工具名与执行状态（都来自真实事件）。
  final String toolName;
  final String toolStatus;

  /// 最近一次状态变化时间。
  final DateTime? at;

  bool get isActive => phase != CollabActivityPhase.done && phase != CollabActivityPhase.failed;

  /// 界面上的那一句话。
  String get label => switch (phase) {
    CollabActivityPhase.thinking => '正在思考…',
    CollabActivityPhase.tool => toolName.isEmpty
        ? (detail.isEmpty ? '正在调用工具…' : '正在用 $detail…')
        : (toolStatus.isEmpty ? '正在用 $toolName…' : '$toolName · $toolStatus'),
    CollabActivityPhase.replying => '正在回答…',
    CollabActivityPhase.done => '已完成',
    CollabActivityPhase.failed => '这一轮没跑完',
  };

  CollabActivity copyWith({
    CollabActivityPhase? phase,
    String? detail,
    String? text,
    String? attemptId,
    String? thoughtSummary,
    String? reasoning,
    List<CollabToolStep>? tools,
    String? toolName,
    String? toolStatus,
    DateTime? at,
  }) {
    return CollabActivity(
      phase: phase ?? this.phase,
      detail: detail ?? this.detail,
      text: text ?? this.text,
      attemptId: attemptId ?? this.attemptId,
      thoughtSummary: thoughtSummary ?? this.thoughtSummary,
      reasoning: reasoning ?? this.reasoning,
      tools: tools ?? this.tools,
      toolName: toolName ?? this.toolName,
      toolStatus: toolStatus ?? this.toolStatus,
      at: at ?? this.at,
    );
  }
}

enum CollabPhase {
  /// 已提交，尚未开始第一轮。
  queued,

  /// 第一轮：各席位独立作答。
  round1,

  /// 审议轮：互看匿名答案后修订（仅 [CollabMode.deliberative]）。
  reviewing,

  /// 校验轮：权威首答之后，其余席位校验与补漏（仅 [CollabMode.evidence]）。
  verifying,

  /// 主席综合出裁决。
  synthesizing,

  /// 裁决已写出。
  done,

  /// 用户取消。
  cancelled,

  /// 无法继续（预算超限、全员失败、内部错误）。
  failed;

  bool get isTerminal => this == done || this == cancelled || this == failed;
}

/// 单个席位的状态。
enum SeatStatus {
  /// 还没答。
  pending,

  /// 正在答（进程重启后看到它，说明上次执行到一半被打断）。
  running,

  /// 第一轮已答。
  answered,

  /// 审议轮已修订。
  revised,

  /// 重试后仍失败。
  failed,

  /// 超过单席时限。
  timedOut,

  /// 用户取消时还没答完。
  cancelled;

  bool get isUsable => this == answered || this == revised;
}

/// 一个席位的配置：用哪家的哪个模型、扮演什么角色。
final class SeatSpec {
  const SeatSpec({
    required this.id,
    required this.provider,
    required this.model,
    this.role = SeatRole.none,
    this.reasoningEffort,
    this.label,
    this.agentPreset,
  });

  factory SeatSpec.fromJson(Map<String, Object?> json) => SeatSpec(
    id: json['id'] as String? ?? '',
    provider: json['provider'] as String? ?? '',
    model: json['model'] as String? ?? '',
    role: SeatRole.values.firstWhere((r) => r.name == json['role'], orElse: () => SeatRole.none),
    reasoningEffort: json['reasoningEffort'] as String?,
    label: json['label'] as String?,
    agentPreset: json['agentPreset'] as String?,
  );

  /// 稳定标识（落盘、审批路由、界面 key 都用它）。
  final String id;
  final String provider;
  final String model;
  final SeatRole role;
  final String? reasoningEffort;

  /// 界面上的名字；空则显示模型名。
  final String? label;

  /// Agent 预设（决定这个席位能用哪些工具，例如联网）；空表示 Host 默认。
  final String? agentPreset;

  String get displayName => label?.trim().isNotEmpty == true ? label!.trim() : model;

  /// 复制一份独立配置（新会话沿用上次成员时用，绝不共享可变状态）。
  SeatSpec copyWith({
    String? id,
    String? provider,
    String? model,
    SeatRole? role,
    String? reasoningEffort,
    String? label,
    String? agentPreset,
    bool clearAgentPreset = false,
  }) => SeatSpec(
    id: id ?? this.id,
    provider: provider ?? this.provider,
    model: model ?? this.model,
    role: role ?? this.role,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    label: label ?? this.label,
    agentPreset: clearAgentPreset ? null : (agentPreset ?? this.agentPreset),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'provider': provider,
    'model': model,
    'role': role.name,
    'reasoningEffort': ?reasoningEffort,
    'label': ?label,
    'agentPreset': ?agentPreset,
  };
}

/// 一次议会/团队运行的规格（提交时定下，运行中不改）。
final class CouncilSpec {
  const CouncilSpec({
    required this.question,
    required this.seats,
    this.mode = CollabMode.quick,
    this.chairId,
    this.maxConcurrency = 1,
    this.seatTimeout = const Duration(seconds: 90),
    this.budgetCalls = 16,
    this.workspaceId,
    this.context = '',
    this.sourceMessageIds = const [],
  });

  factory CouncilSpec.fromJson(Map<String, Object?> json) => CouncilSpec(
    question: json['question'] as String? ?? '',
    seats: [
      for (final s in (json['seats'] as List? ?? const []))
        if (s is Map) SeatSpec.fromJson(s.cast<String, Object?>()),
    ],
    mode: CollabMode.values.firstWhere((m) => m.name == json['mode'], orElse: () => CollabMode.quick),
    chairId: json['chairId'] as String?,
    // 旧会话里存过 2/3 的配置在这里规范化到 1，不让老议会继续并发。
    maxConcurrency: ((json['maxConcurrency'] as num?)?.toInt() ?? 1).clamp(1, 1).toInt(),
    seatTimeout: Duration(milliseconds: (json['seatTimeoutMs'] as num?)?.toInt() ?? 90000),
    budgetCalls: (json['budgetCalls'] as num?)?.toInt() ?? 16,
    workspaceId: json['workspaceId'] as String?,
    context: json['context'] as String? ?? '',
    sourceMessageIds: [
      for (final id in (json['sourceMessageIds'] as List? ?? const []))
        if (id is String && id.isNotEmpty) id,
    ],
  );

  /// 提交给议会的议题。
  final String question;

  /// 席位（2 到 6 个）。
  final List<SeatSpec> seats;

  final CollabMode mode;

  /// 负责综合的主席；空则用第一个席位。
  final String? chairId;

  /// 同时最多几个席位的请求在飞。
  ///
  /// 默认 1：议会按席位顺序依次作答，主聊天区同一时刻只有一位在写
  /// （用户看到的就是正常群聊：上一位说完，下一位再开口）。需要抢时间
  /// 时可以显式调高，但主聊天区的展示仍按完成顺序排列。
  final int maxConcurrency;

  /// 单席一轮的时限。
  final Duration seatTimeout;

  /// 整个运行的调用次数硬上限（席位 × 轮 + 主席），超限必须停下。
  final int budgetCalls;

  /// 席位会话落在哪个工作区；空则默认目录。
  final String? workspaceId;

  /// 此前对话的检索结果（见 lib/collab/collab_context_pack.dart）。
  ///
  /// 用户在这次提问里用「上面那个方案 / 刚才的仓库 / 继续做」指代的内容，
  /// 靠它随议题一起交给成员；随运行一起落盘，重启后仍在。
  final String context;

  /// [context] 用到的历史消息编号：任务记录能追回原文。
  final List<String> sourceMessageIds;

  /// 预计调用次数（界面上「预计 N 次调用」就显示它）。
  /// 循证 = 权威首答 1 次 + 其余席位校验 (N-1) 次 + 主席综合 1 次。
  int get estimatedCalls => switch (mode) {
    CollabMode.quick => seats.length + 1,
    CollabMode.deliberative => seats.length * 2 + 1,
    CollabMode.evidence => seats.length + 1,
  };

  /// 主席席位（chairId 匹配不到时退回第一个）。
  SeatSpec get chair => seats.firstWhere((s) => s.id == chairId, orElse: () => seats.first);

  Map<String, Object?> toJson() => {
    'question': question,
    'seats': [for (final s in seats) s.toJson()],
    'mode': mode.name,
    'chairId': ?chairId,
    'maxConcurrency': maxConcurrency,
    'seatTimeoutMs': seatTimeout.inMilliseconds,
    'budgetCalls': budgetCalls,
    'workspaceId': ?workspaceId,
    if (context.isNotEmpty) 'context': context,
    if (sourceMessageIds.isNotEmpty) 'sourceMessageIds': sourceMessageIds,
  };
}

/// 一个席位跑出来的结果。
final class SeatState {
  const SeatState({
    this.sessionId,
    this.status = SeatStatus.pending,
    this.answer,
    this.revised,
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.error,
    this.attempts = 0,
  });

  factory SeatState.fromJson(Map<String, Object?> json) => SeatState(
    sessionId: json['sessionId'] as String?,
    status: SeatStatus.values.firstWhere((s) => s.name == json['status'], orElse: () => SeatStatus.pending),
    answer: json['answer'] as String?,
    revised: json['revised'] as String?,
    tokensIn: (json['tokensIn'] as num?)?.toInt() ?? 0,
    tokensOut: (json['tokensOut'] as num?)?.toInt() ?? 0,
    error: json['error'] as String?,
    attempts: (json['attempts'] as num?)?.toInt() ?? 0,
  );

  /// 席位自己的子会话 id；第一次执行时创建，恢复时复用它续问。
  final String? sessionId;
  final SeatStatus status;

  /// 第一轮终稿。
  final String? answer;

  /// 审议轮的修订稿。
  final String? revised;
  final int tokensIn;
  final int tokensOut;

  /// 失败原因（给人看的短句）。
  final String? error;

  /// 已尝试次数（含首次）。
  final int attempts;

  /// 这一席目前最有效的回答：修订稿优先。
  String? get best => revised ?? answer;

  /// 是否已有可用答案（第一轮或修订）。
  bool get isUsable => status.isUsable;

  SeatState copyWith({
    String? sessionId,
    SeatStatus? status,
    String? answer,
    String? revised,
    int? tokensIn,
    int? tokensOut,
    String? error,
    int? attempts,
  }) => SeatState(
    sessionId: sessionId ?? this.sessionId,
    status: status ?? this.status,
    answer: answer ?? this.answer,
    revised: revised ?? this.revised,
    tokensIn: tokensIn ?? this.tokensIn,
    tokensOut: tokensOut ?? this.tokensOut,
    error: error ?? this.error,
    attempts: attempts ?? this.attempts,
  );

  Map<String, Object?> toJson() => {
    'sessionId': ?sessionId,
    'status': status.name,
    'answer': ?answer,
    'revised': ?revised,
    'tokensIn': tokensIn,
    'tokensOut': tokensOut,
    'error': ?error,
    'attempts': attempts,
  };
}

/// 一次运行的完整状态。序列化后就是恢复所需的全部信息。
final class CollabRun {
  const CollabRun({
    required this.id,
    required this.spec,
    required this.phase,
    required this.seats,
    this.verdict,
    this.failure,
    this.callsUsed = 0,
    this.cancelRequested = false,
    this.activity = const {},
    required this.createdAt,
    required this.updatedAt,
    this.rev = 0,
  });

  factory CollabRun.fromJson(Map<String, Object?> json) {
    final seats = <String, SeatState>{};
    for (final entry in (json['seats'] as Map? ?? const {}).entries) {
      if (entry.value is Map) {
        seats['${entry.key}'] = SeatState.fromJson((entry.value as Map).cast<String, Object?>());
      }
    }
    return CollabRun(
      id: json['id'] as String? ?? '',
      spec: CouncilSpec.fromJson((json['spec'] as Map? ?? const {}).cast<String, Object?>()),
      phase: CollabPhase.values.firstWhere((p) => p.name == json['phase'], orElse: () => CollabPhase.queued),
      seats: seats,
      verdict: json['verdict'] as String?,
      failure: json['failure'] as String?,
      callsUsed: (json['callsUsed'] as num?)?.toInt() ?? 0,
      cancelRequested: json['cancelRequested'] as bool? ?? false,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
      rev: (json['rev'] as num?)?.toInt() ?? 0,
    );
  }

  /// 运行 id（也是落盘目录名）。
  final String id;
  final CouncilSpec spec;
  final CollabPhase phase;

  /// 按 SeatSpec.id 索引的席位状态。
  final Map<String, SeatState> seats;

  /// 主席写出的裁决（Markdown）。
  final String? verdict;

  /// [CollabPhase.failed] 的原因。
  final String? failure;

  /// 已发出的模型调用次数（预算计数）。
  final int callsUsed;

  /// 用户已请求取消；每个步骤开始前检查。
  final bool cancelRequested;

  /// 各席位此刻的真实执行过程（seatId → 状态）。只在本进程有意义，不落盘。
  final Map<String, CollabActivity> activity;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 状态转移序号，只增；界面据此判断「比上次新」。
  final int rev;

  SeatState seatOf(String id) => seats[id] ?? const SeatState();

  /// 按子会话 id 反查席位：审批卡、通知横幅靠它标明「这是哪一席在请求」。
  SeatSpec? seatBySession(String sessionId) {
    if (sessionId.isEmpty) return null;
    for (final seat in spec.seats) {
      if (seatOf(seat.id).sessionId == sessionId) return seat;
    }
    return null;
  }

  /// 已答出可用答案的席位数。
  int get answeredCount => spec.seats.where((s) => seatOf(s.id).isUsable).length;

  CollabRun copyWith({
    CollabPhase? phase,
    Map<String, SeatState>? seats,
    String? verdict,
    String? failure,
    int? callsUsed,
    bool? cancelRequested,
    Map<String, CollabActivity>? activity,
    DateTime? updatedAt,
    int? rev,
  }) => CollabRun(
    id: id,
    spec: spec,
    phase: phase ?? this.phase,
    seats: seats ?? this.seats,
    verdict: verdict ?? this.verdict,
    failure: failure ?? this.failure,
    callsUsed: callsUsed ?? this.callsUsed,
    cancelRequested: cancelRequested ?? this.cancelRequested,
    activity: activity ?? this.activity,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    rev: rev ?? this.rev,
  );

  /// 换掉某一席的状态（其余不动）。
  CollabRun withSeat(String seatId, SeatState state) => copyWith(seats: {...seats, seatId: state});

  Map<String, Object?> toJson() => {
    'id': id,
    'spec': spec.toJson(),
    'phase': phase.name,
    'seats': {for (final e in seats.entries) e.key: e.value.toJson()},
    'verdict': ?verdict,
    'failure': ?failure,
    'callsUsed': callsUsed,
    'cancelRequested': cancelRequested,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'rev': rev,
  };
}
