// 左上角的聊天模式切换器（总方案 v2 第一阶段）。
//
// 输入栏不再承担导航：协作入口从 Composer 挪到顶栏，和标题并排。三个页面
// （普通聊天 / 议会 / 团队）用的是同一个 [ConversationModeSwitcher]，一份
// 菜单、一份路由，不在各自的页面里各写一套。
//
// 点开是**锚在按钮下方**的紧凑菜单，不是底部弹层：三个选项一眼看完，当前
// 模式带勾。选中即切换，不再二次确认。
//
// 切换规则（第二阶段）：
// - 普通聊天 → 议会/团队：回到上次那条，没有就恢复最近一条，仍没有才新建；
// - 议会 ⇄ 团队：顶层页面**替换**，不往路由栈上叠第二张协作页；
// - 议会/团队 → 普通聊天：回到原来的聊天根页，当前会话不动。
//
// 页面过场只有淡入 + 8dp 位移（[AppMotion.page]）；系统要求减少动画时
// 时长归零，直接换页。

import 'package:flutter/material.dart';
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

/// 「聊天 ⌄」：小图标 + 当前模式 + 下拉箭头。窄屏只留图标和箭头。
class ConversationModeSwitcher extends ConsumerWidget {
  const ConversationModeSwitcher({super.key, required this.mode, this.onSelect, this.forceCompact = false});

  final ConversationMode mode;

  /// 选中后的动作；不传就走统一路由（[switchConversationMode]）。
  final ValueChanged<ConversationMode>? onSelect;

  /// 测试或特殊版式里强制收起文字。
  final bool forceCompact;

  /// 窄屏 / 大字号时先收起模式文字，给标题和模型让位。
  static bool compactFor(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final label = MediaQuery.textScalerOf(context).scale(13);
    return width < 420 || label > 15.6;
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
    final duration = AppMotion.of(context, AppMotion.quick);
    void select(ConversationMode target) {
      if (onSelect case final callback?) {
        callback(target);
      } else {
        switchConversationMode(context, ref, target, from: mode);
      }
    }

    return PopupMenuButton<ConversationMode>(
      key: const ValueKey('conversation-mode'),
      tooltip: '切换聊天模式 · ${mode.label}',
      position: PopupMenuPosition.under,
      offset: const Offset(0, 2),
      color: colors.surfaceContainerHigh,
      elevation: 8,
      constraints: const BoxConstraints(minWidth: 176, maxWidth: 232),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: select,
      itemBuilder: (context) => [
        for (final option in ConversationMode.values)
          PopupMenuItem<ConversationMode>(
            key: ValueKey('mode-${option.name}'),
            value: option,
            height: 44,
            child: _ModeMenuRow(mode: option, selected: option == mode),
          ),
      ],
      child: Semantics(
        button: true,
        label: '切换聊天模式，当前${mode.label}',
        child: GlassSurface(
          tier: GlassTier.chrome,
          bare: true,
          stadium: true,
          grouped: true,
          child: SizedBox(
            height: 44,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 9 : 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    duration: duration,
                    switchInCurve: AppMotion.std,
                    switchOutCurve: AppMotion.std,
                    transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
                    child: Icon(
                      iconOf(mode),
                      key: ValueKey('mode-icon-${mode.name}'),
                      size: 18,
                      color: colors.onSurface.withValues(alpha: 0.86),
                    ),
                  ),
                  if (!compact) ...[
                    const SizedBox(width: 5),
                    AnimatedSwitcher(
                      duration: duration,
                      switchInCurve: AppMotion.std,
                      switchOutCurve: AppMotion.std,
                      transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
                      child: Text(
                        mode.label,
                        key: ValueKey('mode-label-${mode.name}'),
                        maxLines: 1,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                          color: colors.onSurface.withValues(alpha: 0.86),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 2),
                  // 箭头位置固定：图标和文字换的时候它不动。
                  Icon(AppIcons.expand, size: 12, color: colors.onSurfaceVariant.withValues(alpha: 0.7)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 菜单里的一行：选中打勾，未选中留同宽空位，文字不错位。
class _ModeMenuRow extends StatelessWidget {
  const _ModeMenuRow({required this.mode, required this.selected});

  final ConversationMode mode;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tint = selected ? colors.primary : colors.onSurfaceVariant;
    return Row(
      children: [
        SizedBox(
          width: 22,
          child: selected ? Icon(Icons.check, size: 16, color: colors.primary) : const SizedBox.shrink(),
        ),
        Icon(ConversationModeSwitcher.iconOf(mode), size: 18, color: tint),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            mode.label,
            maxLines: 1,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: selected ? colors.onSurface : colors.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ],
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
Route<T> conversationModeRoute<T>({required BuildContext context, required Widget page}) {
  final duration = AppMotion.of(context, AppMotion.page);
  final exit = AppMotion.of(context, AppMotion.quick);
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
