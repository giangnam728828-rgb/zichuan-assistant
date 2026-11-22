// 鸿蒙的默认启动动画：原生答的就是这个形状（ohos/.../LaunchPlugin.ets，
// runtime/tests/ohos/launch-channel.test.mjs 核那一半）。系统启动页自己淡出，没有交接；静止的图标
// 在系统画它的地方等 App 就绪（最多 1.2 s），然后才开始动：App 头 0.7 s 的工作会卡住那几帧。

import 'dart:typed_data';

import 'package:dsh_app/launch/launch_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Map<Object?, Object?> _answer({bool coldEngine = true}) => {
  'active': true,
  'sdk': 26,
  'systemSplash': false,
  'systemIcon': true,
  'iconPx': 192,
  'icon': Uint8List(192 * 192 * 4),
  'background': 0xFFEBF1FE,
  'backgroundBottom': 0xFFEBF1FE,
  'dark': false,
  'coldEngine': coldEngine,
  'motionAfterReady': true,
};

void main() {
  testWidgets('what native answers makes a launch screen with the icon where the system drew it', (tester) async {
    final snapshot = (await tester.runAsync(() => LaunchSnapshot.fromMap(_answer())))!;
    expect(snapshot.systemSplash, isFalse);
    expect(snapshot.systemIcon, isTrue);
    expect(snapshot.icon, isNotNull);
    expect(snapshot.background, const Color(0xFFEBF1FE));
    expect(snapshot.backgroundBottom, snapshot.background, reason: 'the start window is one flat colour');
    expect(snapshot.iconRect(const Size(400, 800), 3), const Rect.fromLTWH(168, 368, 64, 64));
    snapshot.icon!.dispose();
  });

  testWidgets('the motion starts once the app is ready, with nothing to take away', (tester) async {
    final channel = FakeLaunchChannel();
    final snapshot = (await tester.runAsync(() => LaunchSnapshot.fromMap(_answer())))!;
    expect(snapshot.motionAfterReady, isTrue);
    final controller = LaunchController(snapshot: snapshot, channel: channel);
    addTearDown(controller.dispose);
    controller.firstFrame();
    expect(controller.phase, LaunchPhase.cover);
    controller.ready();
    expect(controller.phase, LaunchPhase.playing);
    expect(channel.calls, isNot(contains('reveal')));
    snapshot.icon!.dispose();
  });

  testWidgets('every start holds the motion to its end, whatever the engine is doing', (tester) async {
    Future<LaunchController> started({required bool coldEngine}) async {
      final snapshot = (await tester.runAsync(() => LaunchSnapshot.fromMap(_answer(coldEngine: coldEngine))))!;
      final controller = LaunchController(snapshot: snapshot, channel: FakeLaunchChannel());
      addTearDown(controller.dispose);
      addTearDown(snapshot.icon!.dispose);
      controller
        ..firstFrame()
        ..ready();
      return controller;
    }

    // 知川助手：引擎早在跑也照样播完一轮（原来是「界面可用就收，播到哪算哪」）。
    final running = await started(coldEngine: false);
    expect(running.phase, LaunchPhase.playing);
    running.motionDone();
    expect(running.phase, LaunchPhase.leaving);

    final waits = await started(coldEngine: true);
    expect(waits.phase, LaunchPhase.playing);
    waits.motionDone();
    expect(waits.phase, LaunchPhase.leaving);

    // 引擎先就绪也不许砍掉动效。
    final answered = await started(coldEngine: true);
    answered.engineReady();
    expect(answered.phase, LaunchPhase.playing);
    answered.motionDone();
    expect(answered.phase, LaunchPhase.leaving);
  });
}
