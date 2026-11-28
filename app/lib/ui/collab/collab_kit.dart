// 议会与团队共用的聊天部件。
//
// 顶栏已由统一的 ChatHeader 承担（ui/chat/chat_header.dart），这里不再保留
// 协作专用的顶栏外壳；只保留两种协作模式自己的小东西（模式胶囊、成员头像、
// 席位状态文案），以及把协作数据塞进公共部件的适配层。

import 'package:flutter/material.dart';

import '../../council/collab_models.dart';
import '../chat/model_brand_mark.dart';
import '../theme/app_icons.dart';
import '../chat/widgets/thinking_pill.dart';
import '../chat/shared/conversation_kit.dart';
import '../providers/provider_brand_icon.dart';

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

/// 我说的一句话：直接用普通聊天的气泡。
class CollabUserBubble extends StatelessWidget {
  const CollabUserBubble({super.key, required this.text, this.animate = true});

  final String text;

  /// 切回旧会话时传 false：历史消息不重播进场。
  final bool animate;

  @override
  Widget build(BuildContext context) => ConversationUserMessage(text: text, animate: animate);
}

/// 一条模型消息：品牌图 + 名字 + 普通聊天的裸排正文 + 一行状态。
class CollabMessage extends StatelessWidget {
  const CollabMessage({
    super.key,
    required this.brand,
    required this.name,
    required this.text,
    this.model,
    this.status,
    this.statusColor,
    this.failed = false,
    this.onNameTap,
    this.streaming = false,
    this.thinking = false,
    this.thoughtSummary = '',
    this.reasoning = '',
    this.tools = const [],
    this.toolName = '',
    this.trailing,
    this.animate = true,
  });

  final ModelBrand brand;
  final String name;
  final String text;

  /// 「DeepSeek · V4 Pro」这一行；空则只显示品牌名。
  final String? model;

  /// 「作答中…」/「失败：…」；空则不画。
  final String? status;
  final Color? statusColor;
  final bool failed;
  final VoidCallback? onNameTap;
  final bool streaming;

  /// 这位成员此刻正在思考（v3 · 3.4：状态属于这条消息自己）。
  final bool thinking;

  /// 提供方公开的用户可见思考摘要；原始 reasoning 不进这里。
  final String thoughtSummary;

  /// 与普通聊天同源的思考正文（reasoning 增量），喂给同一个 ThinkingPill。
  final String reasoning;

  /// 这一轮真实发生过的工具调用（名称与结果都来自事件）。
  final List<CollabToolStep> tools;

  /// 真实工具名（有就显示，不编）。
  final String toolName;

  /// 名字后面那枚小标签（主席 / 只读）。
  final Widget? trailing;

  /// 切回旧会话时传 false：历史消息不重播进场。
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final config = model ?? _modelLine(brand, name);
    // 思考正文：公开摘要优先，其次是与普通聊天同源的 reasoning。
    final thought = thoughtSummary.trim().isNotEmpty ? thoughtSummary : reasoning;
    final footer = <Widget>[
      if (thinking || thought.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: ThinkingPill(reasoning: thought, active: thinking, streaming: streaming),
        ),
      // 工具轨迹挂在这位成员自己的消息下面：谁调的、调了什么、成没成，
      // 一眼对得上人（v4.3 · P0-C · 4.3）。绝不编造工具名。
      if (tools.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: CollabToolTrace(tools: tools),
        ),
    ];
    return ConversationAssistantMessage(
      brand: brand,
      name: name,
      text: text,
      model: config,
      badge: trailing,
      status: status,
      statusColor: statusColor,
      failed: failed,
      streaming: streaming,
      onNameTap: onNameTap,
      animate: animate,
      footer: footer.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: footer),
            ),
    );
  }

  /// 名字下面那行小字由调用方给的 `status` 决定，这里只标品牌名。
  static String? _modelLine(ModelBrand brand, String name) {
    final label = brandLabel(brand);
    return label.isEmpty || label == name ? null : label;
  }
}

/// 一位成员的工具调用轨迹：每行一次真实调用，状态跟着事件走。
///
/// 视觉与普通聊天的工具行同一套解剖：小图标 + 工具名 + 状态，次级色、不抢正文。
class CollabToolTrace extends StatelessWidget {
  const CollabToolTrace({super.key, required this.tools, this.limit = 4});

  final List<CollabToolStep> tools;

  /// 最多画几行：更早的收成一句「另有 N 次调用」，不刷屏。
  final int limit;

  @override
  Widget build(BuildContext context) {
    if (tools.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final shown = tools.length <= limit ? tools : tools.sublist(tools.length - limit);
    final hidden = tools.length - shown.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              '另有 $hidden 次工具调用',
              style: theme.textTheme.labelSmall?.copyWith(color: colors.outline, fontSize: 11),
            ),
          ),
        for (final step in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    switch (step.status) {
                      CollabToolStatus.calling => AppIcons.tool,
                      CollabToolStatus.done => AppIcons.done,
                      CollabToolStatus.failed => AppIcons.info,
                    },
                    size: 12,
                    color: step.status == CollabToolStatus.failed ? colors.error : colors.outline,
                  ),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    step.label,
                    key: ValueKey('collab-tool-${step.id}'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 11,
                      color: step.status == CollabToolStatus.failed ? colors.error : colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 一条系统提示（队友加入/离开、主席换了人）。
class CollabSystemNote extends StatelessWidget {
  const CollabSystemNote({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => ConversationSystemNote(text: text);
}

/// 议会/团队共用的输入栏：与普通聊天同一块玻璃、同一颗发送键。
class CollabComposer extends StatelessWidget {
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
    this.sendable = true,
    this.tray,
    this.hasAttachments = false,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final bool busy;
  final String hint;
  final VoidCallback? onStop;
  final Widget? leading;
  final ValueChanged<String>? onChanged;
  final bool enabled;

  /// 成员不足时输入栏照常，只让发送键不亮。
  final bool sendable;

  /// 已选但未发送的附件托盘（与普通聊天同一块）。
  final Widget? tray;

  /// 有附件时发送键在正文为空时也亮（S6：只发附件也允许）。
  final bool hasAttachments;

  @override
  Widget build(BuildContext context) {
    return ConversationComposer(
      controller: controller,
      onSend: onSend,
      busy: busy,
      hint: hint,
      onStop: onStop,
      leading: leading,
      onChanged: onChanged,
      enabled: enabled,
      sendable: sendable,
      tray: tray,
      hasAttachments: hasAttachments,
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
