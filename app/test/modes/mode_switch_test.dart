import 'package:dsh_app/state/app_mode_state.dart';
import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/modes/mode_switch.dart';
import 'package:dsh_app/ui/tavern/tavern_home_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

Widget _app(Widget home) => ProviderScope(
  overrides: [tavernProvider.overrideWith((ref) => PreviewTavern(tick: const Duration(milliseconds: 1)))],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: withTestFonts(buildLightTheme()),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: home,
  ),
);

void main() {
  testWidgets('启动偏好：酒馆折回工作（第 4 步只折酒馆）', (tester) async {
    SharedPreferences.setMockInitialValues({AppModeController.key: 'tavern'});
    await tester.pumpWidget(_app(const ModeLaunch(child: Text('工作首页'))));
    await tester.pumpAndSettle();
    expect(find.byType(TavernHomePage), findsNothing);
    expect(find.text('工作首页'), findsOneWidget);
  });

  testWidgets('启动偏好：伙伴照旧进入伙伴小屋（第 4 步恢复了入口）', (tester) async {
    SharedPreferences.setMockInitialValues({AppModeController.key: 'companion'});
    await tester.pumpWidget(_app(const ModeLaunch(child: Text('工作首页'))));
    await tester.pumpAndSettle();
    expect(find.byType(CompanionPage), findsOneWidget);
  });

  testWidgets('工作 as the startup mode shows the home and opens nothing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_app(const ModeLaunch(child: Text('工作首页'))));
    await tester.pumpAndSettle();

    expect(find.text('工作首页'), findsOneWidget);
    expect(find.byType(TavernHomePage), findsNothing);
  });

  testWidgets('the 模式 sheet opens a visible mode; 启动偏好一律回到工作', (tester) async {
    SharedPreferences.setMockInitialValues({});
    AppMode? opened;
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: ModeSheet(current: AppMode.work, onOpen: (mode) => opened = mode),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('工作'), findsWidgets);
    expect(find.text('伙伴小屋'), findsOneWidget);
    // 酒馆已下线（visibleModes 只剩工作与伙伴），不再出现在这里。
    expect(find.byKey(const ValueKey('mode-row-tavern')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('mode-row-companion')));
    await tester.pumpAndSettle();
    expect(opened, AppMode.companion);

    // 第 4 步：顶栏恢复了「工作 ⇄ 伙伴」，伙伴重新可达，启动偏好照旧生效；
    // 只有已下线的小酒馆被折回工作。
    final container = ProviderScope.containerOf(tester.element(find.byType(ModeSheet)));
    await container.read(appModeProvider.notifier).setStartup(AppMode.companion);
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppModeController.key), 'companion');
    await container.read(appModeProvider.notifier).setStartup(AppMode.tavern);
    await tester.pumpAndSettle();
    expect(prefs.getString(AppModeController.key), 'work');
  });
}
