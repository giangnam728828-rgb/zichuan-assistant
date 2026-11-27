// 议会与团队共用的聊天时间线（总方案 v4 · 三）。
//
// 之前议会和团队各写一套列表：议会用正序 ListView + EdgeFade，团队用
// reverse ListView + 顶部并行条。结果同一个 App 里两处「群聊」的滚动方向、
// 留白、自动跟随、空状态全都不一样。
//
// 这里收成一份，两种模式只提供「有哪些行」：
// - 只有一份滚动位置与自动跟随规则：贴底时新内容自然跟着走，用户往上翻看
//   历史时绝不被强行拉回底部；
// - 底部留白按输入栏的**实测高度**算（[composerHeight]），输入栏长高、键盘
//   弹起、附件托盘展开都跟着连续变化，最后一行永远滚得出来；
// - 顶部/底部渐隐与普通聊天同一套 [EdgeFade]，不额外盖色；
// - 空状态、系统提示、失败行都作为行传进来，列表不再关心业务。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../chat/shared/conversation_workspace.dart';
import '../theme/edge_fade.dart';

/// 一条时间线里的一行。
///
/// [key] 必须稳定（消息 id / 任务 id）：否则流式增量会重建整行，也会把
/// 滑动位置和淡入重播搞乱。
class CollabTimelineRow {
  const CollabTimelineRow({required this.key, required this.child, this.bottomGap = 0});

  final Key key;
  final Widget child;

  /// 这一行后面额外的空隙（任务卡、裁决卡这类块状内容用）。
  final double bottomGap;
}

/// 没有输入栏时的常量高度（[EdgeFade] 只读 value）。
const _staticZero = AlwaysStoppedAnimation<double>(0);

class CollabTimeline extends StatefulWidget {
  const CollabTimeline({
    super.key,
    required this.rows,
    this.empty,
    this.composerHeight,
    this.topFade = 24,
    this.horizontalPadding = 12,
    this.controller,
    this.followOnNewRows = true,
    this.footer,
  });

  /// 从上到下的行；最后一行就是「最新的内容」。
  final List<CollabTimelineRow> rows;

  /// 没有任何行时显示的内容（空会话引导）。
  final Widget? empty;

  /// 输入栏实测高度。底部渐隐与留白都按它算。
  ///
  /// 不传就自己从 [ConversationComposerInset] 读：时间线可用时才拿得到
  /// 自己所在位置的 context，页面在 build 入口读到的还是外面那一层。
  final ValueListenable<double>? composerHeight;

  /// 顶部渐隐长度（与普通聊天一致：滚到顶栏下面时字自己淡掉）。
  final double topFade;

  final double horizontalPadding;

  /// 外部想控制滚动位置时可以传进来（议会恢复会话后停在最新一轮）。
  final ScrollController? controller;

  /// 新行到达时，如果用户正贴着底部，就跟着滚到底。
  final bool followOnNewRows;

  /// 列表末尾（输入栏之上）的常驻内容，例如「正在召集成员…」的一行。
  final Widget? footer;

  /// 判定「贴着底部」的容差：小于这个距离就算用户在底部。
  static const pinnedTolerance = 48.0;

  @override
  State<CollabTimeline> createState() => CollabTimelineState();
}

class CollabTimelineState extends State<CollabTimeline> {
  late ScrollController _scroll = widget.controller ?? ScrollController();
  bool _ownsController = false;

  /// 用户是否贴在底部。往上翻历史时为 false：新内容不再抢滚动。
  bool _pinned = true;
  bool _restored = false;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(CollabTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _scroll.removeListener(_onScroll);
      if (_ownsController) _scroll.dispose();
      _ownsController = widget.controller == null;
      _scroll = widget.controller ?? ScrollController();
      _scroll.addListener(_onScroll);
    }
    if (!widget.followOnNewRows) return;
    if (oldWidget.rows.length != widget.rows.length && _pinned) {
      // 行数变了（新消息/新状态行）且用户在底部：下一帧跟到底。
      _scheduleFollow();
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    if (_ownsController) _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final distance = position.maxScrollExtent - position.pixels;
    final pinned = distance <= CollabTimeline.pinnedTolerance;
    if (pinned != _pinned) _pinned = pinned;
  }

  /// 「贴底」状态：议会/团队页在流式增量后据此决定要不要跟随。
  bool get isPinnedToBottom => _pinned;

  /// 滚到底部（新建/恢复会话、发送后调用）。
  void jumpToBottom({bool animate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (animate) {
        _scroll.animateTo(target, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
      } else {
        _scroll.jumpTo(target);
      }
      _pinned = true;
    });
  }

  void _scheduleFollow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_pinned) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    if (!_restored) {
      // 第一次铺出来就在底部（恢复旧会话看到的是最新一轮，而不是列表顶）。
      _restored = true;
      _scheduleFollow();
    }
    if (rows.isEmpty) return widget.empty ?? const SizedBox.shrink();
    final list = ListView.builder(
      key: const ValueKey('collab-timeline-list'),
      controller: _scroll,
      // 正序：最新的内容在底部，和普通聊天一致。
      padding: EdgeInsets.fromLTRB(widget.horizontalPadding, 4, widget.horizontalPadding, 12),
      itemCount: rows.length + (widget.footer == null ? 0 : 1),
      itemBuilder: (context, index) {
        if (index >= rows.length) {
          return Padding(
            key: const ValueKey('collab-timeline-footer'),
            padding: const EdgeInsets.only(top: 6),
            child: widget.footer,
          );
        }
        final row = rows[index];
        return Padding(
          key: row.key,
          padding: EdgeInsets.only(bottom: row.bottomGap),
          child: row.child,
        );
      },
    );
    // 底部渐隐按输入栏实测高度走（和普通聊天同一条规则）：滚到输入栏
    // 后面的字自己淡掉，而不是被一块色块盖住。
    final bottom =
        widget.composerHeight ?? ConversationComposerInset.maybeOf(context) ?? _staticZero;
    return EdgeFade(top: widget.topFade, topHold: 0, bottom: bottom, child: list);
  }
}
