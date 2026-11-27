// 三种模式共用的聊天工作区内容组件（总方案 v4）。
//
// v3 时这是一个透明 Scaffold，靠「底下那条路由继续画背景」活着；协作页一旦
// 走 opaque 路由，底下不再绘制，透明 Scaffold 就露出路由底色——整片黑。
//
// v4 起三种模式都住在同一个 ChatScreen 里：背景（壁纸 + 潮汐光斑）由外壳
// 画一次，这里只是普通的内容列——顶栏留白、消息区、错误行、输入栏。没有
// Scaffold、没有自己的底色，也就不存在「另一张页面」的底色问题。

import 'package:flutter/material.dart';

import '../../shell/shell_insets.dart';

class ConversationWorkspace extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(height: topInset),
        ...banners,
        Expanded(child: body),
        if (error case final error?) error,
        if (composer case final composer?) _ComposerInset(child: composer),
      ],
    );
  }
}

/// 输入栏底部的留白：与 ChatScreen 的 `_ComposerBottom` 同一套规则——
/// 在外壳里只用 8dp（安全区由外壳让出），独立页面才走 SafeArea。
class _ComposerInset extends StatelessWidget {
  const _ComposerInset({required this.child});

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