// 标签页与聊天模式切换的**同一套**转场规格（方案第八部分）。
//
// 之前两处各写一份：TabShell 固定 200ms 淡入 + 8dp 方向位移，聊天模式切换
// 用 AppMotion.standard 淡入 + 8dp 上移。两种情况同时发生（例如在历史标签里
// 点开一条议会：切回聊天标签 + 打开那条会话）时，两层位移叠在一起，看着就是
// 一跳。
//
// 现在只有一条规矩：
// - 位移只有一个来源（标签方向那 8dp），模式切换**纯淡入**，不再自己挪；
// - 两处时长都取 [duration]（标准档 240ms，减少动画时 0）；
// - 曲线统一 [curveIn] / [curveOut]；
// - 新建会话允许一次轻量入场，返回原会话不播（调用方按 key 判断）。

import 'package:flutter/material.dart';

import '../../theme/motion.dart';

abstract final class ConversationTransition {
  /// 唯一的位移量（dp）。标签切换沿方向移这一段；模式切换不位移。
  static const shift = 8.0;

  /// 淡入淡出时长。
  ///
  /// 标准档 240ms；系统移除动画 / 用户关掉动画时 0（直接呈现，不留半透明帧）。
  static Duration duration(BuildContext context) => AppMotion.of(context, AppMotion.standard);

  /// 是否完全不播（减少动画）。调用方可以据此跳过 AnimatedSwitcher。
  static bool reduced(BuildContext context) => AppMotion.reduced(context);

  static const curveIn = AppMotion.enter;
  static const curveOut = AppMotion.exit;

  /// 标签页：淡入 + 沿切换方向位移 [shift]。
  ///
  /// [direction] 向右为正（从聊天往左数：1 = 往左切，-1 = 往右切）。
  static Widget tab({
    required BuildContext context,
    required Animation<double> animation,
    required double direction,
    required Widget child,
  }) {
    if (reduced(context)) return child;
    final curved = CurvedAnimation(parent: animation, curve: curveIn, reverseCurve: curveOut);
    return AnimatedBuilder(
      animation: curved,
      builder: (context, inner) => Opacity(
        opacity: curved.value.clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset((1 - curved.value) * shift * direction, 0), child: inner),
      ),
      child: child,
    );
  }

  /// 模式切换：**只淡入**，不位移（位移由标签页那一层负责，避免叠加跳动）。
  static Widget mode({required BuildContext context, required Animation<double> animation, required Widget child}) {
    if (reduced(context)) return child;
    final curved = CurvedAnimation(parent: animation, curve: curveIn, reverseCurve: curveOut);
    return FadeTransition(opacity: curved, child: child);
  }
}
