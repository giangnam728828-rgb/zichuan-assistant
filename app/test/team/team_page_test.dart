// 团队页的界面测试（C4 MVP）：建队表单、进入群聊、@ 点名、发送、成员面板。
//
// 编排器用注入的（临时目录 + Stub 驱动），不碰网络也不碰 path_provider。

import 'dart:io';

import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/state/features_state.dart';
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
///
/// [replies] 按「队友名字 → 答复正文」定制台词；没配的人回一句「收到」。
final class StubDriver implements CollabSessionDriver {
  StubDriver({this.replies = const {}});

  final Map<String, String> replies;
  var _sessions = 0;
  final prompts = <String, List<String>>{};
  final _labels = <String, String>{};

  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async {
    final id = 's${_sessions++}';
    _labels[id] = seat.label ?? '';
    return id;
  }

  @override
  Future<TurnOutcome> runTurn(String sessionId, String text, {Duration? timeout}) async {
    prompts.putIfAbsent(sessionId, () => []).add(text);
    final reply = replies[_labels[sessionId]] ?? '收到';
    return TurnOutcome(kind: TurnKind.completed, text: reply);
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

Future<void> _pump(WidgetTester tester, {TeamOrchestrator? orchestrator, String? teamId}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        modelCatalogProvider.overrideWith((ref) async => _catalog()),
        // 预设列表走平台通道，测试里给个空表。
        agentPresetsProvider.overrideWith((ref) async => const <AgentPresetInfo>[]),
        readListLiveConnectionProvider.overrideWith((ref) => null),
      ],
      child: MaterialApp(home: TeamPage(orchestrator: orchestrator, teamId: teamId)),
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

  testWidgets('建队时勾主管：不点名时只有主管答，成员面板标着「主管」', (tester) async {
    await _pump(tester, orchestrator: orch);
    await tester.enterText(find.byType(TextField).at(0), '阿蓝');
    await tester.enterText(find.byType(TextField).at(2), '阿橙');
    await tester.pump();

    // 给第一位勾上主管。
    await tester.tap(find.widgetWithText(FilterChip, '主管').first);
    await tester.pump();

    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, '建队'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.widgetWithText(FilledButton, '建队'));
    await tester.pump();
    await _settleIo(tester);

    // 群里发一句不点名的，只有主管回。
    await tester.enterText(find.byType(TextField), '这周做什么');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    await _settleIo(tester);

    expect(find.text('收到'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.group_outlined));
    await _settleAnim(tester);
    expect(find.text('主管'), findsOneWidget);
  });

  testWidgets('移交卡：队友把活交给下一位，气泡上写着交给谁', (tester) async {
    // 编排器必须在真实异步区里构造：widget 测试的 fake async 区里建出来的
    // Future 链要靠 pump 才推进，在 runAsync 里等它会直接卡死。
    late TeamOrchestrator orchestrator;
    await tester.runAsync(() async {
      final stub = StubDriver(
        replies: {
          '阿蓝': '前端改完了。\n移交 @阿橙',
          '阿橙': '测试跑过了',
        },
      );
      orchestrator = TeamOrchestrator(driver: stub, store: store);
      final team = await orchestrator.create(
        teammates: [_mate('m1', '阿蓝'), _mate('m2', '阿橙')],
      );
      await orchestrator.send(team.id, '@阿蓝 改一下登录页');
    });
    addTearDown(orchestrator.dispose);

    await _pump(tester, orchestrator: orchestrator);
    expect(find.text('前端改完了。'), findsOneWidget);
    expect(find.text('交给 阿橙 接着做'), findsOneWidget);
    expect(find.text('测试跑过了'), findsOneWidget);
    // 移交那行本身不进气泡正文。
    expect(find.textContaining('移交 @阿橙'), findsNothing);
  });

  testWidgets('成员面板点一位队友：设为主管，再点撤销', (tester) async {
    await tester.runAsync(() async {
      await orch.create(teammates: [_mate('m1', '阿蓝'), _mate('m2', '阿橙')]);
    });
    await _pump(tester, orchestrator: orch);

    await tester.tap(find.byIcon(Icons.group_outlined));
    await _settleAnim(tester);
    expect(find.text('主管'), findsNothing);

    await tester.tap(find.text('阿橙'));
    await _settleAnim(tester);
    await _settleIo(tester, rounds: 6);
    expect(find.text('主管'), findsOneWidget);

    await tester.tap(find.text('阿橙'));
    await _settleAnim(tester);
    await _settleIo(tester, rounds: 6);
    expect(find.text('主管'), findsNothing);
  });

  testWidgets('历史团队：列出建过的团队，点一条切回去', (tester) async {
    // setUp 的时钟是固定的，两个团队的 updatedAt 会相同；这里换成走动的时钟
    // 才能确定「最新的是哪个」。
    var tick = 0;
    final ticking = TeamOrchestrator(
      driver: StubDriver(),
      store: store,
      clock: () => DateTime(2026, 3, 1).add(Duration(minutes: tick++)),
    );
    addTearDown(ticking.dispose);
    await tester.runAsync(() async {
      await ticking.create(teammates: [_mate('a1', '阿蓝'), _mate('a2', '阿橙')]);
      await ticking.create(teammates: [_mate('b1', '阿绿'), _mate('b2', '阿紫')]);
    });
    await _pump(tester, orchestrator: ticking);
    // 页面要多读一遍盘（最近团队 + 补登记的会话），再多推几轮。
    await _settleIo(tester, rounds: 60);
    // 默认打开最新那个。
    expect(find.text('阿绿、阿紫 都在群里了。'), findsOneWidget);

    await tester.tap(find.byTooltip('历史团队'));
    await _settleIo(tester);
    await _settleAnim(tester);
    expect(find.text('建过的团队'), findsOneWidget);
    expect(find.text('阿蓝、阿橙'), findsOneWidget);
    expect(find.text('阿绿、阿紫'), findsOneWidget);

    await tester.tap(find.text('阿蓝、阿橙'));
    await _settleIo(tester);
    await _settleAnim(tester);
    expect(find.text('阿蓝、阿橙 都在群里了。'), findsOneWidget);
    expect(find.text('阿绿、阿紫 都在群里了。'), findsNothing);
  });

  testWidgets('指定 teamId：直接打开那一个团队（通知点进来用）', (tester) async {
    var tick = 0;
    final ticking = TeamOrchestrator(
      driver: StubDriver(),
      store: store,
      clock: () => DateTime(2026, 3, 1).add(Duration(minutes: tick++)),
    );
    addTearDown(ticking.dispose);
    late String olderId;
    await tester.runAsync(() async {
      olderId = (await ticking.create(teammates: [_mate('a1', '老蓝'), _mate('a2', '老橙')])).id;
      // 后建的那个更新：默认会打开它，指定 id 时必须打开老的。
      await ticking.create(teammates: [_mate('b1', '新蓝'), _mate('b2', '新橙')]);
    });

    await _pump(tester, orchestrator: ticking, teamId: olderId);
    await _settleIo(tester, rounds: 60);

    expect(find.text('老蓝、老橙 都在群里了。'), findsOneWidget);
    expect(find.text('新蓝、新橙 都在群里了。'), findsNothing);
  });
}
