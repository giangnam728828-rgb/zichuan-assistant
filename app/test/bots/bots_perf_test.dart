// 性能相关的回归：运行状态变化只刷该刷的地方、长历史只建可见的行、
// 流式增量不丢字、翻更早的消息不跳阅读位置、模型一多就一页一页地铺。

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/ui/bots/bot_chat_kit.dart';
import 'package:dsh_app/ui/bots/bot_format.dart' show botClock;
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/chat/model_sheet.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

Future<void> _pump(WidgetTester t, Widget home, {required FakeDsBotTransport transport}) async {
  usePhoneView(t);
  await t.pumpWidget(
    goldenApp(home: home, brightness: Brightness.light, overrides: dsBotOverrides(transport)),
  );
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// 40 条消息，够长到不会在首帧就自动去翻更早的页。
List<Object?> _longRoom() {
  final base = DateTime(2026, 10, 23, 15, 10).millisecondsSinceEpoch;
  return [
    for (var i = 0; i < 40; i++)
      {
        'id': 'm$i',
        'kind': 'user',
        'text': '第 $i 条',
        'time': base + i * 60000,
      },
  ];
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a working update only refreshes the status, not the transcript', (t) async {
    final team = sampleTeam(working: false);
    final now = botClock().millisecondsSinceEpoch;
    var tool = 'bash';
    final fake = FakeDsBotTransport(team: team);
    fake.handlers['state'] = (payload) => payload['since'] == null
        ? team
        : {
            'revision': 7,
            'unchanged': true,
            'activity': {'b2': 'tool'},
            'work': {
              'bots': <String, Object?>{},
              'rooms': {
                'r1': [
                  {'botId': 'b2', 'since': now - 1000, 'tool': tool},
                ],
              },
              'approvals': <Object?>[],
            },
          };

    await _pump(t, const RoomChatPage(roomId: 'r1'), transport: fake);
    final before = t.widget<BotTranscript>(find.byType(BotTranscript));
    expect(find.textContaining('运行命令'), findsWidgets);

    // Bot 换了一步：状态回来，页面上只该动顶栏和成员条。
    tool = 'write';
    fake.emit('live', {});
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }

    expect(find.textContaining('修改文件'), findsWidgets);
    expect(
      identical(t.widget<BotTranscript>(find.byType(BotTranscript)), before),
      isTrue,
      reason: '工具备注变了不该重建整段历史',
    );
  });

  testWidgets('a long history builds only the rows on screen', (t) async {
    var built = 0;
    final rows = [
      for (var i = 0; i < 300; i++) BotTimeRow(DateTime(2026, 10, 23, 9).add(Duration(minutes: i))),
    ];
    usePhoneView(t);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BotTranscript(
            rows: rows,
            topInset: 0,
            rowBuilder: (context, row) {
              built++;
              return const SizedBox(height: 40);
            },
          ),
        ),
      ),
    );
    await t.pump();

    expect(built, lessThan(60), reason: '300 行只该建出屏幕里的那些');
    expect(built, greaterThan(0));
  });

  test('a stream delta that arrives before its start is not dropped', () async {
    final fake = FakeDsBotTransport();
    final container = ProviderContainer(overrides: dsBotOverrides(fake));
    addTearDown(container.dispose);
    container.listen(dsBotProvider, (_, _) {}, fireImmediately: true);
    final chat = container.listen(botChatProvider('b2'), (_, _) {}, fireImmediately: true);
    addTearDown(chat.close);

    // 等 hello → state → chat 都跑完，会话身份落到 b2-c。
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    String? streaming() => container.read(botChatProvider('b2')).streaming;
    expect(container.read(botChatProvider('b2')).sessionId, 'b2-c');

    void send(String phase, String text, {String attempt = 'a1'}) => fake.emit('stream', {
      'botId': 'b2',
      'sessionId': 'b2-c',
      'attemptId': attempt,
      'phase': phase,
      'text': text,
    });

    // 没有 start，直接来增量（重连、订阅晚了一步）：认领它，不丢字。
    send('delta', '你');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(streaming(), '你');

    send('delta', '好');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(streaming(), '你好');

    // 新一轮从空开始。
    send('start', '', attempt: 'a2');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(streaming(), '');

    send('delta', '新', attempt: 'a2');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(streaming(), '新');

    // 上一轮的迟到增量不能混进来。
    send('delta', '旧', attempt: 'a1');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(streaming(), '新');

    send('end', '', attempt: 'a2');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(streaming(), isNull);
  });

  testWidgets('loading earlier messages keeps the reading position', (t) async {
    final fake = FakeDsBotTransport();
    final older = [
      for (var i = 0; i < 12; i++)
        {
          'id': 'old$i',
          'kind': 'user',
          'text': '更早的第 $i 条',
          'time': DateTime(2026, 10, 22, 9, 10).add(Duration(minutes: i)).millisecondsSinceEpoch,
        },
    ];
    fake.handlers['room-chat'] = (payload) => {
      'roomId': 'r1',
      'items': payload['cursor'] == null ? _longRoom() : older,
      'cursor': payload['cursor'] == null ? 'c1' : null,
      'running': false,
      'speaking': null,
    };

    await _pump(t, const RoomChatPage(roomId: 'r1'), transport: fake);
    final anchor = find.text('第 39 条');
    expect(anchor, findsOneWidget);
    final before = t.getTopLeft(anchor);

    final container = ProviderScope.containerOf(t.element(find.byType(RoomChatPage)));
    await container.read(roomChatProvider('r1').notifier).loadEarlier();
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }

    expect(container.read(roomChatProvider('r1')).items.length, 52);
    expect(t.getTopLeft(anchor), before, reason: '翻页不该让人丢掉正在读的那一行');
  });

  testWidgets('a big catalog is laid out one page at a time', (t) async {
    final models = [
      for (var i = 0; i < 60; i++) ModelInfo(provider: 'gateway', id: 'm$i', name: 'Model $i'),
    ];
    usePhoneView(t);
    await t.pumpWidget(
      goldenApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showModelSheet(context, current: null, onSelected: (_) {}),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        brightness: Brightness.light,
        overrides: [
          ...dsBotOverrides(FakeDsBotTransport()),
          modelCatalogProvider.overrideWith(
            (_) async => ModelCatalog(
              defaultSelection: null,
              groups: [ProviderGroup('gateway', 'Gateway', models)],
              routableProviders: const ['gateway'],
              failures: const [],
            ),
          ),
        ],
      ),
    );
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.tap(find.text('open'));
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }

    int cards() => t
        .widgetList(
          find.byWidgetPredicate(
            (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.contains('\u0000'),
          ),
        )
        .length;

    expect(cards(), 24, reason: '60 个模型不该一次全建出来');

    // 滚到底：补上下一页。
    final scroll = t
        .widget<SingleChildScrollView>(
          find.descendant(of: find.byType(BottomSheet), matching: find.byType(SingleChildScrollView)).last,
        )
        .controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(cards(), greaterThan(24));
  });
}
