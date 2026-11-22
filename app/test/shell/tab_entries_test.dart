// 川水 3b：入口一律「切标签」，不再 push 与标签重复的根页。
//
//   ① 工具页「全部设置」→ 设置标签（搜索页作为子页仍压在上面）
//   ② 抽屉身份栏「设置」→ 设置标签
//   ③ 抽屉身份栏「全部功能」→ 工具标签
//   ④ 静态检查：全项目不再有 push(SettingsScreen) / push(AllFeaturesPage)
//
//   flutter test test/shell/tab_entries_test.dart

import 'dart:io';

import 'package:dsh_app/state/adaptive_layout_state.dart';
import 'package:dsh_app/ui/features/all_features_page.dart';
import 'package:dsh_app/ui/settings/search/settings_search_page.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/root_tab.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/glass.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show loadTestFonts, mockClipboard, pumpFrames;
import 'adaptive/support.dart';

// 被路由盖住时 HomeShell 会变成 offstage，find 要显式带上 skipOffstage: false。
ProviderContainer _c(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(HomeShell, skipOffstage: false)));

RootTab _tab(WidgetTester tester) => _c(tester).read(rootTabProvider);

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    freezeClocks();
  });
  tearDown(thawClocks);

  testWidgets('① 工具页「全部设置」切到设置标签，搜索页压在上面', (tester) async {
    useWindow(tester, const Size(390, 844));
    mockClipboard(tester);
    await tester.pumpWidget(homeApp());
    await pumpFrames(tester, 8);
    expect(_tab(tester), RootTab.chat);

    openAllSettings(tester.element(find.byType(HomeShell)));
    await pumpFrames(tester, 10);

    expect(_tab(tester), RootTab.settings);
    // 搜索仍是设置的子页，返回会落到设置标签。
    expect(find.byType(SettingsSearchPage), findsOneWidget);
  });

  testWidgets('② 抽屉身份栏「设置」切到设置标签', (tester) async {
    useWindow(tester, const Size(390, 844));
    mockClipboard(tester);
    await tester.pumpWidget(homeApp());
    await pumpFrames(tester, 8);

    await openDrawerBySwipe(tester);
    expect(find.byType(SessionsDrawer), findsOneWidget);
    final key = find.ancestor(
      of: find.descendant(of: find.byType(IdentityBar), matching: find.byIcon(AppIcons.settings)),
      matching: find.byType(GlassSurface),
    );
    await tester.tap(key.first);
    await pumpFrames(tester, 12);
    expect(_tab(tester), RootTab.settings);
  });

  testWidgets('③ 抽屉身份栏「全部功能」切到工具标签', (tester) async {
    useWindow(tester, const Size(390, 844));
    mockClipboard(tester);
    await tester.pumpWidget(homeApp());
    await pumpFrames(tester, 8);

    await openDrawerBySwipe(tester);
    final key = find.ancestor(
      of: find.descendant(of: find.byType(IdentityBar), matching: find.byIcon(AppIcons.allFeatures)),
      matching: find.byType(GlassSurface),
    );
    await tester.tap(key.first);
    await pumpFrames(tester, 12);
    expect(_tab(tester), RootTab.tools);
  });

  test('④ 全项目不再 push 与标签重复的根页（设置 / 全部功能）', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // 标签页自身的定义与索引用得到这两个类，不算 push 入口。
      if (entity.path.endsWith('settings_screen.dart') ||
          entity.path.endsWith('all_features_page.dart') ||
          entity.path.endsWith('settings_pages.dart') ||
          entity.path.endsWith('page_links.dart')) {
        continue;
      }
      final text = entity.readAsStringSync();
      for (final line in text.split('\n')) {
        if (!line.contains('push(')) continue;
        if (line.contains('SettingsScreen()') || line.contains('AllFeaturesPage()')) {
          offenders.add('${entity.path}: ${line.trim()}');
        }
      }
    }
    expect(offenders, isEmpty, reason: '这些入口应当切标签：\n${offenders.join('\n')}');
  });
}
