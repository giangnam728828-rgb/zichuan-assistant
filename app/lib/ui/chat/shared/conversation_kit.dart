// 普通聊天、议会、团队共用的一套会话骨架。
//
// 之前三套页面各画各的：聊天用 ChatScreen / ChatList / Composer，议会和团队
// 用 CollabHeader / CollabUserBubble / CollabMessage / CollabComposer。结果是
// 同一个 App 里三种「聊天」的手感各不相同。
//
// 这里把三种模式真正共用的那几件抽出来，并且**直接复用普通聊天已有的部件**：
// - 用户消息就是 [UserBubble]（长按菜单、凭据遮挡、引用块都跟着走）；
// - 助手正文就是 [MarkdownBody]（和 AssistantMessage 同一套参数：流式、
//   reveal、不选中、修裸 dsh-ui），只是外面多一行身份（头像 + 名字 + 模型）；
// - 输入栏直接用普通聊天的 [Composer]，附件/语音等 Host 专属件通过扩展槽留空；
// - 顶栏是普通聊天那条透明行的高度、字号、状态点和右侧键位。
//
// 议会与团队只提供数据（谁说的、什么模型、跑到哪一步），不再自己画一套。

import 'package:flutter/material.dart';

import '../../../state/conversation_mode_state.dart';
import '../../providers/provider_brand_icon.dart';
import '../composer.dart';
import '../../theme/app_icons.dart';
import '../../theme/motion.dart';
import '../conversation_mode_switcher.dart';
import '../model_brand_mark.dart';
import '../render/markdown_body.dart';
import '../widgets/user_bubble.dart';

/// 顶栏高度：与 `ChatHeader.barHeight` 一致（不含状态栏）。
const double conversationHeaderHeight = 56;

/// 一条会话的顶栏：返回 / 标题 + 一句状态 / 右侧动作。
///
/// 普通聊天顶栏是一条**透明的行**：没有色带、没有胶囊，标题站左边，下面一行
/// 是状态；滚动渐隐由列表负责。这里保持同一套尺寸与字重，模式差异只体现在
/// 标题旁那枚小胶囊。
class ConversationHeader extends StatelessWidget {
  const ConversationHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.badge,
    this.actions = const [],
    this.onTitleTap,
    this.onBack,
    this.statusColor,
    this.leading,
    this.mode,
    this.onModeSelected,
  });

  final String title;
  final String? subtitle;

  /// 模式标识（「议会」/「团队」），压在标题后面。
  final Widget? badge;
  final List<Widget> actions;
  final VoidCallback? onTitleTap;
  final VoidCallback? onBack;

  /// 状态点颜色；空则不画点，只画副标题。
  final Color? statusColor;

  /// 替换返回键（桌面 / 抽屉场景）。
  final Widget? leading;

  /// 左上角的模式切换器：紧跟返回键，和普通聊天同一枚。
  final ConversationMode? mode;
  final ValueChanged<ConversationMode>? onModeSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return SizedBox(
      height: conversationHeaderHeight,
      child: Row(
        children: [
          leading ??
              IconButton(
                tooltip: '返回',
                onPressed: onBack ?? () => Navigator.of(context).maybePop(),
                icon: const Icon(AppIcons.back, size: 22),
                constraints: const BoxConstraints.tightFor(width: 44, height: 44),
                padding: EdgeInsets.zero,
              ),
          if (mode case final mode?) ...[
            const SizedBox(width: 2),
            ConversationModeSwitcher(mode: mode, onSelect: onModeSelected),
          ],
          const SizedBox(width: 2),
          Expanded(
            child: InkWell(
              onTap: onTitleTap,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                            ),
                          ),
                        ),
                        if (badge != null) ...[const SizedBox(width: 6), badge!],
                      ],
                    ),
                    if (subtitle case final line? when line.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (statusColor != null) ...[
                            ConversationStatusDot(color: statusColor!),
                            const SizedBox(width: 5),
                          ],
                          Flexible(
                            child: Text(
                              line,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontSize: 11,
                                height: 1.25,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          ...actions,
          const SizedBox(width: 2),
        ],
      ),
    );
  }
}

/// 我说的一句话：直接用普通聊天的 [UserBubble]。
class ConversationUserMessage extends StatelessWidget {
  const ConversationUserMessage({super.key, required this.text, this.animate = true});

  final String text;

  /// 切回一条已有会话时传 false：历史消息直接站在原位，不重播进场。
  final bool animate;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: EnterOnce(
        enabled: animate,
        child: Align(
          alignment: Alignment.centerRight,
          child: UserBubble(text: text),
        ),
      ),
    );
  }
}

/// 一条模型/队友消息：身份行（品牌图 + 名字 + 模型）+ 普通聊天的裸排正文。
///
/// 正文与 `AssistantMessage` 用的是同一个 [MarkdownBody] 配置，所以代码块、
/// 引用、表格、流式 reveal 的手感都一致；身份行只是群聊必需的「谁说的」。
class ConversationAssistantMessage extends StatelessWidget {
  const ConversationAssistantMessage({
    super.key,
    required this.brand,
    required this.name,
    required this.text,
    this.model,
    this.badge,
    this.status,
    this.statusColor,
    this.failed = false,
    this.streaming = false,
    this.emptyLabel,
    this.onNameTap,
    this.footer,
    this.animate = true,
  });

  final ModelBrand brand;
  final String name;
  final String text;

  /// 「DeepSeek · V4 Pro」这一行；空则不画。
  final String? model;
  final Widget? badge;

  /// 「正在思考…」「已作答」「失败：…」。
  final String? status;
  final Color? statusColor;
  final bool failed;

  /// 正文还在长（给 MarkdownBody 的流式参数）。
  final bool streaming;

  /// 还没有正文时占位的一句话。
  final String? emptyLabel;
  final VoidCallback? onNameTap;
  final Widget? footer;

  /// 切回一条已有会话时传 false：历史消息不重播进场。
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = failed ? colors.error : brandColorOn(brand, colors);
    final body = text.trim();
    final showBody = body.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: EnterOnce(
        enabled: animate,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 8),
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
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                      if (badge != null) ...[const SizedBox(width: 6), badge!],
                      if (model case final line? when line.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            line,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 11,
                              color: colors.onSurfaceVariant.withValues(alpha: 0.72),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (showBody)
                    MarkdownBody(
                      text: body,
                      streaming: streaming,
                      reveal: streaming,
                      selectable: false,
                      repairBareViews: true,
                    )
                  else if (emptyLabel case final label? when label.isNotEmpty)
                    Text(label, style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                  if (status case final line? when line.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (streaming) ...[ConversationStatusDot(color: accent), const SizedBox(width: 6)],
                        Flexible(
                          child: Text(
                            line,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 11,
                              color: statusColor ?? colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (footer != null) footer!,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一条系统提示（队友加入、主席换人、这一轮取消）。
class ConversationSystemNote extends StatelessWidget {
  const ConversationSystemNote({super.key, required this.text});

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

/// 议会/团队共用的输入栏：**就是普通聊天的 [Composer]**。
///
/// 附件、语音、上下文环这些 Host 专属件不传，就自然不显示；团队的点名按钮
/// 走 [leading]，议会不需要就留空。输入高度、圆角、发送/停止键、焦点动画和
/// 键盘行为都跟聊天完全一致，不再维护第二套外观。
class ConversationComposer extends StatefulWidget {
  const ConversationComposer({
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

  /// 输入栏照常可用，但发送键不亮（例如成员不足）。
  final bool sendable;

  @override
  State<ConversationComposer> createState() => _ConversationComposerState();
}

class _ConversationComposerState extends State<ConversationComposer> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(ConversationComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  void _changed() => widget.onChanged?.call(widget.controller.text);

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 真正的普通聊天输入栏：输入框高度、圆角、发送/停止键、焦点动画、键盘
    // 行为都跟聊天一模一样；议会/团队只通过 leading 放各自的功能（@ 队友）。
    return Composer(
      controller: widget.controller,
      connected: widget.enabled,
      running: widget.busy,
      busy: widget.busy,
      sessionReady: widget.enabled,
      onSend: widget.onSend,
      onStop: widget.onStop ?? () {},
      placeholder: widget.hint,
      leading: widget.leading,
      maxLines: 6,
    );
  }
}

/// 一颗会呼吸的状态点；「减少动态效果」时停在静止帧。
class ConversationStatusDot extends StatefulWidget {
  const ConversationStatusDot({super.key, required this.color, this.size = 6});

  final Color color;
  final double size;

  @override
  State<ConversationStatusDot> createState() => _ConversationStatusDotState();
}

class _ConversationStatusDotState extends State<ConversationStatusDot> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(vsync: this, duration: AppMotion.breath);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _breath.stop();
      _breath.value = 0.6;
    } else if (!_breath.isAnimating) {
      _breath.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _breath,
      builder: (context, _) {
        final t = 0.45 + 0.55 * (AppMotion.reduced(context) ? 1.0 : Curves.easeInOut.transform(_breath.value));
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color.withValues(alpha: t),
          ),
        );
      },
    );
  }
}

/// 首次出现时淡入 + 轻微上移；之后的重建（流式增量、状态变化）不再重播。
class EnterOnce extends StatefulWidget {
  const EnterOnce({super.key, required this.child, this.enabled = true});

  final Widget child;

  /// false：直接呈现（切回旧会话、减少动画），不播这一次的淡入。
  final bool enabled;

  @override
  State<EnterOnce> createState() => _EnterOnceState();
}

class _EnterOnceState extends State<EnterOnce> {
  bool _played = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || _played || AppMotion.reduced(context)) {
      _played = true;
      return widget.child;
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.of(context, AppMotion.standard),
      curve: AppMotion.enter,
      onEnd: () {
        if (mounted && !_played) setState(() => _played = true);
      },
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 6 * (1 - t)), child: child),
      ),
      child: widget.child,
    );
  }
}
