// 任务上下文包（议会 / 团队共用）。
//
// 用户的一次性交代往往很长：完整方案、仓库地址、执行要求、验收标准。这些
// 内容留在**普通聊天**的历史里。切换到议会/团队后，用户的下一句常常只是
// 「按前面那一大段方案执行」「用刚才那个仓库」「继续完成剩下的」——
// 只把最后一句交给成员，成员当然看不出要做什么。
//
// 这里做两件事：
// 1. 从会话历史里**检索**出该带上的内容：一两条「资料型」的长消息（方案、
//    要求）作为锚点，加上最近几轮对话；而不是简单砍掉最前面的消息。
// 2. 把它们排成一段稳定的提示词块（带消息编号，可回溯原文），随议题一起
//    交给成员；同时记下 sourceMessageIds，任务记录里能指回是哪几条消息。
//
// 预算有限（手机端上下文没那么宽裕），所以：锚点优先、单条裁剪、总数封顶；
// 被裁掉/丢弃的数量记在 [dropped] 里，界面可以据此提示「资料太长，已裁剪」。

import 'dart:convert';

/// 历史消息的角色（只区分「用户说的」和「助手说的」）。
enum CollabContextRole { user, assistant, system }

/// 一条可被引用的历史消息。
///
/// [id] 必须稳定（同一会话里同一条消息每次都是同一个 id），
/// 这样任务记录里的 `sourceMessageIds` 才追得回原文。
final class CollabContextMessage {
  const CollabContextMessage({required this.id, required this.text, required this.role, this.at});

  final String id;
  final String text;
  final CollabContextRole role;

  /// 发生时间；没有也可以（按传入顺序排）。
  final DateTime? at;

  bool get isEmpty => text.trim().isEmpty;

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'role': role.name,
    if (at case final at?) 'at': at.toIso8601String(),
  };

  factory CollabContextMessage.fromJson(Map<String, Object?> json) => CollabContextMessage(
    id: json['id'] as String? ?? '',
    text: json['text'] as String? ?? '',
    role: CollabContextRole.values.firstWhere(
      (role) => role.name == json['role'],
      orElse: () => CollabContextRole.user,
    ),
    at: DateTime.tryParse(json['at'] as String? ?? ''),
  );
}

/// 一次任务要带上的上下文：锚点（早期的资料型消息）+ 最近几轮。
final class CollabContextPack {
  const CollabContextPack({
    this.anchors = const [],
    this.recent = const [],
    this.dropped = 0,
    this.truncated = false,
  });

  /// 任务资料的锚点：用户早期给出的方案、要求、仓库信息。
  final List<CollabContextMessage> anchors;

  /// 最近几轮对话（按时间从早到晚）。
  final List<CollabContextMessage> recent;

  /// 因为预算被整体丢弃的消息条数（不是被裁剪）。
  final int dropped;

  /// 有没有单条被裁剪（资料太长）。
  final bool truncated;

  /// 默认字符预算：手机端单轮提示词的实测舒适区，约 4K 汉字。
  static const defaultBudget = 12000;

  /// 多长算「资料型」消息：一句话的提问不需要当锚点。
  static const anchorMinChars = 240;

  /// 单条锚点最多留多少字。
  static const anchorMaxChars = 4000;

  /// 单条近期消息最多留多少字。
  static const recentMaxChars = 1200;

  bool get isEmpty => anchors.isEmpty && recent.isEmpty;

  /// 这段上下文用到的历史消息编号（写进任务记录，能追回原文）。
  List<String> get sourceMessageIds {
    final seen = <String>[];
    for (final message in [...anchors, ...recent]) {
      final id = message.id;
      if (id.isNotEmpty && !seen.contains(id)) seen.add(id);
    }
    return seen;
  }

  /// 交给成员的提示词块；空上下文返回空串（不占 bulletin）。
  String get promptBlock {
    if (isEmpty) return '';
    final buffer = StringBuffer()
      ..writeln('【此前的对话资料】')
      ..writeln('下面是用户在此前的消息里给出的原文（带消息编号）。');
    if (anchors.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('· 任务资料');
      for (final message in anchors) {
        buffer
          ..writeln('[#${message.id}] ${_roleLabel(message.role)}：')
          ..writeln(_clip(message.text, anchorMaxChars))
          ..writeln();
      }
    }
    if (recent.isNotEmpty) {
      buffer.writeln('· 最近几轮');
      for (final message in recent) {
        buffer
          ..writeln('[#${message.id}] ${_roleLabel(message.role)}：')
          ..writeln(_clip(message.text, recentMaxChars))
          ..writeln();
      }
    }
    buffer
      ..writeln('【如何用这些资料】')
      ..writeln('- 当前提问若用「上面 / 前面 / 刚才 / 之前 / 那个方案 / 继续」等说法，指的就是上面的内容。')
      ..writeln('- 资料里已经写明的仓库、分支、要求、验收标准直接采用，不要让用户再贴一遍。')
      ..writeln('- 资料与当前提问冲突时，以当前提问为准；缺的只有资料里也没有的东西才需要问。');
    return buffer.toString().trimRight();
  }

  static String _roleLabel(CollabContextRole role) => switch (role) {
    CollabContextRole.user => '用户',
    CollabContextRole.assistant => '助手',
    CollabContextRole.system => '系统',
  };

  static String _clip(String text, int limit) {
    final body = text.trim();
    if (body.length <= limit) return body;
    return '${body.substring(0, limit)}\n…（后 ${body.length - limit} 字已省略）';
  }

  /// 从历史里挑出该带上的内容。
  ///
  /// - [history] 按时间从早到晚（乱序也可以，给了 [CollabContextMessage.at]
  ///   就按时间排）。
  /// - [currentText] 是这一次要发送的话：它可能已经写进历史，别重复带一份。
  static CollabContextPack build({
    required List<CollabContextMessage> history,
    String? currentText,
    int maxAnchors = 3,
    int maxRecent = 6,
    int budget = defaultBudget,
  }) {
    final cleaned = <CollabContextMessage>[];
    for (final message in history) {
      final text = message.text.trim();
      if (text.isEmpty) continue;
      // 纯工具输出/占位的系统提示不带（它们对新任务没有信息量）。
      if (message.role == CollabContextRole.system && text.length < anchorMinChars) continue;
      cleaned.add(
        CollabContextMessage(id: message.id, text: text, role: message.role, at: message.at),
      );
    }
    final current = currentText?.trim() ?? '';
    if (current.isNotEmpty && cleaned.isNotEmpty && cleaned.last.text.trim() == current) {
      cleaned.removeLast();
    }
    if (cleaned.isEmpty) return const CollabContextPack();

    // 最近的几轮先占位；它们表达的是「用户刚说到哪了」。
    final recentStart = cleaned.length > maxRecent ? cleaned.length - maxRecent : 0;
    final recent = cleaned.sublist(recentStart);
    final earlier = cleaned.sublist(0, recentStart);

    // 锚点：早期的用户消息里，最长的那几条就是方案/要求本身。
    // 长消息优先（方案不会只有一句话），同长度时取更早的，最后按时间排回来。
    final candidates = <({int index, CollabContextMessage message})>[
      for (var i = 0; i < earlier.length; i++)
        if (earlier[i].role == CollabContextRole.user && earlier[i].text.length >= anchorMinChars)
          (index: i, message: earlier[i]),
    ];
    candidates.sort((a, b) {
      final byLength = b.message.text.length.compareTo(a.message.text.length);
      if (byLength != 0) return byLength;
      return a.index.compareTo(b.index);
    });
    final picked = candidates.take(maxAnchors).toList()..sort((a, b) => a.index.compareTo(b.index));
    final anchors = [for (final entry in picked) entry.message];

    // 预算：锚点先拿，单条裁剪；剩下的给最近几轮，装不下就从最旧的开始丢。
    var remaining = budget;
    var truncated = false;
    final keptAnchors = <CollabContextMessage>[];
    for (final message in anchors) {
      if (remaining <= 0) break;
      final limit = remaining < anchorMaxChars ? remaining : anchorMaxChars;
      final body = message.text.length > limit ? message.text.substring(0, limit) : message.text;
      if (body.length != message.text.length) truncated = true;
      remaining -= body.length;
      keptAnchors.add(
        CollabContextMessage(id: message.id, text: body, role: message.role, at: message.at),
      );
    }
    var dropped = anchors.length - keptAnchors.length;
    final keptRecent = <CollabContextMessage>[];
    for (final message in recent.reversed) {
      final limit = remaining < recentMaxChars ? remaining : recentMaxChars;
      if (limit <= 0) {
        dropped++;
        continue;
      }
      final body = message.text.length > limit ? message.text.substring(0, limit) : message.text;
      if (body.length != message.text.length) truncated = true;
      remaining -= body.length;
      keptRecent.insert(0, CollabContextMessage(id: message.id, text: body, role: message.role, at: message.at));
    }
    if (keptAnchors.isEmpty && keptRecent.isEmpty) return const CollabContextPack();

    return CollabContextPack(
      anchors: List.unmodifiable(keptAnchors),
      recent: List.unmodifiable(keptRecent),
      dropped: dropped,
      truncated: truncated,
    );
  }

  Map<String, Object?> toJson() => {
    'anchors': [for (final m in anchors) m.toJson()],
    'recent': [for (final m in recent) m.toJson()],
    'dropped': dropped,
    'truncated': truncated,
  };

  factory CollabContextPack.fromJson(Map<String, Object?> json) {
    List<CollabContextMessage> list(Object? value) => [
      for (final item in (value as List? ?? const []))
        if (item is Map) CollabContextMessage.fromJson(item.cast<String, Object?>()),
    ];
    return CollabContextPack(
      anchors: list(json['anchors']),
      recent: list(json['recent']),
      dropped: (json['dropped'] as num?)?.toInt() ?? 0,
      truncated: json['truncated'] as bool? ?? false,
    );
  }

  @override
  String toString() =>
      'CollabContextPack(anchors: ${anchors.length}, recent: ${recent.length}, '
      'dropped: $dropped, truncated: $truncated)';
}

/// 给界面看的一句话：这次带上了多少资料。
String collabContextSummary(CollabContextPack pack) {
  if (pack.isEmpty) return '没有带上此前的资料';
  final parts = <String>[
    if (pack.anchors.isNotEmpty) '${pack.anchors.length} 段资料',
    if (pack.recent.isNotEmpty) '最近 ${pack.recent.length} 条消息',
  ];
  final tail = pack.truncated ? '（已裁剪）' : '';
  return '已带上${parts.join('、')}$tail';
}

/// 把任意对象转成可落盘的 JSON 字符串（测试与调试用）。
String collabContextToJsonString(CollabContextPack pack) => jsonEncode(pack.toJson());
