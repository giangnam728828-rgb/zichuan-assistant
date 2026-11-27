// 协作会话的导航（v4）：通知/横幅点进来要回到那次议会或团队——
// 不再 push 独立页面，而是把「打开哪条」写进模式状态，由统一的聊天工作区恢复。

import 'dart:io';

import 'package:dsh_app/collab/collab_session_book.dart';
import 'package:dsh_app/state/conversation_mode_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/ui/council/collab_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show testApp;

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('collab-tap');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 摆一个只有按钮的页面：按钮按下就走协作入口，返回它是否接住了。
  Future<ValueNotifier<bool?>> pumpOpener(WidgetTester tester, String sessionId) async {
    final handled = ValueNotifier<bool?>(null);
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => handled.value = openCollabSession(context, host: HostRef.local, sessionId: sessionId),
              child: const Text('open'),
            ),
          ),
        ),
        overrides: [
          collabSessionRootProvider.overrideWithValue(() async => dir),
          readListLiveConnectionProvider.overrideWith((ref) => null),
        ],
      ),
    );
    return handled;
  }

  Future<void> register(WidgetTester tester, CollabSessionOwner owner) async {
    final container = ProviderScope.containerOf(tester.element(find.text('open')));
    await tester.runAsync(() => container.read(collabSessionBookProvider.notifier).register(owner));
    await tester.pump();
  }

  ConversationModeState modeOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.text('open'))).read(conversationModeProvider);

  testWidgets('议会席位会话：回到那一次议会（runId 交给工作区找回）', (tester) async {
    final handled = await pumpOpener(tester, 'sess-seat');
    await register(
      tester,
      const CollabSessionOwner(
        sessionId: 'sess-seat',
        kind: CollabSessionKind.council,
        ownerId: 'run-7',
        label: 'V41 Flash',
        parentLabel: '要不要上线',
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(handled.value, isTrue);
    final state = modeOf(tester);
    expect(state.mode, ConversationMode.council);
    expect(state.openRunId, 'run-7');
    expect(state.createNew, isFalse);
  });

  testWidgets('团队队友会话：回到那个团队（按 teamId 恢复，不新建）', (tester) async {
    final handled = await pumpOpener(tester, 'sess-mate');
    await register(
      tester,
      const CollabSessionOwner(sessionId: 'sess-mate', kind: CollabSessionKind.team, ownerId: 'team-3', label: '阿蓝'),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(handled.value, isTrue);
    final state = modeOf(tester);
    expect(state.mode, ConversationMode.team);
    expect(state.openId, 'team-3');
    expect(state.createNew, isFalse);
  });

  testWidgets('普通会话：不接，交给原来的聊天路由', (tester) async {
    final handled = await pumpOpener(tester, 'plain-session');

    await tester.tap(find.text('open'));
    await tester.pump();

    expect(handled.value, isFalse);
    expect(modeOf(tester).mode, ConversationMode.chat);
  });
}