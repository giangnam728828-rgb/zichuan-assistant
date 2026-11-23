// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../performance/performance_state.dart';
import 'backdrop.dart';
import 'feather.dart';

/// 顶底边缘渐隐(Claude 式):消息滚到顶栏 / 输入栏后面时,文字自己淡出,
/// 而不是被一块背景色盖住,所以浅色、深色、有光斑的背景下都没有色差。
///
/// 用 [ShaderMask](dstIn) 裁内容:顶部 [top]、底部(输入栏高度 + [_bottomTail])
/// 各一段缓动渐变,每段 3 个以上 stops 做出「慢慢淡出」,中间保持不透明,只有
/// 边缘淡出、没有硬边。渐隐层单独 [RepaintBoundary],滚动时 shader 只应用一次。
///
/// ## 降级
///
/// 低端机([PerformanceDefaults.lightweight])不用 ShaderMask 的离屏绘制,
/// 改用 [TopFade] + [BackdropVeil] 盖背景色,成本更低(代价是盖色会盖住
/// 光斑)。系统高对比度下渐隐缩短到 [highContrastFade],避免长尾糊字。
/// 减少动画不影响渐隐:它是静态的。
class EdgeFade extends ConsumerWidget {
  const EdgeFade({super.key, required this.top, required this.bottom, required this.child});

  /// 顶部渐隐高度:状态栏安全区 + 顶栏高度 + 24dp。
  final double top;

  /// 输入栏高度(动态)。底部渐隐高度 = 它 + [_bottomTail](32dp),随输入栏
  /// 多行 / 键盘弹起一起变。
  final ValueListenable<double> bottom;

  final Widget child;

  /// 高对比度时渐隐缩短到这个长度。
  static const highContrastFade = 12.0;

  /// 底部渐隐在输入栏高度之外再留的长度(32dp)。
  static const _bottomTail = 32.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lightweight = ref.watch(performanceDefaultsProvider.select((p) => p.lightweight));
    final highContrast = MediaQuery.maybeHighContrastOf(context) ?? false;
    return ValueListenableBuilder<double>(
      valueListenable: bottom,
      builder: (context, composerHeight, _) {
        final topFade = highContrast ? math.min(top, highContrastFade) : top;
        final bottomFade = highContrast
            ? math.min(composerHeight + _bottomTail, highContrastFade)
            : composerHeight + _bottomTail;
        if (topFade <= 0 && bottomFade <= 0) return child;

        if (lightweight) {
          return _VeilFallback(top: topFade, bottom: bottomFade, child: child);
        }
        return RepaintBoundary(
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) => _fadeShader(bounds.size, topFade, bottomFade),
            child: child,
          ),
        );
      },
    );
  }
}

/// 每段渐隐的采样点数(3 个以上,两端缓动)。
const _samples = 8;

/// 顶 / 底两段缓动渐隐合成的一条线性渐变。中间保持不透明,两端沿
/// easeInOutCubic 淡出,不出现线性硬切的折痕。
Shader _fadeShader(Size size, double topFade, double bottomFade) {
  final h = size.height;
  if (h <= 0) {
    return LinearGradient(colors: const [Colors.white, Colors.white]).createShader(Offset.zero & size);
  }

  final colors = <Color>[];
  final stops = <double>[];

  final topStop = (topFade / h).clamp(0.0, 1.0);
  final bottomStart = (1.0 - bottomFade / h).clamp(0.0, 1.0);
  // 渐隐区重叠(矮窗口)时,让两段各让一半,中间没有不透明区也保证 stops 递增。
  final mid = topStop > bottomStart ? (topStop + bottomStart) / 2 : null;

  // 顶部段:透明 → 不透明。
  if (topFade > 0) {
    final end = mid ?? topStop;
    for (var i = 0; i <= _samples; i++) {
      final t = i / _samples;
      colors.add(Colors.white.withValues(alpha: Curves.easeInOutCubic.transform(t)));
      stops.add(end * t);
    }
    if (mid != null) {
      colors.add(Colors.white);
      stops.add(mid);
    }
  } else {
    colors.add(Colors.white);
    stops.add(0.0);
  }

  // 底部段:不透明 → 透明。
  if (bottomFade > 0) {
    final start = mid ?? math.max(bottomStart, stops.last);
    if (start > stops.last) {
      colors.add(Colors.white);
      stops.add(start);
    }
    for (var i = 0; i <= _samples; i++) {
      final t = i / _samples;
      colors.add(Colors.white.withValues(alpha: 1.0 - Curves.easeInOutCubic.transform(t)));
      stops.add(start + (1.0 - start) * t);
    }
  } else {
    if (stops.last < 1.0) {
      colors.add(Colors.white);
      stops.add(1.0);
    }
  }

  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: colors,
    stops: stops,
  ).createShader(Offset.zero & size);
}

/// 低端机降级:保留旧的「盖背景色」做法,成本低于 ShaderMask 的离屏绘制。
class _VeilFallback extends StatelessWidget {
  const _VeilFallback({required this.top, required this.bottom, required this.child});

  final double top;
  final double bottom;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        // 底部版 BackdropVeil 要铺满整页、和页面左上角对齐,StackFit.expand 给它整屏约束。
        if (bottom > 0) IgnorePointer(child: BackdropVeil(solidHeight: _Fixed(bottom - 14), feather: 14)),
        if (top > 0)
          Positioned(left: 0, right: 0, top: 0, child: TopFade(height: top)),
      ],
    );
  }
}

/// 固定高度,给 [BackdropVeil.solidHeight] 用(它只读 value,不监听)。
class _Fixed implements ValueListenable<double> {
  const _Fixed(this.value);

  @override
  final double value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
