// 团队会话的保留与恢复（方案第五部分 / 第十部分第 4 项）。
//
// 切走页面、页面重建、进程重启之后，团队**还是那一条**：teamId 不变、消息
// 还在、正在跑的不重复跑、也不会因为「重新进了一次」凭空多一条空团队。
//
// 这里用内存 store + 假驱动，不碰网络。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/team/team_models.dart';
import 'package:dsh_app/team/team_orchestrator.dart';
import 'package:dsh_app/team/team_store.dart';
import 'package:dsh_app/ui/chat/shared/conversation_mode_host.dart';
import 'package:dsh_app/ui/team/team_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show testApp;

/// 内存团队仓库：不写磁盘。
final class _MemStore extends TeamStore {
  _MemStore() : super(Directory.systemTemp);

  final teams = <String, TeamState>{};

  @override
  Future<void> save(TeamState state) async => teams[state.id] = state;

  @override
  Future<TeamState?> load(String id) async => teams[id];

  @override
  Future<TeamState?> latest() async {
    if (teams.isEmpty) return null;
    final all = teams.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return all.first;
  }

  @override
  Future<List<TeamState>> list() async => teams.values.toList();

  @override
  Future<void> delete(String id) async => teams.remove(id);
}

/// 只回一句的假驱动：够跑通「一轮答完」，不产生真实调用。
final class _FakeDriver implements CollabSessionDriver {
  int opened = 0;
  final prompts = <String>[];

  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async {
    opened++;
    return 'sess-${seat.id}';
  }

  @override
  Future<TurnOutcome> runTurn(
    String sessionId,
    String text, {
    Duration? timeout,
    List<CollabAttachment> attachments = const [],
  }) async {
    prompts.add(text);
    return const TurnOutcome(kind: TurnKind.completed, text: '收到，我来做。');
  }

  @override
  Future<void> cancel(String sessionId) async {}
}

TeamState _seed(String id) => TeamState(
  id: id,
  title: '输入栏遮挡',
  teammates: const [
    Teammate(id: 'm1', name: '队友甲', provider: 'deepseek', model: 'flash'),
    Teammate(id: 'm2', name: '队友乙', provider: 'deepseek', model: 'pro'),
  ],
  leadId: 'm1',
  messages: [
    TeamMsg(id: 'q1', role: TeamMsgRole.user, text: '把输入栏挡住的内容修掉', at: DateTime(2026, 11, 27, 9)),
    TeamMsg(
      id: 'a1',
      role: TeamMsgRole.teammate,
      teammateId: 'm1',
      text: '已经改好布局了。',
      at: DateTime(2026, 11, 27, 9, 1),
    ),
  ],
  createdAt: DateTime(2026, 11, 27, 9),
  updatedAt: DateTime(2026, 11, 27, 9, 1),
  rev: 1,
);

Future<void> _pump(
  WidgetTester tester, {
  required TeamOrchestrator orchestrator,
  required String? teamId,
  required ValueNotifier<CollabHeaderInfo?> header,
}) async {
  tester.view.physicalSize = const Size(390, 844) * 3.0;
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: TeamModeView(
          orchestrator: orchestrator,
          teamId: teamId,
          createNew: false,
          header: header,
          topInset: 0,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('按 teamId 恢复：消息还在，不新建一条空团队', (tester) async {
    final store = _MemStore()..teams['t1'] = _seed('t1');
    final orchestrator = TeamOrchestrator(driver: _FakeDriver(), store: store);
    addTearDown(orchestrator.dispose);
    final header = ValueNotifier<CollabHeaderInfo?>(null);
    addTearDown(header.dispose);

    await _pump(tester, orchestrator: orchestrator, teamId: 't1', header: header);

    expect(store.teams, hasLength(1), reason: '恢复不是新建');
    expect(find.textContaining('把输入栏挡住的内容修掉'), findsWidgets);
    expect(find.textContaining('已经改好布局了'), findsWidgets);
    // 顶栏拿到的标题来自那条团队，不是「新团队」。
    expect(header.value?.title, '输入栏遮挡');
  });

  testWidgets('页面重建（切走再回来）仍是同一条：id 不变、没有重复消息', (tester) async {
    final store = _MemStore()..teams['t1'] = _seed('t1');
    final orchestrator = TeamOrchestrator(driver: _FakeDriver(), store: store);
    addTearDown(orchestrator.dispose);
    final header = ValueNotifier<CollabHeaderInfo?>(null);
    addTearDown(header.dispose);

    await _pump(tester, orchestrator: orchestrator, teamId: 't1', header: header);
    final before = store.teams['t1']!;

    // 切走：整棵树换掉（模拟切到别的标签/模式）。
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    await _pump(tester, orchestrator: orchestrator, teamId: 't1', header: header);

    expect(store.teams.keys, ['t1'], reason: '不新建、不覆盖成另一条');
    final after = store.teams['t1']!;
    expect(after.id, before.id);
    expect(after.messages.map((m) => m.id), before.messages.map((m) => m.id));
  });

  testWidgets('正在跑的不重复跑：重建后不会自己再发一轮', (tester) async {
    final driver = _FakeDriver();
    final store = _MemStore()..teams['t1'] = _seed('t1');
    final orchestrator = TeamOrchestrator(driver: driver, store: store);
    addTearDown(orchestrator.dispose);
    final header = ValueNotifier<CollabHeaderInfo?>(null);
    addTearDown(header.dispose);

    await _pump(tester, orchestrator: orchestrator, teamId: 't1', header: header);
    final calls = driver.prompts.length;
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await _pump(tester, orchestrator: orchestrator, teamId: 't1', header: header);

    expect(driver.prompts.length, calls, reason: '恢复只读状态，不触发新的模型调用');
  });
}
