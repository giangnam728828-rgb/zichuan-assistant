// 一轮执行过程中的「现在在干什么」。
//
// 议会与团队都按席位/队友各存一份，互不串线。内容只来自 Host 的真实事件：
// assistant-stream 的正文增量、tool/call 的工具名、turn/end 的收尾；没有拿到
// 就直接说「正在思考」，绝不编造进度或推理正文。

import 'dart:async';

import '../council/collab_models.dart';
import '../council/collab_orchestrator.dart';

/// 跑一轮，同时把真实过程回调出去；返回终稿。
///
/// 驱动支持 [CollabStreamingDriver] 时逐事件转发（正文增量按 [throttle] 合并，
/// 避免每个 token 都重建整个列表）；不支持的假驱动退回一次性 `runTurn`，
/// 只在结束时给一个终态。
Future<TurnOutcome> runTurnObserved({
  required CollabSessionDriver driver,
  required String sessionId,
  required String text,
  required Duration timeout,
  required void Function(CollabActivity activity) onActivity,
  List<CollabAttachment> attachments = const [],
  Duration throttle = const Duration(milliseconds: 90),
}) async {
  final now = DateTime.now();
  final streaming = driver is CollabStreamingDriver ? driver as CollabStreamingDriver : null;
  if (streaming == null) {
    final outcome = await driver.runTurn(sessionId, text, timeout: timeout, attachments: attachments);
    onActivity(
      CollabActivity(
        phase: outcome.isCompleted ? CollabActivityPhase.done : CollabActivityPhase.failed,
        text: outcome.text,
        at: now,
      ),
    );
    return outcome;
  }

  final completer = Completer<TurnOutcome>();
  var phase = CollabActivityPhase.thinking;
  var detail = '';
  var thoughtSummary = '';
  var toolName = '';
  var toolStatus = '';
  var buffer = StringBuffer();
  var attemptId = '';
  var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  void push({bool force = false}) {
    final stamp = DateTime.now();
    if (!force && stamp.difference(lastEmit) < throttle) return;
    lastEmit = stamp;
    onActivity(
      CollabActivity(
        phase: phase,
        detail: detail,
        text: buffer.toString(), // 只有回答正文
        attemptId: attemptId,
        thoughtSummary: thoughtSummary, // 只有公开摘要
        toolName: toolName,
        toolStatus: toolStatus,
        at: stamp,
      ),
    );
  }

  void settle(TurnOutcome outcome) {
    if (completer.isCompleted) return;
    phase = outcome.isCompleted ? CollabActivityPhase.done : CollabActivityPhase.failed;
    push(force: true);
    completer.complete(outcome);
  }

  final sub = streaming
      .streamTurn(sessionId, text, timeout: timeout, attachments: attachments)
      .listen(
        (event) {
          switch (event) {
            case final CollabTurnStage stage:
              detail = stage.detail;
              // 摘要只接受提供方明确公开的那一份；reasoning delta 在上游就被丢掉。
              if (stage.summary.isNotEmpty) thoughtSummary = stage.summary;
              phase = switch (stage.stage) {
                'tool' => CollabActivityPhase.tool,
                'replying' => CollabActivityPhase.replying,
                _ => CollabActivityPhase.thinking,
              };
              if (phase == CollabActivityPhase.tool) {
                toolName = detail;
                toolStatus = stage.toolStatus;
              }
              // 阶段变化不节流：工具/思考只来一两次，漏了界面就停在上一句。
              push(force: true);
            case CollabTurnText(:final delta):
              buffer.write(delta);
              phase = CollabActivityPhase.replying;
              push();
            case CollabTurnDone(:final outcome):
              settle(outcome);
          }
        },
        onError: (Object error) => settle(TurnOutcome(kind: TurnKind.failed, error: '$error')),
        onDone: () {
          if (!completer.isCompleted) {
            settle(const TurnOutcome(kind: TurnKind.failed, error: '过程流断开了'));
          }
        },
      );

  try {
    return await completer.future.timeout(
      timeout + const Duration(seconds: 5),
      onTimeout: () {
        phase = CollabActivityPhase.failed;
        push(force: true);
        return const TurnOutcome(kind: TurnKind.failed, error: '这一轮超时了');
      },
    );
  } finally {
    await sub.cancel();
  }
}
