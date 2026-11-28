// 议会席位子会话的归属边界（v4.3 · P0-A · 2.5）。
//
// 同一场议会连续讨论不同问题时，复用成员自己的子会话是**允许**的：成员要记得
// 刚才说过什么。但复用必须带上父会话边界，否则就会出现这些错：
// - 另一条议会/团队的子会话被当成当前成员的会话；
// - 换了成员或换了模型，还接着用旧成员的会话（人格与模型都对不上）；
// - 新建议会继承了旧议会的对话内容。
//
// 所以这里不再「按 seatId 相同就复用」，而是明确要求
// `conversationId + seatId + provider + model + sessionId` 五元组全部对得上。
// 纯数据、可序列化，随会话记录一起落盘。

import '../council/collab_models.dart';

/// 一个席位在某条议会会话里的子会话绑定。
final class SeatSessionBinding {
  const SeatSessionBinding({
    required this.conversationId,
    required this.seatId,
    required this.provider,
    required this.model,
    required this.sessionId,
  });

  factory SeatSessionBinding.fromJson(Map<String, Object?> json) => SeatSessionBinding(
    conversationId: json['conversationId'] as String? ?? '',
    seatId: json['seatId'] as String? ?? '',
    provider: json['provider'] as String? ?? '',
    model: json['model'] as String? ?? '',
    sessionId: json['sessionId'] as String? ?? '',
  );

  /// 这条子会话所属的议会主会话。
  final String conversationId;
  final String seatId;
  final String provider;
  final String model;
  final String sessionId;

  bool get isUsable =>
      conversationId.isNotEmpty && seatId.isNotEmpty && sessionId.isNotEmpty && model.isNotEmpty;

  /// 能不能拿来当 [seat] 在这一轮的种子会话。
  ///
  /// 父会话换了、席位换了、模型换了（provider 或 model 任一不同）都不能复用：
  /// 那已经不是「同一个成员记得刚才说过什么」，而是别人家的上下文。
  bool matchesSeat({
    required String conversationId,
    required SeatSpec seat,
  }) {
    if (!isUsable) return false;
    if (this.conversationId != conversationId) return false;
    if (seatId != seat.id) return false;
    if (provider != seat.provider) return false;
    if (model != seat.model) return false;
    return true;
  }

  Map<String, Object?> toJson() => {
    'conversationId': conversationId,
    'seatId': seatId,
    'provider': provider,
    'model': model,
    'sessionId': sessionId,
  };

  @override
  String toString() => 'SeatSessionBinding($conversationId/$seatId/$provider/$model/$sessionId)';
}

/// 一条议会会话里各席位的子会话表（seatId → 绑定）。
final class SeatSessions {
  const SeatSessions([this.bySeat = const {}]);

  factory SeatSessions.fromJson(Object? value) {
    if (value is! Map) return const SeatSessions();
    final map = <String, SeatSessionBinding>{};
    for (final entry in value.entries) {
      if (entry.value is! Map) continue;
      final binding = SeatSessionBinding.fromJson((entry.value as Map).cast<String, Object?>());
      if (binding.sessionId.isEmpty) continue;
      map['${entry.key}'] = binding;
    }
    return SeatSessions(map);
  }

  /// 按 seatId 索引。
  final Map<String, SeatSessionBinding> bySeat;

  bool get isEmpty => bySeat.isEmpty;

  /// 取给 [seat] 用的种子会话；对不上（换会话/换模型/换人）就是 null。
  String? seedFor({required String conversationId, required SeatSpec seat}) {
    final binding = bySeat[seat.id];
    if (binding == null) return null;
    return binding.matchesSeat(conversationId: conversationId, seat: seat) ? binding.sessionId : null;
  }

  /// 这一轮可用的种子表（只包含对得上的席位）。
  Map<String, String> seedsFor({required String conversationId, required List<SeatSpec> seats}) {
    final seeds = <String, String>{};
    for (final seat in seats) {
      final sessionId = seedFor(conversationId: conversationId, seat: seat);
      if (sessionId != null) seeds[seat.id] = sessionId;
    }
    return seeds;
  }

  /// 记下某一席这一轮真正用的会话（同时把该席位过期的绑定替换掉）。
  SeatSessions record({required String conversationId, required SeatSpec seat, required String sessionId}) {
    if (sessionId.isEmpty || conversationId.isEmpty) return this;
    return SeatSessions({
      ...bySeat,
      seat.id: SeatSessionBinding(
        conversationId: conversationId,
        seatId: seat.id,
        provider: seat.provider,
        model: seat.model,
        sessionId: sessionId,
      ),
    });
  }

  /// 成员被移除：连它的绑定一起清掉，避免以后同 id 复用别人的会话。
  SeatSessions without(Set<String> seatIds) {
    if (seatIds.isEmpty) return this;
    return SeatSessions({
      for (final entry in bySeat.entries)
        if (!seatIds.contains(entry.key)) entry.key: entry.value,
    });
  }

  Map<String, Object?> toJson() => {for (final entry in bySeat.entries) entry.key: entry.value.toJson()};
}
