// 团队页的界面测试（C4 MVP）：建队表单、进入群聊、@ 点名、发送、成员面板。
//
// 编排器用注入的（临时目录 + Stub 驱动），不碰网络也不碰 path_provider。

import 'dart:io';

import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/team/team_models.dart';
import 'package:dsh_app/team/team_orchestrator.dart';
import 'package:dsh_app/team/team_store.dart';
import 'package:dsh_app/ui/team/team_page.dart';
import 'package:dsh_client/dsh_client.dart';
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

/// 立刻答一句的驱动：不经过网络，也不模拟失败。
final class StubDriver implements CollabSessionDriver {
  var _sessions = 0;
  final prompts = <String, List<String>>{};

  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async => 's${_sessions++}';

  @override
  Future<TurnOutcome> runTurn(String sessionId, String text, {Duration? timeout}) async {
    prompts.putIfAbsent(sessionId, () => []).add(text);
    return const TurnOutcome(kind: TurnKind.completed, text: '收到');
  }

  @override
  Future<void> cancel(String sessionId) async {}
}

Teammate _mate(String id, String name) =>
    Teammate(id: id, name: name, provider: 'deepseek', model: 'flash');

/// 推进真实的文件 IO。
///
/// widget 测试跑在 fake async 里：`File.readAsString` 的完成事件要靠真实事件
/// 循环送达，`pump` 才会接着 flush microtask。所以「真实等一小会儿 → pump」
/// 反复几轮，页面上的加载态才会结束（否则一直转圈，pumpAndSettle 会卡死）。
Future<void> _settleIo(WidgetTester tester, {int rounds = 24}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 8)));
    await tester.pump();
  }
}

/// 菜单 / 底部面板的动画：用固定步长推进，不用 pumpAndSettle（页面上可能有
/// 一直在转的进度圈）。
Future<void> _settleAnim(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _pump(WidgetTester tester, {TeamOrchestrator? orchestrator}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        modelCatalogProvider.overrideWith((ref) async => _catalog()),
        readListLiveConnectionProvider.overrideWith((ref) => null),
      ],
      child: MaterialApp(home: TeamPage(orchestrator: orchestrator)),
    ),
  );
  await tester.pump();
  await _settleIo(tester);
}

void main() {
  late Directory dir;
  late TeamStore store;
  late TeamOrchestrator orch;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('team_page');
    store = TeamStore(dir);
    orch = TeamOrchestrator(
      driver: StubDriver(),
      store: store,
      clock: () => DateTime(2026, 3, 1),
    );
  });

  tearDown(() async {
    await orch.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  testWidgets('没连上引擎：摆好两位队友的空位，建队按钮不可用', (tester) async {
    await _pump(tester);
    expect(find.text('几位队友，一个群'), findsOneWidget);
    expect(find.text('队友 1'), findsOneWidget);
    expect(find.text('队友 2'), findsOneWidget);
    expect(find.text('2/6（至少 2 位）'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, '建队'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '建队'));
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('建队：填名字后进入群聊，队友名字用填的', (tester) async {
    await _pump(tester, orchestrator: orch);
    await tester.enterText(find.byType(TextField).at(0), '阿蓝');
    await tester.enterText(find.byType(TextField).at(2), '阿橙');
    await tester.pump();

    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, '建队'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.widgetWithText(FilledButton, '建队'));
    await tester.pump();
    await _settleIo(tester);

    expect(find.text('阿蓝、阿橙 都在群里了。'), findsOneWidget);
    expect(find.text('直接说事，或者 @ 其中一位。'), findsOneWidget);
  });

  testWidgets('群聊：我发的和队友答的都在，@ 点名被剥掉', (tester) async {
    await tester.runAsync(() async {
      final team = await orch.create(teammates: [_mate('m1', '阿蓝'), _mate('m2', '阿橙')]);
      await orch.send(team.id, '@阿蓝 在吗');
    });

    await _pump(tester, orchestrator: orch);
    expect(find.text('在吗'), findsOneWidget);
    expect(find.text('收到'), findsOneWidget);
    expect(find.text('阿蓝'), findsOneWidget);
    // @ 阿橙没被点名，不该有第二个答复
    expect(find.text('收到'), findsOneWidget);
  });

  testWidgets('@ 键：选中队友后插进输入框', (tester) async {
    await tester.runAsync(() async {
      await orch.create(teammates: [_mate('m1', '阿蓝'), _mate('m2', '阿橙')]);
    });
    await _pump(tester, orchestrator: orch);

    await tester.tap(find.byIcon(Icons.alternate_email));
    await _settleAnim(tester);
    await tester.tap(find.text('阿蓝').last);
    await _settleAnim(tester);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, '@阿蓝 ');
  });

  testWidgets('发送：消息上屏，队友答复随后到', (tester) async {
    await tester.runAsync(() async {
      await orch.create(teammates: [_mate('m1', '阿蓝'), _mate('m2', '阿橙')]);
    });
    await _pump(tester, orchestrator: orch);

    await tester.enterText(find.byType(TextField), '大家报个进度');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    await _settleIo(tester);

    expect(find.text('大家报个进度'), findsOneWidget);
    expect(find.text('收到'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('成员面板：两人时不能再减，加人入口在', (tester) async {
    await tester.runAsync(() async {
      await orch.create(teammates: [_mate('m1', '阿蓝'), _mate('m2', '阿橙')]);
    });
    await _pump(tester, orchestrator: orch);

    await tester.tap(find.byIcon(Icons.group_outlined));
    await _settleAnim(tester);

    expect(find.text('队友'), findsOneWidget);
    expect(find.text('2/6（至少 2 位）'), findsOneWidget);
    final remove = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.person_remove_outlined).first,
    );
    expect(remove.onPressed, isNull);
    expect(find.text('加一位队友'), findsOneWidget);
  });
}
