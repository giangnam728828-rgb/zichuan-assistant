// V4.4 · S2 设置行的文字约束（任务书 4.4 / 4.7 / 18.3）。
//
// 真机截图的症状：模型名一长，左边「模型」两个字被压成竖排，右边值还越界。
// 根因是 Row 里 value 没有宽度约束——非 flex 子项先按自然宽度拿走空间，
// Expanded 的标题只剩 0。这里用最窄的手机宽度 + 超长模型名钉住修复结果。

import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show loadTestFonts, testApp;

const _longModel =
    'XingChenAGI/Xing4.1-Preview-Ultra-Long-Context-Reasoning-2026-11-29-experimental-build';

Future<void> _pumpTile(WidgetTester tester, {double width = 320, double scale = 1}) async {
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: SettingsTile(
              icon: AppIcons.providers,
              title: '模型',
              value: const Text(_longModel),
              onTap: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('320dp + 100 字符模型名：标题仍是横排，值在右半边省略', (tester) async {
    await _pumpTile(tester);
    expect(tester.takeException(), isNull);

    final row = tester.getRect(find.byType(SettingsTile));
    final title = tester.getRect(find.text('模型'));
    final value = tester.getRect(find.text(_longModel));
    // 竖排时标题宽只有一个字（约 14dp）；横排至少两个字宽。
    expect(title.width, greaterThan(24), reason: '标题被压成竖排了');
    expect(title.height, lessThan(40), reason: '标题不该折成多行');
    // 值最多拿 58%，且不越过这一行的右边。
    expect(value.width, lessThanOrEqualTo(320 * 0.58 + 1));
    expect(value.right, lessThanOrEqualTo(row.right + 0.5));
  });

  testWidgets('2 倍字号：仍然不越界，标题不竖排', (tester) async {
    await _pumpTile(tester, scale: 2);
    expect(tester.takeException(), isNull);
    final row = tester.getRect(find.byType(SettingsTile));
    final title = tester.getRect(find.text('模型'));
    final value = tester.getRect(find.text(_longModel));
    expect(title.width, greaterThan(24));
    expect(value.right, lessThanOrEqualTo(row.right + 0.5));
  });

  testWidgets('短值只占自己的宽度，标题拿满剩下的空间', (tester) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: SettingsTile(icon: AppIcons.providers, title: '模型', value: const Text('已连接'), onTap: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final value = tester.getRect(find.text('已连接'));
    expect(value.width, lessThan(80), reason: '短值不该被拉成半行宽');
  });
}
