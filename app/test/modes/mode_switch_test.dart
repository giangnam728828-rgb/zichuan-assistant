import 'package:dsh_app/state/app_mode_state.dart';
import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
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
  testWidgets('3a：历史启动偏好（伙伴/酒馆）一律强制回工作，不再进入那个页面', (tester) async {
    // 底部四标签方案里伙伴没有入口；若还按旧偏好启动会卡在一个出不去的地方。
    for (final stored in ['tavern', 'companion']) {
      SharedPreferences.setMockInitialValues({AppModeController.key: stored});
      await tester.pumpWidget(_app(const ModeLaunch(child: Text('工作首页'))));
      await tester.pumpAndSettle();

      expect(find.byType(TavernHomePage), findsNothing, reason: stored);
      expect(find.text('工作首页'), findsOneWidget, reason: stored);
    }
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

    // 3a：启动偏好一律回工作。伙伴/酒馆已没有入口，若按旧偏好启动
    // 会卡在一个出不来的页面上，所以 setStartup 把非工作模式改写成工作。
    final container = ProviderScope.containerOf(tester.element(find.byType(ModeSheet)));
    await container.read(appModeProvider.notifier).setStartup(AppMode.companion);
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppModeController.key), 'work');
  });
}
