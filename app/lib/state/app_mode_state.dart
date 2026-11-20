// 模式: what the app is for right now — 工作 (the DSH chat, in either 界面),
// 伙伴 (the companion room) or 酒馆 (role play, docs/design/roleplay.md).
// 工作 is the home; the other two are full pages over it, so everything the
// home keeps running (links, shares, updates, notifications) keeps running.
//
// [AppModeState.startup] is kept: the next launch opens straight into that
// mode (lib/ui/modes/mode_switch.dart). Not to be confused with 界面
// (ui_mode_state.dart), which picks how 工作 is drawn.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppMode { work, companion, tavern }

class AppModeState {
  const AppModeState({this.startup = AppMode.work, this.loaded = false});

  /// The mode a launch opens in.
  final AppMode startup;
  final bool loaded;
}

class AppModeController extends Notifier<AppModeState> {
  static const key = 'app_mode.startup';

  @override
  AppModeState build() {
    unawaited(_load());
    return const AppModeState();
  }

  Future<void> _load() async {
    var startup = AppMode.work;
    try {
      final prefs = await SharedPreferences.getInstance();
      startup = AppMode.values.asNameMap()[prefs.getString(key)] ?? AppMode.work;
    } catch (_) {
      // No preferences backend (tests) or an unreadable store: 工作.
    }
    // 知川助手：小酒馆(tavern) 已下线。历史启动偏好若指向它，回退到工作，
    // 避免升级后仍自动进入一个已从 UI 移除的模式。
    if (startup == AppMode.tavern) startup = AppMode.work;
    // A choice made while reading back wins over the stored value.
    if (!state.loaded) state = AppModeState(startup: startup, loaded: true);
  }

  Future<void> setStartup(AppMode mode) async {
    // 知川助手：小酒馆已下线，任何设置 tavern 为启动模式的请求一律改回工作。
    if (mode == AppMode.tavern) mode = AppMode.work;
    state = AppModeState(startup: mode, loaded: true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, mode.name);
    } catch (_) {}
  }
}

final appModeProvider = NotifierProvider<AppModeController, AppModeState>(AppModeController.new);
