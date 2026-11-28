// 贴底跟随：三种会话共用的一份滚动行为。
//
// 普通聊天（[ChatList]）原来把这条规则写在私有类 `_FollowPhysics` 里，协作
// 时间线（[CollabTimeline]）则是普通 `ListView` + 「行数变了才跟随」——于是
// 同一条消息里的正文持续变长时，列表不会跟着走，最后几行停在输入栏上方看
// 不见（v4.3 · P0-D · 5.2）。
//
// 这里把规则抽出来，两处共用：
// - 内容高度变化时，**在同一次布局里**把位置放到新的末尾，不会先藏一帧、
//   再跳上来；
// - 拖动、惯性滚动中不插手（那是用户自己在动）；
// - 用户往上翻历史时不跟随（由调用方的 `follows` 决定）。
//
// 只是 ScrollPhysics：不改变列表结构、不改变 [ChatList] 现有行为。

import 'package:flutter/widgets.dart';

/// 贴底跟随的滚动物理。
///
/// [follows] 每次布局都会被问一次「这一刻该不该跟随」（通常是「用户贴底」）。
/// [glides] 决定「变长」是否留给一段滑动去追：为 true 时先露出一点再由外部
/// 动画追上（普通聊天的流体档）；为 false 时立即贴住（协作时间线）。
class FollowScrollPhysics extends ScrollPhysics {
  const FollowScrollPhysics(this.follows, {required this.glides, super.parent});

  final bool Function() follows;

  /// A taller list is left for the glide to catch up with. Shorter still lands at once:
  /// a gap at the bottom can't wait.
  final bool Function() glides;

  @override
  FollowScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      FollowScrollPhysics(follows, glides: glides, parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final adjusted = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    if (isScrolling || velocity != 0 || !follows()) return adjusted;
    // 上一帧之后可能刚追过底（帧后 jumpTo）：看当前位置，也看上次记下的。
    final at = newPosition.pixels > oldPosition.pixels ? newPosition.pixels : oldPosition.pixels;
    if (oldPosition.maxScrollExtent - at > 1 && !glides()) return adjusted;
    if (glides() && newPosition.maxScrollExtent >= at) return adjusted;
    return newPosition.maxScrollExtent;
  }
}
