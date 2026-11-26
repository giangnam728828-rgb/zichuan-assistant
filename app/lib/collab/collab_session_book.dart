// 协作会话登记：议会席位与团队队友的会话是普通顶层会话（Host 不会把它们
// 标成 subagent），不登记就会一条条冒进历史列表——点进去只看到一段段莫名其
// 妙的提示词。这里记住每个会话属于哪次协作、叫什么名字：历史列表据此过滤，
// 协作页据此显示「打开对话」。
//
// 落盘 <应用支持目录>/collab/sessions.json：进程重启后仍然认得这些会话，
// 不会在列表里重新冒出来。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// 这条会话是谁建的。
enum CollabSessionKind { council, team }

final class CollabSessionOwner {
  const CollabSessionOwner({
    required this.sessionId,
    required this.kind,
    required this.ownerId,
    required this.label,
    this.parentLabel,
  });

  factory CollabSessionOwner.fromJson(Map<String, Object?> json) => CollabSessionOwner(
    sessionId: json['sessionId'] as String? ?? '',
    kind: CollabSessionKind.values.firstWhere(
      (kind) => kind.name == json['kind'],
      orElse: () => CollabSessionKind.council,
    ),
    ownerId: json['ownerId'] as String? ?? '',
    label: json['label'] as String? ?? '',
    parentLabel: json['parentLabel'] as String?,
  );

  final String sessionId;
  final CollabSessionKind kind;

  /// 议会的 runId / 团队的 teamId。
  final String ownerId;

  /// 席位名（模型名）或队友名。
  final String label;

  /// 议会议题 / 团队的第一句话：历史里作副标题。
  final String? parentLabel;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'kind': kind.name,
    'ownerId': ownerId,
    'label': label,
    'parentLabel': ?parentLabel,
  };
}

/// 一个刚开出来的协作会话：编排器开完会话就回调，页面登记进 [CollabSessionBook]。
typedef CollabSessionInfo = ({String sessionId, String label, String ownerId, String? parentLabel});

/// 一张登记表的落盘：一条会话一行，整体原子替换。
final class CollabSessionBook {
  CollabSessionBook(this.root);

  /// 存放登记表的目录（通常是 <应用支持目录>/collab）。
  final Directory root;

  File get file => File('${root.path}/sessions.json');

  Future<Map<String, CollabSessionOwner>> load() async {
    if (!await file.exists()) return const {};
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return const {};
      final sessions = json['sessions'];
      if (sessions is! Map) return const {};
      return {
        for (final entry in sessions.entries)
          if (entry.value is Map)
            '${entry.key}': CollabSessionOwner.fromJson((entry.value as Map).cast<String, Object?>()),
      };
    } on FormatException {
      // 半截文件当作没有：历史列表照常显示，别让启动流程崩。
      return const {};
    }
  }

  Future<void> save(Map<String, CollabSessionOwner> owners) async {
    await root.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'version': 1,
        'sessions': {
          for (final entry in owners.entries) entry.key: entry.value.toJson(),
        },
      }),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}

/// 内存里的登记表；[build] 先给空表，随后异步把盘上的合并进来。
class CollabSessionBookNotifier extends Notifier<Map<String, CollabSessionOwner>> {
  CollabSessionBook? _book;
  Completer<void>? _ready;

  /// 盘上的登记表读完（或读失败）之后完成。历史列表等它，避免内部会话
  /// 先冒出来、随后才被过滤掉的闪现。
  Future<void> get ready => (_ready ??= Completer<void>()).future;

  @override
  Map<String, CollabSessionOwner> build() {
    unawaited(_restore());
    return const {};
  }

  Future<CollabSessionBook> _open() async {
    final existing = _book;
    if (existing != null) return existing;
    return _book = CollabSessionBook(await ref.read(collabSessionRootProvider)());
  }

  Future<void> _restore() async {
    try {
      final loaded = await (await _open()).load();
      if (loaded.isNotEmpty) {
        // 已登记过的（本次运行刚建的新会话）优先。
        state = {...loaded, ...state};
      }
    } on Object {
      // 读不出来不算错：只是折叠不了历史列表里的旧会话。
    } finally {
      final ready = _ready;
      if (ready != null && !ready.isCompleted) ready.complete();
    }
  }

  /// 登记一条；内容没变就不写盘。
  Future<void> register(CollabSessionOwner owner) => registerAll([owner]);

  Future<void> registerAll(Iterable<CollabSessionOwner> owners) async {
    final next = {...state};
    var changed = false;
    for (final owner in owners) {
      if (owner.sessionId.isEmpty) continue;
      final current = next[owner.sessionId];
      if (current != null &&
          current.kind == owner.kind &&
          current.ownerId == owner.ownerId &&
          current.label == owner.label &&
          current.parentLabel == owner.parentLabel) {
        continue;
      }
      next[owner.sessionId] = owner;
      changed = true;
    }
    if (changed) await _write(next);
  }

  Future<void> forget(String sessionId) async {
    if (!state.containsKey(sessionId)) return;
    await _write({...state}..remove(sessionId));
  }

  Future<void> _write(Map<String, CollabSessionOwner> next) async {
    state = next;
    try {
      await (await _open()).save(next);
    } on Object {
      // 写不了只影响下次启动：本次运行的历史列表仍然是对的。
    }
  }
}

/// 登记表放在哪个目录（测试替换成临时目录）。
final collabSessionRootProvider = Provider<Future<Directory> Function()>((ref) {
  return () async => Directory('${(await getApplicationSupportDirectory()).path}/collab');
});

final collabSessionBookProvider =
    NotifierProvider<CollabSessionBookNotifier, Map<String, CollabSessionOwner>>(CollabSessionBookNotifier.new);

/// 历史列表用：这条会话是不是某次协作的内部会话。
final collabSessionFilterProvider = Provider<bool Function(String)>((ref) {
  final owners = ref.watch(collabSessionBookProvider);
  return (sessionId) => owners.containsKey(sessionId);
});
