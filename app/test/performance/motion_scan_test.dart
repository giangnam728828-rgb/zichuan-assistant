import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫 V4.2 · S3 的三档模型：任何新代码想判断「要不要动效」，只能问
/// `MotionPolicy.allows(...)` / `AppMotion.fluid(...)`，不能再自己去读系统开关，
/// 也不能再把 `reduceMotion` 当成「所有动效的总闸」。
///
/// 这条测试改的是源码文本，不是行为——它挡的是「以后又有人图省事加一个 if」。
void main() {
  /// 允许直接读系统无障碍开关的文件，各有不可替代的理由。
  const allowed = {
    // 唯一的合并点：系统设置在这里并入 MotionPolicy，再注入 MediaQuery。
    'lib/app.dart',
    // 开屏跑在 MaterialApp 之前，那时还没有 MotionPolicyScope。
    'lib/ui/launch/launch_overlay.dart',
    // 策略自身（含 fallback）。
    'lib/performance/motion_policy.dart',
  };

  test('lib 里只有 app.dart 与开屏能直接读系统「移除动画」', () {
    final root = _appRoot();
    final hits = <String>[];
    for (final file in root.listSync(recursive: true).whereType<File>()) {
      final rel = file.path.substring(root.path.length + 1).replaceAll(r'\', '/');
      if (!rel.startsWith('lib/') || !rel.endsWith('.dart')) continue;
      if (allowed.contains(rel)) continue;
      final text = file.readAsStringSync();
      if (text.contains('accessibilityFeatures.disableAnimations')) hits.add(rel);
    }
    expect(hits, isEmpty, reason: '这些文件绕过了 MotionPolicy：$hits');
  });

  test('没有地方再把 reduceMotion 当作所有动效的总开关', () {
    final root = _appRoot();
    final hits = <String>[];
    for (final file in root.listSync(recursive: true).whereType<File>()) {
      final rel = file.path.substring(root.path.length + 1).replaceAll(r'\', '/');
      if (!rel.startsWith('lib/') || !rel.endsWith('.dart')) continue;
      final text = file.readAsStringSync();
      // 允许：策略自身的派生定义，以及诊断输出。
      if (rel == 'lib/performance/performance_policy.dart') continue;
      if (RegExp(r'provider\.select\(\([a-z]+\) => [a-z]+\.reduceMotion\)').hasMatch(text)) hits.add(rel);
    }
    expect(hits, isEmpty, reason: '请改用 motion.allows(MotionTier.x)：$hits');
  });
}

Directory _appRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 4; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync() && Directory('${dir.path}/lib').existsSync()) return dir;
    dir = dir.parent;
  }
  fail('找不到 app 根目录（从 ${Directory.current.path} 向上 4 层）');
}
