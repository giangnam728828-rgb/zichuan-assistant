// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// 知川助手：背景动态光斑（Tide）。
//
// 一层极慢、极淡的角色主题色光,像水面下的潮汐一样漂移与呼吸。它只画在
// 背景之上、内容之下,用独立的 RepaintBoundary 与 AnimationController,不会
// 让页面内容跟着重建。
//
// 设计取舍:
// - 一个周期 18 秒,位移不超过屏幕短边的 6%,肉眼几乎察觉不到「在动」,
//   但整体观感是活的,不是一张静止的纸。
// - 尊重系统「减少动画」:开启时整个组件不挂 ticker,只画一帧静态图。
// - 颜色取自当前配色的 glow,换主题时自动跟着变。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'surfaces.dart';
import 'tilt_glow.dart';

/// 一层缓慢漂移的柔和光斑。
class TideGlow extends StatefulWidget {
  const TideGlow({super.key, this.enabled = true});

  /// 进程级总开关。widget 测试在 `test/support/test_defaults.dart` 里把它
  /// 设为 false,避免 18 秒的 `repeat()` ticker 让 `pumpAndSettle()` 超时。
  /// 与 [enabled]、系统「减少动画」三者取与。
  static bool animationsEnabled = true;

  /// 关掉后不创建动画,只画一帧。
  final bool enabled;

  @override
  State<TideGlow> createState() => _TideGlowState();
}

class _TideGlowState extends State<TideGlow> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  );

  // 不在这里读 MediaQuery:initState 阶段依赖 InheritedWidget 是非法时机
  // (父级重建时会抛 dependOnInheritedWidgetOfExactType before initState completed)。
  // didChangeDependencies 在 initState 之后首次调用,之后依赖变化也会调用。

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeRun();
  }

  void _maybeRun() {
    if (!mounted) return;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (TideGlow.animationsEnabled && widget.enabled && !reduce) {
      if (!_c.isAnimating) _c.repeat();
    } else if (_c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void didUpdateWidget(TideGlow old) {
    super.didUpdateWidget(old);
    if (old.enabled != widget.enabled) _maybeRun();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surfaces = DshSurfaces.of(context);
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final still = !TideGlow.animationsEnabled || !widget.enabled || reduce;
    // 第 7 步：整层光斑跟着手机倾斜偏移，上限 6dp（TiltGlow.maxShift）。
    // 倾斜值是 ValueListenable，光斑自己重画，页面不重建。
    final tilt = TiltGlow.instance;
    return IgnorePointer(
      child: RepaintBoundary(
        child: ValueListenableBuilder<TiltSample>(
          valueListenable: tilt,
          builder: (context, sample, _) {
            final painter = _TidePainter(
              progress: still ? 0.32 : _c,
              accentA: surfaces.glowPrimary,
              accentB: surfaces.glowSecondary,
              // 两轴已在 TiltGlow 里夹到 [-1, 1]，这里只乘上限。
              shift: Offset(sample.x * TiltGlow.maxShift, sample.y * TiltGlow.maxShift),
            );
            return CustomPaint(painter: painter);
          },
        ),
      ),
    );
  }
}

class _TidePainter extends CustomPainter {
  _TidePainter({required this.progress, required this.accentA, required this.accentB, this.shift = Offset.zero})
    : super(repaint: progress is Animation<double> ? progress : null);

  final Object progress;
  final Color accentA;
  final Color accentB;

  /// 倾斜带来的整体位移（逻辑像素，≤ 6dp）。
  final Offset shift;

  double get _t {
    final p = progress;
    if (p is Animation<double>) return p.value;
    if (p is double) return p;
    return 0;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final t = _t;
    final tau = 2 * math.pi;
    // 三个光斑,不同相位与半径,合成一层很淡的潮汐。
    final spots = <(Offset, double, Color, double)>[
      (
        Offset(
          size.width * (0.18 + 0.05 * math.sin(t * tau)),
          size.height * (0.22 + 0.04 * math.cos(t * tau)),
        ),
        size.shortestSide * (0.42 + 0.03 * math.sin(t * tau)),
        accentA,
        0.30,
      ),
      (
        Offset(
          size.width * (0.86 + 0.04 * math.cos(t * tau + 2)),
          size.height * (0.72 + 0.05 * math.sin(t * tau + 1)),
        ),
        size.shortestSide * (0.38 + 0.03 * math.cos(t * tau + 1)),
        accentB,
        0.26,
      ),
      (
        Offset(
          size.width * (0.5 + 0.06 * math.sin(t * tau + 3)),
          size.height * (0.95 + 0.03 * math.cos(t * tau + 2)),
        ),
        size.shortestSide * 0.34,
        accentA,
        0.16,
      ),
    ];
    for (final (spot, radius, color, alpha) in spots) {
      final center = spot + shift;
      final bounds = Rect.fromCircle(center: center, radius: radius);
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = RadialGradient(
            colors: [color.withValues(alpha: alpha), color.withValues(alpha: 0)],
          ).createShader(bounds),
      );
    }
  }

  @override
  bool shouldRepaint(_TidePainter old) =>
      old.accentA != accentA || old.accentB != accentB || old.progress != progress;
}
