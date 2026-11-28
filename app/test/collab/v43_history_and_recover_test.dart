// v4.3 · 15.4 / 15.7：历史只列真正产生过对话的会话、跨模式切换不串身份、
// 切回正在跑的协作会话时第一层立刻有内容。
//
// 15.4：空议会/空团队仍然保留（成员配置、草稿都在），但不再占历史列表的位置；
//       运行中只要发过一条真实消息就立刻出现。
// 15.7：A/B/C 交叉打开时，每种会话各自带着自己的 kind 与 id；编排器的内存
//       快照（peek）在页面重建后仍然拿得到，不用等落盘。

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/collab/collab_conversations.dart';
import 'package:dsh_app/council/collab_models.dart';
import 'package:dsh_app/council/collab_orchestrator.dart';
import 'package:dsh_app/council/collab_store.dart';
import 'package:dsh_app/state/conversation_mode_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/team/team_models.dart';
import 'package:dsh_app/team/team_orchestrator.dart';
import 'package:dsh_app/team/team_store.dart';
import 'package:dsh_app/ui/collab/conversation_nav.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

SeatSpec _seat(String id) => SeatSpec(id: id, provider: 'p', model: 'm-$id', label: id);
Teammate _mate(String id, String name) => Teammate(id: id, name: name, provider: 'p', model: 'm-$id');

final class _Hang implements CollabSessionDriver {
  final hang = Completer<TurnOutcome>();
  final bySeat = <String, List<String>>{};
  final _seatOf = <String, String>{};
  int _seq = 0;

  @override
  Future<String> openSession(SeatSpec seat, {String? workspaceId}) async {
    final id = 's${_seq++}';
    _seatOf[id] = seat.id;
    return id;
  }

  @override
  Future<TurnOutcome> runTurn(
    String sessionId,
    String text, {
    Duration? timeout,
    List<CollabAttachment> attachments = const [],
  }) {
    bySeat.putIfAbsent(_seatOf[sessionId] ?? '', () => []).add(text);
    return hang.future;
  }

  @override
  Future<void> cancel(String sessionId) async {}
}

Future<void> _until(bool Function() predicate, {Duration timeout = const Duration(seconds: 3)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('15.4 历史只显示真正产生过对话的会话', () {
    test('议会：没有用户提问就不进历史，问过就进', () {
      final now = DateTime.now();
      final empty = CouncilConversation(
        id: 'c0',
        seats: [_seat('a'), _seat('b')],
        turns: const [],
        createdAt: now,
        updatedAt: now,
      );
      expect(empty.hasUserQuestion, isFalse);

      // 建了会话但还没提问（回合已占位、问题为空）：仍然不算。
      final blank = CouncilConversation(
        id: 'c1',
        seats: [_seat('a'), _seat('b')],
        turns: [CouncilTurn(runId: 'r1', question: '  ', at: now)],
        createdAt: now,
        updatedAt: now,
      );
      expect(blank.hasUserQuestion, isFalse);

      final asked = CouncilConversation(
        id: 'c2',
        seats: [_seat('a'), _seat('b')],
        turns: [CouncilTurn(runId: 'r2', question: '你们好', at: now)],
        createdAt: now,
        updatedAt: now,
      );
      expect(asked.hasUserQuestion, isTrue, reason: '运行中只发过一条真实消息也要立刻出现在历史里');
    });

    test('团队：只有系统提示不算对话，有一条用户消息就算', () {
      final now = DateTime.now();
      final empty = TeamState(
        id: 't0',
        teammates: [_mate('m1', '甲'), _mate('m2', '乙')],
        messages: [
          TeamMsg(id: 's1', role: TeamMsgRole.system, text: '团队已就绪', at: now),
        ],
        createdAt: now,
        updatedAt: now,
      );
      expect(empty.hasUserMessage, isFalse);

      final asked = TeamState(
        id: 't1',
        teammates: [_mate('m1', '甲'), _mate('m2', '乙')],
        messages: [
          TeamMsg(id: 's1', role: TeamMsgRole.system, text: '团队已就绪', at: now),
          TeamMsg(id: 'u1', role: TeamMsgRole.user, text: '你们好', at: now),
        ],
        createdAt: now,
        updatedAt: now,
      );
      expect(asked.hasUserMessage, isTrue);
    });

    test('旧数据里的会话级 context 归到最后一条用户消息，之后不再继承', () {
      final now = DateTime.now().toIso8601String();
      final state = TeamState.fromJson({
        'id': 't9',
        'teammates': [
          {'id': 'm1', 'name': '甲', 'provider': 'p', 'model': 'm1'},
          {'id': 'm2', 'name': '乙', 'provider': 'p', 'model': 'm2'},
        ],
        'messages': [
          {'id': 'u1', 'role': 'user', 'text': '帮我看看这个仓库', 'at': now},
          {'id': 'a1', 'role': 'mate', 'teammateId': 'm1', 'text': '看了', 'at': now},
        ],
        'context': '【此前的对话资料】\n修复 UI 层遮挡',
        'createdAt': now,
        'updatedAt': now,
      });
      expect(state.messages.first.context, contains('修复 UI 层遮挡'), reason: '资料回到当时那条消息身上');
      expect(state.context, isEmpty, reason: '会话级字段要清空，不能继续污染下一条消息');
      expect(state.toJson().containsKey('context'), isFalse, reason: '不再往盘上写会话级 context');
      expect(state.messages.length, 2, reason: '一条消息都不删');
    });
  });

  group('15.7 跨模式切换不串身份', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    ConversationRef normal(String id) => ConversationRef(kind: ConversationKind.normal, conversationId: id);
    ConversationRef council(String id) => ConversationRef(kind: ConversationKind.council, conversationId: id);
    ConversationRef team(String id) => ConversationRef(kind: ConversationKind.team, conversationId: id);

    test('议会A → 普通B → 团队C → 普通A：每次都回到自己', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final modes = container.read(conversationModeProvider.notifier);

      modes.setMode(ConversationMode.council);
      modes.rememberCouncil(conversationHostKey(const HostRef.ssh('mac')), 'council-A');

      openConversationWith(container, null, normal('session-B'), goToChatTab: false);
      expect(container.read(currentSessionProvider), 'session-B');
      expect(container.read(conversationModeProvider).mode, ConversationMode.chat);

      openConversationWith(container, null, team('team-C'), goToChatTab: false);
      expect(container.read(conversationModeProvider).openId, 'team-C');
      expect(container.read(currentSessionProvider), 'session-B', reason: '普通会话引用不被团队覆盖');

      openConversationWith(container, null, normal('session-A'), goToChatTab: false);
      expect(container.read(currentSessionProvider), 'session-A');
      expect(
        container.read(conversationModeProvider).idFor(ConversationMode.council, conversationHostKey(const HostRef.ssh('mac'))),
        'council-A',
        reason: '原来的议会记录仍在',
      );
    });

    test('团队A → 议会B → 普通C：三种引用各自独立', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final modes = container.read(conversationModeProvider.notifier);
      modes.setMode(ConversationMode.team);
      modes.rememberTeam(conversationHostKey(const HostRef.ssh('mac')), 'team-A');

      openConversationWith(container, null, council('council-B'), goToChatTab: false);
      expect(container.read(conversationModeProvider).mode, ConversationMode.council);
      expect(
        container.read(conversationModeProvider).idFor(ConversationMode.team, conversationHostKey(const HostRef.ssh('mac'))),
        'team-A',
      );

      openConversationWith(container, null, normal('session-C'), goToChatTab: false);
      expect(container.read(currentSessionProvider), 'session-C');
      expect(container.read(conversationModeProvider).mode, ConversationMode.chat);
    });
  });

  group('15.7 切回来时第一层立刻有内容', () {
    test('团队：运行中的内存快照拿得到（peek 不等落盘）', () async {
      final tmp = Directory.systemTemp.createTempSync('v43_peek');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final driver = _Hang();
      final orchestrator = TeamOrchestrator(driver: driver, store: TeamStore(tmp));
      final team = await orchestrator.create(
        teammates: [_mate('m1', '甲'), _mate('m2', '乙')],
        leadId: 'm1',
      );
      expect(orchestrator.peek(team.id)?.id, team.id);

      unawaited(orchestrator.send(team.id, '分析一下这个方案的取舍'));
      await _until(() => driver.bySeat.values.any((list) => list.isNotEmpty));

      final live = orchestrator.peek(team.id)!;
      expect(live.id, team.id);
      expect(live.messages.where((m) => m.role == TeamMsgRole.user).length, 1, reason: '用户那句话已经在快照里');
      expect(live.rev, greaterThan(team.rev), reason: '快照比初始状态新');

      driver.hang.complete(const TurnOutcome(kind: TurnKind.aborted));
      await orchestrator.dispose();
    });

    test('议会：运行中的 run 能直接 peek 到当前成员与正文', () async {
      final tmp = Directory.systemTemp.createTempSync('v43_peek_run');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final driver = _Hang();
      final orchestrator = CollabOrchestrator(
        driver: driver,
        store: CollabStore(tmp),
        newId: () => 'run-peek',
        retryDelay: (_, _) => Duration.zero,
      );
      unawaited(
        orchestrator.submit(
          CouncilSpec(question: '分析一下这个方案', seats: [_seat('a'), _seat('b')], budgetCalls: 16),
        ),
      );
      await _until(() => orchestrator.peek('run-peek') != null);

      final live = orchestrator.peek('run-peek')!;
      expect(live.phase, isNot(CollabPhase.done));
      expect(live.seats.keys.toSet(), {'a', 'b'});
      expect(live.callsUsed, 0);

      driver.hang.complete(const TurnOutcome(kind: TurnKind.aborted));
      await orchestrator.dispose();
    });
  });
}
