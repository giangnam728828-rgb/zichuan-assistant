// 启动画面的动效：一条时间线，从系统启动画面交到 App 手里那一刻算起。
//
// 知川助手（v3 · 极简字标开屏）：系统启动页只画页面底色，不放任何图标，
// 这里也不再画立绘或任何「形状」。整条时间线只有四件事：
//
//   0 ms        纯色底，与系统页同一个颜色（res/values{-night}/colors.xml）。
//   0–300       中心一条 1px 细线向两侧展开（scaleX 0 → 1，强调色 60%）。
//   200–700     「知川」两字依次上浮 8dp 并淡入；第二字错开 80ms，
//               字重 600、字间距 4。
//   700–1100    字后一圈涟漪扩散一次（描边圆，强调色 40% → 0）。
//   1100 起     静止，等界面可用。
//   界面可用    整层 300 ms 淡出；首页内容上浮 12dp 淡入。
//
// 系统要求减少动画时：只画静态字标，不播放细线、上浮与涟漪。
// 只用 opacity / transform：不 tween 宽高边距，不叠模糊。

import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart' show FontWeight, Offset, Rect, Size;

/// Where things are at one moment of the launch timeline.
class LaunchFrame {
  const LaunchFrame({
    required this.line,
    required this.firstOpacity,
    required this.firstRise,
    required this.secondOpacity,
    required this.secondRise,
    this.ripple,
  });

  /// The hairline spreading from the centre, 0 → 1 (its scaleX).
  final double line;

  /// 第一字「知」：opacity 0 → 1。
  final double firstOpacity;

  /// 第一字距离静止位置还差多少（逻辑像素，向上浮）。
  final double firstRise;

  /// 第二字「川」。
  final double secondOpacity;
  final double secondRise;

  /// 字后的涟漪 0 → 1，或 null（未开始 / 已结束）。
  final double? ripple;
}

/// The launch layout: a centred wordmark, the hairline through its middle, and the
/// ripple expanding behind it.
class LaunchLayout {
  LaunchLayout({required this.screen, this.cover = Rect.zero});

  /// The window the launch layer fills.
  final Size screen;

  /// Kept for callers that still measure the system's splash icon square; the
  /// timeline does not position anything from it any more.
  final Rect cover;

  /// 字标的中心：屏幕正中。
  Offset get centre => Offset(screen.width / 2, screen.height / 2);

  /// The hairline's resting width: a fraction of the screen.
  double get lineWidth => screen.width * LaunchMotion.lineSpread;

  /// 涟漪的最大半径：短边的固定比例。
  double get rippleRadius => screen.shortestSide * LaunchMotion.rippleRadius;

  /// The lockup at [t] since the launch screen took over.
  LaunchFrame at(Duration t) {
    final ms = t.inMicroseconds / 1000;
    final line = _progress(ms, LaunchMotion.line);
    final first = _progress(ms, LaunchMotion.firstChar);
    final second = _progress(ms, LaunchMotion.secondChar);
    final ripple = _progress(ms, LaunchMotion.rippleAt);
    final firstCurve = LaunchMotion.riseCurve.transform(first);
    final secondCurve = LaunchMotion.riseCurve.transform(second);
    return LaunchFrame(
      line: LaunchMotion.lineCurve.transform(line),
      firstOpacity: LaunchMotion.fadeCurve.transform(first),
      firstRise: LaunchMotion.charRiseBy * (1 - firstCurve),
      secondOpacity: LaunchMotion.fadeCurve.transform(second),
      secondRise: LaunchMotion.charRiseBy * (1 - secondCurve),
      ripple: ripple <= 0 || ripple >= 1 ? null : ripple,
    );
  }

  static double _progress(double ms, (int, int) span) {
    final (start, end) = span;
    if (ms <= start) return 0;
    if (ms >= end) return 1;
    return (ms - start) / (end - start);
  }
}

abstract final class LaunchMotion {
  /// 细线向两侧展开。
  static const line = (0, 300);

  /// 第一字「知」上浮并淡入。
  static const firstChar = (200, 700);

  /// 第二字「川」：错开 80ms。
  static const secondChar = (280, 780);

  /// 字后涟漪扩散一次。
  static const rippleAt = (700, 1100);

  /// Everything has come to rest.
  static const total = Duration(milliseconds: 1100);

  /// The whole layer fading away once the app is usable.
  static const leave = Duration(milliseconds: 300);

  /// A custom launch screen fading in over the system's picture.
  static const customIn = Duration(milliseconds: 360);

  static const lineCurve = Cubic(0.2, 0.0, 0.0, 1.0);
  static const fadeCurve = Cubic(0.0, 0.0, 0.2, 1.0);
  static const riseCurve = Cubic(0.2, 0.0, 0.0, 1.0);

  /// 细线最终宽度，占屏宽的比例。
  static const lineSpread = 0.42;

  /// 每字上浮的距离（逻辑像素）。
  static const charRiseBy = 8.0;

  /// 字标的字号、字重、字间距。
  static const wordmarkSize = 34.0;

  /// 横版/平板开屏的字标放大比例（第 7 步）：横屏短边被压扁时，34dp 的字在一台
  /// 平板横版上会显得太小。按短边相对手机短边（≈ 800dp 视口的 0.6）放大，最多 1.35×。
  static double wordmarkScaleFor(Size screen) {
    final shortSide = screen.shortestSide;
    if (shortSide <= 0) return 1;
    final ratio = (shortSide / 520).clamp(1.0, 1.35);
    return ratio;
  }
  static const wordmarkWeight = FontWeight.w600;
  static const wordmarkSpacing = 4.0;

  /// 涟漪最大半径（短边比例）与描边宽度。
  static const rippleRadius = 0.26;
  static const rippleStroke = 1.5;

  /// Kept for callers that still quote the system icon square; unused by the timeline.
  static const iconSize = 160.0;
}
