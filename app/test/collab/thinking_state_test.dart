// v3 · 3.2/3.3 验收：思考摘要与回答正文分离，且绝不泄露原始推理。
//
// 关键点：ReasoningDeltaChunk 只能产出「正在思考」阶段，公开摘要必须是提供方
// 单独标为可见的字段；两者都不能进 CollabActivity.text（那是回答正文）。

import 'dart:async';

import 'package:dsh_app/collab/collab_activity.dart';
import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';

/// 逐事件吐出的假流式驱动。
final class _StreamingFake implements CollabSessionDriver, CollabStreamingDriver {
  _StreamingFake(this.events);

  final List<CollabTurnEvent> events;
  final seen = <CollabTurnEvent>[];

  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async => 's-${seat.id}';

  @override
  Future<TurnOutcome> runTurn(
    String sessionId,
    String text, {
    Duration? timeout,
    List<CollabAttachment> attachments = const [],
  }) async => const TurnOutcome(kind: TurnKind.completed, text: 'fallback');

  @override
  Future<void> cancel(String sessionId) async {}

  @override
  Stream<CollabTurnEvent> streamTurn(
    String sessionId,
    String text, {
    Duration? timeout,
    List<CollabAttachment> attachments = const [],
  }) async* {
    for (final event in events) {
      seen.add(event);
      yield event;
    }
  }
}

void main() {
  test('活动数据：思考摘要、工具名、回答正文各占一个字段', () {
    const activity = CollabActivity(
      phase: CollabActivityPhase.thinking,
      thoughtSummary: '用户可见的简短摘要',
      text: '这是回答正文',
      toolName: 'read_file',
      toolStatus: '执行中',
      attemptId: 'a1',
      at: null,
    );
    expect(activity.thoughtSummary, '用户可见的简短摘要');
    expect(activity.text, '这是回答正文');
    expect(activity.toolName, 'read_file');
    expect(activity.toolStatus, '执行中');
    expect(activity.label, contains('read_file'));

    final next = activity.copyWith(phase: CollabActivityPhase.replying, thoughtSummary: '');
    expect(next.thoughtSummary, isEmpty, reason: '摘要可以被之后的阶段清掉');
    expect(next.text, '这是回答正文', reason: '回答正文不受影响');
  });

  test('公开摘要进 thoughtSummary，不进 text', () async {
    const publicSummary = '我先把布局拆开再看输入栏高度';
    const privateReasoning = '这是不该显示的原始推理';
    final driver = _StreamingFake([
      const CollabTurnStage('thinking', summary: publicSummary),
      const CollabTurnStage('tool', detail: 'read_file', toolStatus: '调用中'),
      CollabTurnStage('thinking'), // 原始 reasoning delta 在上游只到这一步
      const CollabTurnText('我', ),
      const CollabTurnText('完成了布局'),
      const CollabTurnDone(TurnOutcome(kind: TurnKind.completed, text: '完成了布局')),
    ]);
    final activities = <CollabActivity>[];
    final outcome = await runTurnObserved(
      driver: driver,
      sessionId: 's-x',
      text: '问题',
      timeout: const Duration(seconds: 5),
      onActivity: activities.add,
      throttle: Duration.zero,
    );

    expect(outcome.isCompleted, isTrue);
    final finalActivity = activities.last;
    expect(finalActivity.text, '我完成了布局');
    expect(finalActivity.text, isNot(contains(privateReasoning)));
    expect(finalActivity.thoughtSummary, publicSummary);
    expect(activities.any((a) => a.toolName == 'read_file'), isTrue);
    expect(activities.any((a) => a.phase == CollabActivityPhase.replying), isTrue);
  });

  test('没有公开摘要时：摘要留空，界面只显示真实阶段，不编思考文字', () async {
    final driver = _StreamingFake([
      const CollabTurnStage('thinking'), // 原始推理 delta 被丢掉
      const CollabTurnDone(TurnOutcome(kind: TurnKind.completed, text: '答案')),
    ]);
    final activities = <CollabActivity>[];
    await runTurnObserved(
      driver: driver,
      sessionId: 's-x',
      text: '问题',
      timeout: const Duration(seconds: 5),
      onActivity: activities.add,
      throttle: Duration.zero,
    );
    for (final activity in activities) {
      expect(activity.thoughtSummary, isEmpty);
      expect(activity.label, isNotEmpty, reason: '至少显示真实的「正在思考…」阶段');
    }
  });

  test('旧事件（无 summary 字段）保持兼容', () {
    const stage = CollabTurnStage('thinking');
    expect(stage.summary, isEmpty);
    expect(stage.toolStatus, isEmpty);
  });
}
