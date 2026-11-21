// 设置 › 关于：版本行、项目与来源两条链接、底部的品牌与声明。
//
// 知川助手：这一页在原项目里是「作者的三条个人主页」，品牌化之后换成了
// 「知川助手源码 + 上游项目」两条链接。测试跟着新结构走，保留仍然有价值的
// 覆盖：360dp×1.3 不溢出、每条链接可点且打开正确 URL、没有浏览器时复制网址、
// 异常不谎报成功、屏幕阅读器把行读成链接。

import 'dart:ui' show SemanticsAction;

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/app_info.dart';
import 'package:dsh_app/state/star_prompt.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/ui/settings/about_page.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/update/version.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_fonts.dart';

class _FixedUpdate extends AppUpdateController {
  @override
  AppUpdateState build() => const AppUpdateState(current: AppVersion(1, 0, 2, build: 42));
}

class _StarStore implements StarPromptStore {
  final writes = <StarPromptRecord>[];

  @override
  Future<StarPromptRecord?> read() async => const StarPromptRecord();

  @override
  Future<void> write(StarPromptRecord record) async => writes.add(record);
}

/// 关于页的两条链接：自己的源码，与它来自的上游。
const _links = [
  ('about-repository', 'https://github.com/giangnam728828-rgb/zichuan-assistant'),
  ('about-upstream', 'https://github.com/ccch1mneyyy/dsh-go'),
];

void main() {
  late List<Uri> opened;
  late _StarStore store;
  late Future<bool> Function(Uri) opener;

  tearDown(() => AppLocale.use(AppLocale.zhCN));

  setUp(() {
    opened = [];
    store = _StarStore();
    opener = (uri) async {
      opened.add(uri);
      return true;
    };
  });

  Future<void> pump(
    WidgetTester tester, {
    Locale locale = AppLocale.zhCN,
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    AppLocale.use(locale);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appUpdateProvider.overrideWith(_FixedUpdate.new),
          starLinkOpenerProvider.overrideWithValue((uri) => opener(uri)),
          starPromptStoreProvider.overrideWithValue(store),
          starPromptGateProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          theme: withTestFonts(buildLightTheme()),
          darkTheme: withTestFonts(buildDarkTheme()),
          themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
          locale: locale,
          supportedLocales: AppLocale.supported,
          localizationsDelegates: L10n.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const AboutPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final row = find.byKey(ValueKey(key));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  for (final locale in AppLocale.supported) {
    for (final brightness in Brightness.values) {
      testWidgets('source links fit 360dp at 1.3x in $locale $brightness', (tester) async {
        await pump(tester, locale: locale, brightness: brightness, scale: 1.3);
        final english = locale == AppLocale.en;
        final l10n = lookupL10n(locale);

        // 两条链接的标题与句柄（句柄是仓库地址，不是人名了）。
        expect(find.text(l10n.hubAboutRepository), findsOneWidget);
        expect(find.text(l10n.hubAboutUpstream), findsOneWidget);
        expect(find.text('github.com/giangnam728828-rgb/zichuan-assistant'), findsOneWidget);
        expect(find.text('DSH Go · DeepSeek Harness'), findsOneWidget);
        // 版本行还在。
        expect(find.text('1.0.2 (42)'), findsOneWidget);

        for (final (key, _) in _links) {
          final row = find.byKey(ValueKey(key));
          await tester.ensureVisible(row);
          await tester.pumpAndSettle();
          expect(tester.getSize(row).height, greaterThanOrEqualTo(64));
          expect(tester.widget<SettingsTile>(row).onTap, isNotNull);
          expect(tester.takeException(), isNull, reason: 'No overflow at $key');
        }

        // 底部的约定声明必须可读、可点中。
        final disclaimer = find.text(
          english
              ? 'An independent DeepSeek Harness derivative · Not affiliated with DeepSeek'
              : '基于 DeepSeek Harness 的独立衍生应用 · 与 DeepSeek 无官方关联',
        );
        await tester.ensureVisible(disclaimer);
        await tester.pumpAndSettle();
        expect(disclaimer.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('each link opens its exact URL without finishing the star prompt', (tester) async {
    await pump(tester);
    for (final (key, _) in _links) {
      await tap(tester, key);
    }
    expect(opened.map((uri) => uri.toString()), _links.map((link) => link.$2));
    expect(store.writes, isEmpty);
  });

  testWidgets('no browser copies the exact URL and reports it', (tester) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    opener = (_) async => false;
    await pump(tester);
    await tap(tester, 'about-upstream');
    expect(clipboard, AppInfo.upstreamUrl);
    // 复制成功时提示的是「网址已复制」，不是「打开失败」。
    expect(find.text(lookupL10n(AppLocale.zhCN).shellBrowserUrlCopied), findsOneWidget);
    expect(store.writes, isEmpty);
  });

  testWidgets('browser and clipboard exceptions report failure without claiming a copy', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') throw PlatformException(code: 'no-clipboard');
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    opener = (_) async => throw PlatformException(code: 'no-browser');
    await pump(tester, locale: AppLocale.en);
    await tap(tester, 'about-repository');
    expect(find.text(lookupL10n(AppLocale.en).stateBrowserOpenFailed), findsOneWidget);
    expect(find.text(lookupL10n(AppLocale.en).shellBrowserUrlCopied), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('links are announced as actionable links', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await pump(tester, locale: AppLocale.en);
      for (final (key, _) in _links) {
        final row = find.byKey(ValueKey(key));
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        final node = tester.getSemantics(row);
        expect(node.flagsCollection.isLink, isTrue);
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      }
    } finally {
      semantics.dispose();
    }
  });
}
