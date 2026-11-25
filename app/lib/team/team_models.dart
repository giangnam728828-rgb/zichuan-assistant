// 团队（C4）的数据层：队友、群聊消息、一次团队会话的完整状态。
//
// 与议会不同，团队是持久的：队友有名字、角色说明和固定模型，群聊记录
// 随每条消息落盘；每个队友背后是一个独立的子会话（sessionId 记下来，
// 恢复时沿用，不重建）。

/// 一个队友：名字、角色说明、所用模型。
final class Teammate {
  const Teammate({
    required this.id,
    required this.name,
    this.brief = '',
    required this.provider,
    required this.model,
    this.reasoningEffort,
  });

  factory Teammate.fromJson(Map<String, Object?> json) => Teammate(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    brief: json['brief'] as String? ?? '',
    provider: json['provider'] as String? ?? '',
    model: json['model'] as String? ?? '',
    reasoningEffort: json['reasoningEffort'] as String?,
  );

  /// 稳定 id（`mate-<时间戳>`），消息里的发言人指向它。
  final String id;
  final String name;

  /// 角色说明：拼进这位队友每次收到消息时的前置提示。
  final String brief;
  final String provider;
  final String model;
  final String? reasoningEffort;

  Teammate copyWith({String? name, String? brief, String? provider, String? model}) => Teammate(
    id: id,
    name: name ?? this.name,
    brief: brief ?? this.brief,
    provider: provider ?? this.provider,
    model: model ?? this.model,
    reasoningEffort: reasoningEffort,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'brief': brief,
    'provider': provider,
    'model': model,
    'reasoningEffort': ?reasoningEffort,
  };
}

/// 群聊里一条消息的发出者。
enum TeamMsgRole { user, teammate, system }

final class TeamMsg {
  const TeamMsg({
    required this.id,
    required this.role,
    this.teammateId,
    required this.text,
    required this.at,
    this.failed = false,
  });

  factory TeamMsg.fromJson(Map<String, Object?> json) => TeamMsg(
    id: json['id'] as String? ?? '',
    role: TeamMsgRole.values.firstWhere(
      (r) => r.name == json['role'],
      orElse: () => TeamMsgRole.system,
    ),
    teammateId: json['teammateId'] as String?,
    text: json['text'] as String? ?? '',
    at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
    failed: json['failed'] as bool? ?? false,
  );

  final String id;
  final TeamMsgRole role;
  final String? teammateId;
  final String text;
  final DateTime at;
  final bool failed;

  Map<String, Object?> toJson() => {
    'id': id,
    'role': role.name,
    'teammateId': ?teammateId,
    'text': text,
    'at': at.toIso8601String(),
    'failed': failed,
  };
}

/// 一次团队会话的完整状态（落盘就是它）。
final class TeamState {
  const TeamState({
    required this.id,
    required this.teammates,
    this.sessions = const {},
    this.cursors = const {},
    this.messages = const [],
    required this.createdAt,
    required this.updatedAt,
    this.rev = 0,
  });

  factory TeamState.fromJson(Map<String, Object?> json) => TeamState(
    id: json['id'] as String? ?? '',
    teammates: [
      for (final t in (json['teammates'] as List? ?? const []))
        if (t is Map) Teammate.fromJson(t.cast<String, Object?>()),
    ],
    sessions: {
      for (final e in (json['sessions'] as Map? ?? const {}).entries) '${e.key}': e.value as String?,
    },
    cursors: {
      for (final e in (json['cursors'] as Map? ?? const {}).entries)
        '${e.key}': (e.value as num?)?.toInt() ?? 0,
    },
    messages: [
      for (final m in (json['messages'] as List? ?? const []))
        if (m is Map) TeamMsg.fromJson(m.cast<String, Object?>()),
    ],
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
    rev: (json['rev'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final List<Teammate> teammates;

  /// teammateId → 子会话 id；第一次发消息时创建，之后一直复用。
  final Map<String, String?> sessions;

  /// teammateId → 已经看过 [messages] 的第几条（群聊上下文的增量游标）。
  /// 队友各有一个独立会话，别人的发言靠这个游标补进去，不重复复读。
  final Map<String, int> cursors;
  final List<TeamMsg> messages;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 每次落盘 +1。
  final int rev;

  Teammate? mate(String id) {
    for (final mate in teammates) {
      if (mate.id == id) return mate;
    }
    return null;
  }

  /// 按名字找队友（@ 点名用，大小写不敏感）。
  Teammate? mateNamed(String name) {
    for (final mate in teammates) {
      if (mate.name.toLowerCase() == name.toLowerCase()) return mate;
    }
    return null;
  }

  /// 按子会话 id 反查队友：审批卡、通知横幅靠它标明「这是谁在请求授权」。
  Teammate? mateBySession(String sessionId) {
    for (final entry in sessions.entries) {
      if (entry.value == sessionId) return mate(entry.key);
    }
    return null;
  }

  TeamState copyWith({
    List<Teammate>? teammates,
    Map<String, String?>? sessions,
    Map<String, int>? cursors,
    List<TeamMsg>? messages,
    DateTime? updatedAt,
    int? rev,
  }) => TeamState(
    id: id,
    teammates: teammates ?? this.teammates,
    sessions: sessions ?? this.sessions,
    cursors: cursors ?? this.cursors,
    messages: messages ?? this.messages,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    rev: rev ?? this.rev,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'teammates': [for (final t in teammates) t.toJson()],
    'sessions': sessions,
    'cursors': cursors,
    'messages': [for (final m in messages) m.toJson()],
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'rev': rev,
  };

  /// 群聊导出的 Markdown（C6 的「导出」先给团队用）。
  String toMarkdown() {
    final buffer = StringBuffer('# 团队会话\n');
    for (final msg in messages) {
      final who = switch (msg.role) {
        TeamMsgRole.user => '我',
        TeamMsgRole.teammate => mate(msg.teammateId ?? '')?.name ?? '队友',
        TeamMsgRole.system => '系统',
      };
      buffer
        ..writeln()
        ..writeln('**$who**：')
        ..writeln(msg.text);
    }
    return buffer.toString();
  }
}

/// 队友名字在团队里唯一，空名字补成「队友 N」。
List<Teammate> normalizeTeammates(List<Teammate> mates) {
  final seen = <String>{};
  final out = <Teammate>[];
  for (var i = 0; i < mates.length; i++) {
    var name = mates[i].name.trim();
    if (name.isEmpty) name = '队友 ${i + 1}';
    var unique = name;
    var n = 2;
    while (!seen.add(unique.toLowerCase())) {
      unique = '$name $n';
      n++;
    }
    out.add(mates[i].copyWith(name: unique));
  }
  return out;
}

/// 从一条消息里解析 @ 点名；返回 (目标队友, 去掉前缀的正文)。
/// 没有任何 @ 命中时目标是全体（返回空列表）。
({List<Teammate> targets, String text}) parseMentions(List<Teammate> mates, String raw) {
  var text = raw.trim();
  final targets = <Teammate>[];
  // 反复剥离开头的 @名字（允许连续点名多个）。
  var matched = true;
  while (matched) {
    matched = false;
    for (final mate in mates) {
      final prefix = '@${mate.name}';
      if (text.toLowerCase().startsWith(prefix.toLowerCase())) {
        final rest = text.substring(prefix.length);
        if (rest.isEmpty || rest.startsWith(' ') || rest.startsWith('，') || rest.startsWith(',')) {
          targets.add(mate);
          text = rest.replaceFirst(RegExp(r'^[\s，,]+'), '').trim();
          matched = true;
          break;
        }
      }
    }
  }
  return (targets: targets, text: text.isEmpty ? raw.trim() : text);
}
