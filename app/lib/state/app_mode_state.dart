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
    // 知川助手：伙伴入口已取消（底部四标签方案）。任何历史启动偏好（
    // companion / tavern）都强制回工作模式，避免启动后卡在一個没有入口的页面。
    // CompanionPage 的代码保留，只是不再有入口。
    // 知川助手 v3 第 4 步：顶栏恢复了「工作 ⇄ 伙伴」切换，伙伴重新可达，
    // 所以只把已下线的小酒馆折回工作，伙伴的启动偏好照旧生效。
    if (startup == AppMode.tavern) startup = AppMode.work;
    // A choice made while reading back wins over the stored value.
    if (!state.loaded) state = AppModeState(startup: startup, loaded: true);
  }

  Future<void> setStartup(AppMode mode) async {
    // 知川助手：小酒馆已下线（伙伴仍在，见顶栏的 工作 ⇄ 伙伴）。
    if (mode == AppMode.tavern) mode = AppMode.work;
    state = AppModeState(startup: mode, loaded: true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, mode.name);
    } catch (_) {}
  }
}

final appModeProvider = NotifierProvider<AppModeController, AppModeState>(AppModeController.new);
