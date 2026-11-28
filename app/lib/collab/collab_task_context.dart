// 任务上下文包（方案第一部分 · 3.3）。
//
// 一次「让团队/议会去干一件活」的完整上下文：目标和资料来自对话，仓库/分支
// 从用户给的文字里提，成员、依赖、进度、测试与构建状态随运行更新。它是**可
// 落盘、可恢复**的对象，不是临时拼在一次请求里的字符串——进程被杀、切走页面
// 再回来，或隔一天说「继续完成剩下的」，都靠它接上。
//
// 与 [CollabContextPack] 的分工：
// - CollabContextPack 是「这次要交给模型的资料」（提示词块 + 消息编号）；
// - CollabTaskContext 是「这件事本身」（谁负责、做到哪、结果如何）。
//
// 落盘：<应用支持目录>/collab/tasks/<taskId>.json（一个任务一个文件）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'collab_context_pack.dart';

/// 任务走到哪一步。
enum CollabTaskStage {
  /// 刚拆完任务，还没开始做。
  planning,

  /// 有人在做。
  running,

  /// 等用户确认（审批、补充资料）。
  waiting,

  /// 跑测试。
  testing,

  /// 等构建结果。
  building,
  done,
  failed,
  cancelled;

  bool get isTerminal => this == done || this == failed || this == cancelled;

  String get label => switch (this) {
    CollabTaskStage.planning => '规划中',
    CollabTaskStage.running => '进行中',
    CollabTaskStage.waiting => '等待确认',
    CollabTaskStage.testing => '测试中',
    CollabTaskStage.building => '构建中',
    CollabTaskStage.done => '已完成',
    CollabTaskStage.failed => '已失败',
    CollabTaskStage.cancelled => '已取消',
  };
}

/// 一个子任务在上下文里的记录（与团队任务图同源，这里只留恢复需要的最小字段）。
final class CollabTaskItem {
  const CollabTaskItem({
    required this.id,
    required this.title,
    this.owner,
    this.deps = const [],
    this.status = CollabTaskStage.planning,
    this.result = '',
  });

  final String id;
  final String title;

  /// 负责人（成员 id 或名字）。
  final String? owner;
  final List<String> deps;
  final CollabTaskStage status;
  final String result;

  bool get isOpen => !status.isTerminal;

  CollabTaskItem copyWith({String? owner, CollabTaskStage? status, String? result, List<String>? deps}) =>
      CollabTaskItem(
        id: id,
        title: title,
        owner: owner ?? this.owner,
        deps: deps ?? this.deps,
        status: status ?? this.status,
        result: result ?? this.result,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    if (owner != null) 'owner': owner,
    if (deps.isNotEmpty) 'deps': deps,
    'status': status.name,
    if (result.isNotEmpty) 'result': result,
  };

  factory CollabTaskItem.fromJson(Map<String, Object?> json) => CollabTaskItem(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    owner: json['owner'] as String?,
    deps: [
      for (final dep in _asList(json['deps']))
        if (dep is String) dep,
    ],
    status: CollabTaskStage.values.firstWhere((s) => s.name == json['status'], orElse: () => CollabTaskStage.planning),
    result: json['result'] as String? ?? '',
  );
}

/// 一次任务的完整上下文。
final class CollabTaskContext {
  const CollabTaskContext({
    required this.id,
    required this.conversationId,
    required this.kind,
    required this.goal,
    this.sourceMessageIds = const [],
    this.excerpts = const {},
    this.repo,
    this.branch,
    this.credentialRef,
    this.memberIds = const [],
    this.items = const [],
    this.stage = CollabTaskStage.planning,
    this.currentStep = '',
    this.done = const [],
    this.pending = const [],
    this.testStatus = '',
    this.buildStatus = '',
    this.commitSha,
    this.runId,
    this.runUrl,
    this.artifactUrl,
    this.result = '',
    this.failure,
    required this.createdAt,
    required this.updatedAt,
    this.rev = 0,
  });

  /// 任务 id（与它所属的议会 runId / 团队 runId 同源，便于互查）。
  final String id;

  /// 父会话（普通聊天 / 议会 / 团队会话）的 id。
  final String conversationId;

  /// `council` / `team`。
  final String kind;

  /// 用户最终要的东西（一句话，取自这一问）。
  final String goal;

  /// 参考资料来自哪几条历史消息（能追回原文）。
  final List<String> sourceMessageIds;

  /// 那几条消息的原文摘录：messageId → 前若干字（不含凭据）。
  ///
  /// 「通过 messageId 找回原文」不必真去翻另一条会话：任务条展开时直接把
  /// 摘录摆出来，离线、跨页面、重启后都看得到。
  final Map<String, String> excerpts;

  /// 目标仓库（从用户给的文字里提取，未给则空）。
  final String? repo;

  /// 目标分支。
  final String? branch;

  /// 凭据的**引用**，绝不是凭据本身：一个键名/句柄，真正的密钥在安全存储里。
  final String? credentialRef;

  /// 参与了这件事的成员（席位 id / 队友 id）。
  final List<String> memberIds;

  /// 子任务与依赖（团队任务图的投影；议会为空）。
  final List<CollabTaskItem> items;

  final CollabTaskStage stage;

  /// 眼下这一步在做什么（给人看的一句话）。
  final String currentStep;

  /// 已经完成的（人话）。
  final List<String> done;

  /// 还没完成的（人话）。
  final List<String> pending;

  final String testStatus;

  /// 构建状态：只用 GitHub 真实结果填（「构建成功 / 构建失败 / 排队中 …」）。
  final String buildStatus;

  /// 提交到哪个 commit（真实 SHA）。
  final String? commitSha;

  /// 对应的 Actions run id 与链接。
  final int? runId;
  final String? runUrl;

  /// 产物下载链接（有产物时才有）。
  final String? artifactUrl;

  /// 最终结果（裁决首句 / 团队汇总）。
  final String result;

  final String? failure;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// 每次落盘 +1（跨进程比较新旧）。
  final int rev;

  int get openCount => items.where((item) => item.isOpen).length;

  String get progressLabel => items.isEmpty ? stage.label : '${stage.label} · ${items.length - openCount}/${items.length}';

  CollabTaskContext copyWith({
    String? conversationId,
    String? kind,
    String? goal,
    List<String>? sourceMessageIds,
    Map<String, String>? excerpts,
    String? repo,
    String? branch,
    String? credentialRef,
    List<String>? memberIds,
    List<CollabTaskItem>? items,
    CollabTaskStage? stage,
    String? currentStep,
    List<String>? done,
    List<String>? pending,
    String? testStatus,
    String? buildStatus,
    String? commitSha,
    int? runId,
    String? runUrl,
    String? artifactUrl,
    String? result,
    String? failure,
    DateTime? updatedAt,
    int? rev,
  }) => CollabTaskContext(
    id: id,
    conversationId: conversationId ?? this.conversationId,
    kind: kind ?? this.kind,
    goal: goal ?? this.goal,
    sourceMessageIds: sourceMessageIds ?? this.sourceMessageIds,
    excerpts: excerpts ?? this.excerpts,
    repo: repo ?? this.repo,
    branch: branch ?? this.branch,
    credentialRef: credentialRef ?? this.credentialRef,
    memberIds: memberIds ?? this.memberIds,
    items: items ?? this.items,
    stage: stage ?? this.stage,
    currentStep: currentStep ?? this.currentStep,
    done: done ?? this.done,
    pending: pending ?? this.pending,
    testStatus: testStatus ?? this.testStatus,
    buildStatus: buildStatus ?? this.buildStatus,
    commitSha: commitSha ?? this.commitSha,
    runId: runId ?? this.runId,
    runUrl: runUrl ?? this.runUrl,
    artifactUrl: artifactUrl ?? this.artifactUrl,
    result: result ?? this.result,
    failure: failure ?? this.failure,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    rev: rev ?? this.rev,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'conversationId': conversationId,
    'kind': kind,
    'goal': goal,
    if (sourceMessageIds.isNotEmpty) 'sourceMessageIds': sourceMessageIds,
    if (excerpts.isNotEmpty) 'excerpts': excerpts,
    if (repo != null) 'repo': repo,
    if (branch != null) 'branch': branch,
    if (credentialRef != null) 'credentialRef': credentialRef,
    if (memberIds.isNotEmpty) 'memberIds': memberIds,
    if (items.isNotEmpty) 'items': [for (final item in items) item.toJson()],
    'stage': stage.name,
    if (currentStep.isNotEmpty) 'currentStep': currentStep,
    if (done.isNotEmpty) 'done': done,
    if (pending.isNotEmpty) 'pending': pending,
    if (testStatus.isNotEmpty) 'testStatus': testStatus,
    if (buildStatus.isNotEmpty) 'buildStatus': buildStatus,
    if (commitSha != null) 'commitSha': commitSha,
    if (runId != null) 'runId': runId,
    if (runUrl != null) 'runUrl': runUrl,
    if (artifactUrl != null) 'artifactUrl': artifactUrl,
    if (result.isNotEmpty) 'result': result,
    if (failure != null) 'failure': failure,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'rev': rev,
  };

  /// 坏数据不炸启动：认不出的阶段当 planning，类型不对就当空。
  factory CollabTaskContext.fromJson(Map<String, Object?> json) => CollabTaskContext(
    id: json['id'] as String? ?? '',
    conversationId: json['conversationId'] as String? ?? '',
    kind: json['kind'] as String? ?? 'council',
    goal: json['goal'] as String? ?? '',
    sourceMessageIds: [
      for (final id in _asList(json['sourceMessageIds']))
        if (id is String && id.isNotEmpty) id,
    ],
    excerpts: {
      for (final entry in (json['excerpts'] is Map ? (json['excerpts'] as Map).entries : const <MapEntry>[]))
        if (entry.key is String && entry.value is String) '${entry.key}': entry.value as String,
    },
    repo: json['repo'] as String?,
    branch: json['branch'] as String?,
    credentialRef: json['credentialRef'] as String?,
    memberIds: [
      for (final id in _asList(json['memberIds']))
        if (id is String) id,
    ],
    items: [
      for (final item in _asList(json['items']))
        if (item is Map) CollabTaskItem.fromJson(item.cast<String, Object?>()),
    ],
    stage: CollabTaskStage.values.firstWhere(
      (s) => s.name == json['stage'],
      orElse: () => CollabTaskStage.planning,
    ),
    currentStep: json['currentStep'] as String? ?? '',
    done: [
      for (final line in _asList(json['done']))
        if (line is String) line,
    ],
    pending: [
      for (final line in _asList(json['pending']))
        if (line is String) line,
    ],
    testStatus: json['testStatus'] as String? ?? '',
    buildStatus: json['buildStatus'] as String? ?? '',
    commitSha: json['commitSha'] as String?,
    runId: (json['runId'] as num?)?.toInt(),
    runUrl: json['runUrl'] as String?,
    artifactUrl: json['artifactUrl'] as String?,
    result: json['result'] as String? ?? '',
    failure: json['failure'] as String?,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
    rev: (json['rev'] as num?)?.toInt() ?? 0,
  );
}

/// 从用户给的文字里提取仓库、分支、凭据引用。
///
/// 只认「明显是它」的写法，认不出就留空——宁可显示「未指定」，也不猜一个
/// 错误的仓库让人往别处提交。
abstract final class CollabTaskFacts {
  static final _repoUrl = RegExp(r'https?://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)');
  /// 没有完整 URL 时，只认「仓库」这类提示词旁边的 owner/repo。
  ///
  /// 裸的 `xxx/yyy` 不能当仓库：`docs/guide`、`lib/ui` 到处都是，猜错会让人
  /// 往别的仓库提交。
  static final _repoHinted = RegExp(
    r'(?:仓库|repo(?:sitory)?|github)\s*[:：=]?\s*[`"\x27]?([A-Za-z0-9_.-]{1,})/([A-Za-z0-9_.-]{2,})',
    caseSensitive: false,
  );
  static final _branch = RegExp(
    r'(?:分支|branch)\s*[:：=]?\s*[`"\x27]?([A-Za-z0-9._/-]{2,60})',
    caseSensitive: false,
  );
  static final _branchFlag = RegExp(r'--branch[= ]([A-Za-z0-9._/-]{2,60})');

  /// 仓库：优先完整 URL；其次是「仓库 owner/repo」这种带提示词的写法。
  static String? repo(String text) {
    final url = _repoUrl.firstMatch(text);
    if (url != null) {
      final name = url.group(2)!.replaceAll(RegExp(r'\.git$'), '');
      return '${url.group(1)}/$name';
    }
    final hinted = _repoHinted.firstMatch(text);
    if (hinted == null) return null;
    final owner = hinted.group(1)!;
    final name = hinted.group(2)!.replaceAll(RegExp(r'\.git$'), '');
    // 版本号、域名这类别当仓库名。
    if (owner.contains('.') || RegExp(r'^\d+$').hasMatch(owner)) return null;
    return '$owner/$name';
  }

  /// 分支：`分支 xxx` / `branch: xxx` / `--branch xxx`。
  static String? branch(String text) {
    final flag = _branchFlag.firstMatch(text);
    if (flag != null) return flag.group(1);
    final match = _branch.firstMatch(text);
    if (match == null) return null;
    final value = match.group(1)!;
    // 「分支」后面跟的不是名字（例如「分支是什么」）就别当分支。
    if (RegExp(r'^(是|什么|哪|怎么)').hasMatch(value)) return null;
    return value;
  }

  /// 凭据引用：只记「用哪个安全存储里的项」，绝不记密钥本身。
  static String? credentialRef(String text) {
    final ghToken = RegExp(r'\b(ghp_[A-Za-z0-9]{10,})').firstMatch(text);
    if (ghToken != null) return 'github.token';
    // Dart 的 RegExp 不认内联 (?i)：用 caseSensitive 开关。
    if (RegExp(r'github\s*(token|令牌|凭据)', caseSensitive: false).hasMatch(text)) return 'github.token';
    return null;
  }

  /// 从一段资料里一次性取出三项。
  static ({String? repo, String? branch, String? credentialRef}) scan(String text) => (
    repo: repo(text),
    branch: branch(text),
    credentialRef: credentialRef(text),
  );
}

/// 用资料包 + 这一问，给任务上下文打底。
CollabTaskContext collabTaskFromPack({
  required String id,
  required String conversationId,
  required String kind,
  required String goal,
  required CollabContextPack pack,
  List<String> memberIds = const [],
  List<CollabTaskItem> items = const [],
  DateTime? now,
}) {
  final text = [
    for (final message in pack.anchors) message.text,
    for (final message in pack.recent) if (message.role == CollabContextRole.user) message.text,
    goal,
  ].join('\n');
  final facts = CollabTaskFacts.scan(text);
  final at = now ?? DateTime.now();
  return CollabTaskContext(
    excerpts: collabTaskExcerpts(pack),
    id: id,
    conversationId: conversationId,
    kind: kind,
    goal: goal,
    sourceMessageIds: pack.sourceMessageIds,
    repo: facts.repo,
    branch: facts.branch,
    credentialRef: facts.credentialRef,
    memberIds: memberIds,
    items: items,
    createdAt: at,
    updatedAt: at,
  );
}

/// 发送前的自检结果（方案第一部分 · 7 错误分类）。
final class CollabTaskPreflight {
  const CollabTaskPreflight({this.blocking, this.notes = const []});

  /// 必须拦下、并且说清楚缺什么的一句话（null = 可以发）。
  final String? blocking;

  /// 不拦，但要让用户知道的一句提醒。
  final List<String> notes;

  bool get isEmpty => blocking == null && notes.isEmpty;
}

/// 用户这句话是不是在用「上面 / 前面 / 刚才 / 之前 / 那个方案」指代。
bool collabGoalRefersBack(String text) => RegExp(
  r'(上面|前面|刚才|之前|此前|那个方案|这份方案|该方案|这套方案|上一条)',
).hasMatch(text);

/// 这句话是不是**要求去做**（而不是随口带了个「之前」）。
///
/// 「切走之前的那一问」也会命中「之前」，但那不是在指代任务资料——只看指代
/// 词就拦，会把普通提问一起挡掉。所以还要有动作或对象：
/// 「按 / 照 / 根据 / 执行 / 做 / 改 / 继续 / 完成」或者「方案 / 要求 / 计划 / 任务」。
bool collabGoalAsksToAct(String text) =>
    RegExp(r'(按|照|根据|依据|执行|照做|做|改|修|继续|完成|落地|实现|推进|开始)').hasMatch(text) ||
    RegExp(r'(方案|要求|计划|任务|资料|步骤)').hasMatch(text);

/// 发送前检查：指代有没有资料、要提交有没有仓库与凭据。
///
/// 这一步存在的意义：用户说「按前面那个方案做」而资料其实在**另一条**会话里时，
/// 发出去只会得到「本次消息没有具体事项」。与其让成员空转，不如当场说清楚。
CollabTaskPreflight collabTaskPreflight({
  required String goal,
  required CollabContextPack pack,
  String? repo,
  String? credentialRef,
}) {
  final refers = collabGoalRefersBack(goal);
  // 三个条件同时成立才拦：在指代、确实是要干活、而且这句话很短（长句通常
  // 自带上下文，不需要拦）。
  final acts = collabGoalAsksToAct(goal);
  final brief = goal.trim().length <= 60;
  if (refers && acts && brief && pack.isEmpty) {
    return const CollabTaskPreflight(
      blocking: '你说的「上面 / 前面」在这次对话里没有找到对应内容。'
          '它可能在另一条聊天里：把那段方案贴进来，或先在聊天里说完再让成员做。',
    );
  }
  final notes = <String>[];
  final wantsShip = RegExp(r'(提交|push|推送|构建|Actions|发版|出包|APK)', caseSensitive: false).hasMatch(goal);
  if (wantsShip && repo == null) {
    notes.add('没找到目标仓库：要给一个 github 链接，或「仓库 owner/repo」。');
  }
  if (wantsShip && repo != null && credentialRef == null) {
    notes.add('没找到 GitHub 凭据：提交与构建会停在权限这一步。');
  }
  return CollabTaskPreflight(notes: notes);
}

/// 每条资料消息留一段摘录（最多 3 条、每条 200 字），凭据先抹掉。
///
/// 任务是给人看的「这件事」：展开时看到原话，比看到一个编号有用；
/// 编号仍留着，需要精确回溯时还能对回会话。
Map<String, String> collabTaskExcerpts(CollabContextPack pack, {int max = 3, int chars = 200}) {
  final out = <String, String>{};
  for (final message in [...pack.anchors, ...pack.recent]) {
    if (out.length >= max) break;
    if (message.role != CollabContextRole.user) continue;
    final text = _redactSecrets(message.text).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) continue;
    out[message.id] = text.length <= chars ? text : '${text.substring(0, chars)}…';
  }
  return out;
}

/// 抹掉可能出现的令牌/密钥（摘录会显示在界面上）。
String _redactSecrets(String text) => text
    .replaceAll(RegExp(r'gh[pousr]_[A-Za-z0-9]{10,}'), '<已隐去>')
    .replaceAll(RegExp(r'github_pat_[A-Za-z0-9_]{20,}'), '<已隐去>')
    .replaceAll(RegExp(r'(?<=[Bb]earer\s)[A-Za-z0-9._-]{20,}'), '<已隐去>');

/// 任务上下文的落盘仓库：一个任务一个文件，原子写。
class CollabTaskStore {
  CollabTaskStore(this.root);

  final Directory root;

  Directory get _dir => Directory('${root.path}/collab/tasks');

  File _file(String id) => File('${_dir.path}/$id.json');

  Future<void> save(CollabTaskContext task) async {
    await _dir.create(recursive: true);
    final tmp = File('${_dir.path}/${task.id}.json.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(task.toJson()), flush: true);
    await tmp.rename(_file(task.id).path);
  }

  Future<CollabTaskContext?> load(String id) async {
    final file = _file(id);
    if (!file.existsSync()) return null;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return null;
      return CollabTaskContext.fromJson(raw.cast<String, Object?>());
    } on Object {
      // 坏文件当没有：任务还能从会话记录里重建。
      return null;
    }
  }

  Future<List<CollabTaskContext>> list() async {
    if (!_dir.existsSync()) return const [];
    final out = <CollabTaskContext>[];
    for (final entity in _dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final raw = jsonDecode(await entity.readAsString());
        if (raw is Map) out.add(CollabTaskContext.fromJson(raw.cast<String, Object?>()));
      } on Object {
        continue;
      }
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  Future<void> delete(String id) async {
    final file = _file(id);
    if (file.existsSync()) await file.delete();
  }
}

/// 应用支持目录下的任务仓库（懒加载）。
final collabTaskRootProvider = FutureProvider<Directory>((ref) async {
  final support = await getApplicationSupportDirectory();
  return support;
});

/// 内存里的任务表：视图读它、编排写它；每个任务单独落盘。
final collabTaskProvider =
    NotifierProvider<CollabTaskNotifier, Map<String, CollabTaskContext>>(CollabTaskNotifier.new);

class CollabTaskNotifier extends Notifier<Map<String, CollabTaskContext>> {
  CollabTaskStore? _store;
  bool _loaded = false;

  @override
  Map<String, CollabTaskContext> build() {
    // 冷启动把盘上的任务读回来：切走再回来、隔天说「继续」都靠它。
    unawaited(_load());
    return const {};
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await ref.read(collabTaskRootProvider.future);
      _store = CollabTaskStore(dir);
      final tasks = await _store!.list();
      if (tasks.isEmpty) return;
      state = {...state, for (final task in tasks) task.id: task};
    } on Object {
      // 读不到不影响用：新任务照常记录。
    }
  }

  /// 新建或更新一个任务；返回落盘后的那一份。
  Future<CollabTaskContext> upsert(CollabTaskContext task) async {
    final previous = state[task.id];
    final next = task.copyWith(updatedAt: DateTime.now(), rev: (previous?.rev ?? task.rev) + 1);
    state = {...state, next.id: next};
    _store ??= await _openStore();
    try {
      await _store?.save(next);
    } on Object {
      // 写不了只影响重启后恢复，界面照旧。
    }
    return next;
  }

  /// 只改已有任务；不存在就忽略（启动晚于事件时不会凭空造一条）。
  Future<void> patch(String id, CollabTaskContext Function(CollabTaskContext current) mutate) async {
    final current = state[id];
    if (current == null) return;
    await upsert(mutate(current));
  }

  Future<CollabTaskStore?> _openStore() async {
    if (_store != null) return _store;
    try {
      _store = CollabTaskStore(await ref.read(collabTaskRootProvider.future));
    } on Object {
      _store = null;
    }
    return _store;
  }

  Future<void> remove(String id) async {
    state = {...state}..remove(id);
    _store ??= await _openStore();
    try {
      await _store?.delete(id);
    } on Object {
      // 同上。
    }
  }
}

/// 宽容地读一个列表字段：坏数据（字符串、null、对象）一律当空，
/// 不让一条坏记录把整份任务读废弃。
List<Object?> _asList(Object? value) => value is List ? value : const <Object?>[];
