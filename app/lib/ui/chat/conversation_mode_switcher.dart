// 左上角的聊天模式切换器（总方案 v3）。
//
// 三个模式**一直摆在顶栏上**：聊天 / 议会 / 团队。点哪个就直接切，不再先弹
// 菜单。选中背景是一枚会滑动的药丸（AnimatedAlign，220ms easeOutCubic），
// 图标轻微缩放淡入，窄屏只留图标（每段仍是 44dp 触控）。
//
// 三个页面（普通聊天 / 议会 / 团队）用的是同一个 [ConversationModeSwitcher]，
// 一份控件、一份路由，不在各自的页面里各写一套。
//
// 切换规则：
// - 普通聊天 → 议会/团队：回到上次那条，没有就恢复最近一条，仍没有才新建；
// - 议会 ⇄ 团队：顶层页面**替换**，不往路由栈上叠第二张协作页；
// - 议会/团队 → 普通聊天：回到原来的聊天根页，当前会话不动。
//
// 页面过场只有淡入 + 8dp 位移，210ms；系统要求减少动画时全部归零。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/conversation_mode_state.dart';
import '../../state/hosts_state.dart';
import '../council/council_page.dart';
import '../shell/root_tab.dart';
import '../team/team_page.dart';
import '../theme/app_icons.dart';
import '../theme/glass.dart';
import '../theme/motion.dart';
import '../theme/surfaces.dart';

/// 「聊天 ｜ 议会 ｜ 团队」三段式切换器。三段常驻，点击即切换。
class ConversationModeSwitcher extends ConsumerWidget {
  const ConversationModeSwitcher({super.key, required this.mode, this.onSelect, this.forceCompact = false});

  final ConversationMode mode;

  /// 选中后的动作；不传就走统一路由（[switchConversationMode]）。
  final ValueChanged<ConversationMode>? onSelect;

  /// 测试或特殊版式里强制收起文字。
  final bool forceCompact;

  /// 窄屏 / 大字号只留图标，给标题和模型让位。
  static bool compactFor(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final label = MediaQuery.textScalerOf(context).scale(13);
    return width < 560 || label > 16.5;
  }

  static IconData iconOf(ConversationMode mode) => switch (mode) {
    ConversationMode.chat => AppIcons.chat,
    ConversationMode.council => AppIcons.forum,
    ConversationMode.team => AppIcons.team,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compact = forceCompact || compactFor(context);
    final colors = Theme.of(context).colorScheme;
    final reduced = AppMotion.reduced(context);
    final move = reduced ? Duration.zero : const Duration(milliseconds: 220);
    final fade = reduced ? Duration.zero : const Duration(milliseconds: 160);
    final segment = compact ? 44.0 : 64.0;
    final index = mode.index;

    void select(ConversationMode target) {
      if (target == mode) return;
      HapticFeedback.selectionClick();
      if (onSelect case final callback?) {
        callback(target);
      } else {
        switchConversationMode(context, ref, target, from: mode);
      }
    }

    return Semantics(
      container: true,
      label: '聊天模式，当前${mode.label}',
      child: GlassSurface(
        tier: GlassTier.chrome,
        bare: true,
        stadium: true,
        grouped: true,
        child: SizedBox(
          height: 44,
          width: segment * ConversationMode.values.length + 6,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Stack(
              children: [
                // 选中背景：一整段宽的药丸，靠 AnimatedAlign 在三个位置间滑动。
                AnimatedAlign(
                  duration: move,
                  curve: Curves.easeOutCubic,
                  alignment: Alignment(-1 + index.toDouble(), 0),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: AnimatedContainer(
                      duration: move,
                      curve: Curves.easeOutCubic,
                      width: segment,
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: colors.primary.withValues(alpha: 0.18)),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (final option in ConversationMode.values)
                      _ModeSegment(
                        key: ValueKey('mode-${option.name}'),
                        mode: option,
                        selected: option == mode,
                        width: segment,
                        showLabel: !compact,
                        duration: fade,
                        onTap: () => select(option),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeSegment extends StatelessWidget {
  const _ModeSegment({
    super.key,
    required this.mode,
    required this.selected,
    required this.width,
    required this.showLabel,
    required this.duration,
    required this.onTap,
  });

  final ConversationMode mode;
  final bool selected;
  final double width;
  final bool showLabel;
  final Duration duration;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tint = selected ? colors.primary : colors.onSurfaceVariant.withValues(alpha: 0.64);
    final labelStyle = TextStyle(
      fontSize: 13,
      height: 1.2,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      color: tint,
    );
    return Semantics(
      button: true,
      selected: selected,
      label: mode.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: width,
          height: 44,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedScale(
                  scale: selected ? 1 : 0.94,
                  duration: duration,
                  curve: AppMotion.std,
                  child: Icon(ConversationModeSwitcher.iconOf(mode), size: 18, color: tint),
                ),
                if (showLabel) ...[
                  const SizedBox(width: 5),
                  AnimatedDefaultTextStyle(
                    duration: duration,
                    curve: AppMotion.std,
                    style: labelStyle,
                    child: Text(mode.label, maxLines: 1),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 模式切换的唯一路由入口：三处顶栏都走这里。
///
/// [from] 是用户点菜单时所在的模式（页面自己最清楚）；不传则读全局状态。
void switchConversationMode(BuildContext context, WidgetRef ref, ConversationMode target, {ConversationMode? from}) {
  final host = ref.read(activeHostProvider);
  final hostKey = conversationHostKey(host);
  final controller = ref.read(conversationModeProvider.notifier);
  final before = ref.read(conversationModeProvider).mode;
  final current = from ?? before;

  // 先落状态，再换页：页面 initState 里读到的就是新模式。即使点的就是当前
  // 模式，也顺手把全局状态校准（用户可能用系统返回键回到聊天）。
  controller.setMode(target);
  if (target == current) return;

  if (target == ConversationMode.chat) {
    // popUntil 根页 + 切到聊天标签；currentSessionProvider 原样保留。
    switchTab(context, RootTab.chat);
    return;
  }

  final id = ref.read(conversationModeProvider).idFor(target, hostKey);
  final Widget page = switch (target) {
    ConversationMode.council => CouncilPage(conversationId: id, createNew: true, resumeLatest: true),
    ConversationMode.team => TeamPage(teamId: id, createNew: true, resumeLatest: true),
    ConversationMode.chat => const SizedBox.shrink(),
  };
  final route = conversationModeRoute(context: context, page: page);
  final navigator = Navigator.of(context, rootNavigator: true);
  if (current == ConversationMode.chat) {
    navigator.push(route);
  } else {
    // 同一时刻只留一张协作页：议会 ⇄ 团队替换掉顶层，返回仍直接回聊天。
    navigator.pushReplacement(route);
  }
}

/// 模式页的过场：淡入 + 8dp 横向位移，旧页在下层淡出得不突兀。
///
/// [immediate] 给「启动时恢复上次模式」用：不走动画，第一帧就是目标页。
Route<T> conversationModeRoute<T>({required BuildContext context, required Widget page, bool immediate = false}) {
  // 内容切换 210ms（方案要求 180–220），减少动画时归零。
  final duration = immediate || AppMotion.reduced(context) ? Duration.zero : const Duration(milliseconds: 210);
  final exit = AppMotion.reduced(context) ? Duration.zero : AppMotion.of(context, AppMotion.quick);
  return PageRouteBuilder<T>(
    transitionDuration: duration,
    reverseTransitionDuration: exit,
    pageBuilder: (context, animation, secondary) => page,
    transitionsBuilder: (context, animation, secondary, child) {
      if (duration == Duration.zero) return child;
      final curved = CurvedAnimation(parent: animation, curve: AppMotion.std);
      return FadeTransition(
        opacity: curved,
        child: AnimatedBuilder(
          animation: curved,
          builder: (context, inner) => Transform.translate(offset: Offset(8 * (1 - curved.value), 0), child: inner),
          child: child,
        ),
      );
    },
  );
}
