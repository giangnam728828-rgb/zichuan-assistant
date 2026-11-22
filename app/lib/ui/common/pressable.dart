import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../theme/motion.dart';

/// Press feedback for anything tappable: settles to [AppMotion.pressScale]
/// (0.97) while held and back to 1 on release, never past it, on a spring that
/// turns around from wherever it is. In scrollable content the press waits
/// [AppMotion.press] before it shows, so a scroll doesn't flash what it passes
/// under the finger; once shown it stays that long, so a quick tap can be seen.
///
/// Two ways to use it:
///
/// - **Owns the tap**: pass [onTap] / [onLongPress]. Adds a light selection
///   haptic on tap and button semantics.
///   ```dart
///   Pressable(onTap: openCard, child: SuggestionCard(...))
///   ```
/// - **Feedback only**: leave both null and wrap a child that already handles
///   its own taps (an `InkWell`). It only listens to raw pointers, so it never
///   competes in the gesture arena; a pointer that moves past the touch slop (a
///   scroll) cancels the press. `GlassSurface(onTap:)` has one inside already.
///
/// Reduced motion keeps the scale at 1. The fluid tier ([AppMotion.fluid]) lets
/// the release pass 1 by a hair on its way back.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = AppMotion.pressScale,
    this.haptic = true,
    this.enabled = true,
    this.semanticLabel,
    this.behavior = HitTestBehavior.deferToChild,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Scale while pressed.
  final double scale;

  /// Light selection click on tap (only when [onTap] is set).
  final bool haptic;

  /// False: no scale, no callbacks (the child still draws).
  final bool enabled;

  /// Read instead of the child's own text, when [Pressable] owns the tap.
  final String? semanticLabel;

  /// Which pointers count when it only gives feedback.
  final HitTestBehavior behavior;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> with SingleTickerProviderStateMixin {
  // Unbounded: a fluid release passes the resting value.
  late final AnimationController _press = AnimationController.unbounded(vsync: this);

  Offset? _downAt;

  /// Running while a press in scrollable content waits to show.
  Timer? _delay;

  /// Running while a press that showed has to stay.
  Timer? _hold;
  bool _lifted = false;

  bool get _ownsTap => widget.onTap != null || widget.onLongPress != null;

  @override
  void didUpdateWidget(Pressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Disabled mid-press: the release no longer reaches the gesture callbacks.
    if (oldWidget.enabled && !widget.enabled) _cancel();
  }

  @override
  void dispose() {
    _delay?.cancel();
    _hold?.cancel();
    _press.dispose();
    super.dispose();
  }

  void _down([Offset? at]) {
    if (!widget.enabled || AppMotion.reduced(context)) return;
    _downAt = at;
    _lifted = false;
    _delay?.cancel();
    // Owning the tap, `onTapDown` already comes after kPressTimeout (100ms) when
    // a scrollable is competing for the pointer, and not at all if it wins.
    if (at != null && Scrollable.maybeOf(context) != null) {
      _delay = Timer(AppMotion.press, _show);
    } else {
      _show();
    }
  }

  void _show() {
    _delay = null;
    _hold?.cancel();
    _hold = Timer(AppMotion.press, () {
      _hold = null;
      if (_lifted) _settle(0);
    });
    _settle(1);
  }

  /// The finger came up on a tap, which shows even if it was too quick to wait for.
  void _up() {
    _downAt = null;
    if (_delay case final delay?) {
      delay.cancel();
      _show();
    }
    _lifted = true;
    if (_hold == null) _settle(0);
  }

  /// A scroll or the system took the pointer: no tap to show.
  void _cancel() {
    _downAt = null;
    _delay?.cancel();
    _delay = null;
    _hold?.cancel();
    _hold = null;
    _settle(0);
  }

  void _settle(double target) {
    if (_press.value == target && !_press.isAnimating) return;
    if (target == 0 && AppMotion.fluid(context)) {
      _press.animateWith(
        SpringSimulation(
          AppMotion.releaseSpring,
          _press.value,
          0,
          _press.velocity,
          snapToEnd: true,
          tolerance: const Tolerance(distance: 0.002, velocity: 0.02),
        ),
      );
      return;
    }
    _press.animateWith(AppMotion.settle(AppMotion.pressSpring, _press.value, target, _press.velocity));
  }

  void _move(PointerMoveEvent event) {
    final at = _downAt;
    if (at == null) return;
    // What the scrollable above goes by: on Android, well under kTouchSlop.
    final slop = MediaQuery.maybeGestureSettingsOf(context)?.touchSlop ?? kTouchSlop;
    if ((event.position - at).distance > slop) _cancel();
  }

  void _tap() {
    if (widget.haptic) HapticFeedback.selectionClick();
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    // The same tree whether enabled or not, so the child keeps its state.
    final scaled = ScaleTransition(
      scale: Tween(begin: 1.0, end: widget.scale).animate(_press),
      child: widget.child,
    );
    // 第 6 步：高光跟随手指位置。按下点在本地坐标里，柔光以它为中心，随按压缩放淡入；
    // 只画一层径向渐变，不加模糊、不采样背景。
    final child = _PressedGlow(at: _downAt, press: _press, child: scaled);
    if (!_ownsTap) {
      return Listener(
        behavior: widget.behavior,
        onPointerDown: (e) => _down(e.position),
        onPointerMove: _move,
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _cancel(),
        child: child,
      );
    }
    final enabled = widget.enabled;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      // The label stands in for the visible text instead of repeating it.
      excludeSemantics: widget.semanticLabel != null,
      onTap: enabled && widget.onTap != null ? _tap : null,
      onLongPress: enabled ? widget.onLongPress : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: enabled ? (d) => _down(d.localPosition) : null,
        onTapUp: enabled ? (_) => _up() : null,
        onTapCancel: enabled ? _cancel : null,
        onTap: enabled && widget.onTap != null ? _tap : null,
        onLongPress: enabled && widget.onLongPress != null
            ? () {
                _up();
                widget.onLongPress!();
              }
            : null,
        child: child,
      ),
    );
  }
}

/// 按下的位置那一团柔光（第 6 步）：以按下点为中心的径向渐变，透明度跟着按压值。
///
/// 只在有按下点（手指真的落在上面）时画；键盘/无障碍触发的按压没有位置，就只是缩放。
class _PressedGlow extends StatelessWidget {
  const _PressedGlow({required this.at, required this.press, required this.child});

  final Offset? at;
  final Animation<double> press;
  final Widget child;

  static const _radius = 72.0;

  @override
  Widget build(BuildContext context) {
    final at = this.at;
    if (at == null) return child;
    final tint = Theme.of(context).colorScheme.onSurface;
    return AnimatedBuilder(
      animation: press,
      builder: (context, child) {
        final t = press.value.clamp(0.0, 1.0);
        if (t <= 0) return child ?? const SizedBox.shrink();
        return Stack(
          clipBehavior: Clip.none,
          children: [
            child ?? const SizedBox.shrink(),
            Positioned(
              left: at.dx - _radius,
              top: at.dy - _radius,
              width: _radius * 2,
              height: _radius * 2,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        tint.withValues(alpha: 0.07 * t),
                        tint.withValues(alpha: 0),
                      ],
                      stops: const [0, 1],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
      child: child,
    );
  }
}
