// 川水 · 外壳向下传的「底部占用」。
//
// 四个根页（对话/历史/工具/设置）的列表末尾都要留出底部导航的高度，
// 否则最后一行会被悬浮导航盖住。高度用 0→1 的动画值传递，而不是开关：
// 键盘弹起时导航收起，列表 padding 跟着连续变，不会跳一下。

import 'package:flutter/material.dart';

/// 底部导航的几何常量。改这里，四个页面一起跟着变。
abstract final class ShellMetrics {
  /// 导航本体高度（不含安全区）。
  ///
  /// 48（标签触控高度，不再往下压）+ 4×2（玻璃上下内边距）。A2 之前写的是
  /// 64，比实际多 4dp；v4.3 · P1-B 把玻璃内边距从 6 收到 4，视觉占位再少
  /// 4dp，触控高度仍是 48。
  static const navHeight = 56.0;

  /// 玻璃上下内边距（与 [navHeight] 是同一套算法：navHeight = 48 + 2 × 这个）。
  static const navPadding = 4.0;

  /// 导航离屏幕底边的距离：手势条安全区 + 8dp。
  static const navGap = 8.0;

  /// 触控区下限。
  static const minTapTarget = 48.0;

  /// 手机横屏高度低于这个值时导航收窄（只留图标、隐藏文字）。
  static const compactHeight = 500.0;

  /// 键盘收起后延迟这么久再显示导航，避开输入法动画。
  static const navReturnDelay = Duration(milliseconds: 120);

  /// 底部整组在动画值 [t] 时占的高度：导航 + 间隙 + 安全区。
  ///
  /// 外壳抬页面、页面算列表留白都只读这一个公式，两处不会再各写一份漂开。
  static double extentAt(double t, {required double safeBottom}) => (navHeight + navGap + safeBottom) * t;
}

/// 底部占用的动画状态：0 = 完全收起（键盘弹起），1 = 完全展开。
///
/// [progress] 由外壳驱动；页面用 [paddingFor] 算自己的底部留白。
class ShellInsets extends InheritedWidget {
  const ShellInsets({
    super.key,
    required this.progress,
    required this.hasComposer,
    required this.compact,
    required super.child,
  });

  /// 0 → 1 的动画值（外壳用 AnimationController 驱动）。
  final Animation<double> progress;

  /// 对话页有输入栏，其余页没有：决定是否把输入栏高度算进去。
  final bool hasComposer;

  /// 手机横屏等矮窗口。
  final bool compact;

  /// 导航完全展开时占的高度（含安全区）。
  double get navExtent => ShellMetrics.navHeight + ShellMetrics.navGap;

  /// 某一刻底部要留的总高度。
  double extentAt(double t, {required double safeBottom}) => ShellMetrics.extentAt(t, safeBottom: safeBottom);

  /// 给列表/滚动区用的底部留白，随动画连续变化。
  Widget paddingFor({
    required Widget child,
    double extra = 0,
  }) {
    return Builder(
      builder: (context) {
        final safe = MediaQuery.paddingOf(context).bottom;
        return AnimatedBuilder(
          animation: progress,
          builder: (context, _) {
            final t = progress.value.clamp(0.0, 1.0);
            return Padding(
              padding: EdgeInsets.only(bottom: extentAt(t, safeBottom: safe) + extra),
              child: child,
            );
          },
        );
      },
    );
  }

  static ShellInsets? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellInsets>();

  static ShellInsets of(BuildContext context) {
    final insets = maybeOf(context);
    assert(insets != null, 'ShellInsets 只在外壳（HomeShell）内部提供');
    return insets!;
  }

  @override
  bool updateShouldNotify(ShellInsets old) =>
      old.progress != progress || old.hasComposer != hasComposer || old.compact != compact;
}
