// 启动画面的时间线：关键帧上的透明度与缩放，按 launch_motion.dart 顶部的设计量出来。
//
// 知川助手第 1 步：时间线从「系统图标落定 + 字标出现」改成了
// 「全屏立绘淡入推近 → 品牌字上浮 → 细光扫过品牌字」。

import 'package:dsh_app/launch/launch_motion.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 390 × 844 的手机。
  const screen = Size(390, 844);
  final layout = LaunchLayout(screen: screen);
  LaunchFrame at(int ms) => layout.at(Duration(milliseconds: ms));

  test('starts on the bare page colour: nothing drawn yet', () {
    final f = at(0);
    expect(f.artOpacity, 0);
    expect(f.artScale, closeTo(LaunchMotion.artScaleFrom, 1e-9));
    expect(f.wordmarkOpacity, 0);
    expect(f.sweep, isNull);
  });

  test('the artwork fades in and settles to 1.0 by 500 ms', () {
    expect(at(500).artOpacity, 1);
    expect(at(500).artScale, closeTo(1.0, 1e-9));
    // 只减不增：立绘只会落定，不会退回去。
    var last = double.infinity;
    for (var ms = 0; ms <= 520; ms += 10) {
      final s = at(ms).artScale;
      expect(s, lessThanOrEqualTo(last + 1e-9));
      last = s;
    }
    expect(at(260).artScale, greaterThan(1.0));
  });

  test('opacity only ever grows, everywhere', () {
    var lastArt = 0.0;
    var lastWord = 0.0;
    for (var ms = 0; ms <= 1400; ms += 10) {
      final f = at(ms);
      expect(f.artOpacity, greaterThanOrEqualTo(lastArt - 1e-9));
      expect(f.wordmarkOpacity, greaterThanOrEqualTo(lastWord - 1e-9));
      lastArt = f.artOpacity;
      lastWord = f.wordmarkOpacity;
    }
  });

  test('the wordmark comes in between 350 and 800 ms, rising 12 into place', () {
    expect(at(350).wordmarkOpacity, 0);
    expect(at(350).wordmarkRise, LaunchMotion.wordmarkRiseBy);
    expect(at(575).wordmarkOpacity, inExclusiveRange(0.0, 1.0));
    expect(at(800).wordmarkOpacity, 1);
    expect(at(800).wordmarkRise, 0);
  });

  test('the wordmark sits below the middle so it never covers the face', () {
    expect(layout.wordmarkCenterY, closeTo(screen.height * LaunchMotion.wordmarkAnchor, 1e-9));
    expect(layout.wordmarkCenterY, greaterThan(screen.height / 2));
  });

  test('one light crosses the wordmark between 800 and 1400 ms', () {
    expect(at(799).sweep, isNull);
    expect(at(800).sweep, isNull);
    expect(at(1100).sweep, inExclusiveRange(0.0, 1.0));
    expect(at(1400).sweep, isNull);
    // 由左向右。
    expect(at(900).sweep!, lessThan(at(1200).sweep!));
  });

  test('come to rest by total, and stay there', () {
    final rest = at(LaunchMotion.total.inMilliseconds);
    expect(rest.artOpacity, 1);
    expect(rest.artScale, 1.0);
    expect(rest.wordmarkOpacity, 1);
    expect(rest.wordmarkRise, 0);
    expect(rest.sweep, isNull);
    expect(at(LaunchMotion.total.inMilliseconds + 5000).wordmarkOpacity, 1);
  });

  test('a big and a small screen both put the wordmark at the same fraction', () {
    for (final s in [const Size(360, 780), const Size(844, 390), const Size(1280, 800)]) {
      final l = LaunchLayout(screen: s);
      expect(l.wordmarkCenterY, closeTo(s.height * LaunchMotion.wordmarkAnchor, 1e-9));
      expect(l.sweepBand.center.dy, closeTo(l.wordmarkCenterY, 1e-9));
    }
  });
}
