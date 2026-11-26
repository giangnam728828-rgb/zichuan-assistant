// 三种模式共用的聊天工作区外壳（总方案 v3）。
//
// 页面背景、安全区、顶栏、消息区、输入栏和键盘避让只在这里写一次：普通聊天
// 走主壳的壁纸与潮汐光斑，议会/团队用透明 Scaffold 叠在同一个背景上，所以
// 三个模式看起来是同一个应用，而不是三张各自刷底色的页面。
//
// 这里只管「摆放」，不碰任何会话数据：消息、运行状态、草稿仍由各模式自己的
// 控制器提供。

import 'package:flutter/material.dart';

class ConversationWorkspace extends StatelessWidget {
  const ConversationWorkspace({
    super.key,
    required this.header,
    required this.body,
    this.composer,
    this.error,
    this.topSafe = true,
  });

  /// 顶栏（模式切换器已经在里面）。
  final Widget header;

  /// 消息区/空状态，占满中间。
  final Widget body;

  /// 输入栏；没有就只留消息区（例如只读会话）。
  final Widget? composer;

  /// 输入栏上方的一行错误；null 不占位。
  final Widget? error;

  final bool topSafe;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      children: [
        header,
        if (error case final error?) error,
        Expanded(child: body),
        if (composer case final composer?) composer,
      ],
    );
    return Scaffold(
      // 透明：底下是主壳的同一张壁纸 + 潮汐光斑，和普通聊天完全一致。
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: true,
      body: topSafe ? SafeArea(bottom: false, child: content) : content,
    );
  }
}
