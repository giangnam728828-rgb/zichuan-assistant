// v4.3 · 15.5：协作模式的流式正文、思考与工具轨迹。
//
// 与普通聊天对齐的三件事：
// - 正文无论「逐段增量」「只有完整消息」还是「两者都有」，界面都只有一份，
//   不会出现「先流一遍、再整段重复一遍」；
// - 思考不是空标记：reasoning 增量真的累积下来（界面用同一个 ThinkingPill）；
// - 工具行来自真实事件：名称取自 tool/call，完成/失败取自 tool/result，
//   失败原因是真实错误，且不会把错误文案当成工具名。

import 'dart:async';

import 'package:dsh_app/collab/collab_activity.dart';
import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Stream implements CollabSessionDriver, CollabStreamingDriver {
  _Stream(this.events);

  final List<CollabTurnEvent> events;

  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async => 's1';

  @override
  Future<TurnOutcome> runTurn(
    String sessionId,
    String text, {
    Duration? timeout,
    List<CollabAttachment> attachments = const [],
  }) async => const TurnOutcome(kind: TurnKind.completed, text: '');

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
      yield event;
    }
  }
}

Future<List<CollabActivity>> _run(List<CollabTurnEvent> events) async {
  final seen = <CollabActivity>[];
  await runTurnObserved(
    driver: _Stream(events),
    sessionId: 's1',
    text: '你们好',
    timeout: const Duration(seconds: 2),
    throttle: Duration.zero,
    onActivity: seen.add,
  );
  return seen;
}

void main() {
  group('15.5 正文只有一份', () {
    test('增量 + 完整消息：完整消息是替换，不是再追加一遍', () async {
      final seen = await _run([
        const CollabTurnText('你好，'),
        const CollabTurnText('我是甲'),
        const CollabTurnText('你好，我是甲。', replace: true),
        const CollabTurnDone(TurnOutcome(kind: TurnKind.completed, text: '你好，我是甲。')),
      ]);
      expect(seen.last.text, '你好，我是甲。');
      // 任何一刻都不该出现两份拼在一起的正文。
      expect(seen.every((a) => !a.text.contains('我是甲。我是甲')), isTrue);
    });

    test('只有完整消息：直接进 UI', () async {
      final seen = await _run([
        const CollabTurnText('完整答案', replace: true),
        const CollabTurnDone(TurnOutcome(kind: TurnKind.completed, text: '完整答案')),
      ]);
      expect(seen.last.text, '完整答案');
    });

    test('终稿与增量不一致：以终稿为准（替换）', () async {
      final seen = await _run([
        const CollabTurnText('草稿写到一半'),
        const CollabTurnDone(TurnOutcome(kind: TurnKind.completed, text: '最终结论')),
      ]);
      expect(seen.last.text, '最终结论');
    });
  });

  group('15.5 思考与工具', () {
    test('reasoning 增量累积到 activity.reasoning', () async {
      final seen = await _run([
        const CollabTurnStage('thinking', summary: '正在读仓库'),
        const CollabTurnThought('先看目录结构'),
        const CollabTurnThought('先看目录结构，再定位时间线'),
        const CollabTurnDone(TurnOutcome(kind: TurnKind.completed, text: '看完了')),
      ]);
      expect(seen.last.reasoning, '先看目录结构，再定位时间线');
      expect(seen.last.thoughtSummary, '正在读仓库', reason: '公开摘要只接受提供方明确给的那一份');
    });

    test('工具：同一次调用只占一行，从执行中走到完成', () async {
      final seen = await _run([
        const CollabTurnStage('tool', detail: 'read_file', toolStatus: '调用中', toolId: 'c1'),
        const CollabTurnStage('tool', toolStatus: '完成', toolId: 'c1'),
        const CollabTurnDone(TurnOutcome(kind: TurnKind.completed, text: '好了')),
      ]);
      final tools = seen.last.tools;
      expect(tools.length, 1, reason: '开始与结果靠 callId 对上，不重复挂行');
      expect(tools.single.name, 'read_file');
      expect(tools.single.status, CollabToolStatus.done);
    });

    test('工具失败：状态为失败、保留真实工具名、原因是真实错误', () async {
      final seen = await _run([
        const CollabTurnStage('tool', detail: 'shell', toolStatus: '调用中', toolId: 'c9'),
        const CollabTurnStage('tool', detail: '权限不足：/etc/hosts 不可写', toolStatus: '失败', toolId: 'c9', failed: true),
        const CollabTurnDone(const TurnOutcome(kind: TurnKind.completed, text: '没跑成')),
      ]);
      final step = seen.last.tools.single;
      expect(step.name, 'shell', reason: '错误文案不能覆盖工具名');
      expect(step.status, CollabToolStatus.failed);
      expect(step.detail, contains('权限不足'));
      expect(step.label, contains('失败'));
    });

    test('回到思考态时，挂着的「执行中」收住，不留假进度', () async {
      final seen = await _run([
        const CollabTurnStage('tool', detail: 'read_file', toolStatus: '调用中', toolId: 'c1'),
        const CollabTurnStage('thinking'),
        const CollabTurnDone(TurnOutcome(kind: TurnKind.completed, text: '继续')),
      ]);
      expect(seen.last.tools.single.status, CollabToolStatus.done);
    });

    test('两次不同的调用各占一行', () async {
      final seen = await _run([
        const CollabTurnStage('tool', detail: 'read_file', toolStatus: '调用中', toolId: 'c1'),
        const CollabTurnStage('tool', toolStatus: '完成', toolId: 'c1'),
        const CollabTurnStage('tool', detail: 'grep', toolStatus: '调用中', toolId: 'c2'),
        const CollabTurnStage('tool', toolStatus: '完成', toolId: 'c2'),
        const CollabTurnDone(TurnOutcome(kind: TurnKind.completed, text: '两处都看了')),
      ]);
      expect(seen.last.tools.map((t) => t.name), ['read_file', 'grep']);
    });
  });
}
