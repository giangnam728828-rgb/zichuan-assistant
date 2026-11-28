// 协作会话身份：议会与团队不再是「问一次就散」的页面，而是各自独立的聊天。
//
// 议会的一次聊天（[CouncilConversation]）由多个回合（[CouncilTurn]）组成：
// 每个回合就是一次 [CollabRun]（各席位作答 + 主席综合）。回合之间复用同一
// 批席位的子会话，所以第二轮天然带着第一轮的上下文；换成员只影响后续回合。
//
// 团队的会话状态本来就是一条群聊（[TeamState]），这里只补一个标题字段与
// 统一的历史索引（[CollabHistoryEntry]）。
//
// 落盘：
//   <应用支持目录>/council/conversations.json   议会会话（含成员与回合目录）
//   <应用支持目录>/team/<teamId>.json             团队会话（原样）
//
// 与 [CollabSessionBook] 的分工：那边登记「哪条 Host 会话属于哪次协作」，
// 用来把席位的子会话从历史里折起来；这边记的是协作自己这条会话。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../council/collab_models.dart';
import '../team/team_models.dart';
import 'collab_export.dart';
import 'collab_runtime.dart';
import 'seat_sessions.dart';
import '../team/team_store.dart';
import '../team/team_tasks.dart';

/// 协作会话的种类：议会 / 团队。
enum CollabKind { council, team }

/// 议会的一个回合：一次提问 + 它对应的运行。
final class CouncilTurn {
  const CouncilTurn({
    required this.runId,
    required this.question,
    required this.at,
    this.phase,
    this.summary,
    this.failure,
  });

  factory CouncilTurn.fromJson(Map<String, Object?> json) => CouncilTurn(
    runId: json['runId'] as String? ?? '',
    question: json['question'] as String? ?? '',
    at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
    phase: json['phase'] as String?,
    summary: json['summary'] as String?,
    failure: json['failure'] as String?,
  );

  final String runId;
  final String question;
  final DateTime at;

  /// 运行走到哪一步（[CollabPhase.name]）；历史列表据此显示「进行中」。
  final String? phase;

  /// 裁决的第一句（历史列表的副标题）。
  final String? summary;

  /// 这一轮失败/取消的真实原因：历史里能点开看，不再只剩一句「失败」。
  final String? failure;

  bool get running => phase != null && !_isTerminal(phase!);

  static bool _isTerminal(String phase) =>
      phase == CollabPhase.done.name || phase == CollabPhase.cancelled.name || phase == CollabPhase.failed.name;

  CouncilTurn copyWith({String? phase, String? summary, String? failure}) => CouncilTurn(
    runId: runId,
    question: question,
    at: at,
    phase: phase ?? this.phase,
    summary: summary ?? this.summary,
    failure: failure ?? this.failure,
  );

  Map<String, Object?> toJson() => {
    'runId': runId,
    'question': question,
    'at': at.toIso8601String(),
    'phase': ?phase,
    if (failure != null) 'failure': failure,
    'summary': ?summary,
  };
}

/// 一次议会聊天：成员配置 + 回合列表。
final class CouncilConversation {
  const CouncilConversation({
    required this.id,
    required this.seats,
    required this.turns,
    required this.createdAt,
    required this.updatedAt,
    this.title = '',
    this.mode = CollabMode.quick,
    this.chairId,
    this.seatSessions = const SeatSessions(),
  });

  factory CouncilConversation.fromJson(Map<String, Object?> json) => CouncilConversation(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    seats: [
      for (final s in (json['seats'] as List? ?? const []))
        if (s is Map) SeatSpec.fromJson(s.cast<String, Object?>()),
    ],
    mode: CollabMode.values.firstWhere(
      (m) => m.name == json['mode'],
      orElse: () => CollabMode.quick,
    ),
    chairId: json['chairId'] as String?,
    turns: [
      for (final t in (json['turns'] as List? ?? const []))
        if (t is Map) CouncilTurn.fromJson(t.cast<String, Object?>()),
    ],
    // 席位子会话的归属边界（v4.3 · P0-A · 2.5）：只在本条会话内复用。
    seatSessions: SeatSessions.fromJson(json['seatSessions']),
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
  );

  final String id;

  /// 空标题显示「新议会」；第一次提问后自动取议题。
  final String title;

  /// 当前成员配置（2 到 6 位）。每次提问都从这里取，改了只影响之后的回合。
  final List<SeatSpec> seats;
  final CollabMode mode;

  /// 主席席位；空则用第一位。
  final String? chairId;

  final List<CouncilTurn> turns;

  /// 各席位在本条会话里的子会话（带父会话 + 席位 + 模型边界）。
  ///
  /// 新建一条议会只继承成员配置，绝不继承另一条议会的 sessionId。
  final SeatSessions seatSessions;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get displayTitle {
    final t = title.trim();
    if (t.isNotEmpty) return t;
    if (turns.isNotEmpty) return turns.first.question;
    return '新议会';
  }

  bool get running => turns.any((t) => t.running);

  /// 有没有**真正**问过一次。
  ///
  /// 历史列表只显示真正产生过对话的议会：刚建好、只配了成员的空议会不占
  /// 位置。空议会的成员配置、草稿、模式记忆仍然保留，只是不列进历史。
  bool get hasUserQuestion => turns.any((turn) => turn.question.trim().isNotEmpty);

  CouncilConversation copyWith({
    String? title,
    List<SeatSpec>? seats,
    CollabMode? mode,
    String? chairId,
    List<CouncilTurn>? turns,
    SeatSessions? seatSessions,
    DateTime? updatedAt,
  }) => CouncilConversation(
    id: id,
    title: title ?? this.title,
    seats: seats ?? this.seats,
    mode: mode ?? this.mode,
    chairId: chairId ?? this.chairId,
    turns: turns ?? this.turns,
    seatSessions: seatSessions ?? this.seatSessions,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'seats': [for (final s in seats) s.toJson()],
    'mode': mode.name,
    'chairId': ?chairId,
    'turns': [for (final t in turns) t.toJson()],
    if (seatSessions.bySeat.isNotEmpty) 'seatSessions': seatSessions.toJson(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };
}

/// 议会会话的落盘：一份 JSON，整体原子替换。
class CouncilConversationStore {
  CouncilConversationStore(this.root);

  final Directory root;

  File get file => File('${root.path}/conversations.json');

  Future<Map<String, CouncilConversation>> load() async {
    if (!await file.exists()) return const {};
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return const {};
      final all = json['conversations'];
      if (all is! Map) return const {};
      return {
        for (final entry in all.entries)
          if (entry.value is Map)
            '${entry.key}': CouncilConversation.fromJson((entry.value as Map).cast<String, Object?>()),
      };
    } on FormatException {
      // 半截文件当作没有：会话目录还在，最多丢标题。
      return const {};
    }
  }

  Future<void> save(Map<String, CouncilConversation> all) async {
    await root.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'version': 1,
        'conversations': {for (final e in all.entries) e.key: e.value.toJson()},
      }),
      flush: true,
    );
    await tmp.rename(file.path);
  }

  /// 删掉一次议会：会话记录 + 它的运行目录。
  Future<void> delete(String id) async {
    final dir = Directory('${root.path}/runs/$id');
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

/// 应用支持目录（测试替换成临时目录）。
final appSupportDirProvider = Provider<Future<Directory> Function()>((ref) => getApplicationSupportDirectory);

/// 议会目录：运行与会话记录都放这里。
final councilRootProvider = Provider<Future<Directory> Function()>((ref) {
  return () async {
    final support = await ref.read(appSupportDirProvider)();
    return Directory('${support.path}/council');
  };
});

/// 团队目录：每个团队一个 JSON。
final teamRootProvider = Provider<Future<Directory> Function()>((ref) {
  return () async {
    final support = await ref.read(appSupportDirProvider)();
    return Directory('${support.path}/team');
  };
});

final teamStoreProvider = FutureProvider<TeamStore>((ref) async => TeamStore(await ref.read(teamRootProvider)()));

final councilStoreProvider = FutureProvider<CouncilConversationStore>(
  (ref) async => CouncilConversationStore(await ref.read(councilRootProvider)()),
);

/// 议会会话登记表：先给空表，随后异步把盘上的合并进来。
class CouncilConversationsNotifier extends Notifier<Map<String, CouncilConversation>> {
  CouncilConversationStore? _opened;
  Completer<void>? _ready;

  /// 盘上的旧会话读完了才 resolve：打开历史会话前要等它，否则会误建新会话。
  Future<void> get ready => (_ready ??= Completer<void>()).future;

  Future<CouncilConversationStore> _store() async {
    final existing = _opened;
    if (existing != null) return existing;
    _opened = await ref.read(councilStoreProvider.future);
    return _opened!;
  }

  @override
  Map<String, CouncilConversation> build() {
    unawaited(_restore());
    return const {};
  }

  Future<void> _restore() async {
    try {
      final loaded = await (await _store()).load();
      if (loaded.isNotEmpty) {
        // 本次运行刚建的优先。
        state = {...loaded, ...state};
      }
    } on Object {
      // 读不出来不算错：最多少几条历史。
    } finally {
      final ready = _ready;
      if (ready != null && !ready.isCompleted) ready.complete();
    }
  }

  /// 新建一条议会会话：成员从 [seats] 复制（不是共享同一份列表）。
  Future<CouncilConversation> create({
    required List<SeatSpec> seats,
    CollabMode mode = CollabMode.quick,
    String? chairId,
  }) async {
    final conversation = createLocal(seats: seats, mode: mode, chairId: chairId);
    await flush();
    return conversation;
  }

  /// 本地即时创建（方案 8.2）：同步进内存表，第一帧就能显示；落盘交给
  /// [flush]，由调用方在后台做一次并处理失败。快速连续切换不会重复建：
  /// 每次调用只生成一个 id，状态里按 id 去重。
  CouncilConversation createLocal({
    required List<SeatSpec> seats,
    CollabMode mode = CollabMode.quick,
    String? chairId,
  }) {
    final now = DateTime.now();
    final conversation = CouncilConversation(
      id: 'conv${now.microsecondsSinceEpoch.toRadixString(36)}',
      seats: List.unmodifiable(seats.map(_cloneSeat)),
      mode: mode,
      chairId: chairId,
      turns: const [],
      createdAt: now,
      updatedAt: now,
    );
    state = {...state, conversation.id: conversation};
    return conversation;
  }

  /// 把当前表完整落盘一次；失败抛给调用方（界面要显示明确的保存错误）。
  Future<void> flush() async => (await _store()).save(state);

  /// 存一条（改成员、加回合、改标题都走这里）。
  Future<CouncilConversation> save(CouncilConversation conversation) async {
    final next = conversation.copyWith(updatedAt: DateTime.now());
    await _write({...state, next.id: next});
    return next;
  }

  Future<void> remove(String id) async {
    final next = {...state}..remove(id);
    await _write(next);
    try {
      await (await _store()).delete(id);
    } on Object {
      // 运行目录删不掉不影响会话记录已经没了。
    }
  }

  /// 最近一条议会（新会话默认沿用它的成员配置）。
  CouncilConversation? latest() {
    CouncilConversation? newest;
    for (final conversation in state.values) {
      if (newest == null || conversation.updatedAt.isAfter(newest.updatedAt)) newest = conversation;
    }
    return newest;
  }

  Future<void> _write(Map<String, CouncilConversation> next) async {
    state = next;
    try {
      await (await _store()).save(next);
    } on Object {
      // 写不了只影响下次启动。
    }
  }
}

SeatSpec _cloneSeat(SeatSpec seat) => SeatSpec(
  id: seat.id,
  provider: seat.provider,
  model: seat.model,
  role: seat.role,
  reasoningEffort: seat.reasoningEffort,
  label: seat.label,
  agentPreset: seat.agentPreset,
);

final councilConversationsProvider =
    NotifierProvider<CouncilConversationsNotifier, Map<String, CouncilConversation>>(
      CouncilConversationsNotifier.new,
    );

/// 一条协作会话在历史里的运行状态。
///
/// 不能只看 `TeamState.running`：那只是「本进程此刻在飞的队友」，落盘更新
/// 可能把它清空，而任务图里还有 running/pending 的任务。判断要综合
/// 会话状态 + 任务图 + 议会回合，才不会把还在跑的会话标成「已结束」。
enum CollabRunStatus {
  /// 有未完成的运行（正在跑，或进程被杀后可以接着跑）。
  running,

  /// 可以恢复：运行没到终态，但当前没有活动请求。
  recoverable,

  done,
  failed,
  cancelled;

  String get label => switch (this) {
    CollabRunStatus.running => '进行中',
    CollabRunStatus.recoverable => '可恢复',
    CollabRunStatus.done => '已完成',
    CollabRunStatus.failed => '已失败',
    CollabRunStatus.cancelled => '已取消',
  };
}

/// 历史列表里的一条协作会话。
final class CollabHistoryEntry {
  const CollabHistoryEntry({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.memberCount,
    required this.createdAt,
    required this.updatedAt,
    this.status = CollabRunStatus.done,
    this.failure,
    this.lastQuestion = '',
    this.lastAnswer = '',
  });

  final String id;
  final CollabKind kind;
  final String title;
  final String subtitle;
  final int memberCount;
  final DateTime createdAt;
  final DateTime updatedAt;
  final CollabRunStatus status;

  /// 失败/取消的原因（历史里能点开看）。
  final String? failure;

  /// 最近一条用户消息/问题（长按详情面板用）。
  final String lastQuestion;

  /// 最近一次回答的首段（长按详情面板用）。
  final String lastAnswer;

  /// 正在跑（列表里画转圈）。
  bool get running => status == CollabRunStatus.running;

  /// 有「继续」入口。
  bool get resumable => status == CollabRunStatus.running || status == CollabRunStatus.recoverable;

  String get memberLabel => kind == CollabKind.council ? '$memberCount 位参会模型' : '$memberCount 位队友';
}

/// 全部协作会话（议会 + 团队），最近更新的在前。
final collabHistoryProvider = FutureProvider<List<CollabHistoryEntry>>((ref) async {
  // 议会：会话记录本身就是状态来源（回合里存着 phase）。
  final council = ref.watch(councilConversationsProvider).values.toList();
  final teams = await ref.watch(teamStoreProvider.future).then((store) => store.list());
  return [
    // v4.3 · P0-F：只列**真正产生过对话**的会话。空议会/空团队仍然保留
    // （成员配置、草稿、模式记忆都在），只是不占历史列表的位置。
    for (final conversation in council)
      if (conversation.hasUserQuestion)
        CollabHistoryEntry(
          id: conversation.id,
          kind: CollabKind.council,
          title: conversation.displayTitle,
          subtitle: conversation.turns.lastOrNull?.summary ?? '议会',
          memberCount: conversation.seats.length,
          createdAt: conversation.createdAt,
          updatedAt: conversation.updatedAt,
          status: _councilStatus(conversation),
          failure: conversation.turns.lastOrNull?.failure,
          lastQuestion: conversation.turns.lastOrNull?.question ?? '',
          lastAnswer: conversation.turns.lastOrNull?.summary ?? '',
        ),
    for (final team in teams)
      if (team.hasUserMessage)
        CollabHistoryEntry(
          id: team.id,
          kind: CollabKind.team,
          title: team.displayTitle,
          subtitle: team.messages.isEmpty ? '团队' : team.previewText,
          memberCount: team.teammates.length,
          createdAt: team.createdAt,
          updatedAt: team.updatedAt,
          status: teamHistoryStatus(team),
          failure: team.run?.note,
          lastQuestion: _lastUserText(team),
          lastAnswer: _lastMateText(team),
        ),
  ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
});

/// 团队里最近一条用户发言（详情面板用）。
String _lastUserText(TeamState team) {
  for (final message in team.messages.reversed) {
    if (message.role == TeamMsgRole.user && message.text.trim().isNotEmpty) return message.text.trim();
  }
  return '';
}

/// 团队里最近一条队友回答（详情面板用）。
String _lastMateText(TeamState team) {
  for (final message in team.messages.reversed) {
    if (message.role != TeamMsgRole.teammate) continue;
    if (message.text.trim().isEmpty) continue;
    final text = message.text.trim();
    return text.length <= 240 ? text : '${text.substring(0, 240)}…';
  }
  return '';
}

/// 议会的历史状态：最近一个回合的 phase 说了算。
CollabRunStatus _councilStatus(CouncilConversation conversation) {
  final turn = conversation.turns.lastOrNull;
  if (turn == null) return CollabRunStatus.done;
  final phase = CollabPhase.values.firstWhere((p) => p.name == turn.phase, orElse: () => CollabPhase.done);
  if (phase.isTerminal) {
    return switch (phase) {
      CollabPhase.failed => CollabRunStatus.failed,
      CollabPhase.cancelled => CollabRunStatus.cancelled,
      _ => CollabRunStatus.done,
    };
  }
  // 回合记着「还在跑」：正在跑；否则是上次被打断、可以接着跑。
  return turn.running ? CollabRunStatus.running : CollabRunStatus.recoverable;
}

/// 团队的历史状态：会话的 running 只是「此刻在飞的人」，不能单独作数。
/// 综合任务图（run）与任务状态，才能区分进行中 / 可恢复 / 终态。
CollabRunStatus teamHistoryStatus(TeamState team) {
  // 1) 本进程确有队友在飞：肯定在进行中。
  if (team.running.isNotEmpty) return CollabRunStatus.running;
  final run = team.run;
  if (run == null) return CollabRunStatus.done;
  // 2) 任务图没到终态：有开放任务就是可恢复（进程重启后 resumeRun 会补跑）。
  if (!run.isTerminal) {
    return run.tasks.any((task) => task.isOpen) ? CollabRunStatus.recoverable : CollabRunStatus.running;
  }
  return switch (run.status) {
    TeamRunStatus.done => CollabRunStatus.done,
    TeamRunStatus.failed => CollabRunStatus.failed,
    TeamRunStatus.cancelled => CollabRunStatus.cancelled,
    _ => CollabRunStatus.recoverable,
  };
}

/// 「团队」/「议会」：历史行与详情面板共用的一份文案。
String collabKindLabel(CollabKind kind) => kind == CollabKind.council ? '议会' : '团队';

/// 重命名一条协作会话（历史抽屉长按 → 重命名）。
///
/// 团队优先走共享编排器：它持有内存快照，直接写盘会被下一次 load 覆盖。
Future<void> renameCollabEntry(WidgetRef ref, CollabHistoryEntry entry, String title) async {
  final next = title.trim();
  if (next.isEmpty) return;
  if (entry.kind == CollabKind.council) {
    final conversation = ref.read(councilConversationsProvider)[entry.id];
    if (conversation == null) return;
    await ref.read(councilConversationsProvider.notifier).save(conversation.copyWith(title: next));
  } else {
    final orchestrator = sharedTeamOrchestrator;
    if (orchestrator != null) {
      await orchestrator.rename(entry.id, next);
    } else {
      final store = await ref.read(teamStoreProvider.future);
      final team = await store.load(entry.id);
      if (team == null) return;
      await store.save(team.copyWith(title: next, updatedAt: DateTime.now()));
    }
  }
  ref.invalidate(collabHistoryProvider);
}

/// 一条协作会话的 Markdown（长按 → 导出 Markdown）。
Future<String> collabMarkdownFor(WidgetRef ref, CollabHistoryEntry entry) async {
  if (entry.kind == CollabKind.team) {
    final store = await ref.read(teamStoreProvider.future);
    final team = await store.load(entry.id);
    if (team != null) return team.toMarkdown();
  } else {
    final conversation = ref.read(councilConversationsProvider)[entry.id];
    if (conversation != null) return councilConversationMarkdown(conversation);
  }
  // 记录已经不在盘上：至少把历史里已知的内容导出去，不假装成功。
  return [
    '# ${collabKindLabel(entry.kind)} · ${entry.title}',
    '',
    '- 创建：${collabStamp(entry.createdAt)}',
    '- 最近更新：${collabStamp(entry.updatedAt)}',
    '- 成员：${entry.memberCount}',
    '- 状态：${entry.status.label}',
    if (entry.lastQuestion.isNotEmpty) '',
    if (entry.lastQuestion.isNotEmpty) '## 最近的提问',
    if (entry.lastQuestion.isNotEmpty) entry.lastQuestion,
    if (entry.lastAnswer.isNotEmpty) '',
    if (entry.lastAnswer.isNotEmpty) '## 最近的回答',
    if (entry.lastAnswer.isNotEmpty) entry.lastAnswer,
  ].join('\n');
}

/// 继续一条没跑完的协作会话（详情面板上的「继续运行」）。
///
/// 用的是同一个编排器实例与同一个运行 id：不新建、不重发用户原问题。
Future<bool> resumeCollabEntry(WidgetRef ref, CollabHistoryEntry entry) async {
  if (entry.kind == CollabKind.team) {
    final orchestrator = sharedTeamOrchestrator;
    if (orchestrator == null) return false;
    final state = await orchestrator.resumeRun(entry.id);
    ref.invalidate(collabHistoryProvider);
    return state != null;
  }
  final orchestrator = sharedCouncilOrchestrator;
  if (orchestrator == null) return false;
  final conversation = ref.read(councilConversationsProvider)[entry.id];
  final runId = conversation?.turns.reversed
      .where((turn) => turn.runId.isNotEmpty)
      .map((turn) => turn.runId)
      .firstOrNull;
  if (runId == null) return false;
  final run = await orchestrator.resume(runId);
  ref.invalidate(collabHistoryProvider);
  return run != null;
}

/// 删除一条协作会话：只删它自己，别的会话不动。
Future<void> deleteCollabEntry(WidgetRef ref, CollabHistoryEntry entry) async {
  if (entry.kind == CollabKind.council) {
    await ref.read(councilConversationsProvider.notifier).remove(entry.id);
  } else {
    final store = await ref.read(teamStoreProvider.future);
    await store.delete(entry.id);
  }
  ref.invalidate(collabHistoryProvider);
}
