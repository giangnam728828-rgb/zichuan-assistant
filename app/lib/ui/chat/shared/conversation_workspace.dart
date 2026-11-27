// 三种模式共用的聊天工作区内容组件（总方案 v4）。
//
// v3 时这是一个透明 Scaffold，靠「底下那条路由继续画背景」活着；协作页一旦
// 走 opaque 路由，底下不再绘制，透明 Scaffold 就露出路由底色——整片黑。
//
// v4 起三种模式都住在同一个 ChatScreen 里：背景（壁纸 + 潮汐光斑）由外壳
// 画一次，这里只是普通的内容列——顶栏留白、消息区、错误行、输入栏。没有
// Scaffold、没有自己的底色，也就不存在「另一张页面」的底色问题。
//
// v5（遮挡修复）：输入栏是**独立的一行**，不是浮在消息上的玻璃片：
//   SafeArea → 顶栏留白 → 横幅 → 消息区（Expanded，ClipRect 裁死）→ 错误行
//   → 输入栏（实测高度）
// 消息区永远只拿到输入栏上方的剩余空间，因此最后一行一定滚得出来。输入栏
// 长高（多行、附件托盘、@ 队友、键盘）时消息区自动变矮，不需要任何「预留
// 固定高度」的估算。输入栏的实测高度还会通过 [ConversationComposerInset]
// 传给时间线，做底部渐隐与跟随滚动。

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../shell/shell_insets.dart';

class ConversationWorkspace extends StatefulWidget {
  const ConversationWorkspace({
    super.key,
    required this.topInset,
    required this.body,
    this.banners = const [],
    this.composer,
    this.error,
  });

  /// 顶栏（含状态栏）占掉的高度：消息区从它下面开始。
  final double topInset;

  /// 消息区 / 空状态，占满中间。
  final Widget body;

  /// 消息区上方的横幅（审批等），没有就空着。
  final List<Widget> banners;

  /// 输入栏；没有就只留消息区（例如只读会话）。
  final Widget? composer;

  /// 输入栏上方的一行错误；null 不占位。
  final Widget? error;

  /// 消息区至少留多高：窗口再矮也不让输入栏把它挤没。
  static const minBodyHeight = 96.0;

  /// 输入栏最多占可用高度的多少（横屏 + 大字号 + 附件托盘同时出现时封顶）。
  static const maxComposerShare = 0.62;

  @override
  State<ConversationWorkspace> createState() => ConversationWorkspaceState();
}

class ConversationWorkspaceState extends State<ConversationWorkspace> {
  /// 输入栏的实测高度：消息区/时间线据此做底部渐隐与留白。
  final _composerHeight = ValueNotifier<double>(0);

  @override
  void dispose() {
    _composerHeight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxHeight.isFinite ? constraints.maxHeight : double.infinity;
        final reserved = math.max(0.0, available - widget.topInset);
        // 输入栏封顶：至少给消息区留 [ConversationWorkspace.minBodyHeight]，
        // 同时不超过可用高度的 62%。正常竖屏下两个上限都碰不到，输入栏
        // 保持自然高度；横屏 + 附件托盘 + 多行同时出现时才封顶。
        final composerCap = available.isFinite
            ? math.max(
                0.0,
                math.min(
                  available * ConversationWorkspace.maxComposerShare,
                  reserved - ConversationWorkspace.minBodyHeight,
                ),
              )
            : double.infinity;
        return ConversationComposerInset(
          height: _composerHeight,
          child: Column(
            children: [
              SizedBox(height: widget.topInset),
              ...widget.banners,
              // ClipRect：即使某一行自己画超了（长代码块、卡片阴影），也绝不
              // 画到输入栏的地盘上。
              Expanded(
                child: ClipRect(
                  key: const ValueKey('conversation-body'),
                  child: widget.body,
                ),
              ),
              if (widget.error case final error?) error,
              if (widget.composer case final composer?)
                _ComposerInset(
                  key: const ValueKey('conversation-composer'),
                  child: _MeasuredComposer(
                    maxHeight: composerCap > 0 ? composerCap : double.infinity,
                    onHeight: (height) {
                      if ((_composerHeight.value - height).abs() > 0.5) _composerHeight.value = height;
                    },
                    child: composer,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 量出输入栏的实际高度并向上报（时间线据此做底部渐隐）。
class _MeasuredComposer extends StatefulWidget {
  const _MeasuredComposer({required this.maxHeight, required this.onHeight, required this.child});

  /// 输入栏的高度上限（横屏 + 附件托盘 + 多行同时出现时封顶）。
  final double maxHeight;

  /// 量到新高度时回调（外层据此更新广播值）。
  final ValueChanged<double> onHeight;

  final Widget child;

  @override
  State<_MeasuredComposer> createState() => _MeasuredComposerState();
}

class _MeasuredComposerState extends State<_MeasuredComposer> {
  final _key = GlobalKey(debugLabel: 'composer-measured');

  /// 帧后读一次真实高度：布局已定型，回调里改 notifier 不会打断本帧。
  void _measure() {
    final box = _key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final height = box.size.height;
    if (!height.isFinite || height < 0) return;
    widget.onHeight(height);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measure();
    });
    return ConstrainedBox(
      key: _key,
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: widget.child,
    );
  }
}

/// 输入栏实测高度的广播：时间线（[CollabTimeline]）用它算底部渐隐与留白。
class ConversationComposerInset extends InheritedWidget {
  const ConversationComposerInset({super.key, required this.height, required super.child});

  final ValueListenable<double> height;

  static ValueListenable<double>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ConversationComposerInset>()?.height;

  @override
  bool updateShouldNotify(ConversationComposerInset old) => old.height != height;
}

/// 输入栏底部的留白：与 ChatScreen 的 `_ComposerBottom` 同一套规则——
/// 在外壳里只用 8dp（安全区由外壳让出），独立页面才走 SafeArea。
class _ComposerInset extends StatelessWidget {
  const _ComposerInset({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (ShellInsets.maybeOf(context) != null) {
      return Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 8), child: child);
    }
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 8),
      child: Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 0), child: child),
    );
  }
}
