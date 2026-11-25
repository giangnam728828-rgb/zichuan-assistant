// 协作会话的审批收件箱：议会席位、团队队友的授权请求都在这里认人。
//
// 子会话的审批卡原本只在自己那个会话里看得到；协作页把落在本页席位/队友
// 身上的请求接住，标明是谁在申请，并让用户就地拒绝或允许一次。

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

/// 一条等用户处理的协作审批。
class CollabApproval {
  const CollabApproval({required this.eventId, required this.label, required this.request});

  final String eventId;

  /// 发起人的显示名：席位名或队友名。
  final String label;
  final ApprovalRequest request;
}

/// 按会话认人的审批收件箱。
///
/// [labelOf] 返回空表示这个会话不属于本页，直接忽略；[respond] 负责把决定
/// 送回 Host。多个请求按到达顺序排着，页面逐条显示即可（天然是队列）。
class CollabApprovalInbox {
  CollabApprovalInbox({
    required Stream<HostEvent> events,
    required String? Function(String sessionId) labelOf,
    required Future<void> Function(ApprovalRequest request, ApprovalDecision decision) respond,
    Iterable<HostEvent> pending = const [],
    this.onChanged,
  }) : _labelOf = labelOf,
       _respond = respond {
    // 打开页面时已经挂着的请求（通知点进来、重连、重开页面）也要接住：
    // Host 只在请求发生时推一次，不会重放给后来订阅的人。
    var seeded = false;
    for (final event in pending) {
      if (_fill(event)) seeded = true;
    }
    _sub = events.listen((event) {
      if (_fill(event)) onChanged?.call();
    });
    if (seeded) onChanged?.call();
  }

  final String? Function(String sessionId) _labelOf;
  final Future<void> Function(ApprovalRequest request, ApprovalDecision decision) _respond;

  /// 增删一条时回调（页面据此刷新）。
  final void Function()? onChanged;

  final Map<String, CollabApproval> _pending = {};
  StreamSubscription<HostEvent>? _sub;

  /// 等处理的审批，按到达顺序。
  List<CollabApproval> get pending => List.unmodifiable(_pending.values);

  CollabApproval? byEvent(String eventId) => _pending[eventId];

  /// 收下一条事件；有变化返回 true。
  bool _fill(HostEvent event) {
    if (event is ApprovalRequestedEvent) {
      final request = event.request;
      final label = _labelOf(request.sessionId);
      if (label == null) return false;
      _pending[request.eventId] = CollabApproval(eventId: request.eventId, label: label, request: request);
      return true;
    }
    if (event is HostRequestCancelledEvent) {
      return _pending.remove(event.eventId) != null;
    }
    return false;
  }

  /// 回答一条审批；先把它从列表里拿掉，失败由页面自己报错。
  Future<void> decide(String eventId, ApprovalDecision decision) async {
    final entry = _pending.remove(eventId);
    if (entry == null) return;
    onChanged?.call();
    await _respond(entry.request, decision);
  }

  void dispose() {
    unawaited(_sub?.cancel());
    _sub = null;
    _pending.clear();
  }
}
