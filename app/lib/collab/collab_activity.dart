// 一轮执行过程中的「现在在干什么」。
//
// 议会与团队都按席位/队友各存一份，互不串线。内容只来自 Host 的真实事件：
// assistant-stream 的正文增量、reasoning 增量、tool/call 的工具名、
// tool/result 的结果、turn/end 的收尾；没有拿到就直接说「正在思考」，绝不
// 编造进度或推理正文。
//
// v4.3 · P0-C：这里补齐三件与普通聊天对齐的事——
// 1. 正文三种到达方式都接住：逐段增量、只有完整消息、两者都有。完整消息是
//    「替换」而不是「再追加一遍」，收尾时再用终稿校准一次。
// 2. 思考不再是空标记：与普通聊天同源的 reasoning 增量累积进
//    [CollabActivity.reasoning]，界面用同一个 ThinkingPill 渲染。
// 3. 工具调用按 callId 记录真实名称与真实结果（完成/失败 + 错误原因），
//    界面按成员各画各的行。

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
  var reasoning = '';
  var toolName = '';
  var toolStatus = '';
  var buffer = StringBuffer();
  var tools = const <CollabToolStep>[];
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
        reasoning: reasoning, // 与普通聊天同源的思考正文
        tools: tools, // 真实工具轨迹
        toolName: toolName,
        toolStatus: toolStatus,
        at: stamp,
      ),
    );
  }

  /// 工具状态按 callId 就地更新：同一次调用只占一行，状态从「执行中」走到
  /// 「完成/失败」，不会一调用就多出一串重复行。
  void applyTool(CollabTurnStage stage) {
    final name = stage.detail.trim();
    final id = stage.toolId.isNotEmpty ? stage.toolId : 'tool-${tools.length}';
    final status = stage.failed
        ? CollabToolStatus.failed
        : switch (stage.toolStatus) {
            '完成' => CollabToolStatus.done,
            '失败' => CollabToolStatus.failed,
            _ => CollabToolStatus.calling,
          };
    final index = tools.indexWhere((step) => step.id == id);
    if (index < 0) {
      // 名字为空（只有结果没有调用）时不凭空造一行。
      if (name.isEmpty && status != CollabToolStatus.failed) return;
      tools = [
        ...tools,
        CollabToolStep(id: id, name: name.isEmpty ? '工具' : name, status: status, detail: stage.failed ? name : ''),
      ];
    } else {
      final current = tools[index];
      tools = [
        for (var i = 0; i < tools.length; i++)
          if (i == index)
            current.copyWith(
              // 名称只由 tool/call 事件确定；结果事件带的是错误原因，绝不覆盖名字。
              name: current.name,
              status: status,
              detail: stage.failed ? name : '',
            )
          else
            tools[i],
      ];
    }
    final step = tools[index < 0 ? tools.length - 1 : index];
    toolName = step.name;
    toolStatus = step.status.label;
    phase = CollabActivityPhase.tool;
  }

  void settle(TurnOutcome outcome) {
    if (completer.isCompleted) return;
    phase = outcome.isCompleted ? CollabActivityPhase.done : CollabActivityPhase.failed;
    // 终稿校准：模型可能先给增量、最后给一份完整消息（或修正前文）。
    // 有终稿就以终稿为准，且是**替换**，绝不再追加一份。
    final finalText = outcome.text.trim();
    if (finalText.isNotEmpty && finalText != buffer.toString().trim()) {
      buffer = StringBuffer(finalText);
    }
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
              // 摘要只接受提供方明确公开的那一份。
              if (stage.summary.isNotEmpty) thoughtSummary = stage.summary;
              if (stage.stage == 'tool') {
                applyTool(stage);
              } else {
                phase = switch (stage.stage) {
                  'replying' => CollabActivityPhase.replying,
                  _ => CollabActivityPhase.thinking,
                };
                // 回到思考态时把工具那一行收住：工具已经结束，不该还挂着
                // 「正在调用」。已完成/失败的真实结论留在 tools 里。
                if (phase == CollabActivityPhase.thinking && tools.any((s) => s.status == CollabToolStatus.calling)) {
                  tools = [
                    for (final step in tools)
                      if (step.status == CollabToolStatus.calling)
                        step.copyWith(status: CollabToolStatus.done)
                      else
                        step,
                  ];
                  final last = tools.isEmpty ? null : tools.last;
                  if (last != null) {
                    toolName = last.name;
                    toolStatus = last.status.label;
                  }
                }
              }
              // 阶段变化不节流：工具/思考只来一两次，漏了界面就停在上一句。
              push(force: true);
            case CollabTurnThought(:final text):
              if (text == reasoning) break;
              reasoning = text;
              // 思考正文到达时只在还没有正文的情况下切回思考态：正文已经
              // 开始写了就不该把状态倒回去。
              if (buffer.isEmpty) phase = CollabActivityPhase.thinking;
              push();
            case CollabTurnText(:final delta, :final replace):
              if (replace) {
                if (delta.trim().isEmpty) break;
                buffer = StringBuffer(delta);
              } else {
                buffer.write(delta);
              }
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
