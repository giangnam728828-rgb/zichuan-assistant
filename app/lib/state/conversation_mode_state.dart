// 聊天模式：普通聊天 / 议会 / 团队（总方案 v3）。
//
// 左上角的模式切换器只负责「换到哪种模式」；这里记住每种模式**上次用的那条
// 会话**，所以来回切换是回到原来那条，而不是每切一次就新建一条。
//
// 记住的 id 按主机身份分开：本机、SSH、中继的会话 id 互不相干，切换主机后
// 不会拿着 A 主机的内部会话去 B 主机上找。
//
// v3 起这套状态落盘（SharedPreferences）：进程被杀掉再打开，仍然回到上次的
// 模式与具体会话，草稿也还在。启动时由 main() 先读出来，经
// [conversationModeInitialProvider] 注入，所以第一帧就是恢复后的模式，不会先
// 闪一下普通聊天。
//
// 草稿按「模式 + 主机 + 会话」隔离，换回某个模式时会话还在，没发出去的字也还在。

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  Map<String, Object?> toJson() => {'mode': mode.name, 'council': councilIds, 'team': teamIds, 'drafts': drafts};

  /// 坏数据不炸启动：认不出的模式回聊天，字段类型不对就当空。
  factory ConversationModeState.fromJson(Map<String, Object?> json) {
    ConversationMode mode = ConversationMode.chat;
    final rawMode = json['mode'];
    if (rawMode is String) {
      for (final option in ConversationMode.values) {
        if (option.name == rawMode) mode = option;
      }
    }
    Map<String, String> strings(Object? value) {
      if (value is! Map) return const {};
      return {
        for (final entry in value.entries)
          if (entry.key is String && entry.value is String) entry.key as String: entry.value as String,
      };
    }

    return ConversationModeState(
      mode: mode,
      councilIds: strings(json['council']),
      teamIds: strings(json['team']),
      drafts: strings(json['drafts']),
    );
  }
}

/// 主机的稳定标识：同名中继换 id 也算另一台。
String conversationHostKey(HostRef host) => '${host.kind.name}:${host.id}';

/// 模式状态的本地存档。只存很小的一份 JSON（几个 id 和草稿）。
abstract final class ConversationModeStore {
  static const key = 'dsh.conversation_mode.v3';

  static Future<ConversationModeState> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return const ConversationModeState();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const ConversationModeState();
      return ConversationModeState.fromJson(decoded.cast<String, Object?>());
    } on Object {
      // 存档坏了/插件不可用（测试）：当第一次启动，不挡主流程。
      return const ConversationModeState();
    }
  }

  static Future<void> save(ConversationModeState state) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode(state.toJson()));
    } on Object {
      // 存不下不影响本次使用。
    }
  }
}

/// 启动时读到的存档；main() 用 override 注入，测试不注入就是空状态。
final conversationModeInitialProvider = Provider<ConversationModeState>((ref) => const ConversationModeState());

class ConversationModeController extends Notifier<ConversationModeState> {
  Timer? _saveTimer;

  @override
  ConversationModeState build() {
    final initial = ref.read(conversationModeInitialProvider);
    // 外部（历史、深链、页面）改了状态都会走这里，统一延迟落盘，避免每敲一个
    // 字就写一次磁盘。
    ref.onDispose(() {
      _saveTimer?.cancel();
      _saveTimer = null;
    });
    return initial;
  }

  void _commit(ConversationModeState next) {
    if (next == state) return;
    state = next;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), () => ConversationModeStore.save(state));
  }

  void setMode(ConversationMode mode) {
    if (state.mode != mode) _commit(state.copyWith(mode: mode));
  }

  void rememberCouncil(String host, String id) {
    if (state.councilIds[host] == id) return;
    _commit(state.copyWith(councilIds: {...state.councilIds, host: id}));
  }

  void rememberTeam(String host, String id) {
    if (state.teamIds[host] == id) return;
    _commit(state.copyWith(teamIds: {...state.teamIds, host: id}));
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
    _commit(state.copyWith(drafts: next));
  }

  /// 发出去之后清掉草稿。
  void clearDraft(ConversationMode mode, String host, String? id) => saveDraft(mode, host, id, '');
}

final conversationModeProvider = NotifierProvider<ConversationModeController, ConversationModeState>(
  ConversationModeController.new,
);
