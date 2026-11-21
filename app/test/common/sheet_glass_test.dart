// 抽屉与弹层近实心（v3）：首帧即最终色，不建 BackdropFilter —— 这消除了
// 「先白后变色」的闪色。抽屉/弹层的背景色由 backgroundColor 直接给出，
// 只有位移与透明度参与动画。
//
//   flutter test test/common/sheet_glass_test.dart

import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _open(WidgetTester tester, Widget Function(BuildContext) builder) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showAppSheet<void>(context, builder: builder),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pump();
}

final _sheetBlur = find.descendant(of: find.byType(BottomSheet), matching: find.byType(BackdropFilter));

Color _sheetFill(WidgetTester tester) {
  final box = find
      .descendant(of: find.byType(BottomSheet), matching: find.byType(DecoratedBox))
      .first;
  return (tester.widget<DecoratedBox>(box).decoration as ShapeDecoration).color!;
}

void main() {
  testWidgets('弹层首帧即最终色：不建 BackdropFilter，填充近实心', (tester) async {
    await _open(tester, (_) => const SizedBox(height: 240, child: Text('内容')));
    // 还没 settle：第一帧就应该是最终色。
    expect(_sheetBlur, findsNothing, reason: '近实心弹层不做真模糊');
    final fill = _sheetFill(tester);
    expect(fill.a, greaterThanOrEqualTo(0.9), reason: '填充必须接近不透明，背后文字不能透出来');
    await tester.pumpAndSettle();
    expect(_sheetFill(tester), fill, reason: '颜色不参与补间');
  });

  testWidgets('弹层上升过程中也始终是同一个实心色', (tester) async {
    await _open(tester, (_) => const SizedBox(height: 240, child: Text('内容')));
    final first = _sheetFill(tester);
    for (var t = 0; t < 300; t += 40) {
      await tester.pump(const Duration(milliseconds: 40));
      expect(_sheetFill(tester), first, reason: 'at $t ms');
    }
    expect(_sheetBlur, findsNothing);
  });

  testWidgets('抽屉主题的底色是近实心、遮罩带川青', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          drawer: const Drawer(child: SizedBox(width: 240, child: Text('抽屉'))),
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Scaffold.of(context).openDrawer(),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final theme = Theme.of(tester.element(find.text('抽屉')));
    expect(theme.drawerTheme.backgroundColor!.a, greaterThanOrEqualTo(0.9));
    expect(theme.drawerTheme.backgroundColor, isNotNull);
    expect(theme.drawerTheme.surfaceTintColor, Colors.transparent);
    expect(theme.drawerTheme.scrimColor!.r, closeTo(0x08 / 255, 0.01));
  });
}
