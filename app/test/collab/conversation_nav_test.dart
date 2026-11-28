// v4.2 · P0-A / P0-C 验收：历史会话按自己的类型打开，不被当前模式污染。
//
// 之前的 bug：当前停在议会，点普通历史只改了 sessionId，页面仍是议会 →
// 用户看到「普通会话变成了团队/议会」。这里对四种交叉情形逐一断言。

import 'package:dsh_app/state/conversation_mode_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/collab/collab_conversations.dart';
import 'package:dsh_app/ui/collab/conversation_nav.dart';
import 'package:dsh_app/collab/collab_conversations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ConversationRef normal(String id) => ConversationRef(kind: ConversationKind.normal, conversationId: id);
  ConversationRef council(String id) => ConversationRef(kind: ConversationKind.council, conversationId: id);
  ConversationRef team(String id) => ConversationRef(kind: ConversationKind.team, conversationId: id);

  /// 在真实 provider 容器里跑一次打开动作（不依赖页面）。
  ConversationModeState open(ProviderContainer container, ConversationRef target) {
    // 只验证「类型 → 模式 + 会话引用」这一层；切标签需要真实 Navigator，另测。
    openConversationWith(container, null, target, goToChatTab: false);
    return container.read(conversationModeProvider);
  }

  test('当前停在议会，点普通历史 A：模式回聊天、选中 A，不新建议会', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final modes = container.read(conversationModeProvider.notifier);
    modes.setMode(ConversationMode.council);
    modes.rememberCouncil(conversationHostKey(const HostRef.ssh('mac')), 'c-9');

    final after = open(container, normal('session-A'));
    expect(after.mode, ConversationMode.chat, reason: '普通历史必须把浏览模式切回聊天');
    expect(container.read(currentSessionProvider), 'session-A');
    expect(after.createNew, isFalse, reason: '不能顺手建一条新会话');
    expect(after.idFor(ConversationMode.council, conversationHostKey(const HostRef.ssh('mac'))), 'c-9',
        reason: '原来的议会记录不被覆盖');
  });

  test('当前停在团队，点普通历史 B：B 被选中，团队仍保留', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final modes = container.read(conversationModeProvider.notifier);
    modes.setMode(ConversationMode.team);
    modes.rememberTeam(conversationHostKey(const HostRef.ssh('mac')), 't-1');

    final after = open(container, normal('session-B'));
    expect(after.mode, ConversationMode.chat);
    expect(container.read(currentSessionProvider), 'session-B');
    expect(after.idFor(ConversationMode.team, conversationHostKey(const HostRef.ssh('mac'))), 't-1');
  });

  test('当前是普通聊天，点团队 C：进入团队 C，普通会话不被清空', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(currentSessionProvider.notifier).select('session-A');
    container.read(conversationModeProvider.notifier).setMode(ConversationMode.chat);

    final after = open(container, team('team-C'));
    expect(after.mode, ConversationMode.team);
    expect(after.openId, 'team-C');
    expect(container.read(currentSessionProvider), 'session-A', reason: '普通会话引用保持不变');
  });

  test('当前是普通聊天，点议会 D：进入议会 D', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final after = open(container, council('council-D'));
    expect(after.mode, ConversationMode.council);
    expect(after.openId, 'council-D');
  });

  test('交替点 A、B、C、D：每次只换目标，不产生 createNew', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    for (final target in [normal('A'), normal('B'), team('C'), council('D'), normal('A')]) {
      final after = open(container, target);
      expect(after.createNew, isFalse);
      switch (target.kind) {
        case ConversationKind.normal:
          expect(after.mode, ConversationMode.chat);
          expect(container.read(currentSessionProvider), target.conversationId);
        case ConversationKind.team:
          expect(after.mode, ConversationMode.team);
          expect(after.openId, target.conversationId);
        case ConversationKind.council:
          expect(after.mode, ConversationMode.council);
          expect(after.openId, target.conversationId);
      }
    }
  });

  test('协作历史条目转换出的引用带正确的 kind 与 id', () {
    final at = DateTime(2026, 11, 28);
    final councilEntry = CollabHistoryEntry(
      id: 'c1',
      kind: CollabKind.council,
      title: '议会一',
      subtitle: '',
      memberCount: 3,
      createdAt: at,
      updatedAt: at,
    );
    final teamEntry = CollabHistoryEntry(
      id: 't1',
      kind: CollabKind.team,
      title: '团队一',
      subtitle: '',
      memberCount: 2,
      createdAt: at,
      updatedAt: at,
    );
    final a = ConversationRef.fromCollab(councilEntry);
    final b = ConversationRef.fromCollab(teamEntry);
    expect(a.kind, ConversationKind.council);
    expect(a.conversationId, 'c1');
    expect(b.kind, ConversationKind.team);
    expect(b.conversationId, 't1');
    expect(a == b, isFalse);
  });

  test('同一会话的两次引用相等（避免重复打开）', () {
    expect(normal('A') == normal('A'), isTrue);
    expect(normal('A') == normal('B'), isFalse);
    expect(team('T') == council('T'), isFalse, reason: 'id 相同但类型不同，不能当成同一条');
  });
}
