// 议会与团队共用的聊天外壳：顶栏、消息气泡、输入栏、成员行。
//
// 方案第六部分要求两种模式与普通聊天同一套视觉：透明的顶栏行、同样的
// 页面背景、同样的气泡间距、同样的底部输入栏。普通聊天的 ChatScreen 绑着
// Host 会话与工具流，没法直接套在协作运行上，所以这里把两者共用的那几件
// 抽出来，议会页与团队页都用它——不再各画一套。

import 'package:flutter/material.dart';

import '../../council/collab_models.dart';
import '../chat/model_brand_mark.dart';
import '../providers/provider_brand_icon.dart';
import '../chat/render/markdown_body.dart';
import '../theme/app_icons.dart';

/// 协作页顶栏：返回 + 标识 + 标题/副标题 + 右侧动作。
class CollabHeader extends StatelessWidget {
  const CollabHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.actions,
    this.onTitleTap,
  });

  final String title;
  final String subtitle;

  /// 「议会」/「团队」的模式标识。
  final Widget badge;
  final List<Widget> actions;
  final VoidCallback? onTitleTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回',
            icon: const Icon(AppIcons.back, size: 22),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: InkWell(
              onTap: onTitleTap,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 6),
                        badge,
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// 模式标识：一枚小胶囊，字是「议会」/「团队」。
class CollabModeBadge extends StatelessWidget {
  const CollabModeBadge({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600, height: 1.2),
      ),
    );
  }
}

/// 我说的一句话：右侧主色容器气泡，与团队/聊天一致。
class CollabUserBubble extends StatelessWidget {
  const CollabUserBubble({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10, left: 48, right: 4),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
          padding: const EdgeInsets.fromLTRB(13, 10, 13, 11),
          decoration: BoxDecoration(
            color: colors.primaryContainer,
            borderRadius: BorderRadius.circular(18),
          ),
          child: MarkdownBody(text: text, selectable: false),
        ),
      ),
    );
  }
}

/// 一条模型消息：品牌图 + 名字 + 正文，下面一行状态。
class CollabMessage extends StatelessWidget {
  const CollabMessage({
    super.key,
    required this.brand,
    required this.name,
    required this.text,
    this.status,
    this.statusColor,
    this.failed = false,
    this.onNameTap,
    this.streaming = false,
    this.trailing,
  });

  final ModelBrand brand;
  final String name;
  final String text;

  /// 「作答中…」/「失败：…」；空则不画。
  final String? status;
  final Color? statusColor;
  final bool failed;
  final VoidCallback? onNameTap;
  final bool streaming;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final color = failed ? colors.error : brandColorOn(brand, colors);
    return Padding(
      padding: const EdgeInsets.only(top: 10, right: 28, left: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, right: 8),
            child: ProviderBrandIcon(brand: brand, size: 20, filled: true),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: InkWell(
                        onTap: onNameTap,
                        borderRadius: BorderRadius.circular(4),
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colors.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    if (trailing != null) ...[const SizedBox(width: 6), trailing!],
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.86),
                  padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
                  decoration: BoxDecoration(
                    color: failed ? colors.errorContainer.withValues(alpha: 0.55) : colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: MarkdownBody(text: text, streaming: streaming),
                ),
                if (status != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (streaming) ...[
                          SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
                          ),
                          const SizedBox(width: 5),
                        ],
                        Flexible(
                          child: Text(
                            status!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: statusColor ?? colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一条系统提示（队友加入/离开、主席换了人）。
class CollabSystemNote extends StatelessWidget {
  const CollabSystemNote({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 32),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
        ),
      ),
    );
  }
}

/// 议会/团队共用的输入栏：和普通聊天同一套圆角填充、同一颗发送键。
class CollabComposer extends StatefulWidget {
  const CollabComposer({
    super.key,
    required this.controller,
    required this.onSend,
    required this.busy,
    this.hint = '说点什么',
    this.onStop,
    this.leading,
    this.onChanged,
    this.enabled = true,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final bool busy;
  final String hint;
  final VoidCallback? onStop;
  final Widget? leading;
  final ValueChanged<String>? onChanged;
  final bool enabled;

  @override
  State<CollabComposer> createState() => _CollabComposerState();
}

class _CollabComposerState extends State<CollabComposer> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
  }

  @override
  void didUpdateWidget(CollabComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
    }
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = widget.controller.text.trim();
    final canSend = text.isNotEmpty && !widget.busy && widget.enabled;
    return Padding(
      // 键盘弹起时随 viewInsets 上移，不被系统导航栏遮住。
      padding: EdgeInsets.fromLTRB(8, 6, 8, 8 + MediaQuery.viewInsetsOf(context).bottom * 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (widget.leading != null) ...[widget.leading!, const SizedBox(width: 4)],
          Expanded(
            child: TextField(
              controller: widget.controller,
              enabled: widget.enabled,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              onChanged: widget.onChanged,
              style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurface),
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: theme.textTheme.bodyMedium?.copyWith(color: colors.outline),
                filled: true,
                fillColor: colors.surfaceContainerHighest,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          if (widget.busy)
            IconButton.filledTonal(
              tooltip: '停止',
              onPressed: widget.onStop,
              icon: const Icon(AppIcons.stopGenerating, size: 20),
            )
          else
            IconButton.filled(
              tooltip: '发送',
              onPressed: canSend ? widget.onSend : null,
              icon: const Icon(AppIcons.send, size: 20),
            ),
        ],
      ),
    );
  }
}

/// 席位/队友行的头像：品牌图 + 淡底圆。
class CollabAvatar extends StatelessWidget {
  const CollabAvatar({super.key, required this.brand, this.size = 32});

  final ModelBrand brand;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = brandColorOn(brand, Theme.of(context).colorScheme);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      alignment: Alignment.center,
      child: BrandGlyph(brand: brand, size: size * 0.54, color: color),
    );
  }
}

/// 席位状态的一句话（议会消息下面那行）。
(String, Color) seatStatus(CollabRun run, SeatSpec seat, ColorScheme colors) {
  final state = run.seatOf(seat.id);
  return switch (state.status) {
    SeatStatus.pending => ('等待中', colors.onSurfaceVariant),
    SeatStatus.running => ('作答中…', colors.primary),
    SeatStatus.answered => ('已作答', colors.onSurfaceVariant),
    SeatStatus.revised => ('已修订', colors.onSurfaceVariant),
    SeatStatus.failed => ('失败${state.error == null ? '' : '：${state.error}'}', colors.error),
    SeatStatus.timedOut => ('超时${state.attempts > 1 ? '（重试后）' : ''}', colors.error),
    SeatStatus.cancelled => ('已取消', colors.onSurfaceVariant),
  };
}
