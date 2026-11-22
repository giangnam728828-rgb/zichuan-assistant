// 川水 · 底部悬浮水滴导航（对话 / 历史 / 工具 / 设置）。
//
// 只做「看得见 + 点得着」：状态由 rootTabProvider 管，高度由外壳传进来。
// - 选中项上浮 2dp；水滴指示器按下鼓起、松手弹簧落地（阻尼 0.7）。
// - 角标直接读会话状态 provider，不依赖页面是否已构建（懒加载下历史页可能还没建）。
// - 同一标签同时只显示一种角标：待确认是数字点，运行中是呼吸点。
// - 长按捷径：对话 = 新对话，历史 = 聚焦搜索。
// - 重复点击当前标签：对话/工具/设置回根页，历史回顶部。
// - 「减少动画」时全部直接切换；手机横屏（高度 < 500dp）只留图标。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/drawer_view_state.dart' show drawerScopeProvider;
import '../../state/session_attention_state.dart' show pendingInteractionsProvider, PendingKind;
import '../../state/sessions_state.dart' show currentSessionProvider;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'root_tab.dart';
import 'shell_insets.dart';

/// 导航角标：一次只显示一种，克制。
class NavBadges {
  const NavBadges({this.pending = 0, this.running = false, this.chatRunning = false});

  /// 等待确认的会话数（历史标签上的数字点）。
  final int pending;

  /// 有会话在跑（历史标签上的呼吸点）。
  final bool running;

  /// 当前对话在跑（对话标签上的呼吸点）。
  final bool chatRunning;
}

/// 直接读 provider：历史页没构建过也有数据。
final navBadgesProvider = Provider<NavBadges>((ref) {
  final pending = ref.watch(pendingInteractionsProvider);
  final scope = ref.watch(drawerScopeProvider);
  final current = ref.watch(currentSessionProvider);
  final sessions = scope?.sessions ?? const [];
  final running = sessions.any((s) => s.running);
  final chatRunning = current == null ? false : sessions.any((s) => s.sessionId == current && s.running);
  // 待确认只算「要人动手」的那种；纯运行中的不算。
  final waiting = pending.values.where((k) => k == PendingKind.approval || k == PendingKind.question).length;
  return NavBadges(pending: waiting, running: running, chatRunning: chatRunning);
});

class BottomNav extends ConsumerWidget {
  const BottomNav({
    super.key,
    required this.reveal,
    required this.compact,
    this.onReselect,
  });

  /// 0 = 收起（键盘弹起），1 = 展开。外壳驱动。
  final Animation<double> reveal;

  /// 手机横屏等矮窗口：只保留图标。
  final bool compact;

  /// 重复点击当前标签。
  final void Function(RootTab tab)? onReselect;

  static const height = ShellMetrics.navHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(rootTabProvider);
    final badges = ref.watch(navBadgesProvider);
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return IgnorePointer(
      ignoring: reveal.value == 0,
      child: AnimatedBuilder(
        animation: reveal,
        builder: (context, child) {
          final t = reveal.value.clamp(0.0, 1.0);
          return Opacity(
            opacity: t,
            child: Transform.translate(offset: Offset(0, (1 - t) * 24), child: child),
          );
        },
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            bottom: (MediaQuery.paddingOf(context).bottom + ShellMetrics.navGap),
          ),
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            label: '主导航',
            child: GlassSurface(
              tier: GlassTier.chrome,
              borderRadius: const BorderRadius.all(Radius.circular(AppShape.float)),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final tab in RootTab.values)
                    Expanded(
                      child: _TabKey(
                        tab: tab,
                        selected: tab == current,
                        compact: compact,
                        reduceAnimations: reduce,
                        badge: switch (tab) {
                          RootTab.chat => badges.chatRunning,
                          RootTab.history => badges.pending > 0 || badges.running,
                          _ => false,
                        },
                        badgeCount: tab == RootTab.history ? badges.pending : 0,
                        badgeBusy: tab == RootTab.chat ? badges.chatRunning : badges.pending == 0 && badges.running,
                        onTap: () => _onTap(context, ref, tab),
                        onLongPress: switch (tab) {
                          RootTab.chat => () {
                            HapticFeedback.mediumImpact();
                            switchTab(context, RootTab.chat, intent: TabIntent.newChat);
                          },
                          RootTab.history => () {
                            HapticFeedback.mediumImpact();
                            switchTab(context, RootTab.history, intent: TabIntent.focusSearch);
                          },
                          _ => null,
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onTap(BuildContext context, WidgetRef ref, RootTab tab) {
    final current = ref.read(rootTabProvider);
    if (current == tab) {
      // 重复点击：交给页面自己回顶部/底部/根页。
      HapticFeedback.selectionClick();
      onReselect?.call(tab);
      return;
    }
    switchTab(context, tab);
  }
}

class _TabKey extends StatelessWidget {
  const _TabKey({
    required this.tab,
    required this.selected,
    required this.compact,
    required this.reduceAnimations,
    required this.badge,
    required this.badgeCount,
    required this.badgeBusy,
    required this.onTap,
    this.onLongPress,
  });

  final RootTab tab;
  final bool selected;
  final bool compact;
  final bool reduceAnimations;
  final bool badge;
  final int badgeCount;
  final bool badgeBusy;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  static IconData iconOf(RootTab tab) => switch (tab) {
    RootTab.chat => AppIcons.chat,
    RootTab.history => AppIcons.history,
    RootTab.tools => AppIcons.tool,
    RootTab.settings => AppIcons.settings,
  };

  static String labelOf(RootTab tab) => switch (tab) {
    RootTab.chat => '对话',
    RootTab.history => '历史',
    RootTab.tools => '工具',
    RootTab.settings => '设置',
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tint = selected ? colors.primary : colors.onSurfaceVariant;
    final duration = reduceAnimations ? Duration.zero : AppMotion.quick;
    final curve = reduceAnimations ? Curves.linear : const _DropSpring();

    return Semantics(
      button: true,
      selected: selected,
      label: labelOf(tab),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(AppShape.float),
        child: SizedBox(
          height: ShellMetrics.minTapTarget,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 图标：选中上浮 2dp；角标压在右上角。
              AnimatedSlide(
                duration: duration,
                curve: curve,
                offset: Offset(0, selected ? -0.06 : 0),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(iconOf(tab), size: 22, color: tint),
                    if (badge) Positioned(right: -7, top: -3, child: _Badge(count: badgeCount, busy: badgeBusy)),
                  ],
                ),
              ),
              if (!compact) ...[
                const SizedBox(height: 3),
                AnimatedDefaultTextStyle(
                  duration: duration,
                  curve: curve,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.2,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: tint,
                  ),
                  child: Text(labelOf(tab), maxLines: 1),
                ),
                // 水滴指示器：选中时从 0 鼓起成 10×3 的椭圆。
                const SizedBox(height: 2),
                AnimatedContainer(
                  duration: duration,
                  curve: curve,
                  width: selected ? 10 : 0,
                  height: selected ? 3 : 0,
                  decoration: BoxDecoration(
                    color: colors.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 按下鼓起、松手落地，阻尼约 0.7 —— 用一个轻微过冲的曲线近似。
class _DropSpring extends Curve {
  const _DropSpring();

  @override
  double transformInternal(double t) {
    // 过冲 ~4%，收得干净。
    final damped = 1 - math.pow(1 - t, 2.2) * math.cos(t * math.pi * 0.7);
    return damped.clamp(0.0, 1.06);
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count, required this.busy});

  final int count;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (count > 0) {
      return Container(
        constraints: const BoxConstraints(minWidth: 14),
        padding: const EdgeInsets.symmetric(horizontal: 3.5),
        height: 14,
        decoration: BoxDecoration(color: colors.error, borderRadius: BorderRadius.circular(7)),
        alignment: Alignment.center,
        child: Text(
          count > 9 ? '9+' : '$count',
          style: TextStyle(fontSize: 9, height: 1, fontWeight: FontWeight.w700, color: colors.onError),
        ),
      );
    }
    // 运行中：一个呼吸的小圆点。
    final dot = Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: colors.primary, shape: BoxShape.circle),
    );
    if (reduce) return dot;
    return _BreathingDot(child: dot);
  }
}

class _BreathingDot extends StatefulWidget {
  const _BreathingDot({required this.child});

  final Widget child;

  @override
  State<_BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<_BreathingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: AppMotion.breath);

  @override
  void initState() {
    super.initState();
    // 不在 initState 读 MediaQuery：放进 post-frame。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _c.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: Tween(begin: 0.45, end: 1.0).animate(_c), child: widget.child);
}
