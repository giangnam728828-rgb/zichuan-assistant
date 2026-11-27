// 团队实时过程：一位队友在跑的时候，群里能看到他真实的阶段与流式正文；
// 结束后收成同一条消息，不重复、不残留。
//
// 这里用一个会吐事件的假驱动（真驱动见 DshCollabDriver.streamTurn）。

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/team/team_models.dart';
import 'package:dsh_app/team/team_orchestrator.dart';
import 'package:dsh_app/team/team_store.dart';
import 'package:flutter_test/flutter_test.dart';

Teammate _mate(String id, String name, String model) =>
    Teammate(id: id, name: name, provider: 'deepseek', model: model);

final class _StreamingDriver implements CollabSessionDriver, CollabStreamingDriver {
  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async => 's-${seat.id}';

  @override
  Future<TurnOutcome> runTurn(
    String sessionId,
    String text, {
    Duration? timeout,
    List<CollabAttachment> attachments = const [],
  }) async {
    throw StateError('流式驱动不应该走 runTurn');
  }

  @override
  Stream<CollabTurnEvent> streamTurn(
    String sessionId,
    String text, {
    Duration? timeout,
    List<CollabAttachment> attachments = const [],
  }) async* {
    yield const CollabTurnStage('thinking');
    await Future<void>.delayed(const Duration(milliseconds: 8));
    yield const CollabTurnText('先看了登录页，');
    await Future<void>.delayed(const Duration(milliseconds: 8));
    yield const CollabTurnStage('tool', detail: 'read_file');
    await Future<void>.delayed(const Duration(milliseconds: 8));
    yield const CollabTurnText('重复提交在表单里。');
    yield const CollabTurnDone(TurnOutcome(kind: TurnKind.completed, text: '先看了登录页，重复提交在表单里。'));
  }

  @override
  Future<void> cancel(String sessionId) async {}
}

void main() {
  test('跑的时候能看到真实阶段与流式正文，结束后收成一条消息', () async {
    final dir = await Directory.systemTemp.createTemp('team-stream-');
    addTearDown(() => dir.delete(recursive: true));
    final orchestrator = TeamOrchestrator(driver: _StreamingDriver(), store: TeamStore(dir));
    addTearDown(orchestrator.dispose);
    final team = await orchestrator.create(
      teammates: [_mate('m1', '阿蓝', 'pro'), _mate('m2', '阿橙', 'flash')],
      leadId: 'm1',
    );

    final seen = <CollabActivity>[];
    final sub = orchestrator.events.listen((state) {
      if (state.activity['m1'] case final activity?) seen.add(activity);
    });
    await orchestrator.send(team.id, '@阿蓝 看看登录页');
    await sub.cancel();

    // 阶段来自真实事件：先思考、再调 read_file、再写正文。
    expect(seen.any((a) => a.phase == CollabActivityPhase.thinking), isTrue);
    expect(seen.any((a) => a.phase == CollabActivityPhase.tool && a.detail == 'read_file'), isTrue);
    expect(seen.any((a) => a.text.contains('先看了登录页')), isTrue);
    // 另一位没被点名：没有他的过程，也没有他的消息。
    expect(seen.every((a) => a.text != '不该出现'), isTrue);

    final after = (await orchestrator.load(team.id))!;
    expect(after.running, isEmpty);
    expect(after.activity, isEmpty);
    final answers = after.messages.where((m) => m.role == TeamMsgRole.teammate).toList();
    expect(answers, hasLength(1));
    expect(answers.single.teammateId, 'm1');
    expect(answers.single.text, '先看了登录页，重复提交在表单里。');
  });

  test('没有流式能力的驱动仍然能跑完（退回一次性结果）', () async {
    final dir = await Directory.systemTemp.createTemp('team-plain-');
    addTearDown(() => dir.delete(recursive: true));
    final orchestrator = TeamOrchestrator(driver: _PlainDriver(), store: TeamStore(dir));
    addTearDown(orchestrator.dispose);
    final team = await orchestrator.create(
      teammates: [_mate('m1', '阿蓝', 'pro'), _mate('m2', '阿橙', 'flash')],
      leadId: 'm1',
    );

    await orchestrator.send(team.id, '@阿蓝 在吗');
    final after = (await orchestrator.load(team.id))!;
    expect(after.messages.where((m) => m.role == TeamMsgRole.teammate).single.text, '在的');
  });
}

final class _PlainDriver implements CollabSessionDriver {
  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async => 's-${seat.id}';

  @override
  Future<TurnOutcome> runTurn(
    String sessionId,
    String text, {
    Duration? timeout,
    List<CollabAttachment> attachments = const [],
  }) async => const TurnOutcome(kind: TurnKind.completed, text: '在的');

  @override
  Future<void> cancel(String sessionId) async {}
}
