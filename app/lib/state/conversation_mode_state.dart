// 聊天模式：普通聊天 / 议会 / 团队（总方案 v2 第二阶段）。
//
// 左上角的模式切换器只负责「换到哪种模式」；这里记住每种模式**上次用的那条
// 会话**，所以来回切换是回到原来那条，而不是每切一次就新建一条。
//
// 记住的 id 按主机身份分开：本机、SSH、中继的会话 id 互不相干，切换主机后
// 不会拿着 A 主机的内部会话去 B 主机上找。刷新/重启后内存里的 id 会丢，页面
// 会退回到「最近一条」——仍然不会每次新建。
//
// 草稿也放在这里：按「模式 + 主机 + 会话」隔离，换回某个模式时会话还在，
// 没发出去的字也还在。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'hosts_state.dart';

enum ConversationMode {
  chat('聊天'),
  council('议会'),
  team('团队');

  const ConversationMode(this.label);

  final String label;
}

/// 一台主机上，每种模式上次停留的会话，以及没发出去的草稿。
class ConversationModeState {
  const ConversationModeState({
    this.mode = ConversationMode.chat,
    this.councilIds = const {},
    this.teamIds = const {},
    this.drafts = const {},
  });

  /// 当前看到的模式（页面自己也知道，这里给路由与测试一个单一事实）。
  final ConversationMode mode;

  /// hostKey -> CouncilConversation.id
  final Map<String, String> councilIds;

  /// hostKey -> TeamState.id
  final Map<String, String> teamIds;

  /// '模式|hostKey|会话id' -> 输入框里没发出去的字。
  final Map<String, String> drafts;

  String? councilIdFor(String host) => councilIds[host];
  String? teamIdFor(String host) => teamIds[host];

  String? idFor(ConversationMode mode, String host) => switch (mode) {
    ConversationMode.chat => null,
    ConversationMode.council => councilIds[host],
    ConversationMode.team => teamIds[host],
  };

  String draftOf(ConversationMode mode, String host, String? id) => drafts[_draftKey(mode, host, id)] ?? '';

  ConversationModeState copyWith({
    ConversationMode? mode,
    Map<String, String>? councilIds,
    Map<String, String>? teamIds,
    Map<String, String>? drafts,
  }) => ConversationModeState(
    mode: mode ?? this.mode,
    councilIds: councilIds ?? this.councilIds,
    teamIds: teamIds ?? this.teamIds,
    drafts: drafts ?? this.drafts,
  );

  static String _draftKey(ConversationMode mode, String host, String? id) => '${mode.name}|$host|${id ?? ''}';
}

/// 主机的稳定标识：同名中继换 id 也算另一台。
String conversationHostKey(HostRef host) => '${host.kind.name}:${host.id}';

class ConversationModeController extends Notifier<ConversationModeState> {
  @override
  ConversationModeState build() => const ConversationModeState();

  void setMode(ConversationMode mode) {
    if (state.mode != mode) state = state.copyWith(mode: mode);
  }

  void rememberCouncil(String host, String id) {
    if (state.councilIds[host] == id) return;
    state = state.copyWith(councilIds: {...state.councilIds, host: id});
  }

  void rememberTeam(String host, String id) {
    if (state.teamIds[host] == id) return;
    state = state.copyWith(teamIds: {...state.teamIds, host: id});
  }

  /// 记下某个会话没发出去的草稿；空串等于删除。
  void saveDraft(ConversationMode mode, String host, String? id, String text) {
    final key = ConversationModeState._draftKey(mode, host, id);
    if ((state.drafts[key] ?? '') == text) return;
    final next = {...state.drafts};
    if (text.isEmpty) {
      next.remove(key);
    } else {
      next[key] = text;
    }
    state = state.copyWith(drafts: next);
  }

  /// 发出去之后清掉草稿。
  void clearDraft(ConversationMode mode, String host, String? id) => saveDraft(mode, host, id, '');
}

final conversationModeProvider = NotifierProvider<ConversationModeController, ConversationModeState>(
  ConversationModeController.new,
);
