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
    this.readOnly = false,
    this.agentPreset,
  });

  factory Teammate.fromJson(Map<String, Object?> json) => Teammate(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    brief: json['brief'] as String? ?? '',
    provider: json['provider'] as String? ?? '',
    model: json['model'] as String? ?? '',
    reasoningEffort: json['reasoningEffort'] as String?,
    readOnly: json['readOnly'] as bool? ?? false,
    agentPreset: json['agentPreset'] as String?,
  );

  /// 稳定 id（`mate-<时间戳>`），消息里的发言人指向它。
  final String id;
  final String name;

  /// 角色说明：拼进这位队友每次收到消息时的前置提示。
  final String brief;
  final String provider;
  final String model;
  final String? reasoningEffort;

  /// 只读顾问：只出主意、不动手（不改文件、不跑有副作用的命令）。
  /// 团队里可以留一位可写的人，其余都设只读，避免同时改同一份代码。
  final bool readOnly;

  /// Agent 预设（决定这个队友能用哪些工具，例如联网）；空表示 Host 默认。
  final String? agentPreset;

  Teammate copyWith({
    String? name,
    String? brief,
    String? provider,
    String? model,
    String? reasoningEffort,
    bool? readOnly,
    String? agentPreset,
  }) => Teammate(
    id: id,
    name: name ?? this.name,
    brief: brief ?? this.brief,
    provider: provider ?? this.provider,
    model: model ?? this.model,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    readOnly: readOnly ?? this.readOnly,
    agentPreset: agentPreset ?? this.agentPreset,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'brief': brief,
    'provider': provider,
    'model': model,
    'reasoningEffort': ?reasoningEffort,
    if (readOnly) 'readOnly': true,
    'agentPreset': ?agentPreset,
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
    this.handoffTo,
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
    handoffTo: json['handoffTo'] as String?,
  );

  final String id;
  final TeamMsgRole role;
  final String? teammateId;
  final String text;
  final DateTime at;
  final bool failed;

  /// 这条答复把活交给了谁（队友 id）。非空时界面上是一张移交卡。
  final String? handoffTo;

  Map<String, Object?> toJson() => {
    'id': id,
    'role': role.name,
    'teammateId': ?teammateId,
    'text': text,
    'at': at.toIso8601String(),
    'failed': failed,
    'handoffTo': ?handoffTo,
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
    this.leadId,
    this.wakeMinutes,
    this.wakePrompt = defaultWakePrompt,
    this.exclusiveWrite = true,
    this.running = const [],
    required this.createdAt,
    required this.updatedAt,
    this.rev = 0,
  });

  /// 定时唤醒默认说什么。
  static const defaultWakePrompt = '继续推进，汇报一下现在的进展。';

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
    leadId: json['leadId'] as String?,
    wakeMinutes: (json['wakeMinutes'] as num?)?.toInt(),
    wakePrompt: json['wakePrompt'] as String? ?? defaultWakePrompt,
    exclusiveWrite: json['exclusiveWrite'] as bool? ?? true,
    running: [
      for (final id in (json['running'] as List? ?? const []))
        if (id is String && id.isNotEmpty) id,
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

  /// 主管（可选）：没点名时先由他接，他可以 @ 队友把活分下去。
  final String? leadId;

  /// 每隔几分钟自动催一次（null 表示不催）。落盘，重启后接着催。
  final int? wakeMinutes;

  /// 定时唤醒时发的那句话。
  final String wakePrompt;

  /// 可写的队友是否排队执行（默认开）：同一时刻只让一个人动文件，
  /// 免得两位队友同时改同一份代码。只读顾问不受影响，照常并行。
  final bool exclusiveWrite;

  /// 正在跑的队友 id（按开始顺序）。每次开始/结束都落盘，重开页面还能
  /// 看到「谁在做」；进程重启后由编排器清掉（那已经不是在跑了）。
  final List<String> running;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 每次落盘 +1。
  final int rev;

  /// 主管队友；没设或已离开就是 null。
  Teammate? get lead {
    final id = leadId;
    return id == null ? null : mate(id);
  }

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
    String? leadId,
    bool clearLead = false,
    int? wakeMinutes,
    bool clearWake = false,
    String? wakePrompt,
    bool? exclusiveWrite,
    List<String>? running,
    DateTime? updatedAt,
    int? rev,
  }) => TeamState(
    id: id,
    teammates: teammates ?? this.teammates,
    sessions: sessions ?? this.sessions,
    cursors: cursors ?? this.cursors,
    messages: messages ?? this.messages,
    leadId: clearLead ? null : (leadId ?? this.leadId),
    wakeMinutes: clearWake ? null : (wakeMinutes ?? this.wakeMinutes),
    wakePrompt: wakePrompt ?? this.wakePrompt,
    exclusiveWrite: exclusiveWrite ?? this.exclusiveWrite,
    running: running ?? this.running,
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
    'leadId': ?leadId,
    'wakeMinutes': ?wakeMinutes,
    if (wakePrompt != defaultWakePrompt) 'wakePrompt': wakePrompt,
    if (!exclusiveWrite) 'exclusiveWrite': false,
    if (running.isNotEmpty) 'running': running,
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

/// 移交指令所在的那一行：`移交 @名字` / `交给：名字` / `转交 @名字`。
final _handoffLine = RegExp(r'^\s*(?:移交|交给|转交)\s*[:：]?\s*@?\s*(.+?)\s*[。.]?\s*$');

/// 从队友的答复里认出「移交给谁」。
///
/// 只认**最后两行**里的移交指令——正文中间提到「交给阿蓝」通常是叙述，不是
/// 真要把活交出去；放在末尾单独一行才是明确的交付。认不出（或名字对不上
/// 队友）就原样返回，当作普通答复。
({String text, String? toId}) parseHandoff(List<Teammate> mates, String raw) {
  final trimmed = raw.trimRight();
  if (trimmed.isEmpty) return (text: '', toId: null);
  final lines = trimmed.split('\n');
  for (var i = lines.length - 1; i >= 0 && i >= lines.length - 2; i--) {
    final match = _handoffLine.firstMatch(lines[i]);
    if (match == null) continue;
    final name = match.group(1)!.trim();
    Teammate? target;
    for (final mate in mates) {
      if (mate.name.toLowerCase() == name.toLowerCase()) {
        target = mate;
        break;
      }
    }
    if (target == null) continue;
    final rest = [...lines.sublist(0, i), ...lines.sublist(i + 1)].join('\n').trim();
    return (text: rest, toId: target.id);
  }
  return (text: trimmed, toId: null);
}

/// 在正文里找所有 `@名字`（主管分派用）。排除 [exceptId]（一般不点名自己）。
///
/// 与 [parseMentions] 不同：那个只剥开头的前缀（用户在点名），这个扫全文
/// （主管在正文里分派）。名字后必须是边界，避免「@阿蓝蓝」误命中「阿蓝」。
List<Teammate> parseAssignments(List<Teammate> mates, String text, {String? exceptId}) {
  final out = <Teammate>[];
  for (final mate in mates) {
    if (mate.id == exceptId) continue;
    final pattern = RegExp(
      '@${RegExp.escape(mate.name)}(?![\\w\\u4e00-\\u9fa5])',
      caseSensitive: false,
    );
    if (pattern.hasMatch(text)) out.add(mate);
  }
  return out;
}
