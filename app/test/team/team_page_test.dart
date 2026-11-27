// 团队聊天模式的界面测试：点进来就是一条新团队会话、紧凑的初始化面板、
// 成员抽屉、@ 点名、收发消息、从历史恢复、删除只影响这一条（方案第三部分）。
//
// 编排器换成内存仓库：widget 测试跑在 fake async 里，真实文件 IO 会让
// 「等队友答完」永远等不到；落盘另有一条纯 Dart 测试覆盖。

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/collab/collab_conversations.dart';
import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/team/team_models.dart';
import 'package:dsh_app/team/team_orchestrator.dart';
import 'package:dsh_app/team/team_store.dart';
import 'package:dsh_app/ui/collab/collab_kit.dart';
import 'package:dsh_app/ui/chat/shared/conversation_mode_host.dart';
import 'package:dsh_app/ui/team/team_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show testApp;
import '../collab/mode_view_harness.dart';

ModelCatalog _catalog() => const ModelCatalog(
  defaultSelection: ModelSelection(provider: 'deepseek', model: 'flash'),
  routableProviders: ['deepseek', 'zhipu'],
  groups: [
    ProviderGroup('deepseek', 'DeepSeek', [
      ModelInfo(provider: 'deepseek', id: 'flash', name: 'V41 Flash'),
      ModelInfo(provider: 'deepseek', id: 'pro', name: 'V4 Pro'),
    ]),
    ProviderGroup('zhipu', '智谱', [ModelInfo(provider: 'zhipu', id: 'glm-5', name: 'GLM-5')]),
  ],
  failures: [],
);

/// 内存里的团队仓库：不做文件 IO，fake async 下也能跑完。
final class _MemTeamStore extends TeamStore {
  _MemTeamStore() : super(Directory.systemTemp);

  final teams = <String, TeamState>{};

  @override
  Future<void> save(TeamState state) async {
    teams[state.id] = state;
  }

  @override
  Future<TeamState?> load(String id) async => teams[id];

  @override
  Future<List<TeamState>> list() async => teams.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Future<void> delete(String id) async => teams.remove(id);

  @override
  Future<void> writeMarkdown(TeamState state) async {}
}

/// 立刻答一句的驱动：不经过网络，也不模拟失败。
///
/// [replies] 按「队友名字 → 答复正文」定制台词；没配的人回一句「收到」。
final class _Driver implements CollabSessionDriver {
  _Driver({this.replies = const {}});

  final Map<String, String> replies;
  var _sessions = 0;
  final opened = <String>[];
  final _labels = <String, String>{};

  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async {
    final id = 's${_sessions++}';
    opened.add(id);
    _labels[id] = seat.label ?? '';
    return id;
  }

  @override
  Future<TurnOutcome> runTurn(
    String sessionId,
    String text, {
    Duration? timeout,
    List<CollabAttachment> attachments = const [],
  }) async {
    final reply = replies[_labels[sessionId]] ?? '收到';
    return TurnOutcome(kind: TurnKind.completed, text: reply);
  }

  @override
  Future<void> cancel(String sessionId) async {}
}

Teammate _mate(String id, String name) => Teammate(id: id, name: name, provider: 'deepseek', model: 'flash');

/// 推进微任务与帧（内存仓库没有真实 IO，几帧就够）。
Future<void> _settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 菜单 / 底部面板的动画。
Future<void> _settleAnim(WidgetTester tester) => _settle(tester, frames: 25);

/// 等到这个团队里所有队友都答完（没有人在跑）。
Future<void> _waitForIdle(WidgetTester tester, _MemTeamStore store, String teamId) async {
  for (var i = 0; i < 200; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    final state = store.teams[teamId];
    if (state != null && state.running.isEmpty && state.messages.any((m) => m.role == TeamMsgRole.teammate)) {
      return;
    }
  }
  fail('队友没有在限定时间内答完：${store.teams[teamId]?.running}');
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('composer-send')));
  await tester.pump();
}

/// 内存里的议会登记表：历史列表合并读取时不去碰磁盘。
final class _MemConversationStore extends CouncilConversationStore {
  _MemConversationStore() : super(Directory.systemTemp);

  @override
  Future<Map<String, CouncilConversation>> load() async => const {};

  @override
  Future<void> save(Map<String, CouncilConversation> all) async {}
}

Future<void> _pump(
  WidgetTester tester,
  TeamOrchestrator orchestrator, {
  String? teamId,
  bool resumeLatest = false,
}) async {
  final header = ValueNotifier<CollabHeaderInfo?>(null);
  addTearDown(header.dispose);
  await tester.pumpWidget(
    testApp(
      ModeViewHarness(
        header: header,
        newLabel: '新团队',
        child: TeamModeView(orchestrator: orchestrator, teamId: teamId, resumeLatest: resumeLatest, header: header),
      ),
      overrides: [
        modelCatalogProvider.overrideWith((ref) async => _catalog()),
        // 目录已缓存：新建会话按它凑两位成员（真机上点进来时通常也已经有缓存）。
        currentModelCatalogProvider.overrideWithValue(_catalog()),
        readListLiveConnectionProvider.overrideWith((ref) => null),
      ],
    ),
  );
  await _settle(tester);
}

void main() {
  late _MemTeamStore store;

  setUp(() {
    store = _MemTeamStore();
  });

  TeamOrchestrator orchestrator({Map<String, String> replies = const {}}) {
    final created = TeamOrchestrator(
      driver: _Driver(replies: replies),
      store: store,
    );
    addTearDown(created.dispose);
    return created;
  }

  testWidgets('点进来就是一条新团队会话：标识、标题、空状态、输入栏', (tester) async {
    final orch = orchestrator();
    await _pump(tester, orch);

    // 统一顶栏由 ChatHeader 承担；脚手架里标题是「新团队」。
    expect(find.text('新团队'), findsOneWidget);
    expect(find.textContaining('2 位队友'), findsOneWidget);
    // 按模型目录默认给了两位，各用各的模型。
    expect(find.textContaining('都在群里了。'), findsOneWidget);
    expect(find.text('直接说事，或者 @ 其中一位。'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(const ValueKey('team-members')), findsOneWidget);
    expect(store.teams, hasLength(1));
    expect(store.teams.values.single.teammates.map((m) => m.model), ['flash', 'pro']);
  });

  testWidgets('目录里一个模型都没有：紧凑的初始化面板，加完就地回到聊天', (tester) async {
    final orch = orchestrator();
    final header = ValueNotifier<CollabHeaderInfo?>(null);
    addTearDown(header.dispose);
    await tester.pumpWidget(
      testApp(
        ModeViewHarness(
          header: header,
          newLabel: '新团队',
          child: TeamModeView(orchestrator: orch, header: header),
        ),
        overrides: [
          modelCatalogProvider.overrideWith(
            (ref) async => const ModelCatalog(defaultSelection: null, routableProviders: [], groups: [], failures: []),
          ),
          readListLiveConnectionProvider.overrideWith((ref) => null),
        ],
      ),
    );
    await _settle(tester);

    expect(find.text('先加两位队友'), findsOneWidget);
    expect(find.textContaining('每位队友各用各的模型'), findsOneWidget);
    expect(find.byKey(const ValueKey('team-onboarding-add')), findsOneWidget);
    // 没有 @ 键。
    expect(find.byTooltip('点名'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('team-onboarding-add')));
    await _settleAnim(tester);
    expect(find.text('团队成员'), findsOneWidget);
    expect(find.text('还没有队友：加两位，各用各的模型和上下文。'), findsOneWidget);
    // 没有目录可选，点「添加队友」打开的是空的选择器；直接关掉。
    // 抽屉里的「添加队友」在面板底部（页面底下那块还在，取最后一个）。
    await tester.tap(find.widgetWithText(FilledButton, '添加队友').last);
    await _settleAnim(tester);
    expect(find.text('没有匹配的模型'), findsOneWidget);
  });

  testWidgets('群聊：我发的和队友答的各自成条，@ 点名被剥掉', (tester) async {
    // 编排器要在真实异步区里构造：fake async 区里建出的 Future 链在 runAsync 里等不到。
    late TeamOrchestrator orch;
    late String opened;
    await tester.runAsync(() async {
      orch = TeamOrchestrator(driver: _Driver(), store: store);
      addTearDown(orch.dispose);
      final team = await orch.create(teammates: [_mate('m1', '阿蓝'), _mate('m2', '阿橙')], leadId: 'm1');
      await orch.send(team.id, '@阿蓝 在吗');
      opened = team.id;
    });
    await _pump(tester, orch, teamId: opened);

    expect(find.byType(CollabUserBubble), findsOneWidget);
    // 标题也取自第一句，所以正文至少在气泡里。
    expect(find.text('在吗'), findsWidgets);
    expect(find.textContaining('收到'), findsOneWidget);
    expect(find.text('阿蓝'), findsWidgets);
    expect(find.byType(CollabMessage), findsOneWidget);
  });

  testWidgets('@ 键：选中队友后插进输入框', (tester) async {
    final orch = orchestrator();
    await _pump(tester, orch);

    await tester.tap(find.byTooltip('点名'));
    await _settleAnim(tester);
    await tester.tap(find.text('队友 1').last);
    await _settleAnim(tester);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, '@队友 1 ');
  });

  testWidgets('发送：消息上屏，队友答复随后到，落盘的是新会话', (tester) async {
    final orch = orchestrator();
    await _pump(tester, orch);
    final teamId = store.teams.keys.single;

    await _send(tester, '大家报个进度');
    await _waitForIdle(tester, store, teamId);

    expect(find.byType(CollabUserBubble), findsOneWidget);
    // 没点名：默认第一位是主管，先由他接活。
    expect(find.textContaining('主管 队友 1'), findsOneWidget);
    expect(find.byType(CollabMessage), findsOneWidget);
    expect(find.textContaining('收到'), findsOneWidget);

    final saved = store.teams[teamId]!;
    expect(saved.messages.where((m) => m.role == TeamMsgRole.user), hasLength(1));
    expect(saved.messages.where((m) => m.role == TeamMsgRole.teammate), hasLength(1));
    expect(saved.messages.last.teammateId, saved.teammates.first.id);
    expect(saved.displayTitle, '大家报个进度');
    expect(tester.takeException(), isNull);
  });

  testWidgets('成员抽屉：紧凑列表、两人时不能再减、加人入口在', (tester) async {
    final orch = orchestrator();
    await _pump(tester, orch);

    await tester.tap(find.byKey(const ValueKey('team-members')));
    await _settleAnim(tester);

    expect(find.text('团队成员'), findsOneWidget);
    expect(find.text('2/6（至少 2 位）'), findsOneWidget);
    expect(find.text('队友 1'), findsOneWidget);
    expect(find.text('队友 2'), findsOneWidget);
    expect(find.text('添加队友'), findsOneWidget);

    // 默认第一位是主管：展开第二位看操作项；两位时不给移除。
    await tester.tap(find.text('队友 2'));
    await _settleAnim(tester);
    expect(find.text('名字/任务'), findsOneWidget);
    expect(find.text('只读'), findsOneWidget);
    expect(find.text('移除'), findsNothing);
    expect(find.text('设为主管'), findsOneWidget);

    // 关掉抽屉回到聊天：会话还在，记录没丢。
    // 点抽屉外面收起，回到聊天。
    await tester.tapAt(const Offset(5, 5));
    await _settleAnim(tester);
    expect(find.text('团队成员'), findsNothing);
    expect(store.teams, hasLength(1));
  });

  testWidgets('设主管后：不点名时只有主管答，抽屉里标着「主管」', (tester) async {
    final orch = orchestrator();
    await _pump(tester, orch);
    final teamId = store.teams.keys.single;

    await tester.tap(find.byKey(const ValueKey('team-members')));
    await _settleAnim(tester);
    await tester.tap(find.text('队友 2'));
    await _settleAnim(tester);
    await tester.tap(find.text('设为主管'));
    await _settleAnim(tester);
    expect(find.text('取消主管'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await _settleAnim(tester);
    expect(find.textContaining('主管 队友 2'), findsOneWidget);

    await _send(tester, '这周做什么');
    await _waitForIdle(tester, store, teamId);
    expect(find.byType(CollabMessage), findsOneWidget);
    final saved = store.teams[teamId]!;
    expect(saved.leadId, saved.teammates[1].id);
    expect(saved.messages.last.teammateId, saved.teammates[1].id);
  });

  testWidgets('移交卡：队友把活交给下一位，气泡上写着交给谁', (tester) async {
    late TeamOrchestrator orch;
    late String opened;
    await tester.runAsync(() async {
      orch = TeamOrchestrator(
        driver: _Driver(replies: {'阿蓝': '前端改完了。\n移交 @阿橙', '阿橙': '测试跑过了'}),
        store: store,
      );
      addTearDown(orch.dispose);
      final team = await orch.create(teammates: [_mate('m1', '阿蓝'), _mate('m2', '阿橙')]);
      await orch.send(team.id, '@阿蓝 改一下登录页');
      opened = team.id;
    });
    await _pump(tester, orch, teamId: opened);

    expect(find.textContaining('前端改完了。'), findsOneWidget);
    expect(find.textContaining('交给 阿橙 接着做'), findsOneWidget);
    expect(find.textContaining('测试跑过了'), findsOneWidget);
    // 移交那行本身不进气泡正文。
    expect(find.textContaining('移交 @阿橙'), findsNothing);
  });

  testWidgets('新团队：复制上一个团队的队友配置，各会话互不影响', (tester) async {
    final orch = orchestrator();
    await _pump(tester, orch);
    final first = store.teams.values.single;
    final firstTeamId = first.id;

    // 第一条里说句话。
    await _send(tester, '第一条会话');
    await _waitForIdle(tester, store, firstTeamId);
    expect(store.teams, hasLength(1));

    // 菜单里「新团队」。
    await tester.tap(find.byTooltip('更多'));
    await _settleAnim(tester);
    await tester.tap(find.text('新团队'));
    await _settle(tester, frames: 30);
    expect(store.teams, hasLength(2));

    // 新的那条复制了队友，但消息是空的。
    final second = store.teams.values.where((t) => t.id != firstTeamId).single;
    expect(second.teammates.map((m) => m.name), first.teammates.map((m) => m.name));
    expect(second.teammates.map((m) => m.model), first.teammates.map((m) => m.model));
    expect(second.messages, isEmpty);
    expect(find.text('直接说事，或者 @ 其中一位。'), findsOneWidget);
    expect(find.text('新团队'), findsOneWidget);
  });

  testWidgets('从历史打开指定团队：恢复它的消息，不新建', (tester) async {
    late TeamOrchestrator orch;
    await tester.runAsync(() async {
      orch = TeamOrchestrator(driver: _Driver(), store: store);
      addTearDown(orch.dispose);
      final a = await orch.create(teammates: [_mate('a1', '老蓝'), _mate('a2', '老橙')], title: '老团队');
      await orch.send(a.id, '老团队的第一句');
      final b = await orch.create(teammates: [_mate('b1', '新蓝'), _mate('b2', '新橙')]);
      await orch.send(b.id, '新团队的第一句');
    });
    final older = store.teams.values.firstWhere((t) => t.title == '老团队');

    await _pump(tester, orch, teamId: older.id);

    expect(find.text('老团队'), findsOneWidget);
    expect(find.text('老团队的第一句'), findsOneWidget);
    expect(find.text('新团队的第一句'), findsNothing);
    expect(find.byType(CollabMessage), findsNWidgets(2));
    expect(store.teams, hasLength(2));
  });

  test('删除只影响这一条：别的团队、别的记录都还在', () async {
    final dir = await Directory.systemTemp.createTemp('team-delete-');
    addTearDown(() => dir.delete(recursive: true));
    final real = TeamStore(dir);
    final a = TeamState(
      id: 'ta',
      title: '甲',
      teammates: [_mate('a1', '阿蓝'), _mate('a2', '阿橙')],
      createdAt: DateTime(2026, 3, 1),
      updatedAt: DateTime(2026, 3, 1),
      rev: 1,
    );
    final b = TeamState(
      id: 'tb',
      title: '乙',
      teammates: [_mate('b1', '阿绿'), _mate('b2', '阿紫')],
      createdAt: DateTime(2026, 3, 1),
      updatedAt: DateTime(2026, 3, 2),
      rev: 1,
    );
    await real.save(a);
    await real.save(b);
    await real.writeMarkdown(a);
    await real.delete('ta');

    expect(await real.load('ta'), isNull);
    expect((await real.list()).map((t) => t.id), ['tb']);
    expect(File('${dir.path}/ta.md').existsSync(), isFalse);
    expect(File('${dir.path}/ta.json').existsSync(), isFalse);
    expect(File('${dir.path}/tb.json').existsSync(), isTrue);
  });

  testWidgets('历史登记：团队会话进历史列表；删一条只影响这一条', (tester) async {
    await tester.runAsync(() async {
      final orch = TeamOrchestrator(driver: _Driver(), store: store);
      addTearDown(orch.dispose);
      await orch.create(teammates: [_mate('a1', '阿蓝'), _mate('a2', '阿橙')], title: '留下来的');
      final talked = await orch.create(teammates: [_mate('b1', '阿绿'), _mate('b2', '阿紫')]);
      await orch.send(talked.id, '历史里的问题');
    });
    final talkedId = store.teams.values.firstWhere((t) => t.messages.isNotEmpty).id;

    final probe = GlobalKey<_HistoryProbeState>();
    await tester.pumpWidget(
      testApp(
        _HistoryProbe(key: probe),
        overrides: [
          teamStoreProvider.overrideWith((ref) async => store),
          councilStoreProvider.overrideWith((ref) async => _MemConversationStore()),
        ],
      ),
    );
    await _settle(tester);

    final entries = probe.currentState!.entries;
    // 最近说过话的在前。
    expect(entries.first.id, talkedId);
    expect(entries.first.kind, CollabKind.team);
    expect(entries.first.title, '历史里的问题');
    expect(entries.first.memberLabel, '2 位队友');
    expect(entries.last.title, '留下来的');

    // 删掉说过话的那条：另一条还在，登记表里也没了。
    final doomed = entries.first;
    await probe.currentState!.delete(doomed.id);
    await _settle(tester);
    expect(store.teams.containsKey(talkedId), isFalse);
    expect(probe.currentState!.entries.map((e) => e.id), isNot(contains(talkedId)));
  });
}

/// 把历史列表暴露出来给测试读，并代为调用删除（删除需要 WidgetRef）。
class _HistoryProbe extends ConsumerStatefulWidget {
  const _HistoryProbe({super.key});

  @override
  ConsumerState<_HistoryProbe> createState() => _HistoryProbeState();
}

class _HistoryProbeState extends ConsumerState<_HistoryProbe> {
  final _loaded = Completer<void>();
  List<CollabHistoryEntry> entries = const [];

  Future<void> get loaded => _loaded.future;

  Future<void> delete(String id) => deleteCollabEntry(ref, entries.firstWhere((e) => e.id == id));

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(collabHistoryProvider);
    entries = async.value ?? const [];
    if (async.hasValue && !_loaded.isCompleted) _loaded.complete();
    return const Scaffold(body: Text('probe'));
  }
}
