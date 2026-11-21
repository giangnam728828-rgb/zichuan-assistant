// 启动画面: the layer over the whole app at a cold start (lib/launch/launch_state.dart has the
// story). Its first frame is the system's launch picture redrawn pixel for pixel; then the icon
// settles above the wordmark and a fine light crosses it once (lib/launch/launch_motion.dart),
// or the user's own launch screen fades in and plays once. The moment the app is usable the
// whole layer fades away, wherever the motion has got to.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../launch/custom_launch.dart';
import '../../launch/launch_media.dart';
import '../../launch/launch_motion.dart';
import '../../launch/launch_state.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../state/app_info.dart';
import '../theme/theme.dart';

/// Where the launch screen goes: over everything in the app (MaterialApp.builder), for as long
/// as [LaunchController.active] has one. Always in the tree, so the app under it keeps its place.
///
/// On a cold start it also tells the launch screen when this phone's engine is up
/// ([LaunchController.engineReady]): the motion needn't finish once the engine answers. Without
/// a launch screen (or on a warm start) it reads nothing.
class LaunchLayer extends StatelessWidget {
  const LaunchLayer({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<LaunchController?>(
    valueListenable: LaunchController.active,
    builder: (context, controller, _) {
      if (controller == null) return const SizedBox.shrink();
      final overlay = LaunchOverlay(key: ObjectKey(controller), controller: controller);
      return controller.snapshot.coldEngine ? _EngineWatch(controller: controller, child: overlay) : overlay;
    },
  );
}

/// The app under the launch screen: built and laid out all along (it keeps its place and its
/// state), but not painted while the launch screen covers it whole. Painted, its blurs ran every
/// frame of the motion: 7–11 ms of raster on a phone, more than a 120 Hz frame has.
class LaunchUnder extends StatefulWidget {
  const LaunchUnder({super.key, required this.child});

  final Widget child;

  @override
  State<LaunchUnder> createState() => _LaunchUnderState();
}

class _LaunchUnderState extends State<LaunchUnder> {
  LaunchController? _controller;

  @override
  void initState() {
    super.initState();
    _controller = LaunchController.active.value?..addListener(_changed);
    LaunchController.active.addListener(_follow);
  }

  void _follow() {
    final next = LaunchController.active.value;
    if (next == _controller) return;
    _controller?.removeListener(_changed);
    _controller = next?..addListener(_changed);
    _changed();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    LaunchController.active.removeListener(_follow);
    _controller?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phase = _controller?.phase;
    return Offstage(offstage: phase == LaunchPhase.cover || phase == LaunchPhase.playing, child: widget.child);
  }
}

/// Passes "this phone's engine is running" to a cold start's [controller].
class _EngineWatch extends ConsumerWidget {
  const _EngineWatch({required this.controller, required this.child});

  final LaunchController controller;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(localRuntimeProvider.select((s) => s.status.phase == RuntimePhase.running));
    if (running) {
      // Not during a build: the overlay rebuilds on what this changes.
      SchedulerBinding.instance.addPostFrameCallback((_) => controller.engineReady());
    }
    return child;
  }
}

/// The launch screen over the app, until [LaunchController.gone].
class LaunchOverlay extends StatefulWidget {
  const LaunchOverlay({super.key, required this.controller, this.reduceMotion});

  final LaunchController controller;

  /// Overrides the system's 减少动画 (tests, previews); null reads it from MediaQuery.
  final bool? reduceMotion;

  /// The layer's tap target (a tap skips the launch screen).
  static const skipKey = ValueKey('launch-skip');

  @override
  State<LaunchOverlay> createState() => _LaunchOverlayState();
}

class _LaunchOverlayState extends State<LaunchOverlay> with TickerProviderStateMixin {
  late final AnimationController _play = AnimationController(vsync: this, duration: LaunchMotion.total);
  late final AnimationController _custom = AnimationController(vsync: this, duration: LaunchMotion.customIn);
  late final AnimationController _leave = AnimationController(vsync: this, duration: LaunchMotion.leave);
  late final Animation<double> _shown = ReverseAnimation(CurvedAnimation(parent: _leave, curve: AppMotion.std));
  late final Animation<double> _customShown = CurvedAnimation(parent: _custom, curve: AppMotion.std);
  bool _mediaPlaying = false;

  LaunchController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_sync);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _c.firstFrame();
      // A layer remounted under a controller already past the cover won't hear of the phase it
      // missed, and the motion's first frame is a blank page.
      if (_c.phase != LaunchPhase.cover) _sync();
    });
  }

  @override
  void didUpdateWidget(LaunchOverlay old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_sync);
      widget.controller.addListener(_sync);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_sync);
    _play.dispose();
    _custom.dispose();
    _leave.dispose();
    super.dispose();
  }

  bool get _reduced => widget.reduceMotion ?? AppMotion.reduced(context);

  /// The system's own 减少动画, without a light phone's (which [_reduced] has too): the user's
  /// launch screen is their own choice, and only this keeps it to its first frame.
  bool get _systemReduced =>
      widget.reduceMotion ?? WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;

  void _sync() {
    if (!mounted) return;
    switch (_c.phase) {
      case LaunchPhase.cover || LaunchPhase.gone:
        break;
      case LaunchPhase.playing:
        if (_c.showsCustom) {
          _startCustom();
        } else if (_reduced) {
          // 减少动画：不再播放，但立绘与品牌字必须停在各自终点（progress = 1），
          // 否则会停在 0 —— 那就是一片纯色，什么也看不见。
          if (_play.value != 1) _play.value = 1;
        } else if (!_play.isAnimating && _play.value == 0) {
          unawaited(_play.forward().then((_) => _c.motionDone()));
        }
      case LaunchPhase.leaving:
        if (_leave.isAnimating || _leave.isCompleted) break;
        _play.stop();
        if (_reduced) {
          _c.gone();
        } else {
          unawaited(_leave.forward().then((_) => _c.gone()));
        }
    }
    setState(() {});
  }

  /// The user's launch screen over the system picture, as soon as its first frame is decoded.
  void _startCustom() {
    final media = _c.media;
    if (media == null || _mediaPlaying) return;
    _mediaPlaying = true;
    if (_systemReduced) {
      // 减少动画: its first frame, still.
      _custom.value = 1;
      _c.mediaFinished();
    } else {
      media.play(
        onDone: () {
          _c.mediaFinished();
          _c.motionDone();
        },
      );
      unawaited(_custom.forward());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_c.phase == LaunchPhase.gone) return const SizedBox.shrink();
    // 减少动画 (the system's, or the app's own on a light phone, which can arrive a moment
    // late): the controller then waits for nothing. The user's own picture still plays on a light
    // phone.
    final reduced = _c.showsCustom ? _systemReduced : _reduced;
    if (_c.reduced != reduced) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _c.reduced = reduced;
      });
    }
    final snapshot = _c.snapshot;
    final media = MediaQuery.of(context);
    final layout = LaunchLayout(
      screen: media.size,
      cover: _c.iconSquare(media.size, media.devicePixelRatio),
    );
    final leaving = _c.phase == LaunchPhase.leaving;
    final custom = _c.custom;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(snapshot.dark ? Brightness.dark : Brightness.light),
      child: IgnorePointer(
        ignoring: leaving,
        child: FadeTransition(
          opacity: _shown,
          child: Semantics(
            container: true,
            label: AppInfo.name,
            child: BlockSemantics(
              // A tap anywhere ends it (the page under it takes no taps meanwhile).
              child: GestureDetector(
                key: LaunchOverlay.skipKey,
                behavior: HitTestBehavior.opaque,
                onTap: _c.skip,
                // Over the navigator: no Material above to give text its style.
                child: Material(
                  type: MaterialType.transparency,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      LaunchBackground(snapshot: snapshot),
                      AnimatedBuilder(
                        animation: _play,
                        builder: (context, _) {
                          final frame = layout.at(LaunchMotion.total * _play.value);
                          return LaunchMark(
                            snapshot: snapshot,
                            frame: frame,
                            layout: layout,
                            showWordmark: !_c.showsCustom,
                          );
                        },
                      ),
                      if (custom != null && _c.media != null)
                        FadeTransition(
                          opacity: _customShown,
                          child: CustomLaunchView(custom: custom, media: _c.media!, dark: snapshot.dark),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The launch window's page: one flat colour, on every Android version.
///
/// 知川助手（第 1 步）：系统启动页现在只画 `launch_background_top` 这一个纯色
/// （values-v31 的 windowSplashScreenBackground，8–11 的 launch_background.xml），
/// 而 Kotlin 把这个颜色原样交给这一层，所以系统页与 Flutter 第一帧之间没有
/// 任何颜色或形状的跳变——这正是要消除的那种割裂。
class LaunchBackground extends StatelessWidget {
  const LaunchBackground({super.key, required this.snapshot});

  final LaunchSnapshot snapshot;

  @override
  Widget build(BuildContext context) => ColoredBox(color: snapshot.background);
}

/// 极简字标：中心细线展开、「知川」两字上浮、一圈涟漪。
///
/// v3：没有图片、没有形状、不铺满。只用 opacity / transform；
/// 减少动画时只画静态字标（由 frame 的 progress=1 保证）。
class LaunchMark extends StatelessWidget {
  const LaunchMark({
    super.key,
    required this.snapshot,
    required this.frame,
    required this.layout,
    this.showWordmark = true,
  });

  final LaunchSnapshot snapshot;
  final LaunchFrame frame;
  final LaunchLayout layout;
  final bool showWordmark;

  /// The hairline layer. Kept under this name so existing launch tests keep
  /// finding the thing that carries the motion.
  static const iconKey = ValueKey('launch-icon');
  static const wordmarkKey = ValueKey('launch-wordmark');

  Color get _accent => snapshot.dark ? LaunchColors.accentDark : LaunchColors.accentLight;

  @override
  Widget build(BuildContext context) {
    final ink = snapshot.dark ? LaunchColors.paper : LaunchColors.ink;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 中心 1px 细线向两侧展开。
        if (showWordmark)
          Center(
            child: Opacity(
              opacity: frame.line.clamp(0.0, 1.0),
              child: Transform.scale(
                scaleX: frame.line.clamp(0.0, 1.0),
                scaleY: 1,
                alignment: Alignment.center,
                child: Container(
                  key: iconKey,
                  width: layout.lineWidth,
                  height: 1,
                  color: _accent.withValues(alpha: 0.60),
                ),
              ),
            ),
          ),
        // 「知川」两字依次上浮 8dp 并淡入。
        if (showWordmark && (frame.firstOpacity > 0 || frame.secondOpacity > 0))
          Center(
            child: Opacity(
              key: wordmarkKey,
              opacity: math.max(frame.firstOpacity, frame.secondOpacity).clamp(0.0, 1.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _glyph('知', frame.firstOpacity, frame.firstRise, ink),
                  const SizedBox(width: LaunchMotion.wordmarkSpacing),
                  _glyph('川', frame.secondOpacity, frame.secondRise, ink),
                ],
              ),
            ),
          ),
        // 字后一圈涟漪：强调色 40% → 0。
        if (showWordmark && frame.ripple != null)
          IgnorePointer(
            child: CustomPaint(
              painter: _RipplePainter(
                progress: frame.ripple!.clamp(0.0, 1.0),
                radius: layout.rippleRadius,
                centre: layout.centre,
                color: _accent,
              ),
            ),
          ),
      ],
    );
  }

  Widget _glyph(String char, double opacity, double rise, Color color) => Transform.translate(
    offset: Offset(0, rise),
    child: Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: Text(
        char,
        maxLines: 1,
        softWrap: false,
        // A logo, not a line of reading: the same size at every text scale.
        textScaler: TextScaler.noScaling,
        style: AppType.wordmark(size: LaunchMotion.wordmarkSize, color: color).copyWith(
          fontWeight: LaunchMotion.wordmarkWeight,
          letterSpacing: 0,
        ),
      ),
    ),
  );
}

/// 一圈向外扩散并淡出的描边圆。
class _RipplePainter extends CustomPainter {
  const _RipplePainter({
    required this.progress,
    required this.radius,
    required this.centre,
    required this.color,
  });

  final double progress;
  final double radius;
  final Offset centre;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final r = radius * (0.25 + 0.75 * progress);
    final alpha = (1 - progress) * 0.40;
    if (alpha <= 0) return;
    canvas.drawCircle(
      centre,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = LaunchMotion.rippleStroke
        ..color = color.withValues(alpha: alpha),
    );
  }

  @override
  bool shouldRepaint(_RipplePainter old) =>
      old.progress != progress || old.radius != radius || old.centre != centre || old.color != color;
}

/// The user's launch screen: the picture on its background, filling the screen or whole and
/// centred.
class CustomLaunchView extends StatelessWidget {
  const CustomLaunchView({super.key, required this.custom, required this.media, required this.dark});

  final CustomLaunch custom;
  final LaunchMedia media;

  /// The system's mode, for the automatic background.
  final bool dark;

  /// Room around a centred picture, inside the safe area.
  static const margin = 40.0;

  @override
  Widget build(BuildContext context) {
    final size = media.size;
    final picture = SizedBox(width: size.width, height: size.height, child: media.view());
    return ColoredBox(
      color: custom.background(dark: dark),
      child: switch (custom.fit) {
        LaunchFit.fill => ClipRect(
          child: custom.zoom <= 1
              ? FittedBox(
                  fit: BoxFit.cover,
                  alignment: Alignment(custom.alignX.clamp(-1.0, 1.0), custom.alignY.clamp(-1.0, 1.0)),
                  child: picture,
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final screen = constraints.biggest;
                    if (screen.isEmpty || size.isEmpty) {
                      return FittedBox(fit: BoxFit.cover, child: picture);
                    }
                    final scale = math.max(screen.width / size.width, screen.height / size.height);
                    final z = custom.zoom.clamp(1.0, CustomLaunch.maxZoom);
                    final width = size.width * scale * z;
                    final height = size.height * scale * z;
                    return OverflowBox(
                      alignment: Alignment(custom.alignX.clamp(-1.0, 1.0), custom.alignY.clamp(-1.0, 1.0)),
                      minWidth: width,
                      maxWidth: width,
                      minHeight: height,
                      maxHeight: height,
                      child: FittedBox(fit: BoxFit.fill, child: picture),
                    );
                  },
                ),
        ),
        LaunchFit.center => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(margin),
            child: Center(
              child: FittedBox(fit: BoxFit.contain, child: picture),
            ),
          ),
        ),
      },
    );
  }
}
