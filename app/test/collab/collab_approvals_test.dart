// 协作审批收件箱：按 sessionId 认人，增减、回答、撤下都要对。

import 'dart:async';

import 'package:dsh_app/collab/collab_approvals.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

ApprovalRequest _request(String eventId, String sessionId, {String tool = 'shell'}) => ApprovalRequest(
  eventId: eventId,
  sessionId: sessionId,
  toolName: tool,
  reason: '要跑一条命令',
);

void main() {
  late StreamController<HostEvent> events;
  late List<({String eventId, ApprovalDecision decision})> answered;
  late int changes;
  late CollabApprovalInbox inbox;

  setUp(() {
    events = StreamController<HostEvent>.broadcast();
    answered = [];
    changes = 0;
    inbox = CollabApprovalInbox(
      events: events.stream,
      labelOf: (sessionId) => switch (sessionId) {
        'sess-a' => '阿蓝',
        'sess-b' => '小镜',
        _ => null,
      },
      respond: (request, decision) async => answered.add((eventId: request.eventId, decision: decision)),
      onChanged: () => changes++,
    );
  });

  tearDown(() async {
    inbox.dispose();
    await events.close();
  });

  test('本页会话的请求进队列，按到达顺序；别的会话忽略', () async {
    events.add(ApprovalRequestedEvent(_request('e1', 'sess-a')));
    events.add(ApprovalRequestedEvent(_request('e2', 'sess-x')));
    events.add(ApprovalRequestedEvent(_request('e3', 'sess-b')));
    await pumpEventQueue();

    expect(inbox.pending.map((a) => a.eventId), ['e1', 'e3']);
    expect(inbox.pending.map((a) => a.label), ['阿蓝', '小镜']);
    expect(changes, 2);
  });

  test('Host 撤下（别处已答 / 请求消失）时从队列里拿掉', () async {
    events.add(ApprovalRequestedEvent(_request('e1', 'sess-a')));
    await pumpEventQueue();
    events.add(const HostRequestCancelledEvent('e1'));
    await pumpEventQueue();

    expect(inbox.pending, isEmpty);
    expect(changes, 2);
  });

  test('回答一条：先出队再送决定，重复回答不会送第二次', () async {
    events.add(ApprovalRequestedEvent(_request('e1', 'sess-a')));
    await pumpEventQueue();

    await inbox.decide('e1', ApprovalDecision.allowOnce);
    expect(inbox.pending, isEmpty);
    expect(answered, [(eventId: 'e1', decision: ApprovalDecision.allowOnce)]);

    await inbox.decide('e1', ApprovalDecision.reject);
    expect(answered, hasLength(1));
  });

  test('多条同时到达：各自回答，互不影响', () async {
    events.add(ApprovalRequestedEvent(_request('e1', 'sess-a', tool: 'write')));
    events.add(ApprovalRequestedEvent(_request('e2', 'sess-b', tool: 'shell')));
    await pumpEventQueue();

    await inbox.decide('e2', ApprovalDecision.reject);
    expect(inbox.pending.map((a) => a.eventId), ['e1']);
    expect(answered.single.eventId, 'e2');
  });

  test('打开页面时已经挂着的请求也接住（通知点进来 / 重连）', () async {
    // Host 只在请求发生时推一次，后来订阅的人要靠 pending 补上。
    var seededChanges = 0;
    final seeded = CollabApprovalInbox(
      events: events.stream,
      pending: [ApprovalRequestedEvent(_request('e9', 'sess-a')), ApprovalRequestedEvent(_request('e8', 'sess-x'))],
      labelOf: (sessionId) => sessionId == 'sess-a' ? '阿蓝' : null,
      respond: (request, decision) async => answered.add((eventId: request.eventId, decision: decision)),
      onChanged: () => seededChanges++,
    );
    addTearDown(seeded.dispose);

    expect(seeded.pending.map((a) => a.eventId), ['e9']);
    expect(seededChanges, 1);

    await seeded.decide('e9', ApprovalDecision.allowOnce);
    expect(answered.single.eventId, 'e9');
  });

  test('dispose 后新请求不再进来', () async {
    inbox.dispose();
    events.add(ApprovalRequestedEvent(_request('e1', 'sess-a')));
    await pumpEventQueue();

    expect(inbox.pending, isEmpty);
  });
}
