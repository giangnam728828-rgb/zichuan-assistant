// 议会/团队在统一聊天工作区里的宿主（总方案 v4 · 三）。
//
// ChatScreen 是唯一的聊天根页面；这里按当前模式把对应的业务视图放进同一套
// 背景、顶栏和布局里。视图只负责数据与内容（消息、发送、成员、运行恢复），
// 顶栏仍是真正的 ChatHeader——视图把标题/状态/菜单动作发布到 [header]，
// ChatScreen 拿去喂给顶栏，三种模式的顶部因此完全一致。
//
// 会话隔离（方案十二）：视图按「模式 + 主机 + 请求序号」建 Key。用户主动
// 切模式 / 从历史打开都会 bump 序号，得到全新的状态实例；冷启动恢复时序号
// 不变，读的是上次那条会话。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/conversation_mode_state.dart';
import '../../../state/hosts_state.dart';
import '../../council/council_page.dart';
import '../../team/team_page.dart';
import '../../theme/motion.dart';

/// ⋯ 菜单里的一项（成员管理、导出、设置……）。
class CollabMenuAction {
  const CollabMenuAction({required this.key, required this.label, required this.onTap, this.icon});

  final String key;
  final String label;
  final VoidCallback onTap;
  final IconData? icon;
}

/// 协作视图发布给统一顶栏的信息。
class CollabHeaderInfo {
  const CollabHeaderInfo({
    required this.title,
    required this.subtitle,
    this.busy = false,
    this.failed = false,
    this.onTitleTap,
    this.onNew,
    this.actions = const [],
  });

  final String title;
  final String subtitle;

  /// 有回合/队友在跑：状态点走 busy。
  final bool busy;

  /// 最近一次运行失败：状态点走 error。
  final bool failed;

  final VoidCallback? onTitleTap;

  /// 「新对话」键：新建一条当前模式的会话。
  final VoidCallback? onNew;

  /// ⋯ 菜单内容（成员管理排第一）。
  final List<CollabMenuAction> actions;

  /// 只比数据与菜单项：回调是每次构建的新闭包，不参与比较，
  /// 顶栏因此不会为同一份信息反复重建。
  @override
  bool operator ==(Object other) =>
      other is CollabHeaderInfo &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.busy == busy &&
      other.failed == failed &&
      (other.onTitleTap != null) == (onTitleTap != null) &&
      (other.onNew != null) == (onNew != null) &&
      other.actions.length == actions.length &&
      _sameActions(other.actions, actions);

  static bool _sameActions(List<CollabMenuAction> a, List<CollabMenuAction> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i].key != b[i].key || a[i].label != b[i].label) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    title,
    subtitle,
    busy,
    failed,
    onTitleTap != null,
    onNew != null,
    Object.hashAll([for (final action in actions) Object.hash(action.key, action.label)]),
  );
}

/// 按当前模式把议会/团队视图放进聊天工作区。
class ConversationModeHost extends ConsumerWidget {
  const ConversationModeHost({
    super.key,
    required this.mode,
    required this.header,
    required this.topInset,
    this.parentSessionId,
  });

  /// 只会是 council / team；chat 由 ChatScreen 自己渲染。
  final ConversationMode mode;

  /// 视图 → 顶栏的信息通道（ChatScreen 持有并监听）。
  final ValueNotifier<CollabHeaderInfo?> header;

  /// 顶栏（含状态栏）高度：内容从它下面开始。
  final double topInset;

  /// 这一页所在的普通聊天会话 id：议会/团队发消息时从这里检索此前的资料
  /// （用户上一条给的长方案、仓库、要求都在它的历史里）。
  final String? parentSessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 只订阅请求相关字段：草稿变化不触发工作区重建。
    final request = ref.watch(
      conversationModeProvider.select((s) => (s.requestNonce, s.openId, s.openRunId, s.createNew)),
    );
    final hostKey = conversationHostKey(ref.watch(activeHostProvider));
    // 每次主动切换 / 历史打开都是新序号：全新状态实例，不共享可变消息列表。
    final key = ValueKey('${mode.name}-$hostKey-${request.$1}');
    final remembered = ref.read(conversationModeProvider).idFor(mode, hostKey);
    final Widget view = switch (mode) {
      ConversationMode.council => CouncilModeView(
        key: key,
        header: header,
        topInset: topInset,
        parentSessionId: parentSessionId,
        conversationId: request.$2 ?? (request.$4 || request.$3 != null ? null : remembered),
        runId: request.$3,
        createNew: request.$4,
        resumeLatest: !request.$4 && request.$2 == null && request.$3 == null,
      ),
      ConversationMode.team => TeamModeView(
        key: key,
        header: header,
        topInset: topInset,
        parentSessionId: parentSessionId,
        teamId: request.$2 ?? (request.$4 ? null : remembered),
        createNew: request.$4,
        resumeLatest: !request.$4 && request.$2 == null,
      ),
      ConversationMode.chat => const SizedBox.shrink(),
    };
    // 内容切换：轻量淡入 + 8dp 位移（方案 11.2）；背景和顶栏不参与重建。
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.standard),
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.exit,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, inner) => Transform.translate(offset: Offset(0, 8 * (1 - animation.value)), child: inner),
          child: child,
        ),
      ),
      child: view,
    );
  }
}