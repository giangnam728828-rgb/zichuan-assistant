// 会话类型的选择器（总方案 v4 / V4.2 · S5 D2）。
//
// 类型只在「新建会话」时确定：已有会话不能在会话内换类型。因此顶栏那枚
// 按钮是**只读徽标**（图标 + 名字，没有小箭头、不响应点击），真正的入口是
// 右上角「新对话」——点开是一张纵向三项的轻量悬浮面板（聊天 / 议会 / 团队），
// 选中当前类型就是再建一条同类会话，选中其他类型则新建该类型会话。
//
// 新建不 push 独立页面：三种模式共用同一个 ChatScreen 工作区，只改
// [conversationModeProvider] 的状态——
// - 新建议会/团队：开一条全新会话（成员配置继承最近一条）；
// - 新建普通聊天：回到未选中状态，原来的聊天会话留在历史里。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/conversation_mode_state.dart';
import '../shell/root_tab.dart';
import '../theme/app_icons.dart';
import '../theme/glass.dart';
import '../theme/motion.dart';
import '../theme/surfaces.dart';

/// 一枚紧凑的「会话类型」徽标。只显示，不切换：已有会话的类型在创建时就定了。
///
/// [onSelect] 保留给「新对话」打开的类型面板；徽标本身点击不做事。
class ConversationModeSwitcher extends ConsumerWidget {
  const ConversationModeSwitcher({super.key, required this.mode, this.onSelect, this.forceCompact = false});

  final ConversationMode mode;

  /// 选中后的动作；不传就走统一的状态切换（[switchConversationMode]）。
  final ValueChanged<ConversationMode>? onSelect;

  /// 测试或特殊版式里强制收起文字。
  final bool forceCompact;

  /// 窄屏 / 大字号只留图标，给标题让位（方案 2.2：先缩辅助文字，不缩触控区）。
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

  static String descriptionOf(ConversationMode mode) => switch (mode) {
    ConversationMode.chat => '普通 AI 对话',
    ConversationMode.council => '多个模型共同参与议题',
    ConversationMode.team => '主管与多位队友协作',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compact = forceCompact || compactFor(context);
    final colors = Theme.of(context).colorScheme;
    final tint = colors.primary;

    // 类型在新建时确定（D2）：这枚徽标只显示当前会话是什么，点它不换类型。
    return Semantics(
      label: '会话类型：${mode.label}，新建时选择',
      excludeSemantics: false,
      child: GlassSurface(
        key: const ValueKey('mode-chip'),
        tier: GlassTier.chrome,
        bare: true,
        stadium: true,
        grouped: true,
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: AppMotion.of(context, AppMotion.quick),
                  child: Icon(iconOf(mode), key: ValueKey(mode), size: 18, color: tint),
                ),
                if (!compact) ...[
                  const SizedBox(width: 5),
                  Text(
                    mode.label,
                    maxLines: 1,
                    style: TextStyle(fontSize: 13, height: 1.2, fontWeight: FontWeight.w600, color: tint),
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

/// 从按钮附近展开的纵向选择面板。用于「新对话」时选会话类型。
///
/// 走一条透明的 dialog 路由：点外面关、Android 返回键关，都是路由自带的；
/// 过场只有淡入 + 轻微缩放 + 6dp 位移（约 200ms），系统减少动画时直接呈现。
Future<void> showConversationModePanel(
  BuildContext context, {
  GlobalKey? anchor,
  required ConversationMode current,
  required ValueChanged<ConversationMode> onSelect,
}) {
  final reduced = AppMotion.reduced(context);
  final duration = reduced ? Duration.zero : const Duration(milliseconds: 200);
  // 按钮在屏幕上的位置：面板贴着它的下沿、右对齐。
  Rect? anchorRect;
  if (anchor?.currentContext case final anchorContext?) {
    final box = anchorContext.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      final overlay = Navigator.of(context, rootNavigator: true).overlay!.context.findRenderObject();
      if (overlay is RenderBox) {
        anchorRect = MatrixUtils.transformRect(box.getTransformTo(overlay), Offset.zero & box.size);
      }
    }
  }
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭类型选择',
    barrierColor: Colors.transparent,
    transitionDuration: duration,
    pageBuilder: (dialogContext, animation, secondary) => _ModePanel(
      anchorRect: anchorRect,
      current: current,
      onSelect: (mode) {
        Navigator.of(dialogContext).pop();
        onSelect(mode);
      },
    ),
    transitionBuilder: (context, animation, secondary, child) {
      if (duration == Duration.zero) return child;
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: AnimatedBuilder(
          animation: curved,
          builder: (context, inner) => Transform.translate(
            offset: Offset(0, -6 * (1 - curved.value)),
            child: Transform.scale(scale: 0.96 + 0.04 * curved.value, alignment: Alignment.topRight, child: inner),
          ),
          child: child,
        ),
      );
    },
  );
}

class _ModePanel extends StatelessWidget {
  const _ModePanel({required this.anchorRect, required this.current, required this.onSelect});

  final Rect? anchorRect;
  final ConversationMode current;
  final ValueChanged<ConversationMode> onSelect;

  static const _width = 272.0;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final rect = anchorRect;
    final top = rect == null ? padding.top + 60 : rect.bottom + 6;
    final right = rect == null ? 12.0 : (size.width - rect.right).clamp(12.0, size.width - _width - 12);
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: EdgeInsets.only(top: top.clamp(padding.top + 8, size.height - 240), right: right),
        child: Material(
          type: MaterialType.transparency,
          child: GlassSurface(
            tier: GlassTier.sheet,
            borderRadius: BorderRadius.circular(20),
            child: SizedBox(
              width: _width,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
                      child: Row(
                        children: [
                          Text(
                            '新建会话',
                            style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const Spacer(),
                          Text(
                            '类型创建后不改',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    for (final mode in ConversationMode.values)
                      _ModeOption(
                        key: ValueKey('mode-option-${mode.name}'),
                        mode: mode,
                        selected: mode == current,
                        onTap: () => onSelect(mode),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({super.key, required this.mode, required this.selected, required this.onTap});

  final ConversationMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tint = selected ? colors.primary : colors.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: mode.label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: AnimatedContainer(
              duration: AppMotion.of(context, AppMotion.standard),
              curve: AppMotion.std,
              padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
              decoration: BoxDecoration(
                color: selected ? colors.primary.withValues(alpha: 0.10) : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(ConversationModeSwitcher.iconOf(mode), size: 20, color: tint),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          mode.label,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                            color: selected ? colors.primary : colors.onSurface,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          ConversationModeSwitcher.descriptionOf(mode),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (selected)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '当前',
                        style: theme.textTheme.labelSmall?.copyWith(color: colors.primary, height: 1.2),
                      ),
                    )
                  else
                    Icon(AppIcons.newChat, size: 15, color: colors.onSurfaceVariant.withValues(alpha: 0.7)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「新对话」用：先选类型，再建会话。点外面返回 null。
///
/// D2：类型只在创建时确定一次，所以入口必须在这里而不是会话内的顶栏。
Future<ConversationMode?> pickConversationType(BuildContext context, {required ConversationMode current}) {
  final completer = Completer<ConversationMode?>();
  unawaited(
    showConversationModePanel(
      context,
      current: current,
      onSelect: (mode) {
        if (!completer.isCompleted) completer.complete(mode);
      },
    ).then((_) {
      if (!completer.isCompleted) completer.complete(null);
    }),
  );
  return completer.future;
}

/// 模式切换的唯一入口：只改状态，不再 push 任何整页路由（方案三）。
///
/// [from] 是用户点面板时所在的模式；不传则读全局状态。
void switchConversationMode(BuildContext context, WidgetRef ref, ConversationMode target, {ConversationMode? from}) {
  final controller = ref.read(conversationModeProvider.notifier);
  final current = from ?? ref.read(conversationModeProvider).mode;
  if (target == current) {
    controller.setMode(target);
    return;
  }
  HapticFeedback.selectionClick();
  if (target == ConversationMode.chat) {
    // 回普通聊天：原来的聊天会话原样保留（currentSessionProvider 不动）。
    controller.setMode(target);
  } else {
    // 切到议会/团队 = 新建一条对应会话；旧会话留在历史里。
    controller.startNew(target);
  }
  // 模式内容都在聊天工作区里：确保聊天标签在前台。
  switchTab(context, RootTab.chat);
}
