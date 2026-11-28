// 团队执行的单飞调度（v3 · 第二部分 2.4）。
//
// 一个团队在同一时刻**只能有一个模型请求在飞**：主管规划、队友执行、审核、
// 返工、汇总、恢复——全部走这一个通道排队。这不是 UI 的错觉，是真的串行：
// 上一个请求的 Future 结束，下一个才开始。
//
// 为什么不用「每处各加一把锁」：
// 之前群聊有 `_active`、任务图有 `_runActive`、写文件有 `_writeGates`，三段
// 各自保护一小块，不同入口互相绕过；于是「看起来只有一个气泡」，底层却可能
// 两个模型同时跑。这里只有一条队列。
//
// 失败/取消也必须释放：任何异常路径都不能把队列卡死。

import 'dart:async';

/// 每个团队的串行执行通道。
class TeamRunScheduler {
  /// teamId → 队尾（链式 Future）。
  final _tails = <String, Future<void>>{};

  /// teamId → 还在排队的数量（给界面/诊断用）。
  final _queued = <String, int>{};

  /// teamId → 当前持锁的标签（队友名 / 阶段名），便于诊断。
  final _holding = <String, String>{};

  /// 某个团队此刻是否有人在跑。
  bool isBusy(String teamId) => _holding.containsKey(teamId);

  /// 某个团队此刻正在跑谁（没有则为 null）。
  String? holder(String teamId) => _holding[teamId];

  /// 排队数量（不含正在跑的）。
  int pending(String teamId) => _queued[teamId] ?? 0;

  /// 在 [teamId] 的通道里排一次执行：前一个结束（成功/失败/取消）后开始。
  Future<T> run<T>(String teamId, Future<T> Function() action, {String? label}) {
    final previous = _tails[teamId] ?? Future<void>.value();
    final done = Completer<void>();
    _tails[teamId] = done.future;
    _queued[teamId] = (_queued[teamId] ?? 0) + 1;

    void release() {
      final left = (_queued[teamId] ?? 1) - 1;
      if (left <= 0) {
        _queued.remove(teamId);
      } else {
        _queued[teamId] = left;
      }
      if (!done.isCompleted) done.complete();
      if (identical(_tails[teamId], done.future)) _tails.remove(teamId);
    }

    return previous.then((_) async {
      // 轮到我了：记下持锁人（诊断/界面用），跑完无论如何都释放。
      if (label != null) _holding[teamId] = label;
      try {
        return await action();
      } finally {
        _holding.remove(teamId);
        release();
      }
    }, onError: (Object _, StackTrace __) async {
      // 前一个失败不该堵住后面：这里不执行 action，直接接力并释放。
      release();
      throw StateError('team scheduler chain broken');
    });
  }

  /// 等一个团队把队列跑干净（取消后用）。
  Future<void> drain(String teamId) async {
    final tail = _tails[teamId];
    if (tail == null) return;
    try {
      await tail;
    } on Object {
      // 队尾失败无所谓：drain 只保证「等到不再有人跑」。
    }
  }

  /// 取消后清空排队（正在跑的那一个不会被强行掐断，由调用方调 driver.cancel）。
  void clearQueue(String teamId) {
    _queued.remove(teamId);
  }

  /// 编排器 dispose 时把所有等待者放行，避免退出时挂着。
  void dispose() {
    for (final done in _tails.values) {
      // 已经在跑的 Future 由它自己结束；这里不强行 complete，避免重复 complete。
      done.ignore();
    }
    _tails.clear();
    _queued.clear();
    _holding.clear();
  }
}
