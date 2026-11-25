// Goldens (light + dark) of the Bot pages: the home with unread and working
// states, the install card, a Bot chat with a question card, a group chat
// with the @ picker open, both details pages, the new Bot form and the new
// group sheet. Regenerate with
// `flutter test --update-goldens test/bots/bots_golden_test.dart`.

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/ui/bots/bot_chat_page.dart';
import 'package:dsh_app/ui/bots/bot_details_page.dart';
import 'package:dsh_app/ui/bots/bots_page.dart';
import 'package:dsh_app/ui/bots/new_bot_page.dart';
import 'package:dsh_app/ui/bots/new_room_sheet.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/bots/room_details_page.dart';
import 'package:dsh_app/ui/chat/model_sheet.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show StaticRuntime;
import '../shell/golden_harness.dart';
import 'support.dart';

/// Renders [home] at phone width and [height] in light and dark.
void goldenBots(
  String name,
  Widget Function() home, {
  required FakeDsBotTransport Function() transport,
  Future<void> Function(WidgetTester tester, FakeDsBotTransport transport)? before,
  double height = 844,
  List<Override> extra = const [],
}) {
  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('$name ($mode)', (tester) async {
      useBotGoldenClock();
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(loadGoldenFonts);
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = Size(390 * 2, height * 2);
      tester.view.padding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
      tester.view.viewPadding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
      addTearDown(tester.view.reset);
      final fake = transport();
      await tester.pumpWidget(
        goldenApp(home: home(), brightness: brightness, overrides: [...dsBotOverrides(fake), ...extra]),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The photo decodes off the frame clock.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      // 头像的毛发也在后台算：等它落地，图才不会时对时错。
      await settleBotAvatars(tester);
      await tester.pump(const Duration(milliseconds: 300));
      if (before != null) await before(tester, fake);
      await tester.pump(const Duration(milliseconds: 600));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${name}_$mode.png'));
    });
  }
}

Map<String, Object?> notice(int seq, String kind, String text, {String? roomId}) => {
  'seq': seq,
  'kind': kind,
  'botId': 'b2',
  'name': 'Writer',
  'roomId': ?roomId,
  'title': roomId == null ? null : '发布会',
  'text': text,
  // Today at a fixed clock time, so the row's time reads the same on every run.
  'time': todayAt(9, 40 + seq).millisecondsSinceEpoch,
};

void main() {
  goldenBots(
    'bots_home',
    () => const BotsPage(),
    transport: FakeDsBotTransport.new,
    before: (tester, fake) async {
      fake
        ..emit('notice', notice(1, 'message', '海报文案我今晚给出，先发你一版提纲。'))
        ..emit('notice', notice(2, 'message', '提纲在 docs/poster.md'))
        ..emit('notice', notice(3, 'group', '初稿写好了，放在 docs/launch.md', roomId: 'r1'));
      await tester.pump(const Duration(milliseconds: 100));
    },
  );

  goldenBots(
    'bots_home_install',
    () => const BotsPage(),
    transport: () => FakeDsBotTransport()..handlers['hello'] = (_) => throw const DshHttpException(404, 'missing'),
  );

  goldenBots(
    'bot_chat',
    () => const BotChatPage(botId: 'm1'),
    transport: () => FakeDsBotTransport(
      team: sampleTeam(
        working: false,
        questions: {
          'm1c': {
            'id': 'q1',
            'question': '演示脚本交给 Coder 吗？',
            'options': [
              {'label': '交给 Coder'},
              {'label': '我自己写'},
            ],
          },
        },
      ),
    ),
  );

  // 有待答问题时，回答直接写在同一个输入框里。
  goldenBots(
    'bot_chat_answer',
    () => const BotChatPage(botId: 'm1'),
    transport: () => FakeDsBotTransport(
      team: sampleTeam(
        working: false,
        questions: {
          'm1c': {
            'id': 'q1',
            'question': '演示脚本交给 Coder 吗？',
            'options': [
              {'label': '交给 Coder'},
              {'label': '我自己写'},
            ],
            'allowCustom': true,
          },
        },
      ),
    ),
    before: (tester, fake) async {
      await tester.enterText(find.byType(TextField), '先给 Coder 一版，周五再看');
      await tester.pump(const Duration(milliseconds: 300));
    },
  );

  // 多模型讨论室：每条消息都带厂商标记，成员条各自显示真实状态。
  goldenBots(
    'room_chat_multi',
    () => const RoomChatPage(roomId: 'r1'),
    transport: () => FakeDsBotTransport(team: multiModelTeam())..roomSpeaking = 'b2',
  );

  // 讨论室暂停：顶栏说清状态，输入框上方给出继续。
  goldenBots(
    'room_chat_paused',
    () => const RoomChatPage(roomId: 'r1'),
    transport: () => FakeDsBotTransport(team: pausedTeam()),
  );

  // 模型选择器：渠道与每张卡都带厂商 Logo。
  goldenBots(
    'model_sheet',
    () => const _ModelSheetHost(),
    transport: FakeDsBotTransport.new,
    extra: [
      modelCatalogProvider.overrideWith((_) async => modelCatalog()),
      // 模型面板会读到本机引擎的状态；测试里没有原生侧，用静态替身。
      localRuntimeProvider.overrideWith(StaticRuntime.new),
    ],
    before: (tester, fake) async {
      await tester.tap(find.text('open'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // 换一个渠道：卡片上的厂商标记跟着换。
      await tester.tap(find.text('OpenAI'));
      await tester.pump(const Duration(milliseconds: 400));
    },
  );

  goldenBots(
    'room_chat_mention',
    () => const RoomChatPage(roomId: 'r1'),
    transport: () => FakeDsBotTransport()
      ..roomRunning = true
      ..roomSpeaking = 'b3',
    before: (tester, fake) async {
      await tester.enterText(find.byType(TextField), '@');
      await tester.pump(const Duration(milliseconds: 300));
    },
  );

  goldenBots('bot_details', () => const BotDetailsPage(botId: 'm1'), transport: FakeDsBotTransport.new, height: 1500);

  goldenBots(
    'room_details',
    () => const RoomDetailsPage(roomId: 'r1'),
    transport: FakeDsBotTransport.new,
    height: 1300,
  );

  goldenBots('new_bot', () => const NewBotPage(), transport: FakeDsBotTransport.new, height: 980);

  goldenBots(
    'new_room_sheet',
    () => const _SheetHost(),
    transport: FakeDsBotTransport.new,
    before: (tester, fake) async {
      await tester.tap(find.text('open'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('member-m1')));
      await tester.tap(find.byKey(const ValueKey('member-b2')));
      await tester.pump(const Duration(milliseconds: 300));
    },
  );
}

/// A page with a button that opens the new group sheet.
class _SheetHost extends StatelessWidget {
  const _SheetHost();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(onPressed: () => showNewRoomSheet(context), child: const Text('open')),
    ),
  );
}

/// A page with a button that opens the model sheet.
class _ModelSheetHost extends StatelessWidget {
  const _ModelSheetHost();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => showModelSheet(context, current: null, onSelected: (_) {}),
        child: const Text('open'),
      ),
    ),
  );
}

/// Writer 用 OpenAI、Coder 用 Anthropic：讨论室里每条消息都能看出是谁、
/// 哪个模型在说，两个成员同时在跑。
Map<String, Object?> multiModelTeam() {
  final team = sampleTeam(working: false);
  final bots = (team['bots']! as List).cast<Map<String, Object?>>();
  bots[1]['model'] = 'openai/gpt-5.2';
  bots[2]['model'] = 'anthropic/claude-4.6';
  team['models'] = [
    {'ref': 'deepseek/deepseek-v4-pro', 'name': 'DeepSeek-V4-Pro', 'providerName': 'DeepSeek'},
    {'ref': 'openai/gpt-5.2', 'name': 'GPT-5.2', 'providerName': 'OpenAI'},
    {'ref': 'anthropic/claude-4.6', 'name': 'Claude 4.6', 'providerName': 'Anthropic'},
  ];
  final now = todayAt(15, 12).millisecondsSinceEpoch;
  team['activity'] = {'b2': 'tool', 'b3': 'tool'};
  (team['work']! as Map<String, Object?>)['rooms'] = {
    'r1': [
      {'botId': 'b2', 'since': now, 'tool': 'write'},
      {'botId': 'b3', 'since': now, 'tool': 'bash'},
    ],
  };
  final room = ((team['rooms']! as List).cast<Map<String, Object?>>()).first;
  room['mode'] = 'everyone';
  return team;
}

/// 一轮讨论被叫停：房间有暂停的调用，界面上给出继续。
Map<String, Object?> pausedTeam() {
  final team = sampleTeam(working: false);
  final room = ((team['rooms']! as List).cast<Map<String, Object?>>()).first;
  room['mode'] = 'everyone';
  room['paused'] = [
    {'id': 'call-1'},
  ];
  return team;
}

/// Three providers, so the channel bar and every card show their own logo.
ModelCatalog modelCatalog() => const ModelCatalog(
  defaultSelection: null,
  groups: [
    ProviderGroup('deepseek', 'DeepSeek', [
      ModelInfo(provider: 'deepseek', id: 'deepseek-v4-pro', name: 'DeepSeek-V4-Pro', description: '更强的推理与编码'),
      ModelInfo(provider: 'deepseek', id: 'deepseek-v4-flash', name: 'DeepSeek-V4-Flash', description: '更快、更省'),
    ]),
    ProviderGroup('openai', 'OpenAI', [
      ModelInfo(provider: 'openai', id: 'gpt-5.2', name: 'GPT-5.2', description: '通用最强'),
      ModelInfo(provider: 'openai', id: 'gpt-5.2-mini', name: 'GPT-5.2 mini', description: '轻量'),
    ]),
    ProviderGroup('anthropic', 'Anthropic', [
      ModelInfo(provider: 'anthropic', id: 'claude-4.6', name: 'Claude 4.6', description: '长文与代码'),
    ]),
  ],
  routableProviders: ['deepseek', 'openai', 'anthropic'],
  failures: [],
);
