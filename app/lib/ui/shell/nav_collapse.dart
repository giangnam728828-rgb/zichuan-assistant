// 川水 V4.4 · 底部导航收缩的**唯一判定入口**。
//
// 旧实现（v4.3 及之前）直接在外壳里读 `ScrollUpdateNotification` 的像素差：
// 分不清「用户手指拖动」「程序 animateTo/jumpTo」「流式输出自动跟随」
// 「Markdown 高度变化」「键盘挤压布局」——于是出现「没滑也收」「滑了不收」
// 「流式输出把导航带走」这些反复被反馈的问题。
//
// 这里的规则（对应整改任务书 2.3–2.6）：
//
// 1. **只认带 dragDetails 的滚动事件**：Flutter 只给手指拖动产生的
//    `ScrollUpdateNotification` / `ScrollStartNotification` 带 dragDetails；
//    `animateTo()`、`jumpTo()`、`ScrollPosition.correctPixels()`、流式增长
//    引起的范围变化都不带。程序滚动只更新基线，永不改状态。
// 2. **双阈值迟滞**：往下读累计 24dp 收起；反向累计 12dp 展开。1–3dp 的
//    手指抖动到不了阈值，来回轻扫也不会连续开合（达到阈值后本段手势即结账，
//    要再动 24/12 才会再变一次）。
// 3. **接近底部强制展开**：距最新消息 < 48dp（`extentAfter`）时一定展开，
//    不管前面收没收起；回到顶部（overscroll）同理。
// 4. **键盘**：弹起立刻收起；收起后延迟 120ms 再展开，避开输入法动画。
// 5. **只认最外层、竖向、当前标签**：嵌套列表（横向 chip 行、代码块里的
//    滚动区）与任务/工具/设置页的滚动不参与。
//
// 控制器只管「目标状态」，动画仍由外壳的一条 [AnimationController] 驱动，
// 所以导航位移、页面抬升、列表留白始终是同一个进度。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

/// 导航收缩/展开的判定器。纯逻辑（除了展开延迟用的 [Timer]），可直接单测。
class NavigationCollapseController {
  NavigationCollapseController({
    this.collapseAfter = 24,
    this.expandAfter = 12,
    this.bottomZone = 48,
    this.returnDelay = const Duration(milliseconds: 120),
    this.onChange,
  });

  /// 往下读多少 dp 收起。
  final double collapseAfter;

  /// 往回读多少 dp 展开。
  final double expandAfter;

  /// 距列表末尾小于这个距离时强制展开。
  final double bottomZone;

  /// 展开前的延迟（键盘收起、手势结束）。
  final Duration returnDelay;

  /// 目标状态变化时回调：true = 收起，false = 展开。
  final void Function(bool collapsed)? onChange;

  bool _collapsed = false;
  bool _keyboard = false;
  Timer? _return;

  /// 当前目标状态：true = 导航应收起。
  bool get collapsed => _collapsed;

  /// 键盘是否弹起（弹起期间一切手势判定都让位给键盘）。
  bool get keyboardUp => _keyboard;

  /// 是否正被手指拖着（调试/测试用）。
  bool get dragging => _dragging;

  bool _dragging = false;

  /// 本次手势的起点位置，用来在松手时补一次「快速甩动」判定。
  double _gestureStart = 0;

  /// 本次手势内已结算的位移（方向反转时重置）。
  double _down = 0;
  double _up = 0;
  double _lastPixels = 0;

  /// 外壳每次挂到 `NotificationListener<ScrollNotification>` 上。
  ///
  /// 返回 false 让通知继续冒泡（不吞事件）。
  bool handle(ScrollNotification n) {
    // depth 是「跨过几层 viewport」：当前列表自己的 CustomScrollView 已经算
    // 一层（外层 listener 收到时 depth 至少 1），所以 > 1 才是嵌套列表
    // （代码块里的滚动区、卡片里的横向行）。
    if (n.depth > 1) return false;
    if (n.metrics.axis != Axis.vertical) return false;
    final metrics = n.metrics;

    switch (n) {
      case ScrollStartNotification(:final dragDetails):
        _dragging = dragDetails != null;
        _lastPixels = metrics.pixels;
        _gestureStart = metrics.pixels;
        _down = 0;
        _up = 0;
        if (_dragging && _keyboard) {
          // 键盘还开着就拖动列表：先收起键盘由系统处理，导航保持收起。
          _dragging = false;
        }
      case ScrollUpdateNotification(:final dragDetails):
        final delta = metrics.pixels - _lastPixels;
        _lastPixels = metrics.pixels;
        if (dragDetails != null && !_keyboard) {
          _dragging = true;
          _accumulate(delta, metrics);
        } else {
          // 程序滚动 / 惯性 / 键盘期间：只更新基线。
          _syncBottom(metrics);
        }
      case ScrollEndNotification(:final metrics):
        // 松手：快速甩动可能在拖动阶段还没到 24dp（手指抬起很快），
        // 用整段手势位移补一次。只对真实手势生效，程序滚动 _dragging 为 false。
        if (_dragging) {
          final moved = metrics.pixels - _gestureStart;
          if (moved.abs() >= collapseAfter) {
            _set(moved > 0 ? true : false, immediate: false);
          }
        }
        _dragging = false;
        _syncBottom(metrics);
      case OverscrollNotification(:final metrics, :final dragDetails):
        // 拖到顶（看更早内容）：立刻回来。下拉刷新式的顶部回弹也在此。
        if (dragDetails != null && metrics.pixels <= 0) _set(false);
      case UserScrollNotification(direction: ScrollDirection.idle):
        _dragging = false;
      default:
        break;
    }
    return false;
  }

  void _accumulate(double delta, ScrollMetrics metrics) {
    if (delta > 0) {
      _down += delta;
      _up = 0;
    } else if (delta < 0) {
      _up += -delta;
      _down = 0;
    }
    if (!_collapsed && _down >= collapseAfter) {
      _set(true);
    } else if (_collapsed && _up >= expandAfter) {
      _set(false);
    }
    _syncBottom(metrics);
  }

  /// 距末尾足够近：一定展开（用户已经回到底部，导航不该继续躲着）。
  void _syncBottom(ScrollMetrics metrics) {
    if (_keyboard) return;
    if (!metrics.hasContentDimensions) return;
    if (metrics.extentAfter <= bottomZone && _collapsed) _set(false, immediate: true);
  }

  /// 键盘开合。弹起立刻收起；收起延迟 [returnDelay] 再展开。
  void setKeyboard(bool up) {
    if (up == _keyboard) return;
    _keyboard = up;
    _dragging = false;
    if (up) {
      _return?.cancel();
      _set(true);
    } else {
      _scheduleExpand();
    }
  }

  /// 换标签 / 换会话 / 新建对话 / 点「回到底部」：立即展开，并清掉手势残留。
  void reset() {
    _dragging = false;
    _down = 0;
    _up = 0;
    _return?.cancel();
    _set(false, immediate: true);
  }

  /// 用户明确要求回到底部（点了按钮）：立刻展开，不等 120ms。
  void revealNow() => reset();

  void _scheduleExpand() {
    _return?.cancel();
    _return = Timer(returnDelay, () {
      if (_keyboard) return;
      _set(false, immediate: true);
    });
  }

  void _set(bool want, {bool immediate = false}) {
    if (want) {
      // 想收起：取消还没到点的展开，别在 120ms 后自己弹回来。
      _return?.cancel();
      if (_collapsed) return;
      _collapsed = true;
      // 结算：本段手势已经改变过状态，要再动一个完整阈值才会再变。
      _down = 0;
      _up = 0;
      onChange?.call(true);
      return;
    }
    if (!_collapsed) {
      _return?.cancel();
      return;
    }
    if (!immediate) {
      // 展开走统一的延迟：手势刚停、键盘刚收时不立刻弹回来。
      _scheduleExpand();
      return;
    }
    _return?.cancel();
    _collapsed = false;
    _down = 0;
    _up = 0;
    onChange?.call(false);
  }

  void dispose() {
    _return?.cancel();
    _return = null;
  }
}
