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
import '../team/team_store.dart';

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
  });

  factory CouncilTurn.fromJson(Map<String, Object?> json) => CouncilTurn(
    runId: json['runId'] as String? ?? '',
    question: json['question'] as String? ?? '',
    at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
    phase: json['phase'] as String?,
    summary: json['summary'] as String?,
  );

  final String runId;
  final String question;
  final DateTime at;

  /// 运行走到哪一步（[CollabPhase.name]）；历史列表据此显示「进行中」。
  final String? phase;

  /// 裁决的第一句（历史列表的副标题）。
  final String? summary;

  bool get running => phase != null && !_isTerminal(phase!);

  static bool _isTerminal(String phase) =>
      phase == CollabPhase.done.name || phase == CollabPhase.cancelled.name || phase == CollabPhase.failed.name;

  CouncilTurn copyWith({String? phase, String? summary}) => CouncilTurn(
    runId: runId,
    question: question,
    at: at,
    phase: phase ?? this.phase,
    summary: summary ?? this.summary,
  );

  Map<String, Object?> toJson() => {
    'runId': runId,
    'question': question,
    'at': at.toIso8601String(),
    'phase': ?phase,
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
  final DateTime createdAt;
  final DateTime updatedAt;

  String get displayTitle {
    final t = title.trim();
    if (t.isNotEmpty) return t;
    if (turns.isNotEmpty) return turns.first.question;
    return '新议会';
  }

  bool get running => turns.any((t) => t.running);

  CouncilConversation copyWith({
    String? title,
    List<SeatSpec>? seats,
    CollabMode? mode,
    String? chairId,
    List<CouncilTurn>? turns,
    DateTime? updatedAt,
  }) => CouncilConversation(
    id: id,
    title: title ?? this.title,
    seats: seats ?? this.seats,
    mode: mode ?? this.mode,
    chairId: chairId ?? this.chairId,
    turns: turns ?? this.turns,
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
    await _write({...state, conversation.id: conversation});
    return conversation;
  }

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
    this.running = false,
  });

  final String id;
  final CollabKind kind;
  final String title;
  final String subtitle;
  final int memberCount;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool running;

  String get memberLabel => kind == CollabKind.council ? '$memberCount 位参会模型' : '$memberCount 位队友';
}

/// 全部协作会话（议会 + 团队），最近更新的在前。
final collabHistoryProvider = FutureProvider<List<CollabHistoryEntry>>((ref) async {
  final council = ref.watch(councilConversationsProvider).values.toList();
  final teams = await ref.watch(teamStoreProvider.future).then((store) => store.list());
  return [
    for (final conversation in council)
      CollabHistoryEntry(
        id: conversation.id,
        kind: CollabKind.council,
        title: conversation.displayTitle,
        subtitle: conversation.turns.lastOrNull?.summary ?? '议会',
        memberCount: conversation.seats.length,
        createdAt: conversation.createdAt,
        updatedAt: conversation.updatedAt,
        running: conversation.running,
      ),
    for (final team in teams)
      CollabHistoryEntry(
        id: team.id,
        kind: CollabKind.team,
        title: team.displayTitle,
        subtitle: team.messages.isEmpty ? '团队' : team.previewText,
        memberCount: team.teammates.length,
        createdAt: team.createdAt,
        updatedAt: team.updatedAt,
        running: team.running.isNotEmpty,
      ),
  ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
});

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
