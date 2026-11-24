// 输入栏控制行的「模式」胶囊（B2）：原来顶着输入栏上方的那枚权限胶囊、以及
// 空状态里的「标准模式 / 完全权限」两枚选项，收成同一枚胶囊，放在 ＋ 的右边。
//
// ```
// (+) ( ⚒ 标准模式 ⌄ )                    ( ◔ ) ( ☎ ) ( 🎙 )
// ```
//
// - 新对话：写会生效的预设（「标准模式」）；权限比工作区内修改更宽时先写权限
//   （「完全权限」）——安全信息比预设重要。点开是一件表：预设在上、权限在下。
// - 已有会话：写它的权限名，点开就是权限页（showPermissionSheet）。
// - Host 还没说它给什么时整枚不画。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/session_modes.dart';
import '../../features/feature_format.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../new_chat_options.dart';
import 'plus_panel.dart' show showPermissionSheet;

/// 一枚和输入栏圆键同高的胶囊。
abstract final class ComposerModePillMetrics {
  static const height = 36.0;
  static const inset = 10.0;
  static const icon = 14.0;
  static const maxWidth = 168.0;
}

class ComposerModePill extends ConsumerWidget {
  const ComposerModePill({super.key, required this.sessionId});

  /// null：还没有会话（新对话），胶囊管预设与权限。
  final String? sessionId;

  /// 「模式：工作区内修改」；没有可说的就不画。
  ({String label, bool risky})? _mode(WidgetRef ref) {
    final id = sessionId;
    if (id != null) {
      final preset = ref.watch(sessionModesProvider(id).select((m) => m.preset));
      // 日志还没说权限时也留着入口：写「模式」，点开就是权限页。
      if (preset == null) return (label: appL10n.chatComposerMode, risky: false);
      return (label: permissionName(preset), risky: preset == 'danger-full-access' || preset == 'auto');
    }
    final mode = readNewChatMode(ref);
    final label = mode.label;
    return label == null ? null : (label: label, risky: mode.risky);
  }

  void _open(BuildContext context) {
    HapticFeedback.selectionClick();
    switch (sessionId) {
      case final id?:
        unawaited(showPermissionSheet(context, id));
      case null:
        unawaited(showNewChatModeSheet(context));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = _mode(ref);
    if (mode == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final risky = mode.risky;
    final fg = risky ? dsh.onWarningContainer : theme.colorScheme.onSurfaceVariant;
    final shape = StadiumBorder(
      side: BorderSide(
        color: risky ? dsh.warning.withValues(alpha: 0.35) : DshSurfaces.of(context).pill.hairline,
        width: 0.5,
      ),
    );
    return Semantics(
      button: true,
      label: l10n.chatComposerMode,
      value: mode.label,
      onTap: () => _open(context),
      excludeSemantics: true,
      child: Material(
        key: const ValueKey('composer-mode'),
        color: risky
            ? Color.alphaBlend(dsh.warningContainer.withValues(alpha: 0.94), theme.colorScheme.surface)
            : theme.colorScheme.onSurface.withValues(alpha: 0.04),
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _open(context),
          customBorder: const StadiumBorder(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: ComposerModePillMetrics.height,
              maxWidth: ComposerModePillMetrics.maxWidth,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: ComposerModePillMetrics.inset),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    risky ? AppIcons.securityWarning : AppIcons.permissions,
                    size: ComposerModePillMetrics.icon,
                    color: fg,
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      mode.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(color: fg),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(AppIcons.expand, size: ComposerModePillMetrics.icon, color: fg.withValues(alpha: 0.7)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
