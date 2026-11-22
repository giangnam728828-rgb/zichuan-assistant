// 知川助手 · 川水第 7 步：陀螺仪倾斜 → 背景光斑偏移。
//
// 原生侧 android/.../tilt/TiltPlugin.kt 用 SensorManager 直读（不引入任何 Flutter 传感器包）：
// `dsh/tilt` 上问 `available` / `powerSaving`，`dsh/tilt/events` 上收 30Hz 的两轴倾斜
// （右倾 +x、前倾 +y，已低通滤波，范围 [-1, 1]）。
//
// 这一层只做三件事：把两轴推到 [TiltGlow] 里、在没有原生侧（测试/桌面/鸿蒙）时安静地
// 什么都不做、以及按「低端机 / 省电 / 减少动画」决定要不要订阅。
//
// 谁订阅：聊天页可见时（`TiltScope` 包在 ChatScreen 里），页面不可见就 stop —— 光斑只在
// 看得到的时候跟手，后台不耗电。

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 一条倾斜样本（已归一化到 [-1, 1]）。
@immutable
class TiltSample {
  const TiltSample(this.x, this.y);

  final double x;
  final double y;

  @override
  bool operator ==(Object other) => other is TiltSample && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'TiltSample($x, $y)';
}

/// 原生侧（`dsh/tilt`）。没有原生侧时全部安静失败（测试、桌面、鸿蒙）。
class TiltChannel {
  const TiltChannel();

  static const _method = MethodChannel('dsh/tilt');
  static const _events = EventChannel('dsh/tilt/events');

  Future<bool> available() async {
    try {
      return await _method.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> powerSaving() async {
    try {
      return await _method.invokeMethod<bool>('powerSaving') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 30Hz 的倾斜流；原生侧没有传感器时是空流。
  Stream<TiltSample> stream() => _events.receiveBroadcastStream().map((raw) {
    if (raw is! Map) return const TiltSample(0, 0);
    final x = raw['x'];
    final y = raw['y'];
    return TiltSample(x is num ? x.toDouble() : 0, y is num ? y.toDouble() : 0);
  });
}

/// 背景光斑的倾斜来源：一个 [ValueNotifier]，供 [TideGlow] 直接读，不重建页面。
///
/// 单例（`TiltGlow.instance`）：光斑在外壳（HomeShell 的唯一一层 TideGlow），
/// 订阅由聊天页的 [TiltScope] 打开/关闭，两边通过同一个对象说话。
class TiltGlow extends ValueNotifier<TiltSample> {
  TiltGlow._() : super(const TiltSample(0, 0));

  static final TiltGlow instance = TiltGlow._();

  /// 位移上限（dp）。方案要求 ≤ 6dp。
  static const maxShift = 6.0;

  /// 进程级总开关（widget 测试关掉，避免任何平台通道抖动）。
  static bool enabled = true;

  final TiltChannel _channel = const TiltChannel();
  StreamSubscription<TiltSample>? _sub;
  bool _checked = false;

  /// 这一台设备能不能用倾斜（有传感器、不是省电模式）。
  Future<bool> get usable async {
    if (!enabled) return false;
    if (_checked) return _usable;
    final available = await _channel.available();
    final saving = available ? await _channel.powerSaving() : false;
    _usable = available && !saving;
    _checked = true;
    return _usable;
  }

  bool _usable = false;

  bool get running => _sub != null;

  /// 开始跟随（页面可见、减少动画关闭、可用时）。重复调用无害。
  Future<void> start() async {
    if (_sub != null) return;
    if (!await usable) return;
    _sub = _channel.stream().listen(_accept, onError: (_) {});
  }

  /// 停止跟随，并把光斑平滑送回正中（直接归零，避免停在偏的一侧）。
  void stop() {
    _sub?.cancel();
    _sub = null;
    if (value != const TiltSample(0, 0)) value = const TiltSample(0, 0);
  }

  /// 收一条样本：两轴先夹到 [-1, 1]，绘制层再乘 [maxShift]。
  /// 这样「偏移 ≤ 6dp」这条约束只在一个地方成立（原生侧已经归一化，这里是第二道）。
  void _accept(TiltSample sample) => value = TiltSample(sample.x.clamp(-1.0, 1.0), sample.y.clamp(-1.0, 1.0));

  @visibleForTesting
  void feed(TiltSample sample) => _accept(sample);

  @visibleForTesting
  void resetForTest() {
    stop();
    _checked = false;
    _usable = false;
  }
}

/// 让「倾斜跟随」只在子树可见时打开：包在聊天页外面即可。
///
/// - 页面不可见（切到别的标签、退到后台）→ stop，光斑回到正中，不再收样本。
/// - 系统要求减少动画 → 完全不订阅（方案第 7 步：减少动画时关闭）。
/// - 低端机/省电模式 → 原生侧不出流，[TiltGlow.usable] 也会返回 false。
class TiltScope extends StatefulWidget {
  const TiltScope({super.key, required this.child});

  final Widget child;

  @override
  State<TiltScope> createState() => _TiltScopeState();
}

class _TiltScopeState extends State<TiltScope> with WidgetsBindingObserver {
  bool _reduce = false;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce != _reduce) {
      _reduce = reduce;
      _sync();
    } else {
      _sync();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = state == AppLifecycleState.resumed;
    if (visible != _visible) {
      _visible = visible;
      _sync();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    TiltGlow.instance.stop();
    super.dispose();
  }

  void _sync() {
    if (_reduce || !_visible) {
      TiltGlow.instance.stop();
    } else {
      unawaited(TiltGlow.instance.start());
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
