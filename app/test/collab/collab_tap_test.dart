// 协作会话的导航：通知/横幅点进来要回到那次议会或团队，
// 而不是打开一个孤立的子会话。

import 'dart:io';

import 'package:dsh_app/collab/collab_session_book.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/ui/council/collab_entry.dart';
import 'package:dsh_app/ui/council/council_page.dart';
import 'package:dsh_app/ui/team/team_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('collab-tap');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 摆一个只有按钮的页面：按钮按下就走协作路由，返回它是否接住了。
  Future<ValueNotifier<bool?>> pumpOpener(WidgetTester tester, String sessionId) async {
    final handled = ValueNotifier<bool?>(null);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          collabSessionRootProvider.overrideWithValue(() async => dir),
          readListLiveConnectionProvider.overrideWith((ref) => null),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    handled.value = openCollabSession(context, host: HostRef.local, sessionId: sessionId),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    return handled;
  }

  Future<void> register(WidgetTester tester, CollabSessionOwner owner) async {
    final container = ProviderScope.containerOf(tester.element(find.text('open')));
    await tester.runAsync(() => container.read(collabSessionBookProvider.notifier).register(owner));
    await tester.pump();
  }

  testWidgets('议会席位会话：回到那一次议会', (tester) async {
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
    expect(find.byType(CouncilPage), findsOneWidget);
    expect(find.byType(TeamPage), findsNothing);
  });

  testWidgets('团队队友会话：回到那个团队', (tester) async {
    final handled = await pumpOpener(tester, 'sess-mate');
    await register(
      tester,
      const CollabSessionOwner(
        sessionId: 'sess-mate',
        kind: CollabSessionKind.team,
        ownerId: 'team-3',
        label: '阿蓝',
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(handled.value, isTrue);
    expect(find.byType(TeamPage), findsOneWidget);
    expect(find.byType(CouncilPage), findsNothing);
  });

  testWidgets('普通会话：不接，交给原来的聊天路由', (tester) async {
    final handled = await pumpOpener(tester, 'plain-session');

    await tester.tap(find.text('open'));
    await tester.pump();

    expect(handled.value, isFalse);
    expect(find.byType(CouncilPage), findsNothing);
    expect(find.byType(TeamPage), findsNothing);
  });
}
