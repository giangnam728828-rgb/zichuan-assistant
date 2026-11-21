// The launch screen's fixed colours are the Android launch window's (res/values{,-night}/colors.xml):
// a drift would show as a colour step at the hand-over.

import 'dart:io';
import 'dart:ui';

import 'package:dsh_app/launch/custom_launch.dart';
import 'package:dsh_app/ui/theme/palette.dart';
import 'package:flutter_test/flutter_test.dart';

Color _color(String dir, String name) {
  final xml = File('android/app/src/main/res/$dir/colors.xml').readAsStringSync();
  final m = RegExp('<color name="$name">#([0-9A-Fa-f]{8})</color>').firstMatch(xml)!;
  return Color(int.parse(m.group(1)!, radix: 16));
}

void main() {
  test('light launch colours match colors.xml', () {
    expect(LaunchColors.mistTop, _color('values', 'launch_background_top'));
    expect(LaunchColors.mistBottom, _color('values', 'launch_background_bottom'));
  });

  test('dark launch colours match values-night/colors.xml', () {
    expect(LaunchColors.nightTop, _color('values-night', 'launch_background_top'));
    expect(LaunchColors.nightBottom, _color('values-night', 'launch_background_bottom'));
  });

  test('the wordmark ink is the default palette text', () {
    expect(LaunchColors.ink, DshPalette.ink);
    expect(LaunchColors.paper, DshPalette.paper);
  });

  test('知川助手：第 2 步后启动页底色与 App 页面底色一致（无淡出色阶）', () {
    // 第 1 步把启动页定为月白/墨；第 2 步（主题层）把 App 页面底色也换成
    // 同一个月白/墨。两者一致，启动层 300 ms 淡出不再有色阶跳变。
    expect(LaunchColors.mistTop, DshPalette.mistTop);
    expect(LaunchColors.nightTop, DshPalette.nightTop);
  });
}
