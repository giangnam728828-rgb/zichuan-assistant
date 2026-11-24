// A phone's header and side panel: the title gets the header's width, the model moves
// beside the composer, and the panel shows the conversation's panes.

import 'package:dsh_app/plugins/native/native_model.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/quick_panel_state.dart';
import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/empty_state.dart' show chatClock;
import 'package:dsh_app/ui/chat/model_sheet.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart' show AttachButton;
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/session/conversation_overview.dart';
import 'package:dsh_app/ui/session/conversation_panel.dart';
import 'package:dsh_app/ui/session/conversation_panes.dart';
import 'package:dsh_app/ui/session/session_tab.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_destination.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../chat/support/sample_chat.dart';

ChatState _chat() => ChatState(
  items: <ChatItem>[
    user(1, '问题'),
    assistant(2, '回答', rowKey: 'm'),
  ],
  title: '修复登录重复提交的问题并补上回归测试',
  loading: false,
);

ChatHarness _harness({Map<String, ChatState>? states, List<Override> extra = const []}) =>
    ChatHarness(session: 's1', states: states ?? {'s1': _chat()}, extra: extra);

void main() {
  setUpAll(() async {
    await loadTestFonts();
    chatClock = () => DateTime(2026, 10, 23, 9);
  });

  group('the header', () {
    Future<void> screen(WidgetTester tester, Size size) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      mockClipboard(tester);
      await tester.pumpWidget(testApp(const ChatScreen(), overrides: _harness().overrides));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('on a phone the title and the model share the line', (tester) async {
      await screen(tester, const Size(390, 844));
      // B1：模型名是一枚无底色的文字按钮，手机上也有它的位置；标题在它左边。
      expect(find.byType(ModelChip), findsOneWidget);
      expect(find.descendant(of: find.byType(ChatHeader), matching: find.textContaining('V4 Pro')), findsOneWidget);
      final title = tester.getRect(find.byKey(const ValueKey('chat-title-pill')));
      final chip = tester.getRect(find.byType(ModelChip));
      expect(chip.left, greaterThanOrEqualTo(title.right), reason: '标题与模型名不重叠');
      // 「伙伴」收进了 ⋯（B1），顶栏不再有常驻的 chat-companion。
      expect(find.byKey(const ValueKey('chat-companion')), findsNothing);
      expect(find.byKey(const ValueKey('chat-more')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a phone: one fixed card, two rows, whatever the focus and the keyboard', (tester) async {
      await screen(tester, const Size(390, 844));
      // B2：输入栏常驻两行，圆角固定 float，不再随焦点 / 键盘变形。
      final card = find.ancestor(of: find.byType(TextField), matching: find.byType(GlassSurface)).first;
      BorderRadiusGeometry? corners() => tester.widget<GlassSurface>(card).borderRadius;
      final resting = corners();
      expect(resting, const BorderRadius.all(Radius.circular(AppShape.float)));
      expect(
        find.descendant(of: find.byType(Composer), matching: find.byType(BackdropFilter)),
        findsNothing,
        reason: '半透明实心底，不做真模糊',
      );
      final field = tester.getRect(find.byType(TextField));
      final plus = tester.getRect(find.byType(AttachButton));
      expect(field.bottom, lessThanOrEqualTo(plus.top), reason: '输入区在控制行上方');
      expect(field.left - tester.getRect(find.byType(Composer)).left, closeTo(14, 0.5), reason: '文字从 14 起');

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(corners(), resting);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(corners(), resting, reason: '键盘弹起只挪位置，不改形状');
      expect(tester.getSize(find.byType(Composer)).height, greaterThan(0));
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(corners(), resting);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a wide window keeps its chip', (tester) async {
      await screen(tester, const Size(900, 800));
      expect(find.byType(ModelChip), findsOneWidget);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      // B1 起模型只在顶栏；输入栏里没有第二枚模型键。
      expect(find.byKey(const ValueKey('composer-model')), findsNothing);
      expect(find.byKey(const ValueKey('composer-mode')), findsOneWidget);
    });
  });

  group('the composer\'s control row', () {
    // A ring taller than a key beside the send key, as the context ring can be.
    Future<void> composer(WidgetTester tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Composer(
                controller: TextEditingController(),
                connected: true,
                running: false,
                onSend: () {},
                onStop: () {},
                leading: AttachButton(onPressed: () {}),
                modePill: const SizedBox(key: Key('mode'), width: 100, height: 36),
                accessory: const SizedBox(key: Key('ring'), width: 50, height: 44),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('keys, the mode pill and the ring on one line, even gaps', (tester) async {
      await composer(tester);
      final card = tester.getRect(find.byType(Composer));
      final plus = tester.getRect(find.byType(AttachButton));
      final mode = tester.getRect(find.byKey(const Key('mode')));
      final ring = tester.getRect(find.byKey(const Key('ring')));
      final send = tester.getRect(
        find.ancestor(of: find.byIcon(AppIcons.send), matching: find.byType(AnimatedContainer)).first,
      );
      // ＋ 与胶囊在左，环与发送在右，边距都是 6。
      expect(plus.left - card.left, moreOrLessEquals(6, epsilon: 0.5));
      expect(mode.left - plus.right, moreOrLessEquals(6, epsilon: 0.5));
      expect(card.right - send.right, moreOrLessEquals(6, epsilon: 0.5));
      final tallest = [plus, mode, ring, send].reduce((a, b) => a.height >= b.height ? a : b);
      expect(card.bottom - tallest.bottom, moreOrLessEquals(6, epsilon: 0.5));
      for (final piece in [plus, mode, ring, send]) {
        expect(piece.center.dy, moreOrLessEquals(plus.center.dy, epsilon: 0.5), reason: 'one centre line');
      }
    });
  });

  testWidgets('glass over a web page does not blur what it cannot see', (tester) async {
    await tester.pumpWidget(
      testApp(
        const Column(
          children: [
            GlassSurface(tier: GlassTier.chrome, child: SizedBox.square(dimension: 40)),
            GlassOverNativeView(
              child: GlassSurface(
                tier: GlassTier.chrome,
                child: SizedBox.square(key: Key('web'), dimension: 40),
              ),
            ),
          ],
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget, reason: 'the first one only');
    expect(find.ancestor(of: find.byKey(const Key('web')), matching: find.byType(BackdropFilter)), findsNothing);
  });

  group('sliding glass', () {
    testWidgets('fades to glass when it lands and stops sampling when it moves', (tester) async {
      final motion = AnimationController(vsync: const TestVSync());
      addTearDown(motion.dispose);
      await tester.pumpWidget(
        testApp(
          SlidingGlass(
            motion: motion,
            tier: GlassTier.chrome, // 第 2 步后 sheet 故意不模糊，这里验证玻璃本身的采样逻辑
            borderRadius: BorderRadius.zero,
            child: const SizedBox.square(key: Key('inside'), dimension: 50),
          ),
        ),
      );
      double settled() => tester.widget<GlassSurface>(find.byType(GlassSurface)).settled!;
      final inside = tester.element(find.byKey(const Key('inside')));
      expect(settled(), 0);
      motion.value = 0.5;
      await tester.pump();
      expect(settled(), 0, reason: 'moving: no sampling');
      motion.value = 1;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(settled(), inExclusiveRange(0, 1), reason: 'landing fades, it does not cut');
      await tester.pumpAndSettle();
      expect(settled(), 1);
      motion.value = 0.9;
      await tester.pump();
      expect(settled(), 0, reason: 'moving: no sampling from the first frame');
      expect(tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled, isFalse);
      await tester.pump(const Duration(milliseconds: 40));
      expect(settled(), 0, reason: 'the moving panel stays opaque');
      await tester.pumpAndSettle();
      expect(settled(), 0);
      expect(tester.element(find.byKey(const Key('inside'))), same(inside), reason: 'content is not rebuilt');
    });
  });

  group('the panel', () {
    Future<List<DrawerDestination>> panel(WidgetTester tester, {ChatHarness? harness}) async {
      usePhoneView(tester);
      mockClipboard(tester);
      final opened = <DrawerDestination>[];
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: SizedBox(
              width: 334,
              child: ConversationPanel(sessionId: 's1', onOpen: opened.add),
            ),
          ),
          overrides: (harness ?? _harness()).overrides,
        ),
      );
      await tester.pump();
      return opened;
    }

    testWidgets('opens on 信息, with the whole title', (tester) async {
      await panel(tester);
      expect(find.byType(ConversationOverview), findsOneWidget);
      expect(find.text('修复登录重复提交的问题并补上回归测试'), findsOneWidget);
      expect(find.byKey(const ValueKey('overview-model')), findsOneWidget);
    });

    testWidgets('before the conversation has loaded, 信息 shows the title the list knows', (tester) async {
      final harness = _harness(states: {'s1': const ChatState(loading: true)});
      harness.sessions.listed = [
        SessionSummary(
          sessionId: 's1',
          updatedAt: DateTime(2026, 10, 23),
          running: false,
          blank: false,
          agentAvailable: false,
          projections: const SessionProjections(1, {'title': '列表里的标题'}),
        ),
      ];
      await panel(tester, harness: harness);
      await tester.pump();
      expect(find.text('列表里的标题'), findsOneWidget);
    });

    for (final (mode, opens) in [(SubagentMode.oneShot, false), (SubagentMode.continuable, true)]) {
      testWidgets('a ${mode.name} subagent ${opens ? 'can' : 'cannot'} change model from 信息', (tester) async {
        await panel(
          tester,
          harness: _harness(
            extra: [
              subagentParentProvider.overrideWith(
                (ref, id) => SubagentParent(
                  address: SubagentAddress(parentSessionId: 'p', childSessionId: id, mode: mode),
                  label: '子代理',
                  parentTitle: '上级',
                ),
              ),
            ],
          ),
        );
        await tester.tap(find.byKey(const ValueKey('overview-model')), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(find.text('思考深度'), opens ? findsOneWidget : findsNothing);
      });
    }

    for (final (turnsOneShot, picks) in [(false, 1), (true, 0)]) {
      testWidgets('a model picked after the conversation ${turnsOneShot ? 'turned out' : 'did not turn out'} '
          'one-shot: $picks set', (tester) async {
        var mode = SubagentMode.continuable;
        final harness = _harness(
          extra: [
            subagentParentProvider.overrideWith(
              (ref, id) => SubagentParent(
                address: SubagentAddress(parentSessionId: 'p', childSessionId: id, mode: mode),
                label: '子代理',
                parentTitle: '上级',
              ),
            ),
          ],
        );
        await panel(tester, harness: harness);
        await tester.tap(find.byKey(const ValueKey('overview-model')));
        await tester.pumpAndSettle();
        if (turnsOneShot) {
          mode = SubagentMode.oneShot;
          ProviderScope.containerOf(tester.element(find.byType(ConversationOverview)))
              .invalidate(subagentParentProvider);
          await tester.pump();
        }
        await tester.tap(find.text('V41 Flash'));
        await tester.pumpAndSettle();
        expect(harness.controllers['s1']!.models, hasLength(picks));
      });
    }

    testWidgets('a plugin\'s conversation action is a row on 信息, signed with its name', (tester) async {
      await panel(
        tester,
        harness: _harness(
          extra: [
            nativeSessionActionsProvider.overrideWithValue(const [
              NativeAction(package: 'toolbox', surface: NativeSurface.sessionActions, id: 'mark', label: '标记这段对话'),
            ]),
          ],
        ),
      );
      final row = find.byKey(const ValueKey('overview-action|toolbox|mark'));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('标记这段对话')), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('toolbox')), findsOneWidget);
    });

    testWidgets('a long action label at a large text size stays inside its row', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await panel(
        tester,
        harness: _harness(
          extra: [
            nativeSessionActionsProvider.overrideWithValue(const [
              NativeAction(
                package: 'toolbox',
                surface: NativeSurface.sessionActions,
                id: 'mark',
                label: '一二三四五六七八九十一二',
              ),
            ]),
          ],
        ),
      );
      final row = find.byKey(const ValueKey('overview-action|toolbox|mark'));
      final name = find.descendant(of: row, matching: find.text('toolbox'));
      expect(tester.getTopRight(name).dx, lessThanOrEqualTo(tester.getTopRight(row).dx));
    });

    testWidgets('a panel that asked only for its plugin page stays out of 插件', (tester) async {
      await panel(
        tester,
        harness: _harness(
          extra: [
            nativePanelsProvider.overrideWithValue(const [
              NativePanel(package: 'toolbox', id: 'about', title: '状态', placement: {DshGoPanel.pluginPage}),
            ]),
          ],
        ),
      );
      await tester.tap(find.text('插件').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pane-find-plugins')), findsOneWidget);
    });

    testWidgets('插件 is there with no plugins, and says where they come from', (tester) async {
      final opened = await panel(tester);
      await tester.tap(find.text('插件'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ConversationOverview), findsNothing);
      expect(find.text('这段对话还没有插件面板'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pane-find-plugins')));
      expect(opened, [DrawerDestination.plugins]);
    });

    Future<void> withPanels(WidgetTester tester, List<NativePanel> panels) async {
      usePhoneView(tester);
      mockClipboard(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: SizedBox(
              width: 334,
              child: ConversationPanel(sessionId: 's1', onOpen: (_) {}),
            ),
          ),
          overrides: [..._harness().overrides, nativePanelsProvider.overrideWithValue(panels)],
        ),
      );
      await tester.pump();
      await tester.tap(find.text('插件').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('several plugin panels get a row, whichever place they asked for', (tester) async {
      await withPanels(tester, const [
        NativePanel(package: 'a', id: 'chat', title: '工具', placement: {DshGoPanel.chatPanel}),
        NativePanel(package: 'a', id: 'tab', title: '统计', placement: {DshGoPanel.sessionTab}),
        NativePanel(package: 'b', id: 'all', title: '大全', placement: {DshGoPanel.features}),
      ]);
      expect(find.byKey(const ValueKey('pane-native|a|chat')), findsOneWidget);
      expect(find.byKey(const ValueKey('pane-native|a|tab')), findsOneWidget);
      expect(find.byKey(const ValueKey('pane-native|b|all')), findsOneWidget);
    });

    testWidgets('one plugin panel fills it, no row', (tester) async {
      await withPanels(tester, const [
        NativePanel(package: 'a', id: 'chat', title: '工具', placement: {DshGoPanel.chatPanel}),
      ]);
      expect(find.byKey(const ValueKey('pane-native|a|chat')), findsNothing);
      expect(find.text('这段对话还没有插件面板'), findsNothing);
    });

    testWidgets('every shortcut ticked on a narrow phone still fits', (tester) async {
      SharedPreferences.setMockInitialValues({
        QuickPanelController.itemsKey: [for (final d in DrawerDestination.values) d.name],
      });
      usePhoneView(tester);
      mockClipboard(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: SizedBox(
              width: 264,
              child: ConversationPanel(sessionId: 's1', onOpen: (_) {}),
            ),
          ),
          overrides: _harness().overrides,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    });

    testWidgets('its foot opens the shortcuts', (tester) async {
      final opened = await panel(tester);
      await tester.tap(find.byKey(const ValueKey('quick-panel-settings')));
      expect(opened, [DrawerDestination.settings]);
    });
  });

  test('every tab of the page is a registered pane', () {
    for (final tab in SessionTab.values) {
      expect(ConversationPane.ofTab(tab).tab, tab);
    }
  });
}
