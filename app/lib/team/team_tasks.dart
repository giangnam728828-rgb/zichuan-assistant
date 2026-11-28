// 团队任务图（S8）：一次团队协作的计划、任务与执行记录。
//
// 方案要求「主管先出计划 → 调度器按依赖并行 → 成员回传结果 → 主管审核 →
// 汇总」，并且每一步都先落盘再执行。这里只放纯数据与解析；调度在
// [TeamOrchestrator] 里，界面只读快照。
//
// 与旧的「群里 @ 一下」相比，任务图多了三件事：
// 1. 任务有负责人、依赖和状态，依赖没满足不会开跑；
// 2. 结果挂在任务上，重开应用还能接着做已完成的；
// 3. 主管可以打回重做，最多两次，不会无限循环。

import 'dart:convert';

/// 单个任务的状态。
enum TeamTaskStatus {
  /// 还没轮到的任务。
  pending,

  /// 依赖已满足，可以开跑。
  ready,

  /// 正在执行。
  running,

  /// 依赖没满足（或被上游失败卡住）。
  blocked,

  /// 结果已回，等主管审核。
  reviewing,

  done,
  failed,
  cancelled,
}

/// 一张任务图的生命周期。
enum TeamRunStatus { planning, running, reviewing, summarizing, done, failed, cancelled }

final class TeamTask {
  const TeamTask({
    required this.id,
    required this.title,
    required this.ownerId,
    this.deps = const [],
    this.status = TeamTaskStatus.pending,
    this.input = '',
    this.result = '',
    this.attempts = 0,
    this.review = '',
  });

  factory TeamTask.fromJson(Map<String, Object?> json) => TeamTask(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    ownerId: json['ownerId'] as String? ?? '',
    deps: [
      for (final dep in (json['deps'] as List? ?? const []))
        if (dep is String) dep,
    ],
    status: TeamTaskStatus.values.firstWhere((s) => s.name == json['status'], orElse: () => TeamTaskStatus.pending),
    input: json['input'] as String? ?? '',
    result: json['result'] as String? ?? '',
    attempts: (json['attempts'] as num?)?.toInt() ?? 0,
    review: json['review'] as String? ?? '',
  );

  final String id;
  final String title;

  /// 负责人（队友 id）。
  final String ownerId;
  final List<String> deps;
  final TeamTaskStatus status;

  /// 主管给这位成员的做事说明（与总目标分开）。
  final String input;
  final String result;

  /// 已尝试次数（含首次）；返工上限 2 次由编排器判断。
  final int attempts;

  /// 主管的审核意见（通过或打回原因）。
  final String review;

  bool get isOpen =>
      status == TeamTaskStatus.pending ||
      status == TeamTaskStatus.ready ||
      status == TeamTaskStatus.running ||
      status == TeamTaskStatus.blocked ||
      status == TeamTaskStatus.reviewing;

  TeamTask copyWith({
    String? title,
    String? ownerId,
    List<String>? deps,
    TeamTaskStatus? status,
    String? input,
    String? result,
    int? attempts,
    String? review,
  }) => TeamTask(
    id: id,
    title: title ?? this.title,
    ownerId: ownerId ?? this.ownerId,
    deps: deps ?? this.deps,
    status: status ?? this.status,
    input: input ?? this.input,
    result: result ?? this.result,
    attempts: attempts ?? this.attempts,
    review: review ?? this.review,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'ownerId': ownerId,
    'deps': deps,
    'status': status.name,
    'input': input,
    'result': result,
    'attempts': attempts,
    'review': review,
  };
}

/// 一次团队运行：一张任务图 + 主管 + 汇总。
final class TeamRun {
  const TeamRun({
    required this.id,
    required this.sessionId,
    required this.status,
    required this.supervisorId,
    required this.tasks,
    required this.createdAt,
    required this.updatedAt,
    this.goal = '',
    this.summary = '',
    this.note = '',
    this.context = '',
  });

  factory TeamRun.fromJson(Map<String, Object?> json) => TeamRun(
    id: json['id'] as String? ?? '',
    sessionId: json['sessionId'] as String? ?? '',
    status: TeamRunStatus.values.firstWhere((s) => s.name == json['status'], orElse: () => TeamRunStatus.planning),
    supervisorId: json['supervisorId'] as String? ?? '',
    tasks: [
      for (final task in (json['tasks'] as List? ?? const []))
        if (task is Map) TeamTask.fromJson(task.cast<String, Object?>()),
    ],
    goal: json['goal'] as String? ?? '',
    summary: json['summary'] as String? ?? '',
    note: json['note'] as String? ?? '',
    context: json['context'] as String? ?? '',
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
  );

  final String id;
  final String sessionId;
  final TeamRunStatus status;

  /// 主管（队友 id）。任务图必须有一位主管，否则退回群聊分派。
  final String supervisorId;
  final List<TeamTask> tasks;

  /// 用户这一轮的目标（原文，供恢复与提示词使用）。
  final String goal;

  /// 主管的最终汇总（一条完整回复）。
  final String summary;

  /// 给用户看的一句话：例如「达到返工上限，用已有结果汇总」。
  final String note;

  /// 这一轮随用户消息带来的资料（只有那句话明确指代此前内容时才非空）。
  ///
  /// 任务执行与恢复都靠它：进程被杀后接着跑，队友仍能看到当初交代的方案与
  /// 仓库要求。它**不会**污染之后的新消息——新消息只带自己的资料。
  final String context;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isTerminal =>
      status == TeamRunStatus.done || status == TeamRunStatus.failed || status == TeamRunStatus.cancelled;

  TeamTask? task(String id) {
    for (final task in tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  int get doneCount => tasks.where((t) => t.status == TeamTaskStatus.done).length;

  TeamRun copyWith({
    TeamRunStatus? status,
    List<TeamTask>? tasks,
    String? summary,
    String? note,
    DateTime? updatedAt,
  }) => TeamRun(
    id: id,
    sessionId: sessionId,
    status: status ?? this.status,
    supervisorId: supervisorId,
    tasks: tasks ?? this.tasks,
    goal: goal,
    summary: summary ?? this.summary,
    note: note ?? this.note,
    context: context,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  TeamRun withTask(String taskId, TeamTask Function(TeamTask task) mutate) => copyWith(
    tasks: [
      for (final task in tasks)
        if (task.id == taskId) mutate(task) else task,
    ],
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'status': status.name,
    'supervisorId': supervisorId,
    'tasks': [for (final task in tasks) task.toJson()],
    'goal': goal,
    'summary': summary,
    'note': note,
    if (context.isNotEmpty) 'context': context,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };
}

/// 主管给出的一条计划（还没绑定队友 id）。
final class PlannedTask {
  const PlannedTask({
    required this.id,
    required this.title,
    required this.owner,
    this.deps = const [],
    this.input = '',
  });

  final String id;
  final String title;

  /// 队友名字（主管只知道名字）。
  final String owner;
  final List<String> deps;
  final String input;
}

/// 一次规划的输出：任务列表 + 不拆分时的直接答复。
final class TeamPlan {
  const TeamPlan({this.tasks = const [], this.summary = '', this.problem});

  final List<PlannedTask> tasks;

  /// 主管认为不需要拆分时，直接给出的最终答复。
  final String summary;

  /// 有任务但字段有问题时的原因（用于告诉用户，不用于执行）。
  final String? problem;
}

final _fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```', caseSensitive: false);

/// 从主管回复里解析计划。
///
/// 兼容两种写法：
/// - `{"tasks":[{"id":"t1","title":"…","owner":"研究员","deps":[]}]}`
/// - `{"actions":[{"type":"assign","task":"…","owner":"…","deps":[]}]}`
///
/// 解析不出来返回 null（调用方退回群聊分派，不把主管的普通回答当计划）。
TeamPlan? parseTeamPlan(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final candidates = <String>[];
  for (final match in _fence.allMatches(text)) {
    final body = match.group(1)?.trim();
    if (body != null && body.isNotEmpty) candidates.add(body);
  }
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start >= 0 && end > start) candidates.add(text.substring(start, end + 1));

  for (final candidate in candidates) {
    Object? decoded;
    try {
      decoded = jsonDecode(candidate);
    } on FormatException {
      continue;
    }
    final plan = _fromDecoded(decoded);
    if (plan != null) return plan;
  }
  return null;
}

TeamPlan? _fromDecoded(Object? decoded) {
  if (decoded is List) {
    final tasks = _tasksOf(decoded);
    return tasks == null ? null : TeamPlan(tasks: tasks);
  }
  if (decoded is! Map) return null;
  final map = decoded.cast<String, Object?>();
  final summary = (map['summary'] as String? ?? map['answer'] as String? ?? '').trim();
  if (map['tasks'] case final List raw) {
    final tasks = _tasksOf(raw) ?? const <PlannedTask>[];
    // 空任务 + 一段答复 = 主管认为不用拆分；两个都空才当解析失败。
    if (tasks.isEmpty && summary.isEmpty) return null;
    return TeamPlan(tasks: tasks, summary: summary);
  }
  if (map['actions'] case final List raw) {
    final tasks = <PlannedTask>[];
    var seq = 0;
    for (final action in raw) {
      if (action is! Map) continue;
      final item = action.cast<String, Object?>();
      if ((item['type'] as String? ?? 'assign') != 'assign') continue;
      seq++;
      final deps = [
        for (final dep in (item['deps'] as List? ?? const []))
          if (dep is String) dep,
      ];
      tasks.add(
        PlannedTask(
          id: item['id'] as String? ?? item['taskId'] as String? ?? 't$seq',
          title: (item['title'] as String? ?? item['task'] as String? ?? '').trim(),
          owner: (item['owner'] as String? ?? item['to'] as String? ?? '').trim(),
          deps: deps,
          input: (item['input'] as String? ?? item['detail'] as String? ?? '').trim(),
        ),
      );
    }
    if (tasks.isEmpty && summary.isEmpty) return null;
    return TeamPlan(tasks: tasks, summary: summary);
  }
  // 只给了一段答复：不当作计划，避免把闲聊变成任务图。
  return null;
}

List<PlannedTask>? _tasksOf(List raw) {
  final tasks = <PlannedTask>[];
  var seq = 0;
  for (final item in raw) {
    if (item is! Map) continue;
    final map = item.cast<String, Object?>();
    seq++;
    final title = (map['title'] as String? ?? map['task'] as String? ?? '').trim();
    if (title.isEmpty) continue;
    tasks.add(
      PlannedTask(
        id: (map['id'] as String? ?? 't$seq').trim(),
        title: title,
        owner: (map['owner'] as String? ?? map['ownerName'] as String? ?? map['to'] as String? ?? '').trim(),
        deps: [
          for (final dep in (map['deps'] as List? ?? const []))
            if (dep is String) dep,
        ],
        input: (map['input'] as String? ?? map['detail'] as String? ?? '').trim(),
      ),
    );
  }
  return tasks.isEmpty ? null : tasks;
}

/// 把计划绑定到真实队友并校验依赖图；有问题返回原因。
///
/// 校验：负责人必须存在；id 唯一；依赖必须存在；不能成环。
({List<TeamTask>? tasks, String? problem}) bindPlan(TeamPlan plan, {required Map<String, String> idOfName}) {
  final ids = <String>{};
  final tasks = <TeamTask>[];
  for (final planned in plan.tasks) {
    var id = planned.id.trim();
    if (id.isEmpty) id = 't${tasks.length + 1}';
    if (!ids.add(id)) return (tasks: null, problem: '任务编号重复：$id');
    final ownerId = idOfName[planned.owner.trim().toLowerCase()];
    if (ownerId == null) return (tasks: null, problem: '任务「${planned.title}」的负责人「${planned.owner}」不在团队里');
    tasks.add(TeamTask(id: id, title: planned.title, ownerId: ownerId, deps: planned.deps, input: planned.input));
  }
  for (final task in tasks) {
    for (final dep in task.deps) {
      if (!ids.contains(dep)) return (tasks: null, problem: '任务「${task.title}」依赖了不存在的 $dep');
      if (dep == task.id) return (tasks: null, problem: '任务「${task.title}」依赖了自己');
    }
  }
  // 环检测：反复剥掉「依赖都已就绪」的节点，剥不完就是有环。
  final remaining = {for (final task in tasks) task.id};
  var changed = true;
  while (changed && remaining.isNotEmpty) {
    changed = false;
    for (final task in tasks) {
      if (!remaining.contains(task.id)) continue;
      if (task.deps.every((dep) => !remaining.contains(dep))) {
        remaining.remove(task.id);
        changed = true;
      }
    }
  }
  if (remaining.isNotEmpty) return (tasks: null, problem: '任务依赖成环：${remaining.join('、')}');
  return (tasks: tasks, problem: null);
}

/// 现在可以开跑的任务：状态 ready/pending 且依赖全部完成。
List<TeamTask> readyTasks(List<TeamTask> tasks) {
  final done = {
    for (final task in tasks)
      if (task.status == TeamTaskStatus.done) task.id,
  };
  return [
    for (final task in tasks)
      if ((task.status == TeamTaskStatus.pending || task.status == TeamTaskStatus.ready) &&
          task.deps.every(done.contains))
        task,
  ];
}

/// 把「依赖没满足」的任务标成 blocked（界面用）。
List<TeamTask> settleBlocked(List<TeamTask> tasks) {
  final done = {
    for (final task in tasks)
      if (task.status == TeamTaskStatus.done) task.id,
  };
  final failed = {
    for (final task in tasks)
      if (task.status == TeamTaskStatus.failed || task.status == TeamTaskStatus.cancelled) task.id,
  };
  return [
    for (final task in tasks)
      if ((task.status == TeamTaskStatus.pending || task.status == TeamTaskStatus.ready) &&
          task.deps.any((dep) => !done.contains(dep)))
        task.copyWith(status: TeamTaskStatus.blocked)
      else if (task.status == TeamTaskStatus.blocked && task.deps.every(done.contains))
        task.copyWith(status: TeamTaskStatus.ready)
      else if (task.status == TeamTaskStatus.blocked && task.deps.any((dep) => failed.contains(dep)))
        task.copyWith(status: TeamTaskStatus.failed, review: '上游任务没有完成')
      else
        task,
  ];
}
