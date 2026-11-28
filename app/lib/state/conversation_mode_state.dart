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
    this.scrollOffsets = const {},
    this.requestNonce = 0,
    this.openId,
    this.openRunId,
    this.createNew = false,
  });

  /// 当前看到的模式（页面自己也知道，这里给路由与测试一个单一事实）。
  final ConversationMode mode;

  /// hostKey -> CouncilConversation.id
  final Map<String, String> councilIds;

  /// hostKey -> TeamState.id
  final Map<String, String> teamIds;

  /// '模式|hostKey|会话id' -> 输入框里没发出去的字。
  final Map<String, String> drafts;

  /// 瞬时请求序号（不落盘）：用户主动切模式 / 从历史打开时 +1，
  /// 工作区据此重建对应模式的视图。冷启动恢复时保持 0，不触发新建。
  final int requestNonce;

  /// 本次请求要显式打开的会话（历史 / 深链）；null 走启动规则。
  final String? openId;

  /// 深链只带 runId 的旧议会数据：视图启动后自己找回所属会话。
  final String? openRunId;

  /// true：本次请求要求新建一条会话（用户主动切换模式，方案 4.1）。
  final bool createNew;

  String? councilIdFor(String host) => councilIds[host];
  String? teamIdFor(String host) => teamIds[host];

  String? idFor(ConversationMode mode, String host) => switch (mode) {
    ConversationMode.chat => null,
    ConversationMode.council => councilIds[host],
    ConversationMode.team => teamIds[host],
  };

  String draftOf(ConversationMode mode, String host, String? id) => drafts[_draftKey(mode, host, id)] ?? '';

  /// 每个会话各自记住的滚动位置（v4.2 · P0-D）：切走再回来接着看，
  /// 不会把 A 的位置用到 B 上。
  double? scrollOf(ConversationMode mode, String host, String? id) => scrollOffsets[_draftKey(mode, host, id)];

  ConversationModeState copyWith({
    ConversationMode? mode,
    Map<String, String>? councilIds,
    Map<String, String>? teamIds,
    Map<String, String>? drafts,
    Map<String, double>? scrollOffsets,
  }) => ConversationModeState(
    mode: mode ?? this.mode,
    councilIds: councilIds ?? this.councilIds,
    teamIds: teamIds ?? this.teamIds,
    drafts: drafts ?? this.drafts,
    scrollOffsets: scrollOffsets ?? this.scrollOffsets,
    requestNonce: requestNonce,
    openId: openId,
    openRunId: openRunId,
    createNew: createNew,
  );

  static String _draftKey(ConversationMode mode, String host, String? id) => '${mode.name}|$host|${id ?? ''}';

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'council': councilIds,
    'team': teamIds,
    'drafts': drafts,
    if (scrollOffsets.isNotEmpty) 'scroll': scrollOffsets,
  };

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

    Map<String, double> doubles(Object? value) {
      if (value is! Map) return const {};
      return {
        for (final entry in value.entries)
          if (entry.key is String && entry.value is num) entry.key as String: (entry.value as num).toDouble(),
      };
    }

    return ConversationModeState(
      mode: mode,
      councilIds: strings(json['council']),
      teamIds: strings(json['team']),
      drafts: strings(json['drafts']),
      scrollOffsets: doubles(json['scroll']),
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

  /// 临时切到某种模式：**回到该模式上次那条会话**，不新建。
  ///
  /// 一次性请求（新建 / 从历史打开 / 深链 runId）在这里清掉：它们是「这一次
  /// 点击」的意思，切走再回来不该重放——否则切到团队会把议会刚建的那条
  /// 又建一遍，或者把历史打开请求重新触发一次。记住的会话 id 与草稿保留，
  /// 正在跑的运行由进程级编排器继续驱动。
  void setMode(ConversationMode mode) {
    if (state.mode == mode) return;
    _commit(
      ConversationModeState(
        mode: mode,
        councilIds: state.councilIds,
        teamIds: state.teamIds,
        drafts: state.drafts,
        requestNonce: state.requestNonce,
      ),
    );
  }

  /// 用户主动切到议会/团队：像点「新建对话」一样开一条全新会话（方案 4.1）。
  /// 旧会话留在各自历史里；成员配置由视图从最近一条继承。
  void startNew(ConversationMode mode) {
    assert(mode != ConversationMode.chat, '普通聊天没有「新建协作会话」请求');
    _commit(
      ConversationModeState(
        mode: mode,
        councilIds: state.councilIds,
        teamIds: state.teamIds,
        drafts: state.drafts,
        requestNonce: state.requestNonce + 1,
        createNew: true,
      ),
    );
  }

  /// 从历史/深链打开某条协作会话：恢复原会话，不新建、不覆盖（方案 4.3）。
  void openExisting(ConversationMode mode, String id) {
    assert(mode != ConversationMode.chat);
    _commit(
      ConversationModeState(
        mode: mode,
        councilIds: state.councilIds,
        teamIds: state.teamIds,
        drafts: state.drafts,
        requestNonce: state.requestNonce + 1,
        openId: id,
      ),
    );
  }

  /// 深链只带某次议会的 runId：视图启动后找回它所属的会话。
  void openRun(String runId) {
    _commit(
      ConversationModeState(
        mode: ConversationMode.council,
        councilIds: state.councilIds,
        teamIds: state.teamIds,
        drafts: state.drafts,
        requestNonce: state.requestNonce + 1,
        openRunId: runId,
      ),
    );
  }

  void rememberCouncil(String host, String id) {
    if (state.councilIds[host] == id) return;
    _commit(state.copyWith(councilIds: {...state.councilIds, host: id}));
  }

  void rememberTeam(String host, String id) {
    if (state.teamIds[host] == id) return;
    _commit(state.copyWith(teamIds: {...state.teamIds, host: id}));
  }

  /// 记下某个会话的滚动位置（节流调用；值不变就跳过）。
  void saveScroll(ConversationMode mode, String host, String? id, double offset) {
    final key = ConversationModeState._draftKey(mode, host, id);
    final current = state.scrollOffsets[key];
    if (current != null && (current - offset).abs() < 1.0) return;
    _commit(state.copyWith(scrollOffsets: {...state.scrollOffsets, key: offset}));
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
