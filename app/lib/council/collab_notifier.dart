// 协作运行的终态通知：完成或失败时推一条，点开回到对应的议会。
//
// 只订阅、不改编排器：orchestrator.events 每次落盘都会发一份快照，
// 这里看到终态就发通知并自动退订。取消不发（那是用户自己的动作）。
//
// 通知走现有的 dsh/notify 通道（NotifyChannel），与聊天完成通知同一套
// 系统权限与「完成 / 需处理」两组开关；kind 用 'council' 区分来源。

import 'dart:async';

import '../notify/notify_channel.dart';
import '../state/hosts_state.dart';
import 'collab_models.dart';

/// 一次运行的终态通知绑定。
final class CollabNotifier {
  CollabNotifier({
    Future<void> Function(NotifyPost post)? show,
    HostRef host = HostRef.local,
  }) : _show = show ?? NotifyChannel().show,
       _host = host;

  /// 真正的投递口；测试注入一个记录器。
  final Future<void> Function(NotifyPost post) _show;
  final HostRef _host;

  /// 订阅一组流转事件；终态后自动退订。返回订阅本身，调用方可提前取消。
  StreamSubscription<CollabRun> bind(Stream<CollabRun> events) {
    late StreamSubscription<CollabRun> subscription;
    subscription = events.listen((run) {
      if (!run.phase.isTerminal) return;
      unawaited(subscription.cancel());
      if (run.phase == CollabPhase.cancelled) return; // 用户自己停的，不打扰
      unawaited(_post(run).catchError((_) {})); // 通知发不出去不影响运行结果
    });
    return subscription;
  }

  Future<void> _post(CollabRun run) async {
    final total = run.spec.seats.length;
    final answered = run.answeredCount;
    final (title, text) = switch (run.phase) {
      CollabPhase.done => ('议会完成 · $answered/$total 席', verdictLead(run.verdict)),
      CollabPhase.failed => ('议会没能完成', run.failure ?? '运行失败'),
      _ => ('议会', ''),
    };
    await _show(
      NotifyPost(
        group: 'council|${run.id}',
        key: 'council-${run.id}',
        attention: false,
        title: title,
        text: text,
        publicText: '议会已完成',
        sessionId: run.id,
        host: _host,
        kind: 'council',
      ),
    );
  }

  /// 裁决的第一句（去掉 Markdown 记号），太长截断。
  static String verdictLead(String? verdict) {
    if (verdict == null || verdict.trim().isEmpty) return '裁决已生成';
    for (final raw in verdict.split('\n')) {
      final line = raw
          .replaceAll(RegExp(r'^#+\s*'), '')
          .replaceAll(RegExp(r'[*_`>]'), '')
          .trim();
      if (line.isEmpty || line.startsWith('结论') && line.length <= 4) continue;
      return line.length <= 60 ? line : '${line.substring(0, 60)}…';
    }
    return '裁决已生成';
  }
}
