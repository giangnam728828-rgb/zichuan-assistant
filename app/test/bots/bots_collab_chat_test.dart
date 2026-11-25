// 聊天式改造的回归：问题卡在时间线里、输入框能直接回答问题、
// 新建讨论室带上协作方式。

import 'package:dsh_app/ui/bots/bot_chat_kit.dart';
import 'package:dsh_app/ui/bots/bot_chat_page.dart';
import 'package:dsh_app/ui/bots/bot_format.dart' show botClock;
import 'package:dsh_app/ui/bots/new_room_sheet.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

Future<void> _pump(WidgetTester t, Widget home, {FakeDsBotTransport? transport}) async {
  usePhoneView(t);
  await t.pumpWidget(
    goldenApp(
      home: home,
      brightness: Brightness.light,
      overrides: dsBotOverrides(transport ?? FakeDsBotTransport()),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Map<String, Object?> _question({
  bool multiSelect = false,
  bool allowCustom = false,
  List<String> options = const ['交给 Coder', '我自己写'],
}) => {
  'm1c': {
    'id': 'q1',
    'question': '演示脚本交给 Coder 吗？',
    'options': [for (final label in options) {'label': label}],
    'multiSelect': multiSelect,
    'allowCustom': allowCustom,
  },
};

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a question card lives in the timeline, not above the composer', (t) async {
    final fake = FakeDsBotTransport(team: sampleTeam(working: false, questions: _question(allowCustom: true)));
    await _pump(t, const BotChatPage(botId: 'm1'), transport: fake);

    expect(find.byType(BotQuestionCard), findsOneWidget);
    // 在聊天记录里，而不是 bottom 的卡片列。
    expect(
      find.ancestor(of: find.byType(BotQuestionCard), matching: find.byType(BotTranscript)),
      findsOneWidget,
    );
  });

  testWidgets('free text in the composer answers the question instead of sending', (t) async {
    final fake = FakeDsBotTransport(team: sampleTeam(working: false, questions: _question(allowCustom: true)));
    fake.handlers['answer-question'] = (_) => true;
    await _pump(t, const BotChatPage(botId: 'm1'), transport: fake);

    await t.enterText(find.byType(TextField).first, '今晚给我就行');
    await t.pump();
    await t.tap(find.byIcon(AppIcons.send));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }

    final call = fake.calls.lastWhere((c) => c.$1 == 'answer-question');
    expect(call.$2['questionId'], 'q1');
    expect(call.$2['answer'], {'selected': <String>[], 'custom': '今晚给我就行'});
    // 不能把回答当成普通消息发出去，否则服务端仍认为问题没答。
    expect(fake.calls.where((c) => c.$1 == 'send'), isEmpty);
  });

  testWidgets('a failed answer keeps the draft for another try', (t) async {
    final fake = FakeDsBotTransport(team: sampleTeam(working: false, questions: _question(allowCustom: true)));
    fake.handlers['answer-question'] = (_) => throw Exception('offline');
    await _pump(t, const BotChatPage(botId: 'm1'), transport: fake);

    await t.enterText(find.byType(TextField).first, '今晚给我就行');
    await t.pump();
    await t.tap(find.byIcon(AppIcons.send));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }

    expect(t.widget<TextField>(find.byType(TextField).first).controller!.text, '今晚给我就行');
  });

  testWidgets('a multi-select question sends every picked option once', (t) async {
    final fake = FakeDsBotTransport(
      team: sampleTeam(working: false, questions: _question(multiSelect: true)),
    );
    fake.handlers['answer-question'] = (_) => true;
    await _pump(t, const BotChatPage(botId: 'm1'), transport: fake);

    await t.tap(find.text('交给 Coder'));
    await t.pump();
    await t.tap(find.text('我自己写'));
    await t.pump();
    // 多选要点一下发送：给反悔的机会。
    await t.tap(find.text('发送'));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }

    final call = fake.calls.lastWhere((c) => c.$1 == 'answer-question');
    expect(call.$2['answer'], {
      'selected': ['交给 Coder', '我自己写'],
    });
  });

  testWidgets('a new room is created without a greeting and its mode is set', (t) async {
    final fake = FakeDsBotTransport();
    fake.handlers['create-room'] = (payload) => {'id': 'r9', 'name': '新群', 'members': payload['members']};
    fake.handlers['update-room'] = (_) => true;
    await _pump(
      t,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(onPressed: () => showNewRoomSheet(context), child: const Text('open')),
          ),
        ),
      ),
      transport: fake,
    );

    await t.tap(find.text('open'));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.tap(find.byKey(const ValueKey('member-b2')));
    await t.tap(find.byKey(const ValueKey('member-b3')));
    await t.pump();
    // 默认就是多模型讨论：全员依次回答。
    expect(find.byKey(const ValueKey('mode-everyone')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('room-create')));
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }

    final created = fake.calls.firstWhere((c) => c.$1 == 'create-room');
    expect(created.$2['greet'], isFalse);
    final updated = fake.calls.firstWhere((c) => c.$1 == 'update-room');
    expect(updated.$2['id'], 'r9');
    expect(updated.$2['mode'], 'everyone');
    expect(find.byType(RoomChatPage), findsOneWidget);
  });

  testWidgets('a room whose mode could not be set still opens, with a retry', (t) async {
    final fake = FakeDsBotTransport();
    // 房间已经在团队里（创建成功后刷新过），模式没设上。
    fake.handlers['create-room'] = (payload) => {'id': 'r1', 'name': '发布会', 'members': payload['members']};
    fake.handlers['update-room'] = (_) => throw Exception('no mode');
    await _pump(
      t,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(onPressed: () => showNewRoomSheet(context), child: const Text('open')),
          ),
        ),
      ),
      transport: fake,
    );

    await t.tap(find.text('open'));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.tap(find.byKey(const ValueKey('member-b2')));
    await t.tap(find.byKey(const ValueKey('member-b3')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('room-create')));
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }

    // 房间已经建好，不能丢：进去，并说清哪一步没成。
    expect(find.byType(RoomChatPage), findsOneWidget);
    expect(find.text('讨论室已创建，但协作方式没设上'), findsOneWidget);
    expect(find.byKey(const ValueKey('room-mode-retry')), findsOneWidget);
  });

  testWidgets('every member that is actually working shows its own state', (t) async {
    final team = sampleTeam(working: false);
    final now = botClock().millisecondsSinceEpoch;
    (team['work'] as Map<String, Object?>)['rooms'] = {
      'r1': [
        {'botId': 'b2', 'since': now - 3000, 'tool': 'bash', 'note': '写初稿'},
        {'botId': 'b3', 'since': now - 2000, 'tool': 'bash', 'note': '装依赖'},
      ],
    };
    final fake = FakeDsBotTransport(team: team);
    await _pump(t, const RoomChatPage(roomId: 'r1'), transport: fake);

    final writer = find.byKey(const ValueKey('member-state-b2'));
    final coder = find.byKey(const ValueKey('member-state-b3'));
    expect(writer, findsOneWidget);
    expect(coder, findsOneWidget);
    // 两个人同时在工作，都要露出自己的状态，而不是只挑一个、也不是标成空闲。
    String stateOf(Finder chip) => t
        .widgetList<Text>(find.descendant(of: chip, matching: find.byType(Text)))
        .last
        .data!;
    expect(stateOf(writer), isNot('空闲'));
    expect(stateOf(coder), isNot('空闲'));
  });
}
