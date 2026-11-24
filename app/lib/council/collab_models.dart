// 多 AI 协作（议会 / 团队）的纯数据层：一次协作运行的完整状态。
//
// 这一层不碰 Flutter、不碰网络、不碰磁盘 IO——可序列化成一份 JSON，
// 由 [CollabStore] 原样落盘、由 [CollabOrchestrator] 驱动转移。
// 「先写盘再执行」：任何一步开始前，run 的最新状态都已存好，进程被杀
// 后从盘上的 phase 与各席位状态继续，已经答过的席位不会重复提问。

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
enum CollabPhase {
  /// 已提交，尚未开始第一轮。
  queued,

  /// 第一轮：各席位独立作答。
  round1,

  /// 审议轮：互看匿名答案后修订（仅 [CollabMode.deliberative]）。
  reviewing,

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
  });

  factory SeatSpec.fromJson(Map<String, Object?> json) => SeatSpec(
    id: json['id'] as String? ?? '',
    provider: json['provider'] as String? ?? '',
    model: json['model'] as String? ?? '',
    role: SeatRole.values.firstWhere(
      (r) => r.name == json['role'],
      orElse: () => SeatRole.none,
    ),
    reasoningEffort: json['reasoningEffort'] as String?,
    label: json['label'] as String?,
  );

  /// 稳定标识（落盘、审批路由、界面 key 都用它）。
  final String id;
  final String provider;
  final String model;
  final SeatRole role;
  final String? reasoningEffort;

  /// 界面上的名字；空则显示模型名。
  final String? label;

  String get displayName => label?.trim().isNotEmpty == true ? label!.trim() : model;

  Map<String, Object?> toJson() => {
    'id': id,
    'provider': provider,
    'model': model,
    'role': role.name,
    'reasoningEffort': ?reasoningEffort,
    'label': ?label,
  };
}

/// 一次议会/团队运行的规格（提交时定下，运行中不改）。
final class CouncilSpec {
  const CouncilSpec({
    required this.question,
    required this.seats,
    this.mode = CollabMode.quick,
    this.chairId,
    this.maxConcurrency = 3,
    this.seatTimeout = const Duration(seconds: 90),
    this.budgetCalls = 16,
    this.workspaceId,
  });

  factory CouncilSpec.fromJson(Map<String, Object?> json) => CouncilSpec(
    question: json['question'] as String? ?? '',
    seats: [
      for (final s in (json['seats'] as List? ?? const []))
        if (s is Map) SeatSpec.fromJson(s.cast<String, Object?>()),
    ],
    mode: CollabMode.values.firstWhere(
      (m) => m.name == json['mode'],
      orElse: () => CollabMode.quick,
    ),
    chairId: json['chairId'] as String?,
    maxConcurrency: (json['maxConcurrency'] as num?)?.toInt() ?? 3,
    seatTimeout: Duration(milliseconds: (json['seatTimeoutMs'] as num?)?.toInt() ?? 90000),
    budgetCalls: (json['budgetCalls'] as num?)?.toInt() ?? 16,
    workspaceId: json['workspaceId'] as String?,
  );

  /// 提交给议会的议题。
  final String question;

  /// 席位（2 到 6 个）。
  final List<SeatSpec> seats;

  final CollabMode mode;

  /// 负责综合的主席；空则用第一个席位。
  final String? chairId;

  /// 同时最多几个席位的请求在飞（手机并发：3 到 4）。
  final int maxConcurrency;

  /// 单席一轮的时限。
  final Duration seatTimeout;

  /// 整个运行的调用次数硬上限（席位 × 轮 + 主席），超限必须停下。
  final int budgetCalls;

  /// 席位会话落在哪个工作区；空则默认目录。
  final String? workspaceId;

  /// 预计调用次数（界面上「预计 N 次调用」就显示它）。
  int get estimatedCalls =>
      seats.length * (mode == CollabMode.deliberative ? 2 : 1) + (mode == CollabMode.evidence ? 1 : 0) + 1;

  /// 主席席位（chairId 匹配不到时退回第一个）。
  SeatSpec get chair => seats.firstWhere(
    (s) => s.id == chairId,
    orElse: () => seats.first,
  );

  Map<String, Object?> toJson() => {
    'question': question,
    'seats': [for (final s in seats) s.toJson()],
    'mode': mode.name,
    'chairId': ?chairId,
    'maxConcurrency': maxConcurrency,
    'seatTimeoutMs': seatTimeout.inMilliseconds,
    'budgetCalls': budgetCalls,
    'workspaceId': ?workspaceId,
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
    status: SeatStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => SeatStatus.pending,
    ),
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
      phase: CollabPhase.values.firstWhere(
        (p) => p.name == json['phase'],
        orElse: () => CollabPhase.queued,
      ),
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
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 状态转移序号，只增；界面据此判断「比上次新」。
  final int rev;

  SeatState seatOf(String id) => seats[id] ?? const SeatState();

  /// 已答出可用答案的席位数。
  int get answeredCount => spec.seats.where((s) => seatOf(s.id).isUsable).length;

  CollabRun copyWith({
    CollabPhase? phase,
    Map<String, SeatState>? seats,
    String? verdict,
    String? failure,
    int? callsUsed,
    bool? cancelRequested,
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
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    rev: rev ?? this.rev,
  );

  /// 换掉某一席的状态（其余不动）。
  CollabRun withSeat(String seatId, SeatState state) =>
      copyWith(seats: {...seats, seatId: state});

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
