// 川水第 7 步：陀螺仪倾斜 → 背景光斑偏移的边界。
//
// 真机手感只能装机看，这里锁住的是三条能测的约定：
//   ① 两轴被夹到 [-1, 1]，乘上限后位移永远 ≤ 6dp（方案要求）；
//   ② 没有原生通道 / 关掉开关时，[TiltGlow.usable] 为 false，不订阅、不报错；
//   ③ stop() 把光斑送回正中（不会停在偏的一侧）。
//
//   flutter test test/theme/tilt_glow_test.dart

import 'package:dsh_app/ui/theme/tilt_glow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TiltGlow.enabled = true;
    TiltGlow.instance.resetForTest();
  });

  tearDown(() {
    TiltGlow.instance.resetForTest();
    TiltGlow.enabled = true;
  });

  test('方案上限：位移不超过 6dp', () {
    expect(TiltGlow.maxShift, 6.0);
  });

  test('两轴夹到 [-1, 1]：位移永远不会超过 6dp', () {
    final tilt = TiltGlow.instance;
    tilt.feed(const TiltSample(12, -7));
    expect(tilt.value.x, 1.0);
    expect(tilt.value.y, -1.0);
    expect(tilt.value.x.abs() * TiltGlow.maxShift, lessThanOrEqualTo(6.0));
    expect(tilt.value.y.abs() * TiltGlow.maxShift, lessThanOrEqualTo(6.0));

    tilt.feed(const TiltSample(-0.35, 0.62));
    expect(tilt.value.x, closeTo(-0.35, 1e-9));
    expect(tilt.value.y, closeTo(0.62, 1e-9));
  });

  test('stop() 把光斑送回正中', () {
    final tilt = TiltGlow.instance;
    tilt.feed(const TiltSample(0.8, 0.4));
    expect(tilt.value.x, 0.8);
    tilt.stop();
    expect(tilt.value, const TiltSample(0, 0));
    expect(tilt.running, isFalse);
  });

  test('开关关掉时不可用（低端机/省电侧的兜底）', () async {
    TiltGlow.enabled = false;
    expect(await TiltGlow.instance.usable, isFalse);
    await TiltGlow.instance.start();
    expect(TiltGlow.instance.running, isFalse, reason: '不可用时不该订阅');
  });

  testWidgets('TiltScope：减少动画时不订阅，页面照常挂载', (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: TiltScope(child: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();
    expect(TiltGlow.instance.running, isFalse, reason: '减少动画时关闭（方案第 7 步）');
    expect(tester.takeException(), isNull);
  });
}
