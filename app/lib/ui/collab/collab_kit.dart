// 议会与团队共用的聊天外壳。
//
// 这里不再自己画一套：顶栏、用户气泡、助手消息、系统提示、输入栏全部转交给
// `ui/chat/shared/conversation_kit.dart`——也就是普通聊天在用的那套部件与
// 排版。本文件只保留两种协作模式自己的小东西（模式胶囊、成员头像、席位状态
// 文案），以及把协作数据塞进公共部件的适配层。

import 'package:flutter/material.dart';

import '../../council/collab_models.dart';
import '../../state/conversation_mode_state.dart';
import '../chat/model_brand_mark.dart';
import '../chat/shared/conversation_kit.dart';
import '../providers/provider_brand_icon.dart';

/// 协作页顶栏：与普通聊天同一条透明行，只多一枚模式胶囊。
class CollabHeader extends StatelessWidget {
  const CollabHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.actions,
    this.onTitleTap,
    this.statusColor,
    this.mode,
    this.onModeSelected,
  });

  final String title;
  final String subtitle;

  /// 「议会」/「团队」的模式标识。
  final Widget badge;
  final List<Widget> actions;
  final VoidCallback? onTitleTap;

  /// 状态点颜色（正在跑的时候给主色）。
  final Color? statusColor;

  /// 左上角模式切换器：返回键之后、标题之前。
  final ConversationMode? mode;
  final ValueChanged<ConversationMode>? onModeSelected;

  @override
  Widget build(BuildContext context) {
    return ConversationHeader(
      title: title,
      subtitle: subtitle,
      badge: badge,
      actions: actions,
      onTitleTap: onTitleTap,
      statusColor: statusColor,
      mode: mode,
      onModeSelected: onModeSelected,
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

  /// 名字后面那枚小标签（主席 / 只读）。
  final Widget? trailing;

  /// 切回旧会话时传 false：历史消息不重播进场。
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final config = model ?? _modelLine(brand, name);
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
    );
  }

  /// 名字下面那行小字由调用方给的 `status` 决定，这里只标品牌名。
  static String? _modelLine(ModelBrand brand, String name) {
    final label = brandLabel(brand);
    return label.isEmpty || label == name ? null : label;
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
