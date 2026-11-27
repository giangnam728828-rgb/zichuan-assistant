import 'package:dsh_app/performance/performance_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MotionPolicy 三档', () {
    test('默认全开', () {
      const policy = MotionPolicy(systemReduced: false, userMuted: false, lightweight: false);
      expect(policy.allows(MotionTier.essential), isTrue);
      expect(policy.allows(MotionTier.standard), isTrue);
      expect(policy.allows(MotionTier.decorative), isTrue);
      expect(policy.muted, isFalse);
    });

    test('低端机 / 发热只关装饰档，转场与按压保留', () {
      const policy = MotionPolicy(systemReduced: false, userMuted: false, lightweight: true);
      expect(policy.allows(MotionTier.essential), isTrue);
      expect(policy.allows(MotionTier.standard), isTrue, reason: '这是 V4.2 S3 的根因：档位降级不能再把基础动效归零');
      expect(policy.allows(MotionTier.decorative), isTrue, reason: '档位只能改默认值，不能替用户做选择');
      expect(policy.decorativeByDefault, isFalse);
    });

    test('用户关动画：留状态动效，关结构与装饰', () {
      const policy = MotionPolicy(systemReduced: false, userMuted: true, lightweight: false);
      expect(policy.allows(MotionTier.essential), isTrue);
      expect(policy.allows(MotionTier.standard), isFalse);
      expect(policy.allows(MotionTier.decorative), isFalse);
      expect(policy.muted, isTrue);
    });

    test('系统移除动画：三档全关，压过用户的任何选择', () {
      const policy = MotionPolicy(systemReduced: true, userMuted: false, lightweight: false);
      expect(policy.allows(MotionTier.essential), isFalse);
      expect(policy.allows(MotionTier.standard), isFalse);
      expect(policy.allows(MotionTier.decorative), isFalse);
      expect(policy.muted, isTrue);
    });

    test('withSystemReduced 只改系统位，其余保留', () {
      const base = MotionPolicy(systemReduced: false, userMuted: false, lightweight: true);
      final next = base.withSystemReduced(true);
      expect(next.systemReduced, isTrue);
      expect(next.userMuted, isFalse);
      expect(next.lightweight, isTrue);
      expect(next.allows(MotionTier.decorative), isFalse);
      expect(next.decorativeByDefault, isFalse);
      expect(identical(base.withSystemReduced(false), base), isTrue, reason: '值没变就不该产生新对象');
    });
  });

  group('PerformanceDefaults 派生', () {
    PerformanceDefaults resolve({
      DeviceTier tier = DeviceTier.medium,
      bool thermal = false,
      PerformancePrefs prefs = const PerformancePrefs(),
    }) => PerformanceDefaults.resolve(
      PerformanceSnapshot(
        device: {'tier': tier.name},
        thermal: {'lightweight': thermal},
        loaded: true,
        available: true,
      ),
      prefs,
    );

    test('低端机不再等于「关掉所有动效」', () {
      final d = resolve(tier: DeviceTier.low);
      expect(d.lightweight, isTrue);
      expect(d.motion.allows(MotionTier.standard), isTrue);
      expect(d.motion.decorativeByDefault, isFalse);
      expect(d.reduceMotion, isFalse, reason: 'reduceMotion 是用户意愿的派生值，不该被档位改写');
      expect(d.fluidMotion, isFalse);
      expect(d.tilt, isFalse);
    });

    test('发热降级同样只降装饰档', () {
      final d = resolve(thermal: true);
      expect(d.lightweight, isTrue);
      expect(d.motion.allows(MotionTier.standard), isTrue);
      expect(d.motion.decorativeByDefault, isFalse);
    });

    test('低端机仍可单独打开灵动动效', () {
      final d = resolve(tier: DeviceTier.low, prefs: const PerformancePrefs(fluid: true));
      expect(d.fluidMotion, isTrue);
    });

    test('用户关动画时 reduceMotion 为真、状态动效仍在', () {
      final d = resolve(prefs: const PerformancePrefs(animations: false));
      expect(d.reduceMotion, isTrue);
      expect(d.motion.allows(MotionTier.essential), isTrue);
      expect(d.fluidMotion, isFalse);
    });

    test('高性能机全开', () {
      final d = resolve(tier: DeviceTier.high);
      expect(d.motion.allows(MotionTier.decorative), isTrue);
      expect(d.reduceMotion, isFalse);
    });
  });
}
