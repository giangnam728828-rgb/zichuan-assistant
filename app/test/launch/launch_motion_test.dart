// 启动画面的时间线：关键帧上的细线、两字与涟漪，按 launch_motion.dart 顶部的设计量出来。
//
// v3：极简字标开屏——细线展开 → 「知」「川」依次上浮 → 一圈涟漪。

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
    expect(f.line, 0);
    expect(f.firstOpacity, 0);
    expect(f.secondOpacity, 0);
    expect(f.firstRise, LaunchMotion.charRiseBy);
    expect(f.secondRise, LaunchMotion.charRiseBy);
    expect(f.ripple, isNull);
  });

  test('the hairline spreads from the centre over 0–300 ms', () {
    expect(at(0).line, 0);
    expect(at(150).line, inExclusiveRange(0.0, 1.0));
    expect(at(300).line, 1);
    // 只增不减。
    var last = -1.0;
    for (var ms = 0; ms <= 320; ms += 10) {
      final v = at(ms).line;
      expect(v, greaterThanOrEqualTo(last - 1e-9));
      last = v;
    }
  });

  test('「知」then「川」rise 8 dp and fade in, staggered 80 ms', () {
    expect(at(200).firstOpacity, 0);
    expect(at(200).firstRise, LaunchMotion.charRiseBy);
    expect(at(700).firstOpacity, 1);
    expect(at(700).firstRise, 0);
    // 第二字晚 80 ms 起步。
    expect(at(280).secondOpacity, 0);
    expect(at(780).secondOpacity, 1);
    expect(at(780).secondRise, 0);
    expect(at(240).secondOpacity, 0);
    expect(at(500).secondOpacity, inExclusiveRange(0.0, 1.0));
  });

  test('opacity only ever grows, everywhere', () {
    var lastFirst = 0.0;
    var lastSecond = 0.0;
    for (var ms = 0; ms <= 1100; ms += 10) {
      final f = at(ms);
      expect(f.firstOpacity, greaterThanOrEqualTo(lastFirst - 1e-9));
      expect(f.secondOpacity, greaterThanOrEqualTo(lastSecond - 1e-9));
      lastFirst = f.firstOpacity;
      lastSecond = f.secondOpacity;
    }
  });

  test('the ripple expands once between 700 and 1100 ms', () {
    expect(at(700).ripple, isNull);
    expect(at(900).ripple, inExclusiveRange(0.0, 1.0));
    expect(at(1100).ripple, isNull);
  });

  test('the mark is centred on the screen', () {
    expect(layout.centre.dx, closeTo(screen.width / 2, 1e-9));
    expect(layout.centre.dy, closeTo(screen.height / 2, 1e-9));
    expect(layout.lineWidth, closeTo(screen.width * LaunchMotion.lineSpread, 1e-9));
  });
  test('横版/平板开屏：字标按短边放大，竖版手机不变（第 7 步）', () {
    // 竖版手机（短边 390）：1.0，字号仍是 34。
    expect(LaunchMotion.wordmarkScaleFor(const Size(390, 844)), 1.0);
    // 平板横版（短边 800）：放大但没有超过上限。
    final tablet = LaunchMotion.wordmarkScaleFor(const Size(1280, 800));
    expect(tablet, greaterThan(1.0));
    expect(tablet, lessThanOrEqualTo(1.35));
    // 极端方屏也不会失控。
    expect(LaunchMotion.wordmarkScaleFor(const Size(2000, 2000)), 1.35);
  });

}
