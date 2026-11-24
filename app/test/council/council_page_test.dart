// 议会页的界面测试（C2 MVP）：编辑态渲染、成员多选门槛、提交按钮文案。

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/ui/council/council_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ModelCatalog _catalog() => const ModelCatalog(
  defaultSelection: ModelSelection(provider: 'deepseek', model: 'flash'),
  routableProviders: ['deepseek', 'zhipu'],
  groups: [
    ProviderGroup('deepseek', 'DeepSeek', [
      ModelInfo(provider: 'deepseek', id: 'flash', name: 'V41 Flash'),
      ModelInfo(provider: 'deepseek', id: 'pro', name: 'V4 Pro'),
    ]),
    ProviderGroup('zhipu', '字谱', [
      ModelInfo(provider: 'zhipu', id: 'glm-5', name: 'GLM-5'),
    ]),
  ],
  failures: [],
);

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        modelCatalogProvider.overrideWith((ref) async => _catalog()),
        readListLiveConnectionProvider.overrideWith((ref) => null),
      ],
      child: const MaterialApp(home: CouncilPage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('编辑态：标题、议题输入、按供应商分组的模型', (tester) async {
    await _pump(tester);
    expect(find.text('向议会提问'), findsOneWidget);
    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.text('字谱'), findsOneWidget);
    expect(find.text('V41 Flash'), findsOneWidget);
    expect(find.text('GLM-5'), findsOneWidget);
    // 未选成员：提交按钮禁用并提示门槛
    expect(find.textContaining('至少选 2 个成员'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('选满两个成员后按钮可用，文案带预计调用数', (tester) async {
    await _pump(tester);
    await tester.tap(find.widgetWithText(FilterChip, 'V41 Flash'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip, 'V4 Pro'));
    await tester.pump();
    await tester.scrollUntilVisible(find.byType(FilledButton), 200, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('预计 3 次调用'), findsOneWidget);
    // 审议模式预计 2 倍
    await tester.tap(find.text('审议'));
    await tester.pump();
    expect(find.textContaining('预计 5 次调用'), findsOneWidget);
  });

  testWidgets('循证模式：模式说明切换，成员行出现角色下拉', (tester) async {
    await _pump(tester);
    await tester.tap(find.widgetWithText(FilterChip, 'V41 Flash'));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('循证'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('循证'));
    await tester.pump();
    expect(find.text('权威席位先答，其余成员只做校验与补漏。'), findsOneWidget);
    // 已选成员行有角色下拉（默认「无角色」）
    expect(find.text('成员与角色'), findsOneWidget);
    expect(find.byType(DropdownButton<SeatRole>), findsOneWidget);
    // 换角色
    await tester.tap(find.byType(DropdownButton<SeatRole>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('怀疑者').last);
    await tester.pumpAndSettle();
    expect(find.text('怀疑者'), findsOneWidget);
  });

  testWidgets('最多选 6 个成员', (tester) async {
    await _pump(tester);
    // 只有 3 个模型可选，全选上不越界
    for (final name in ['V41 Flash', 'V4 Pro', 'GLM-5']) {
      await tester.tap(find.widgetWithText(FilterChip, name));
      await tester.pump();
    }
    expect(find.text('已选 3（2 到 6 个）'), findsOneWidget);
  });

  testWidgets('没有连接时提交给出明确错误，不崩', (tester) async {
    await _pump(tester);
    await tester.enterText(find.byType(TextField), '本地优先做哪类功能？');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip, 'V41 Flash'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip, 'V4 Pro'));
    await tester.pump();
    await tester.scrollUntilVisible(find.byType(FilledButton), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('还没有连上引擎'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
