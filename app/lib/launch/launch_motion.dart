// 启动画面的动效：一条时间线，从系统启动画面交到 App 手里那一刻算起。
//
// 知川助手（第 1 步：开屏重做）：系统启动页只画纯色，不放任何图标，所以这里
// 也不再从「系统画的方形图标」接着往下演——那正是「方形 → 圆形」割裂的来源。
// 现在整条时间线只有三件事：
//
//   0 ms      纯色底，与系统页同一个颜色（res/values{-night}/colors.xml）。
//   0–500     全屏立绘淡入，同时从 1.04 缓慢推近到 1.0（Cubic(.2,0,0,1)，
//             慢起柔停）。立绘用 cover 铺满，不裁形状，所以没有任何"出现"的边缘。
//   350–800   品牌字「知川助手」淡入，自下 12 上浮到位（Cubic(0,0,.2,1)）。
//   800–1400  一道细光只从左向右扫过品牌字一次（Cubic(.45,0,.55,1)），
//             峰值不透明度 0.18，比原来扫整块图低调。
//   1400 起   静止，等界面可用。
//   界面可用   整层 300 ms 淡出（AppMotion.std）；可能在任何时刻到来，不等动画播完。
//
// 系统要求减少动画时：立绘与品牌字直接停在各自终点，不再播放。

import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart' show Rect, Size;

/// Where things are at one moment of the launch timeline.
class LaunchFrame {
  const LaunchFrame({
    required this.artOpacity,
    required this.artScale,
    required this.wordmarkOpacity,
    required this.wordmarkRise,
    this.sweep,
  });

  /// The full-bleed artwork's opacity, 0 → 1.
  final double artOpacity;

  /// The artwork's scale, [LaunchMotion.artScaleFrom] → 1.0.
  final double artScale;

  /// 0 → 1 as the wordmark comes in.
  final double wordmarkOpacity;

  /// How far below its resting place the wordmark is (logical pixels).
  final double wordmarkRise;

  /// The light band's progress across the wordmark (0 → 1), or null when it isn't on it.
  final double? sweep;
}

/// The launch layout: full-screen artwork, and the wordmark placed below its centre.
class LaunchLayout {
  LaunchLayout({required this.screen, this.cover = Rect.zero});

  /// The window the launch layer fills.
  final Size screen;

  /// Kept for callers that still measure the system's splash icon square; nothing
  /// in the timeline positions itself from it any more.
  final Rect cover;

  /// The wordmark's line height.
  double get wordmarkHeight => LaunchMotion.wordmarkSize * LaunchMotion.wordmarkLine;

  /// The wordmark's centre: below the middle, so it never sits on the artwork's face.
  double get wordmarkCenterY => screen.height * LaunchMotion.wordmarkAnchor;

  /// Top of the wordmark's line at rest.
  double get wordmarkTop => wordmarkCenterY - wordmarkHeight / 2;

  /// How tall the soft gradient under the wordmark is: from the bottom of the
  /// screen up past the wordmark, so it reads on top of the artwork.
  double get wordmarkScrimHeight => screen.height * LaunchMotion.wordmarkScrimHeight;

  /// The light band's track: a little wider than the wordmark, centred on it.
  Rect get sweepBand {
    final width = screen.width * LaunchMotion.sweepBandWidth;
    return Rect.fromCenter(
      center: Offset(screen.width / 2, wordmarkCenterY),
      width: width,
      height: wordmarkHeight,
    );
  }

  /// The lockup at [t] since the launch screen took over.
  LaunchFrame at(Duration t) {
    final ms = t.inMicroseconds / 1000;
    final a = _progress(ms, LaunchMotion.artIn);
    final w = _progress(ms, LaunchMotion.wordmark);
    final sweep = _progress(ms, LaunchMotion.sweep);
    final artCurve = LaunchMotion.artInCurve.transform(a);
    return LaunchFrame(
      artOpacity: artCurve,
      // 1.04 → 1.0, never below 1: the picture only ever settles, never recedes.
      artScale: LaunchMotion.artScaleFrom +
          (1 - LaunchMotion.artScaleFrom) * LaunchMotion.artScaleCurve.transform(a),
      wordmarkOpacity: LaunchMotion.wordmarkFade.transform(w),
      wordmarkRise: LaunchMotion.wordmarkRiseBy * (1 - LaunchMotion.wordmarkRiseCurve.transform(w)),
      sweep: sweep <= 0 || sweep >= 1 ? null : LaunchMotion.sweepCurve.transform(sweep),
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
  /// The artwork fading in and settling.
  static const artIn = (0, 500);

  /// The wordmark coming in.
  static const wordmark = (350, 800);

  /// The light crossing the wordmark.
  static const sweep = (800, 1400);

  /// Everything has come to rest.
  static const total = Duration(milliseconds: 1400);

  /// The whole layer fading away once the app is usable.
  static const leave = Duration(milliseconds: 300);

  /// A custom launch screen fading in over the system's picture.
  static const customIn = Duration(milliseconds: 360);

  /// Slow start, soft landing: the artwork is already there, it only settles.
  static const artInCurve = Cubic(0.2, 0.0, 0.0, 1.0);
  static const artScaleCurve = Cubic(0.2, 0.0, 0.0, 1.0);
  static const wordmarkFade = Cubic(0.0, 0.0, 0.2, 1.0);
  static const wordmarkRiseCurve = Cubic(0.2, 0.0, 0.0, 1.0);
  static const sweepCurve = Cubic(0.45, 0.0, 0.55, 1.0);

  /// The artwork starts slightly larger and settles to 1.0.
  static const artScaleFrom = 1.04;

  /// Where the wordmark's centre sits, as a fraction of the screen height.
  static const wordmarkAnchor = 0.60;

  /// The wordmark: AppType.wordmark at this size, its line this many times the size.
  static const wordmarkSize = 28.0;
  static const wordmarkLine = 1.2;

  /// The wordmark starts this far below its place.
  static const wordmarkRiseBy = 12.0;

  /// The soft gradient under the wordmark: its height as a fraction of the screen,
  /// and how opaque the page colour gets at the very bottom.
  static const wordmarkScrimHeight = 0.30;
  static const wordmarkScrimPeak = 0.55;

  /// The light band's width against the screen's, its tilt, its brightest white.
  static const sweepBandWidth = 0.62;
  static const sweepTilt = 0.32; // radians, about 18°
  static const sweepPeak = 0.18;

  /// The asset the launch layer draws, full bleed.
  static const artAsset = 'assets/brand/launch_bg.jpg';

  /// Kept for callers that still quote the system icon square; unused by the timeline.
  static const iconSize = 160.0;
}
