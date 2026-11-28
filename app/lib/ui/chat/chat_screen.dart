// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
// Local changes: rewritten for dsh_client / Riverpod state; keeps the
// floating-composer height sync and the "content scrolls under glass" layout.

import 'dart:async';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/app_mode_state.dart' show AppMode;
import '../modes/mode_switch.dart';
import '../../notify/chat_alerts.dart' show approvalText, questionText;
import '../../runtime/local_footprint.dart' show RuntimeMissing;
import '../../runtime/runtime_bridge.dart' show RuntimePhase;
import '../../runtime/runtime_state.dart' show localRuntimeProvider;
import '../../speech/read_aloud.dart';
import '../../speech/voice_cloud.dart';
import '../../state/android_features.dart';
import '../../state/account_state.dart';
import '../speech/voice_call_page.dart';
import '../../state/streaming_asr_state.dart';
import '../../state/streaming_pcm_state.dart';
import '../../voice/live_words.dart';
import '../../voice/live_words_model.dart';
import '../../voice/streaming_pcm.dart';
import '../../state/agents_state.dart' show subagentParentProvider;
import '../../state/attachments.dart';
import '../../state/balance_state.dart';
import '../../state/chat_error_text.dart';
import '../../state/chat_state.dart';
import '../../state/conversation_mode_state.dart';
import '../../state/commands_state.dart';
import '../../state/compose_inbox.dart';
import '../../state/composer_insert.dart';
import '../../state/phone_skill_use.dart';
import '../../state/composer_quote.dart';
import '../../state/connection_state.dart';
import '../../state/draft_store.dart';
import '../../state/drawer_view_state.dart';
import '../../state/engine_control.dart';
import '../../state/engine_settings_state.dart' show engineSettingsProvider;
import '../../state/features_state.dart' show agentPresetsProvider, permissionStateProvider;
import '../../state/hosts_state.dart' show HostKind, HostRef, activeHostProvider;
import '../../state/media_generation.dart';
import '../../state/mention_state.dart';
import '../../state/models_state.dart';
import '../../state/new_chat_modes.dart';
import '../../state/session_search.dart' show folderLabel;
import '../../state/safe_mode_state.dart';
import '../../state/session_modes.dart';
import '../../state/sessions_state.dart';
import '../../state/settings_state.dart';
import '../../state/usage_state.dart';
import '../../state/voice_state.dart';
import '../../state/voice_model_state.dart';
import '../../state/voice_settings.dart';
import '../../state/workspaces_state.dart' show selectedWorkspaceProvider, workspaceTitle;
import '../../usage/usage_stats.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/fluid_bits.dart';
import '../common/ui_trace.dart';
import '../common/sheet_title_bar.dart';
import '../common/smooth_size.dart';
import '../common/status_dot.dart';
import '../agents/header_agents.dart' show headerPieceGap;
import '../features/session_export_page.dart';
import '../onboarding/local_install.dart';
import '../pets/pet_perch.dart';
import '../pets/pet_stage.dart';
import '../plugins/native/composer_strip.dart' show ComposerStripSlot;
import '../plugins/native/native_composer_bar.dart';
import '../plugins/native/native_taps.dart' show NativeComposerHost, NativeComposerScope, runNativeAction;
import '../plugins/seats/plugin_overlay_layer.dart';
import '../safe_mode/engine_failure_card.dart';
import '../safe_mode/safe_mode_banner.dart';
import '../session/session_detail_page.dart';
import '../settings/media_settings_page.dart' show MediaSettingsPage, showMediaInstallSheet, showMediaUnavailableSheet;
import '../settings/settings_widgets.dart' show SettingsTile;
import '../shell/adaptive/adaptive_layout.dart' show WindowClass;
import '../shell/root_tab.dart';
import '../shell/shell_insets.dart';
import '../shell/drawer/folder_sheets.dart';
import '../theme/app_icons.dart';
import '../theme/edge_fade.dart';
import '../theme/theme.dart';
import '../wallpaper/wallpaper_backdrop.dart';
import '../workspace/workspace_switcher.dart' show showWorkspaceSheet;
import '../workspace/workspaces_page.dart';
import 'balance_widgets.dart';
import 'chat_header.dart';
import 'chat_list.dart';
import 'composer.dart';
import 'conversation_mode_switcher.dart';
import 'composer_toast.dart';
import 'shared/conversation_mode_host.dart';
import 'dock/chat_dock.dart';
import 'dock/dock_stack.dart';
import 'empty_state.dart';
import 'new_chat_options.dart';
import 'media/generate_mode.dart';
import 'media/generate_sheet.dart';
import 'media/media_card.dart' show MediaCardActions, mediaItemBytes;
import 'media/media_format.dart' show chatTitleShown;
import 'mention/mention_controller.dart';
import 'mention/mention_picker.dart';
import 'mention/mention_text_controller.dart';
import 'model_brand_mark.dart';
import 'model_sheet.dart';
import 'slash_palette.dart';
import 'trajectory_sheet.dart';
import 'usage_sheet.dart';
import 'voice/voice_controller.dart';
import 'widgets/activity_strip.dart';
import 'widgets/attachments.dart';
import 'widgets/composer_mode_pill.dart';
import 'widgets/permission_pill.dart';
import 'widgets/notice_row.dart';
import 'widgets/plus_panel.dart';
import 'widgets/quote_chip.dart';
import 'widgets/read_only_bar.dart';
import 'widgets/unknown_results_banner.dart';

/// 聊天页:玻璃顶栏 + 消息列表 + 玻璃输入条。
///
/// 读 [currentSessionProvider];为 null 时是"新对话"空状态,第一次发送时
/// 才建会话(create → select → send)。
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, this.onOpenDrawer, this.backdrop = true});

  /// Opens the sessions drawer (the shell owns the drawer).
  final VoidCallback? onOpenDrawer;

  /// False when the shell already paints the page backdrop.
  final bool backdrop;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> with WidgetsBindingObserver {
  final _toTop = defaultTargetPlatform == TargetPlatform.iOS ? StatusBarTop() : null;

  /// B3：小技巧不再每次都占一行——三分之一的空状态里才给一条，其余时候
  /// 这一行根本不出现。进页面时定一次，之后不再翻。
  late final List<String> _emptyTips = rollEmptyTips();

  void Function()? _endInteraction;
  bool _routeCurrent = true;
  ModalRoute<Object?>? _interactionRoute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _keyboardInset ??= View.of(context).viewInsets.bottom;
    _interactionRoute = ModalRoute.of<Object?>(context);
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (current == _routeCurrent) return;
    _routeCurrent = current;
    if (current) {
      _scheduleInteraction();
    } else {
      _endInteraction?.call();
      _endInteraction = null;
    }
  }

  void _scheduleInteraction() {
    _endInteraction?.call();
    _endInteraction = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_routeCurrent) return;
      _endInteraction?.call();
      final sessionId = ref.read(currentSessionProvider);
      if (sessionId == null) return;
      _endInteraction = ref.read(chatProvider(sessionId).notifier).beginInteraction(() {
        final lifecycle = WidgetsBinding.instance.lifecycleState;
        return mounted &&
            (_interactionRoute?.isCurrent ?? true) &&
            ref.read(currentSessionProvider) == sessionId &&
            (lifecycle == null || lifecycle == AppLifecycleState.resumed);
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _scheduleInteraction();
  }

  @override
  void didChangeMetrics() {
    final inset = View.of(context).viewInsets.bottom;
    final hidden = (_keyboardInset ?? 0) > 0 && inset == 0;
    _keyboardInset = inset;
    if (hidden && (_interactionRoute?.isCurrent ?? true)) _dismissSlashPalette();
  }

  final _input = MentionTextController();

  /// The composer as plugin controls and ui.json capsules see it.
  late final _nativeHost = _ChatComposerHost(this);

  /// The `@` picker over [_input].
  late final _mentions = MentionPickerController(
    input: _input,
    source: () => ref.read(mentionSourceProvider),
    sessionId: () => ref.read(currentSessionProvider),
    localSessions: () => ref.read(sessionsProvider.future),
    recents: ref.read(mentionRecentsProvider),
  );

  /// Dictation into [_input]. Made in [initState], not on first use: a
  /// read-only conversation never builds the composer, and [dispose] must not
  /// create it from an unmounted ref.
  late final VoiceInputController _voice;

  /// Where [_voice] says it is on, for what waits for a quiet moment.
  late final VoiceInputActiveController _voiceFlag;
  final _focus = FocusNode();

  // Keep this slash draft closed until it leaves slash input or starts again at "/".
  String? _dismissedSlashText;
  double? _keyboardInset;
  final _composerGroup = Object();

  /// 「新对话」按钮的锚点：类型选择面板据此贴在按钮旁边弹出。
  final _newChatAnchor = GlobalKey(debugLabel: 'chat-new-chat-anchor');

  /// 底部渐隐恒为 0：消息区已在输入栏上沿结束（见 [_ChatLayout]）。
  final _zeroFade = ValueNotifier<double>(0);

  void _resetSlashDismissal() {
    final dismissed = _dismissedSlashText;
    if (dismissed == null) return;
    final text = _input.text;
    final newSlash = text.trim() == '/' && dismissed.trim() != '/';
    _dismissedSlashText = parseSlashInput(text) == null || newSlash ? null : text;
  }

  void _dismissSlashPalette() {
    if (_dismissedSlashText != null || parseSlashInput(_input.text) == null) return;
    setState(() => _dismissedSlashText = _input.text);
  }

  PaletteContent? _slashContent(List<SlashCommand> commands) => _dismissedSlashText != null
      ? null
      : PaletteContent.of(
          commands,
          _input.text,
          caret: _input.selection.isCollapsed ? _input.selection.extentOffset : -1,
        );

  KeyEventResult _composerKey(FocusNode node, KeyEvent event) {
    final mention = _mentions.handleKey(node, event);
    if (mention != KeyEventResult.ignored) return mention;
    final composing = _input.value.composing;
    if (composing.isValid && !composing.isCollapsed) return KeyEventResult.ignored;
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape && _slashContent(_commands) != null) {
      _dismissSlashPalette();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 底色遮罩的实心高度:页面布局排好输入条时写入(见 [_ChatLayout])。
  final _veilHeight = ValueNotifier<double>(0);

  /// 议会/团队视图 → 统一顶栏的信息通道（v4）。
  final _collabHeader = ValueNotifier<CollabHeaderInfo?>(null);

  /// How far the list has scrolled under the header (0..1), for its fade.
  final _scrolledUnder = ValueNotifier<double>(0);

  /// Picked in the ＋ menu, not sent yet.
  List<DraftAttachment> _drafts = const [];

  /// Only this creation may own the composer's busy state.
  Object? _creating;

  /// Only one apply of a session's owed new-chat setup at a time.
  Object? _applyingSetup;

  /// A page/client change retires an intent even when its draft key returns.
  Object _draftScope = Object();

  /// Only this wait may resume a send or clear the composer's busy state.
  Object? _syncWait;

  /// How the last turn ended, for the header's live region.
  String? _spoken;

  /// 每个对话一份草稿:换对话时输入条换成那个对话的字和附件。
  late final DraftStore _draftStore;

  /// The open conversation's id, or `new`.
  late String _draftKey;

  PreparedPhoneSkill? _preparedPhoneSkill;
  PreparedPhoneSkill? _sendingPhoneSkill;
  bool get _phoneSkillSending => _sendingPhoneSkill != null;

  void _dropPreparedPhoneSkill() {
    final prepared = _preparedPhoneSkill;
    _preparedPhoneSkill = null;
    // If send is waiting, its final source predicate will reject. If it already
    // dispatched, only its own completion can report what was accepted.
    if (prepared != null && !identical(prepared, _sendingPhoneSkill)) unawaited(prepared.discard());
  }

  bool _phoneSkillCurrent(PreparedPhoneSkill prepared) =>
      mounted &&
      identical(_preparedPhoneSkill, prepared) &&
      prepared.origin.current(ProviderScope.containerOf(context, listen: false));

  Future<void> _sendPhoneSkill() async {
    final prepared = _preparedPhoneSkill;
    if (prepared == null || _phoneSkillSending) return;
    if (!_phoneSkillCurrent(prepared)) {
      setState(_dropPreparedPhoneSkill);
      _composerToast(appL10n.phoneSkillReplaySourceChanged);
      return;
    }
    setState(() => _sendingPhoneSkill = prepared);
    final chat = ref.read(chatProvider(prepared.origin.sessionId).notifier);
    bool ok = false;
    try {
      // No ordinary input, quote or attachments are consumed. Queue rather than
      // steer an existing turn; the final predicate runs beside client.prompt.
      ok = await chat.send(prepared.text, mode: SendMode.queue, deliveryAllowed: () => _phoneSkillCurrent(prepared));
    } finally {
      if (!ok) unawaited(prepared.discard());
      if (mounted) {
        final showReceipt = _phoneSkillCurrent(prepared);
        setState(() {
          if (identical(_preparedPhoneSkill, prepared)) _preparedPhoneSkill = null;
          if (identical(_sendingPhoneSkill, prepared)) _sendingPhoneSkill = null;
        });
        if (showReceipt) _composerToast(ok ? appL10n.phoneSkillReplayQueued : appL10n.phoneSkillReplaySendUncertain);
      }
    }
  }

  void _saveDraft() => _draftStore.save(_draftKey, _input.text, _drafts);

  /// Attachments first: setting the text saves both.
  void _showDraft(ChatDraft? draft) {
    _drafts = draft?.attachments ?? const [];
    final text = draft?.text ?? '';
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _reportVoice() => _voiceFlag.set(_voice.active);

  void _switchDraft(String? sessionId) {
    final key = sessionId ?? 'new';
    if (key == _draftKey) return;
    _dropPreparedPhoneSkill();
    _draftScope = Object();
    _creating = null;
    _syncWait = null;
    _composerToastWait?.cancel();
    if (_voice.active) unawaited(_voice.cancel());
    _mentions.dismiss();
    _dismissedSlashText = null;
    _saveDraft();
    _draftKey = key;
    _spoken = null;
    _editing = false;
    setState(() => _showDraft(ref.read(draftStoreProvider).drafts[key]));
  }

  /// 没有会话时的错误(建会话失败),会话内的错误走 ChatState.error。
  String? _localError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleInteraction();
    ref.listenManual(currentSessionProvider, (_, _) => _scheduleInteraction());
    _voice = VoiceInputController(
      input: _input,
      bridge: ref.read(voiceBridgeProvider),
      mode: () async {
        final mode = await ref.read(voiceSettingsProvider.notifier).ready();
        return mounted && ref.read(harmonyLocalVoiceProvider) ? voiceModeOnHarmonyLocal(mode) : mode;
      },
      harmony: () => ref.read(operatingSystemProvider) == 'ohos',
      cloud: (mode) => ref.read(voiceCloudProvider)(mode),
      cloudLikely: () => ref.read(voiceCloudLikelyProvider)(),
      signedIn: () => ref.read(accountProvider).signedIn,
      liveWords: (onWords) async {
        final pcm = ref.read(streamingPcmCaptureProvider);
        final asr = ref.read(streamingAsrProvider);
        try {
          final chosen = await liveWordsModel(ref);
          if (chosen == null || !mounted) return null;
          final live = LiveWords(pcm, asr, chosen.model, StreamingPcmSource.dictation, onWords, trial: chosen.trial);
          await live.start();
          return live;
        } on Object {
          // Without live words dictation works as before.
          return null;
        }
      },
      // The voice model lives in the on-device engine: it counts for that host only.
      modelReady: () =>
          mounted &&
          (ref.read(activeConnectionProvider).value?.isLocal ?? false) &&
          ref.read(voiceModelProvider).status == VoiceModelStatus.ready,
      // The capability probe is async and can finish after this page is gone.
      client: () => mounted ? ref.read(activeConnectionProvider).value?.client : null,
      inputOwner: () => mounted ? ref.read(activeHostProvider) : null,
      onRecognized: () {
        if (mounted) ref.read(usageStatsProvider.notifier).count(UsageCount.voice);
      },
    );
    // A download or deletion changes capabilities without replacing the host.
    ref.listenManual(voiceModelProvider.select((s) => s.status == VoiceModelStatus.ready), (_, _) {
      if (mounted && (ref.read(activeConnectionProvider).value?.isLocal ?? false)) {
        unawaited(_voice.refreshAfterModelChange());
      }
    });
    _voiceFlag = ref.read(voiceInputActiveProvider.notifier);
    _voice.addListener(_reportVoice);
    _draftKey = ref.read(currentSessionProvider) ?? 'new';
    _draftStore = ref.read(draftStoreProvider.notifier);
    // Start reading what earlier sessions still owe before the first send.
    ref.read(owedSetupsProvider.notifier);
    _showDraft(ref.read(draftStoreProvider).drafts[_draftKey]);
    _input.addListener(_resetSlashDismissal);
    _input.addListener(_saveDraft);
    ref.listenManual(currentSessionProvider, (_, next) {
      // Another conversation: nothing of this one is read aloud any more.
      ref.read(readAloudProvider.notifier).stop();
      _switchDraft(next);
    });
    ref.listenManual(activeConnectionProvider.select((c) => c.value?.client), (_, _) {
      _dropPreparedPhoneSkill();
      _draftScope = Object();
      if (_creating != null || _syncWait != null) {
        setState(() {
          _creating = null;
          _syncWait = null;
        });
      }
    });
    // Saved drafts arrive a moment after launch.
    ref.listenManual(draftStoreProvider.select((s) => s.loaded), (_, loaded) {
      if (loaded && _input.text.isEmpty) {
        setState(() => _showDraft(ref.read(draftStoreProvider).drafts[_draftKey]));
      }
    });
    // Opening the chat counts as "open" for the balance (throttled to 1/min).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(balanceProvider.notifier).refresh();
      // Asked for from another page before this one was built.
      if (mounted && ref.read(repairDraftProvider) != null) _takeRepairDraft();
      if (mounted && ref.read(composerInsertProvider) != null) {
        _takeComposerInsert();
      }
      if (mounted && ref.read(readyComposeProvider) != null) _takeCompose();
    });
  }

  void _takeRepairDraft() {
    final text = ref.read(repairDraftProvider.notifier).take();
    if (text == null || !mounted) return;
    ref.read(currentSessionProvider.notifier).select(null);
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _focus.requestFocus();
  }

  /// Skills handed over from 技能: `/name` alone is then a message, never a
  /// command whose name merely starts the same way (a new chat has no skill
  /// list to tell them apart).
  final _handedSkills = <String>{};

  /// 技能 › 「在对话里用」/「新对话里用」: the word into that conversation's
  /// composer (null: a new one) at the caret, focused, confirmed above it.
  void _takeComposerInsert() {
    final insert = ref.read(composerInsertProvider.notifier).take();
    if (insert == null || !mounted) return;
    if (insert.phoneSkill case final prepared?) {
      if (!prepared.origin.current(ProviderScope.containerOf(context, listen: false)) ||
          insert.sessionId != prepared.origin.sessionId) {
        unawaited(prepared.discard());
        _composerToast(appL10n.phoneSkillReplaySourceChanged);
        return;
      }
      setState(() {
        _dropPreparedPhoneSkill();
        _preparedPhoneSkill = prepared;
      });
      return;
    }
    if (ref.read(currentSessionProvider) != insert.sessionId) {
      ref.read(currentSessionProvider.notifier).select(insert.sessionId);
    }
    _switchDraft(insert.sessionId);
    if (insert.skill case final name?) _handedSkills.add(name);
    _input.value = insertComposerToken(_input.value, insert.token);
    _focus.requestFocus();
    _composerToast(composerInsertedText);
  }

  /// A toast about the composer (a fork's 「返回原对话」, an inserted skill): above
  /// it, once the frame has laid out whatever just went into it (编辑后重发's text)
  /// and the capsule has finished growing to it.
  void _composerToast(String message, {String? actionLabel, VoidCallback? onAction}) {
    void show() {
      if (!mounted) return;
      showComposerToast(
        context,
        message,
        composerHeight: _veilHeight.value,
        actionLabel: actionLabel,
        onAction: onAction,
      );
    }

    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted) return;
        _composerToastWait?.cancel();
        // A composer that has just been focused is still opening.
        final opening = _composerOpens(context) && _focus.hasFocus;
        _composerToastWait = Timer(AppMotion.of(context, opening ? AppMotion.emphasized : AppMotion.quick), show);
      })
      ..ensureVisualUpdate();
  }

  Timer? _composerToastWait;

  /// 手机上 (可能) 正在弹键盘：toast 因此多等一拍再出现。输入栏自 B2 起
  /// 不论宽窄都是两行，这里只按窗口判断键盘会不会来。
  bool _composerOpens(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width < WindowClass.mediumMin && size.height >= WindowClass.compactHeight;
  }

  @override
  void dispose() {
    _toTop?.dispose();
    _dropPreparedPhoneSkill();
    WidgetsBinding.instance.removeObserver(this);
    _endInteraction?.call();
    _endInteraction = null;
    _draftScope = Object();
    _creating = null;
    _syncWait = null;
    _composerToastWait?.cancel();
    _input.removeListener(_resetSlashDismissal);
    _input.removeListener(_saveDraft);
    _mentions.dispose();
    _voice.removeListener(_reportVoice);
    _voice.dispose();
    // The page is gone, and its dictation with it.
    final flag = _voiceFlag;
    scheduleMicrotask(() => flag.set(false));
    _input.dispose();
    _focus.dispose();
    _scrolledUnder.dispose();
    _veilHeight.dispose();
    _zeroFade.dispose();
    _collabHeader.dispose();
    super.dispose();
  }

  /// The open session, or a new one (create → select → apply the model picked
  /// on the new-chat screen). Null when it could not be created.
  /// [onCreated]: the session this call made, once it is selected, even when its
  /// picks then fail to apply and null comes back.
  Future<String?> _ensureSession({required bool Function() isCurrent, void Function(String id)? onCreated}) async {
    if (!isCurrent()) return null;
    final current = ref.read(currentSessionProvider);
    if (current != null) {
      // A session made on the new-chat screen may still owe its picks (a
      // failed apply, kept across screens and restarts): settle them first.
      // (The saved ones are read when this screen starts, long before a send.)
      final host = ref.read(activeHostProvider);
      final owed = ref.read(owedSetupsProvider.notifier).of(host, current);
      if (owed != null && !await _applyOwedSetup(host, current, owed, isCurrent)) return null;
      return current;
    }
    if (_creating != null) return null;
    final host = ref.read(activeHostProvider);
    final pendingFolder = ref.read(pendingSessionFolderProvider);
    final attempt = Object();
    bool ownsCreation() => identical(_creating, attempt) && isCurrent();
    setState(() {
      _creating = attempt;
      _localError = null;
    });
    try {
      final String sessionId;
      try {
        sessionId = await ref.read(sessionsProvider.notifier).create();
      } catch (e) {
        if (ownsCreation()) {
          setState(() => _localError = chatErrorText(e, action: appL10n.chatCreateFailed));
        }
        return null;
      }
      // A completed create may outlive its page, client or new-chat draft.
      // Check before any selection, migration, deletion or model side effect.
      if (!ownsCreation() || _draftKey != 'new' || ref.read(currentSessionProvider) != null) return null;
      if (ref.read(pendingSessionFolderProvider) != pendingFolder) return null;
      if (pendingFolder != null) {
        await ref
            .read(drawerViewProvider.notifier)
            .moveSessions(
              [sessionId],
              pendingFolder,
              isCurrent: () => ownsCreation() && ref.read(pendingSessionFolderProvider) == pendingFolder,
            );
        if (!ownsCreation() || ref.read(pendingSessionFolderProvider) != pendingFolder) return null;
      }
      final pendingModes = ref.read(pendingNewChatModesProvider);
      // What the chips show is what the session gets: a pick the Host no
      // longer offers falls back to the default, a hidden Host default to
      // the offered one.
      final setup = OwedSetup(
        preset: newChatPresetToApply(ref.read(agentPresetsProvider).value, pendingModes.preset),
        permission: newChatPermissionToApply(ref.read(permissionStateProvider(null)).value, pendingModes.permission),
        model: ref.read(pendingModelProvider),
      );
      _draftKey = sessionId;
      _saveDraft();
      if (!ownsCreation() || _draftKey != sessionId) return null;
      ref.read(currentSessionProvider.notifier).select(sessionId);
      if (!ownsCreation() || _draftKey != sessionId || ref.read(currentSessionProvider) != sessionId) return null;
      onCreated?.call(sessionId);
      ref.read(composerQuoteProvider.notifier).move('new', sessionId);
      ref.read(generateModeProvider.notifier).move('new', sessionId);
      if (!ownsCreation() || _draftKey != sessionId) return null;
      _draftStore.clear('new');
      if (!setup.isEmpty) {
        if (!ownsCreation()) return null;
        // The picks move to the session: owed until the Host confirms each.
        ref.read(pendingNewChatModesProvider.notifier).clear();
        ref.read(pendingModelProvider.notifier).select(null);
        ref.read(owedSetupsProvider.notifier).put(host, sessionId, setup);
        if (!ownsCreation()) return null;
        if (!await _applyOwedSetup(host, sessionId, setup, ownsCreation)) return null;
      }
      if (!ownsCreation() || _draftKey != sessionId || ref.read(currentSessionProvider) != sessionId) return null;
      return sessionId;
    } finally {
      if (mounted && identical(_creating, attempt)) setState(() => _creating = null);
    }
  }

  /// Applies what [sessionId] still owes from the new-chat screen before its
  /// first prompt: the preset first (it may bring its own defaults), then the
  /// permission and model picks on top. Each pick stays owed (owedSetupsProvider,
  /// across screens and restarts) until the Host confirms it, and is retried
  /// on the next send: the message must not go out under a setup the person
  /// did not choose.
  Future<bool> _applyOwedSetup(HostRef host, String sessionId, OwedSetup owed, bool Function() isCurrent) async {
    if (_applyingSetup != null) return false;
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return false;
    // What the Host confirms is recorded even if this screen goes meanwhile.
    final container = ProviderScope.containerOf(context, listen: false);
    final setups = ref.read(owedSetupsProvider.notifier);
    final attempt = Object();
    _applyingSetup = attempt;
    bool current() => identical(_applyingSetup, attempt) && mounted && isCurrent();
    try {
      if (owed.preset case final preset?) {
        await client.selectAgentPreset(sessionId, preset);
        setups.settled(host, sessionId, preset: preset);
        if (!current()) return false;
      }
      if (owed.permission case final permission?) {
        final CommandResult result;
        try {
          result = await client.setPermissionPreset(sessionId, permission);
        } finally {
          container.invalidate(permissionStateProvider(sessionId));
        }
        if (!result.success) throw DshRemoteException('permission', result.text ?? permission);
        setups.settled(host, sessionId, permission: permission);
        if (!current()) return false;
      }
      if (owed.model case final model?) {
        // setModel says itself what went wrong.
        if (!await ref.read(chatProvider(sessionId).notifier).setModel(model)) return false;
        setups.settled(host, sessionId, model: model);
        if (!current()) return false;
      }
      return true;
    } catch (e) {
      // The session exists by now, so the new-chat error slot is gone: say it
      // where the person is looking. The message stays in the composer.
      if (current()) _toast(chatErrorText(e, action: appL10n.viewNewChatModesFailed));
      return false;
    } finally {
      if (identical(_applyingSetup, attempt)) _applyingSetup = null;
    }
  }

  /// 新对话：先选类型再建会话（V4.2 · S5 / D2：类型创建后不改）。
  ///
  /// 选当前类型就是再建一条同类会话；选其他类型走统一入口新建该类型，
  /// 已有会话原样留在历史里，不会被改类型。
  Future<void> _pickNewConversation(ConversationMode current) async {
    HapticFeedback.selectionClick();
    // 锚点一路传下去：ChatHeader 的按钮 → pickConversationType →
    // showConversationModePanel，面板才会出现在按钮下方而不是左上角。
    final target = await pickConversationType(context, current: current, anchor: _newChatAnchor);
    if (!mounted || target == null) return;
    if (target == current) {
      switch (current) {
        case ConversationMode.chat:
          ref.read(currentSessionProvider.notifier).select(null);
        case ConversationMode.council || ConversationMode.team:
          _collabHeader.value?.onNew?.call();
      }
      return;
    }
    if (target == ConversationMode.chat) {
      // 「新对话 → 聊天」= 空白会话；原来的聊天留在历史里。
      ref.read(currentSessionProvider.notifier).select(null);
      switchConversationMode(context, ref, ConversationMode.chat, from: current);
      return;
    }
    // 面板里选了别的类型 = 明确要新建一条该类型的会话。
    switchConversationMode(context, ref, target, from: current, fresh: true);
  }

  Future<void> _send({SendMode mode = SendMode.now}) async {
    // The `@` picker is open on a typed name: sending picks its marked row.
    if (_mentions.pickHighlighted()) return;
    final typed = _input.text.trim();
    final drafts = _drafts;
    if ((typed.isEmpty && drafts.isEmpty) || _creating != null || _syncWait != null) return;
    // Generation mode: an ordinary message whose first line is the
    // parameter header (media-generation §8, revision of 2026-10-28).
    final generate = ref.read(generateModeProvider).byKey[_draftKey];
    if (generate != null && !_generateReady(generate, typed, drafts)) return;
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return;
    final generation = client.mux.generation;
    final scope = _draftScope;
    bool ownsDraft() => identical(_draftScope, scope) && _sameConnection(client, generation);
    // 引用追问: the passage above the composer goes in front, as a quote.
    final quote = ref.read(composerQuoteProvider)[_draftKey];
    final asked = quote == null ? typed : withQuote(quote, typed);
    // The header grammar refuses what it can't carry (§4.6.4): nothing goes.
    final written = generate?.tryMessage(asked);
    if (written != null && written.text == null) {
      _toast(switch (written.code) {
        GenerateHeaderCode.missingPrompt => appL10n.mediaNoDescription,
        GenerateHeaderCode.tooLong => appL10n.mediaDescriptionTooLong,
        _ => appL10n.mediaErrorGeneric,
      });
      return;
    }
    final text = written?.text ?? asked;

    // With attachments or a quote the line is a message, even if it starts
    // with "/".
    if (drafts.isEmpty && quote == null && generate == null) {
      final input = parseSlashInput(text);
      // A bare "/": the palette is open, the person picks a row.
      if (input != null && !input.hasArgs && input.token.isEmpty) return;
      final slash = _slashFor(text);
      if (slash != null) {
        final (command, line, picked) = slash;
        if (picked) {
          _pick(command, atCaret: false);
        } else {
          await _runSlash(command, line);
        }
        return;
      }
    }

    final sessionId = await _ensureSession(isCurrent: ownsDraft);
    if (sessionId == null || !ownsDraft() || _draftKey != sessionId) return;
    final chat = ref.read(chatProvider(sessionId).notifier);
    if (!ref.read(chatProvider(sessionId)).controlReady) {
      if (mode == SendMode.interrupt) return;
      // session/create can finish before its first follow snapshot. Keep
      // the draft visible while waiting; a timeout must not eat the message.
      final wait = Object();
      bool current() => identical(_syncWait, wait) && _draftKey == sessionId && ownsDraft();
      setState(() => _syncWait = wait);
      try {
        final ready = await chat.waitForSync(isCurrent: current);
        if (!ready ||
            !current() ||
            _input.text.trim() != typed ||
            !identical(_drafts, drafts) ||
            ref.read(composerQuoteProvider)[sessionId] != quote) {
          return;
        }
      } finally {
        if (mounted && identical(_syncWait, wait)) setState(() => _syncWait = null);
      }
    }
    // Creation/model application can also await while the composer is edited,
    // even when the session's baseline is already available on return.
    if (!ownsDraft() ||
        _draftKey != sessionId ||
        _input.text.trim() != typed ||
        !identical(_drafts, drafts) ||
        ref.read(composerQuoteProvider)[sessionId] != quote) {
      return;
    }
    setState(() => _drafts = const []);
    // A new message: the reply being read aloud is old news.
    ref.read(readAloudProvider.notifier).stop();
    _input.clear();
    ref.read(composerQuoteProvider.notifier).clear(sessionId);

    // One open question and nothing else waiting: the text is its answer
    // (a steer would wait behind the question).
    final current = ref.read(chatProvider(sessionId));
    final bool ok;
    if (current.singleQuestion case final request?
        when drafts.isEmpty &&
            quote == null &&
            generate == null &&
            mode == SendMode.now &&
            current.openApproval == null) {
      ok = await chat.answer(request, [QuestionAnswer(request.questions.single.id, custom: text)]);
    } else {
      ok = await chat.send(text, attachments: drafts, mode: mode);
      // A generation request, counted on top of its turn.
      if (ok && generate != null && mounted) ref.read(usageStatsProvider.notifier).count(UsageCount.gen);
    }
    if (!ok && _sameHost(client)) _giveBack(sessionId, typed, drafts, quote: quote);
  }

  // A failed send belongs to the Host that accepted it. The controller may
  // retire its continuation after reconnect; do not restore its draft into a
  // replacement Host merely because it uses the same session id.
  bool _sameConnection(DshClient client, MuxGeneration? generation) =>
      mounted &&
      identical(ref.read(activeConnectionProvider).value?.client, client) &&
      identical(client.mux.generation, generation);

  /// A send that did not go out (`send` is false only then) comes back on the Host that had
  /// it, over a reconnect too (#1416); never into a replacement Host.
  bool _sameHost(DshClient client) => mounted && identical(ref.read(activeConnectionProvider).value?.client, client);

  /// 没发出去:把字、附件和引用还给那个对话(用户还没开始打新的才还)。
  void _giveBack(String sessionId, String text, List<DraftAttachment> attachments, {String? quote}) {
    final quotes = ref.read(composerQuoteProvider.notifier);
    if (quote != null && ref.read(composerQuoteProvider)[sessionId] == null) {
      quotes.set(sessionId, quote);
    }
    if (_draftKey != sessionId) {
      // Moved on to another conversation: back into its own draft.
      if (ref.read(draftStoreProvider).drafts[sessionId] == null) {
        _draftStore.save(sessionId, text, attachments);
      }
      return;
    }
    if (_drafts.isEmpty) setState(() => _drafts = attachments);
    if (_input.text.isEmpty) {
      _input.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    _saveDraft();
  }

  /// 「重新回答」, second half: the fork is open; send the prompt there as
  /// it was. Not sent: it waits in that conversation's composer.
  Future<void> _resend(String sessionId, String text, List<DraftAttachment> images) async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return;
    final ok = await ref.read(chatProvider(sessionId).notifier).send(text, attachments: images);
    if (ok || !_sameHost(client)) return;
    final (:quote, :body) = splitQuote(text);
    _giveBack(sessionId, quote == null ? text : body, images, quote: quote);
  }

  /// 「引用」 on a reply of [sessionId]: the passage above its composer.
  void _quote(String sessionId, String passage) {
    ref.read(composerQuoteProvider.notifier).set(sessionId, passage);
    _focus.requestFocus();
  }

  /// [message] into the composer, its leading quote back above it as the
  /// chip (「编辑后重发」 of a message that quoted something), a generation
  /// request's header back as the mode. [quoteChip] false
  /// keeps it all as text (shared text: the chip would cut a long quote);
  /// [restoreMode] false takes a leading header as text too (a description
  /// from a card); [focus] false leaves the keyboard down (dictation).
  void _compose(String message, {bool quoteChip = true, bool restoreMode = true, bool focus = true}) {
    var text = message;
    // A valid generation request, where this host can generate: its header
    // becomes the mode again, the description (as it was) the text. Anywhere
    // else the whole message stays as it was, header and all (§4.6.6).
    if (quoteChip && restoreMode && _generationOn) {
      if (GenerateHeader.parse(text) case (:final header, :final description)) {
        _restoreGenerate(header);
        text = description;
      }
    }
    final (:quote, :body) = quoteChip ? splitQuote(text) : (quote: null, body: text);
    if (quote != null) {
      ref.read(composerQuoteProvider.notifier).set(_draftKey, quote);
    }
    final shown = quote == null ? text : body;
    _input.value = TextEditingValue(
      text: shown,
      selection: TextSelection.collapsed(offset: shown.length),
    );
    if (focus) _focus.requestFocus();
  }

  bool _takingCompose = false;

  /// The share sheet, a launcher shortcut, the tile, a file opened with the
  /// app (ui/shell/system_entry_host.dart): 新对话, its composer filled — the
  /// shared text under what was there, attachments after its own — and
  /// focused, or listening for 「语音输入」. Nothing is sent.
  void _takeCompose() {
    if (_takingCompose) return;
    _takingCompose = true;
    try {
      // The queue itself, not readyComposeProvider: this runs inside its
      // notification.
      while (mounted && ref.read(draftStoreProvider).loaded) {
        final request = ref.read(composeInboxProvider.notifier).take();
        if (request == null) break;
        if (ref.read(currentSessionProvider) != null) {
          ref.read(currentSessionProvider.notifier).select(null);
        }
        _switchDraft(null);
        final merged = mergeIntoDraft(
          text: _input.text,
          attachments: _drafts,
          request: request,
          filesAllowed: canStageFiles(ref.read(activeConnectionProvider).value, ref.read(activeHostProvider)),
        );
        setState(() => _drafts = merged.attachments);
        _compose(merged.text, quoteChip: false, focus: !request.voice);
        _saveDraft();
        if (request.voice) {
          _focus.unfocus();
          unawaited(_voice.start());
        }
        if (merged.problem ?? request.note case final line?) {
          showComposerToast(context, line, composerHeight: _veilHeight.value);
        }
      }
    } finally {
      _takingCompose = false;
    }
  }

  /// Long-press on send while a turn runs: how this message should land.
  Future<void> _sendOptions() async {
    final sessionId = ref.read(currentSessionProvider);
    final running = sessionId != null && ref.read(chatProvider(sessionId)).running;
    if (!running) return _send();
    // The choice belongs to the draft and connection that opened this menu.
    // A surviving sheet must not send a newly selected conversation or draft.
    final scope = _draftScope;
    final client = ref.read(activeConnectionProvider).value?.client;
    final generation = client?.mux.generation;
    final readyNumber = client?.mux.lastReadyGenerationNumber;
    final text = _input.text;
    final drafts = _drafts;
    final quote = ref.read(composerQuoteProvider)[sessionId];
    final mode = await showAppSheet<SendMode>(
      context,
      builder: (sheet) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(appL10n.chatSendMode),
            SheetGroup(
              margin: const EdgeInsets.symmetric(horizontal: SheetTitleBar.inset),
              children: [
                for (final (mode, icon, title, subtitle) in [
                  (SendMode.steer, AppIcons.steer, appL10n.chatSteer, appL10n.chatSteerHint),
                  (SendMode.interrupt, AppIcons.interrupt, appL10n.chatInterruptAndSend, appL10n.chatInterruptHint),
                  (SendMode.queue, AppIcons.queued, appL10n.chatQueue, appL10n.chatQueueHint),
                ])
                  SettingsTile(
                    tinted: false,
                    chevron: false,
                    icon: icon,
                    title: title,
                    subtitle: subtitle,
                    onTap: () => Navigator.pop(sheet, mode),
                  ),
              ],
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
    if (mode == null ||
        !mounted ||
        !identical(_draftScope, scope) ||
        _draftKey != sessionId ||
        ref.read(currentSessionProvider) != sessionId ||
        client == null ||
        !_sameConnection(client, generation) ||
        client.mux.lastReadyGenerationNumber != readyNumber ||
        _input.text != text ||
        !identical(_drafts, drafts) ||
        ref.read(composerQuoteProvider)[sessionId] != quote) {
      return;
    }
    await _send(mode: mode);
  }

  /// 「立即发送」 / 「发送」 on a waiting message.
  Future<void> _sendNow(PendingPrompt prompt) async {
    final sessionId = ref.read(currentSessionProvider);
    if (sessionId == null) return;
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return;
    final generation = client.mux.generation;
    final lost = await ref.read(chatProvider(sessionId).notifier).sendNow(prompt);
    if (_sameConnection(client, generation)) _giveBackLost(sessionId, lost);
  }

  /// A waiting message taken out to go again did not make it back: into the
  /// composer, like any send that failed.
  void _giveBackLost(String sessionId, List<PendingPrompt> lost) {
    final prompt = lost.firstOrNull;
    if (prompt == null) return;
    final (:quote, :body) = splitQuote(prompt.text);
    _giveBack(sessionId, quote == null ? prompt.text : body, prompt.attachments, quote: quote);
  }

  /// "撤回" on a queued message: out of the inbox and back into the composer
  /// (unless the person already started typing something new).
  Future<void> _withdraw(PendingPrompt prompt) async {
    final sessionId = ref.read(currentSessionProvider);
    if (sessionId == null) return;
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return;
    final generation = client.mux.generation;
    final readyNumber = client.mux.lastReadyGenerationNumber;
    final ok = await ref.read(chatProvider(sessionId).notifier).withdrawQueued(prompt);
    if (!ok ||
        !mounted ||
        !_sameConnection(client, generation) ||
        client.mux.lastReadyGenerationNumber != readyNumber) {
      return;
    }
    if (_draftKey != sessionId) {
      // The queue removal succeeded, but its text still belongs to that chat.
      // Preserve an existing draft as a whole, including its quote.
      if (ref.read(draftStoreProvider).drafts[sessionId] == null) {
        _giveBackLost(sessionId, [prompt]);
      }
      return;
    }
    var restored = false;
    if (_input.text.trim().isEmpty && prompt.text.isNotEmpty) {
      final (:quote, :body) = splitQuote(prompt.text);
      if (quote != null && ref.read(composerQuoteProvider)[sessionId] == null) {
        ref.read(composerQuoteProvider.notifier).set(sessionId, quote);
      }
      _input.text = quote == null ? prompt.text : body;
      restored = true;
    }
    if (_drafts.isEmpty && prompt.attachments.isNotEmpty) {
      setState(() => _drafts = prompt.attachments);
      restored = true;
    }
    if (restored) _focus.requestFocus();
    showBriefNotice(context, restored ? appL10n.chatWithdrawnEditable : appL10n.chatWithdrawn);
  }

  // ---------------------------------------------------------------------------
  // 附件

  Future<void> _attach() async {
    final room = maxAttachments - _drafts.length;
    final client = ref.read(activeConnectionProvider).value?.client;
    // A draft or connection that changes away and back still retires this pick.
    final scope = _draftScope;
    final generation = client?.mux.generation;
    final readyNumber = client?.mux.lastReadyGenerationNumber;
    var hostRetired = false;
    bool ownsDraft() =>
        mounted &&
        !hostRetired &&
        identical(_draftScope, scope) &&
        identical(ref.read(activeConnectionProvider).value?.client, client) &&
        identical(client?.mux.generation, generation) &&
        client?.mux.lastReadyGenerationNumber == readyNumber;
    // A derived connection can coalesce A -> B -> A before its next read.
    // Observe the selected Host directly for this picker attempt only.
    final hostChanges = ref.listenManual(activeHostProvider, (previous, next) {
      if (previous != next) hostRetired = true;
    });
    try {
      final choice = await showPlusPanel(
        context,
        files: canStageFiles(ref.read(activeConnectionProvider).value, ref.read(activeHostProvider)),
        sessionId: ref.read(currentSessionProvider),
        generate: ref.read(mediaPluginProvider) != MediaPluginState.absent,
        call: true,
      );
      if (choice is CallChoice) {
        if (ownsDraft() && mounted) await _startCall(ownsDraft);
        return;
      }
      if (choice is GenerateChoice) {
        if (ownsDraft()) _enterGenerate();
        return;
      }
      if (choice is NativeToolChoice) {
        if (ownsDraft() && mounted) {
          final scope = DshGoScope(sessionId: ref.read(currentSessionProvider));
          unawaited(runNativeAction(context, ref, choice.action, scope: scope, composer: _nativeHost));
        }
        return;
      }
      if (choice is! AttachChoice || !ownsDraft()) return;
      if (room <= 0) {
        _toast(appL10n.chatAttachmentLimit(maxAttachments));
        return;
      }
      final source = choice.source;
      final picker = ref.read(attachmentPickerProvider);
      final PickedAttachments picked;
      try {
        picked = switch (source) {
          AttachSource.gallery => PickedAttachments(await picker.pickImages(limit: room)),
          AttachSource.camera => PickedAttachments([?await picker.takePhoto()]),
          AttachSource.files => await picker.pickFiles(limit: room, heldBytes: totalAttachmentBytes(_drafts)),
        };
      } on PlatformException catch (e) {
        if (!ownsDraft()) return;
        _toast(
          e.code.contains('denied') || e.code.contains('permission')
              ? appL10n.chatAttachmentPermission
              : chatErrorText(e, action: appL10n.chatOpenAttachmentFailed),
        );
        return;
      } catch (e) {
        if (!ownsDraft()) return;
        _toast(chatErrorText(e, action: appL10n.chatReadFailed));
        return;
      }
      if (!ownsDraft()) return;
      _addDrafts(picked.attachments, problem: picked.problem);
    } finally {
      hostChanges.close();
    }
  }

  /// An image from the keyboard (screenshot, sticker): into the tray, not sent.
  void _pasteContent(KeyboardInsertedContent content) {
    final data = content.data;
    if (data == null || data.isEmpty) {
      _toast(appL10n.chatReadImageFailed);
      return;
    }
    final extension = switch (content.mimeType) {
      'image/jpeg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      _ => 'png',
    };
    _addDrafts([DraftAttachment.sniff('${appL10n.fileImageName}.$extension', data)]);
  }

  void _addDrafts(List<DraftAttachment> picked, {String? problem}) {
    final room = maxAttachments - _drafts.length;
    var heldBytes = totalAttachmentBytes(_drafts);
    final ok = <DraftAttachment>[];
    for (final a in picked) {
      final p = attachmentProblem(a) ?? attachmentBudgetProblem(heldBytes, a);
      if (p != null) {
        problem ??= p;
      } else if (ok.length < room) {
        ok.add(a);
        heldBytes += a.size;
      } else {
        problem ??= appL10n.chatAttachmentLimit(maxAttachments);
      }
    }
    if (ok.isNotEmpty) {
      setState(() => _drafts = [..._drafts, ...ok]);
      _saveDraft();
    }
    if (problem != null) _toast(problem);
  }

  void _removeDraft(DraftAttachment a) {
    setState(
      () => _drafts = [
        for (final d in _drafts)
          if (d.id != a.id) d,
      ],
    );
    _saveDraft();
  }

  void _toast(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // 生成模式 (docs/design/media-generation.md §4.2)

  /// The last mode came from 编辑: the hint asks how to change it.
  bool _editing = false;

  /// This host can generate now: the plugin runs, its catalogue reads, and a
  /// configured service with its key offers a model (media-generation §4.3).
  bool get _generationOn =>
      ref.read(mediaPluginProvider) == MediaPluginState.ready && ref.read(mediaCatalogProvider).configured;

  /// Into generation mode for this conversation: its own mode if it has one,
  /// else the kind used last ([kind] picks one). A host that only offers the
  /// plugin gets 「在此主机上安装」; a catalogue that is missing, damaged or
  /// of an unknown version, 「生成模式不可用」 (chat goes on as usual).
  void _enterGenerate({GenerateKind? kind, bool edit = false}) {
    if (ref.read(mediaPluginProvider) != MediaPluginState.ready) {
      unawaited(showMediaInstallSheet(context));
      return;
    }
    final catalog = ref.read(mediaCatalogProvider);
    if (catalog.status == MediaCatalogStatus.loading) {
      _whenSettingsRead(() => _enterGenerate(kind: kind, edit: edit));
      return;
    }
    if (!catalog.usable) {
      unawaited(showMediaUnavailableSheet(context));
      return;
    }
    if (!catalog.configured) {
      unawaited(_configureMedia(kind: kind, edit: edit));
      return;
    }
    final modes = ref.read(generateModeProvider);
    // This conversation's own mode keeps its model even when the host no
    // longer has it (the sheet then asks); a fresh one starts on this host's.
    final own = modes.byKey[_draftKey];
    var params = own ?? (kind == null ? modes.start : modes.startOf(kind)).startOn(catalog);
    if (kind != null && params.kind != kind) params = modes.startOf(kind).startOn(catalog);
    // A kind the host has no model for: the one it has.
    final kinds = catalog.kinds;
    if (!kinds.contains(params.kind)) params = modes.startOf(kinds.first).startOn(catalog);
    ref.read(generateModeProvider.notifier).set(_draftKey, params.fitTo(catalog));
    setState(() => _editing = edit);
    _focus.requestFocus();
  }

  /// [then] once the engine settings (and with them the catalogue) are read,
  /// if this draft is still the one on screen.
  void _whenSettingsRead(VoidCallback then) {
    final key = _draftKey;
    unawaited(
      ref.read(engineSettingsProvider.future).then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (!mounted || _draftKey != key) return;
        if (ref.read(mediaCatalogProvider).status == MediaCatalogStatus.loading) return;
        then();
      }),
    );
  }

  /// The plugin is there with no service yet: 图像与视频 first, then the
  /// mode once a service is set up.
  Future<void> _configureMedia({GenerateKind? kind, bool edit = false}) async {
    final key = _draftKey;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MediaSettingsPage()));
    if (!mounted || _draftKey != key || !ref.read(mediaCatalogProvider).configured) return;
    _enterGenerate(kind: kind, edit: edit);
  }

  /// A generation request back in the composer (编辑后重发): exactly its
  /// values become this conversation's mode, its model by marker or by a
  /// name only one choice has; otherwise the sheet asks (§4.6.5).
  void _restoreGenerate(GenerateHeader header) {
    ref
        .read(generateModeProvider.notifier)
        .set(_draftKey, GenerateParams.fromHeader(header, ref.read(mediaCatalogProvider)));
    setState(() => _editing = false);
  }

  /// × on the capsule: out of the mode; the text stays.
  void _exitGenerate() {
    ref.read(generateModeProvider.notifier).set(_draftKey, null);
    setState(() => _editing = false);
  }

  void _openGenerateSheet(GenerateParams params) {
    final key = _draftKey;
    unawaited(
      showGenerateSheet(
        context,
        params: params,
        onChanged: (next) {
          if (ref.read(generateModeProvider).byKey[key] != null) {
            ref.read(generateModeProvider.notifier).set(key, next);
          }
        },
      ),
    );
  }

  /// Whether [params] can go with [typed] and [drafts]; says why not.
  bool _generateReady(GenerateParams params, String typed, List<DraftAttachment> drafts) {
    if (typed.isEmpty) {
      _toast(appL10n.mediaNoDescription);
      return false;
    }
    // A model this host can't pin to one service is never guessed (§4.6.5).
    final model = ref.read(mediaCatalogProvider).resolve(params.model, params.kind)?.model;
    if (model == null) {
      _toast(appL10n.mediaPickModelFirst);
      return false;
    }
    final pictures = drafts.where((d) => d.isImage).length;
    if (pictures > 0 && model.maxRefs == 0) {
      _toast(appL10n.mediaNoRefs);
      return false;
    }
    if (params.isVideo && pictures >= 2 && !model.lastFrame) {
      _toast(appL10n.mediaNoLastFrame);
      return false;
    }
    if (pictures > model.maxRefs) {
      _toast(appL10n.mediaRefLimit(model.maxRefs));
      return false;
    }
    return true;
  }

  /// ↻ on a card: the same request again, as a new generation message — when
  /// the card's model pins one of this host's choices. Otherwise it is 修改:
  /// the person sees the values and picks.
  Future<void> _regenerateMedia(String sessionId, MediaMeta meta) async {
    final prompt = meta.prompt ?? '';
    if (prompt.trim().isEmpty) return;
    if (_generationOn) {
      final catalog = ref.read(mediaCatalogProvider);
      final params = GenerateParams.fromMeta(meta, catalog);
      final text = catalog.resolve(params.model, params.kind) == null ? null : params.tryMessage(prompt).text;
      if (text != null) {
        HapticFeedback.selectionClick();
        await ref.read(chatProvider(sessionId).notifier).send(text);
        return;
      }
    }
    _reviseMedia(meta);
  }

  /// 修改: the card's description back in the composer as it was, in
  /// generation mode with the card's values where this host can generate.
  void _reviseMedia(MediaMeta meta) {
    final prompt = meta.prompt ?? '';
    if (prompt.trim().isEmpty) return;
    if (_generationOn) {
      ref
          .read(generateModeProvider.notifier)
          .set(_draftKey, GenerateParams.fromMeta(meta, ref.read(mediaCatalogProvider)));
      setState(() => _editing = false);
    }
    _compose(prompt, restoreMode: false);
  }

  /// ⋯ › 编辑 / 做成视频: the picture into the tray, generation mode on.
  Future<void> _reuseMedia(String sessionId, MediaMeta meta, MediaItem item, {required bool video}) async {
    final scope = _draftScope;
    try {
      final bytes = await mediaItemBytes(ref, sessionId, item);
      if (!mounted || !identical(scope, _draftScope)) return;
      _addDrafts([DraftAttachment.sniff(item.name, bytes)]);
      _enterGenerate(kind: video ? GenerateKind.video : GenerateKind.image, edit: !video);
    } catch (e) {
      if (mounted) _toast(chatErrorText(e, action: appL10n.chatReadImageFailed));
    }
  }

  Future<void> _pickNewChatFolder() async {
    final scope = _draftScope;
    final host = ref.read(activeHostProvider);
    bool current() =>
        mounted &&
        identical(scope, _draftScope) &&
        ref.read(activeHostProvider) == host &&
        ref.read(currentSessionProvider) == null;
    final view = ref.read(drawerViewProvider);
    final selected = ref.read(pendingSessionFolderProvider);
    final pick = await showMoveToFolderSheet(
      context,
      folders: view.folders,
      counts: {for (final f in view.folders) f.id: f.sessionIds.length},
      currentFolder: selected,
      anyFiled: selected != null,
      title: context.l10n.shellFolders,
      allowCreate: false,
    );
    if (pick == null || !current()) return;
    final String? folderId;
    switch (pick) {
      case PickFolder(:final folderId):
        if (ref.read(drawerViewProvider).byId(folderId) == null) return;
        ref.read(pendingSessionFolderProvider.notifier).select(folderId);
        return;
      case PickNoFolder():
        folderId = null;
      case PickNewFolder():
        return;
    }
    ref.read(pendingSessionFolderProvider.notifier).select(folderId);
  }

  // ---------------------------------------------------------------------------
  // 斜杠指令

  List<SlashCommand> get _commands => ref.read(slashCommandsProvider(ref.read(currentSessionProvider)));

  /// What sending [text] means as a command: an exact name runs as typed;
  /// a partial name picks the palette's first row (`picked`). Null = a
  /// normal message (not a command line, or an unknown name with input,
  /// such as a path).
  (SlashCommand, String, bool)? _slashFor(String text) {
    final input = parseSlashInput(text);
    if (input == null) return null;
    final commands = _commands;
    final exact = resolveSlashCommand(commands, input.token);
    // `/skill …` is a message: the Host loads the skill from its text.
    if (exact?.kind == SlashCommandKind.skill) return null;
    if (exact != null) {
      return (exact, '/${exact.name}${input.rest ?? ''}', false);
    }
    if (input.hasArgs) return null;
    if (_handedSkills.contains(input.token)) return null;
    final matches = filterSlashCommands(commands, input.token);
    if (matches.isEmpty) return null;
    return (matches.first, '/${matches.first.name}', true);
  }

  /// A row picked in the palette: app commands and commands without input run
  /// now; commands that take input go into the composer for the arguments.
  void _pick(SlashCommand command, {bool atCaret = true}) {
    _dismissSlashPalette();
    final value = _input.value;
    final caret = atCaret && value.selection.isValid ? value.selection.end : value.text.length;
    final (:leading, :suffix) = slashCompletionContext(_commands, value.text, caret);
    if (slashPickInsertsText(command, hasSuffix: suffix.isNotEmpty)) {
      final prefix = '${value.text.substring(0, leading)}/${command.name}';
      final separator = suffix.isEmpty || !RegExp(r'^\s').hasMatch(suffix) ? ' ' : '';
      final text = '$prefix$separator$suffix';
      _input.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: (prefix.length + 1).clamp(0, text.length)),
      );
      _focus.requestFocus();
      return;
    }
    _runSlash(command, '/${command.name}');
  }

  Future<void> _runSlash(SlashCommand command, String line) async {
    HapticFeedback.selectionClick();
    switch (command.kind) {
      case SlashCommandKind.app:
        _input.clear();
        switch (command.name) {
          case 'new':
            ref.read(currentSessionProvider.notifier).select(null);
          case 'model':
            await _showModelSheet();
          case 'features':
            // 3b：切到「工具」标签，不再压一个与标签重复的根页。
            switchTab(context, RootTab.tools);
          case 'export':
            final sessionId = ref.read(currentSessionProvider);
            if (sessionId == null) {
              _toast(appL10n.chatOpenChatFirst);
              return;
            }
            await Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => SessionExportPage(sessionId: sessionId)));
        }
      case SlashCommandKind.skill:
        _pick(command);
      case SlashCommandKind.host:
        final client = ref.read(activeConnectionProvider).value?.client;
        if (client == null) return;
        final generation = client.mux.generation;
        final scope = _draftScope;
        final text = _input.text;
        final drafts = _drafts;
        final quote = ref.read(composerQuoteProvider)[_draftKey];
        bool ownsDraft() => identical(_draftScope, scope) && _sameConnection(client, generation);
        final sessionId = await _ensureSession(isCurrent: ownsDraft);
        if (sessionId == null ||
            !ownsDraft() ||
            _draftKey != sessionId ||
            _input.text != text ||
            !identical(_drafts, drafts) ||
            ref.read(composerQuoteProvider)[sessionId] != quote) {
          return;
        }
        _input.clear();
        await ref.read(chatProvider(sessionId).notifier).runCommand(line);
    }
  }

  void _openUsage(String sessionId, ModelSelection? model) {
    showUsageSheet(context, sessionId: sessionId, model: model);
  }

  /// The header's 语音通话 key: a call with the conversation on screen.
  void _callFromHeader() {
    HapticFeedback.selectionClick();
    final scope = _draftScope;
    unawaited(_startCall(() => mounted && identical(_draftScope, scope)));
  }

  /// 「语音通话」 with this conversation (a new chat gets its conversation
  /// with the first thing said); [ownsDraft]: still the conversation it was asked from.
  Future<void> _startCall(bool Function() ownsDraft) async {
    final host = ref.read(activeHostProvider);
    // Dictation gives the microphone back first (what it heard so far goes, as on a draft switch).
    await _voice.cancel();
    if (!mounted || !ownsDraft() || ref.read(activeHostProvider) != host) return;
    final sessionId = ref.read(currentSessionProvider);
    final listed = sessionId == null ? null : ref.read(chatProvider(sessionId)).title;
    final title = listed != null && listed.trim().isNotEmpty ? chatTitleShown(listed.trim()) : appL10n.commonNewChat;
    // The call stays with the conversation it began in, whatever is opened meanwhile.
    var pinned = sessionId;
    unawaited(
      openChatCall(
        context,
        title: title,
        session: () async {
          // Another host now: its conversation of the same id is not this call's.
          if (!mounted || ref.read(activeHostProvider) != host) return null;
          final id = pinned;
          if (id == null) {
            // Begun on the new-chat screen: another conversation opened since is not this call's.
            if (ref.read(currentSessionProvider) != null) return null;
            String? created;
            final made = await _ensureSession(isCurrent: () => mounted, onCreated: (id) => created = id);
            // Made but its picks failed to apply: still this call's, the next line retries them.
            pinned = made ?? created;
            return made;
          }
          // Picks it still owes (a failed apply on the new-chat screen) are settled before it is spoken to.
          final owed = ref.read(owedSetupsProvider.notifier).of(host, id);
          if (owed != null && !await _applyOwedSetup(host, id, owed, () => mounted)) return null;
          return id;
        },
      ),
    );
  }

  /// The stop key; what waits in the inbox goes right away (see
  /// [ChatController.cancel]).
  Future<void> _stop() async {
    final sessionId = ref.read(currentSessionProvider);
    if (sessionId == null) return;
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return;
    final generation = client.mux.generation;
    final lost = await ref.read(chatProvider(sessionId).notifier).cancel();
    if (_sameConnection(client, generation)) _giveBackLost(sessionId, lost);
  }

  /// The engine could not be reached: try again.
  void _reconnect() {
    final host = ref.read(activeHostProvider);
    if (host.kind == HostKind.local) {
      ref.invalidate(localConnectionProvider);
    } else {
      ref.read(remoteConnectionProvider(host).notifier).retry();
    }
  }

  void _onSuggestion(ChatSuggestion suggestion) {
    _input.value = TextEditingValue(
      text: suggestion.prompt,
      selection: TextSelection.collapsed(offset: suggestion.prompt.length),
    );
    _focus.requestFocus();
  }

  Future<void> _showModelSheet() {
    final sessionId = ref.read(currentSessionProvider);
    final selection = sessionId == null ? ref.read(pendingModelProvider) : ref.read(chatProvider(sessionId)).model;
    return showModelSheet(
      context,
      current: selection ?? ref.read(currentModelCatalogProvider)?.defaultSelection,
      onSelected: _modelTarget(),
    );
  }

  /// 「换模型」 after the engine refused the model. DSH follows the official
  /// model listing, so the catalog read earlier may be stale: read it again.
  void _switchModel() {
    ref.invalidate(modelCatalogProvider);
    unawaited(_showModelSheet());
  }

  /// Where a model picked in a sheet opened now goes: the conversation open
  /// now (with none, the next new chat), on this host. The sheet can outlive
  /// that — the conversation deleted on the host while the catalog is read
  /// again, another conversation or host chosen — and a pick then goes to
  /// neither, rather than to whatever is open by then.
  ValueChanged<ModelSelection> _modelTarget() {
    final scope = ref.read(modelSelectionScopeProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    final generation = client?.mux.generation;
    final sessionId = ref.read(currentSessionProvider);
    return (selection) {
      if (!mounted ||
          client == null ||
          !_sameConnection(client, generation) ||
          ref.read(activeConnectionProvider).isLoading ||
          ref.read(activeConnectionProvider).hasError ||
          !identical(ref.read(modelSelectionScopeProvider), scope) ||
          ref.read(currentSessionProvider) != sessionId) {
        return;
      }
      if (sessionId == null) {
        ref.read(pendingModelProvider.notifier).select(selection);
      } else {
        // A newer pick replaces a model still owed from the new-chat screen.
        ref.read(owedSetupsProvider.notifier).dropModel(ref.read(activeHostProvider), sessionId);
        ref.read(chatProvider(sessionId).notifier).setModel(selection);
      }
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sessionId = ref.watch(currentSessionProvider);
    final connAsync = ref.watch(activeConnectionProvider);
    final conn = connAsync.value;
    final connected = conn != null;
    final local = ref.watch(activeHostProvider.select((h) => h.kind == HostKind.local));
    final starting = local && ref.watch(localRuntimeProvider.select((s) => s.status.phase == RuntimePhase.starting));
    final tidying = starting && ref.watch(localRuntimeProvider.select((s) => s.status.tidyingFiles));
    // The engine stopped on its own: the failure card above the empty state
    // carries the recovery, so the empty state offers no second one.
    final failureCard = local && ref.watch(localRuntimeProvider.select((s) => EngineFailureCard.visibleFor(s.status)));
    // 本机 down for good: no runtime (notInstalled), or stopped with auto
    // start off (installed). Null otherwise.
    final localIdle = local && !failureCard
        ? ref.watch(
            localRuntimeProvider.select(
              (s) => s.status.runtimeMissing
                  ? RuntimePhase.notInstalled
                  : s.status.phase == RuntimePhase.installed
                  ? RuntimePhase.installed
                  : null,
            ),
          )
        : null;
    final idle = switch (localIdle) {
      RuntimePhase.notInstalled => switch (localMissingCopy(
        l10n,
        available: ref.watch(localRuntimeProvider.select((s) => s.available)),
      )) {
        final copy => ChatIdleAction(
          message: copy.title,
          label: copy.action,
          onTap: () => unawaited(openLocalInstall(context)),
        ),
      },
      RuntimePhase.installed => ChatIdleAction(
        message: l10n.shellEngineNotRunning,
        label: l10n.shellStartEngine,
        onTap: () => unawaited(EngineControl.ensureStarted(ProviderScope.containerOf(context, listen: false))),
      ),
      _ => null,
    };
    // A conversation open with nothing loaded while 本机 is down (a cold
    // start back into the last one, auto start off): the empty page with its
    // one fix rather than a blank list.
    final idleBlank =
        idle != null && sessionId != null && ref.watch(chatProvider(sessionId).select((s) => s.items.isEmpty));

    // 只盯顶栏 / 输入条需要的几个字段:流式增量不重建整页。
    final chat = sessionId == null
        ? null
        : ref.watch(
            chatProvider(sessionId).select(
              (s) => (
                title: s.title,
                running: s.running,
                stopping: s.stopping,
                streamLost: s.streamLost,
                syncing: s.syncing,
                resyncing: s.resyncing,
                controlReady: s.controlReady,
                connection: s.connection,
                approval: s.openApproval,
                question: s.questions.firstOrNull,
                singleQuestion: s.singleQuestion != null,
                model: s.model,
                error: s.error,
                syncError: s.syncError,
                defaultModelSaveFailed: s.defaultModelSaveFailed,
                notice: s.notice,
                autoApprove: s.autoApprove,
              ),
            ),
          );
    final listedTitle = sessionId == null
        ? null
        : ref.watch(
            sessionsProvider.select((async) => async.value?.where((s) => s.sessionId == sessionId).firstOrNull?.title),
          );
    final pendingModel = ref.watch(pendingModelProvider);
    // 模型选择搬进输入栏后，这里只在页面里取一次「当前生效的模型」：
    // 顶栏不再显示模型名，输入栏的模型键用它选厂商标记与读屏文案。
    final modelCatalog = ref.watch(currentModelCatalogProvider);
    final modelSelection = sessionId == null ? pendingModel : chat?.model;
    final effectiveModel = modelSelection ?? modelCatalog?.defaultSelection;
    final modelName = modelShortName(effectiveModel, modelCatalog);
    final newFolder = sessionId == null
        ? ref.watch(drawerViewProvider).byId(ref.watch(pendingSessionFolderProvider))
        : null;
    final hasFolders = sessionId == null && ref.watch(drawerViewProvider).folders.isNotEmpty;
    final commands = ref.watch(slashCommandsProvider(sessionId));
    final contextFraction = sessionId == null
        ? null
        : ref.watch(sessionUsageProvider(sessionId).select((u) => u.contextFraction));
    // 「帮我修复」: a fresh chat with the repair prompt in the composer,
    // not sent — the person reads it first.
    ref.listen(repairDraftProvider, (_, next) {
      if (next != null) _takeRepairDraft();
    });
    ref.listen(composerInsertProvider, (_, next) {
      if (next != null) _takeComposerInsert();
    });
    // Heard while providers refresh: switching the conversation right there
    // would rebuild the ones already refreshed this frame.
    ref.listen(readyComposeProvider, (_, next) {
      if (next != null) scheduleMicrotask(_takeCompose);
    });
    if (sessionId != null) {
      // A finished turn spent money: re-read the balance (throttled).
      ref.listen(chatProvider(sessionId).select((s) => s.running), (previous, running) {
        if (running) {
          _spoken = null;
        } else if (previous == true) {
          final turns = ref.read(chatProvider(sessionId)).turns;
          _spoken = switch (turns.lastOrNull?.endReason?.kind) {
            'aborted' => l10n.commonStopped,
            null || 'completed' || 'max-tokens' => l10n.chatTurnCompleted,
            _ => l10n.chatTurnError,
          };
          ref.read(balanceProvider.notifier).refresh();
        }
      });
    }

    final title = switch (chat?.title ?? listedTitle) {
      final t? when t.trim().isNotEmpty => chatTitleShown(t.trim()),
      _ => l10n.commonNewChat,
    };
    final approval = chat?.approval;
    final question = chat?.question;
    final status = _status(
      connecting: connAsync.isLoading && conn == null,
      starting: starting,
      connected: connected,
      idleLabel: switch (localIdle) {
        RuntimePhase.notInstalled => l10n.phoneEngineNotInstalled,
        RuntimePhase.installed => l10n.commonStopped,
        _ => null,
      },
      streamLost: chat?.streamLost ?? false,
      syncing: chat?.syncing ?? false,
      label: conn?.label ?? l10n.commonThisPhone,
      connection: chat?.connection,
      running: chat?.running ?? false,
      stopping: chat?.stopping ?? false,
      waiting: approval != null
          ? l10n.commonWaitingApproval
          : question != null
          ? l10n.commonWaitingAnswer
          : null,
      // The live region reads out what is waiting, or how the turn ended.
      spoken: approval != null
          ? approvalText(approval)
          : question != null
          ? questionText(question)
          : _spoken,
    );
    final narrow = MediaQuery.sizeOf(context).width < WindowClass.mediumMin;
    // Where a new conversation starts (the drawer's workspace, else the one a
    // remote host falls back to, so the host's start directory is never silent).
    final newChat = sessionId == null;
    final workspace =
        ref.watch(selectedWorkspaceProvider) ?? (newChat ? ref.watch(recentWorkspaceForNewChatProvider) : null);
    final inHostDefault = newChat && workspace == null && ref.watch(newChatInHostDefaultProvider);
    // A one-shot subagent takes no messages: DSH Web shows it read-only.
    final readOnly =
        sessionId != null &&
        ref.watch(subagentParentProvider(sessionId).select((p) => p?.address.mode == SubagentMode.oneShot));
    // A subagent conversation: 「‹ 上级对话」 takes the menu key's place, so
    // the 新对话 key would have nothing to mirror.
    final isChild = sessionId != null && ref.watch(subagentParentProvider(sessionId).select((p) => p != null));
    // v4：三种模式共用这一个工作区。议会/团队不再是独立路由，而是这里的
    // 内容切换；子代理对话不参与模式切换。
    final collabMode = isChild ? ConversationMode.chat : ref.watch(conversationModeProvider.select((s) => s.mode));
    // 生成模式: this conversation's, and what the host can do.
    final generate = ref.watch(generateModeProvider.select((m) => m.byKey[_draftKey]));
    final mediaReady = ref.watch(mediaPluginProvider) == MediaPluginState.ready;
    // What the catalogue really offers here (§4.3): a picture can go in as a
    // reference, or as a video's first frame, only where a model takes one.
    final mediaEdit =
        mediaReady &&
        ref.watch(
          mediaCatalogProvider.select((c) => c.of(GenerateKind.image).any((e) => e.model.edit || e.model.maxRefs > 0)),
        );
    final mediaVideo =
        mediaReady &&
        ref.watch(
          mediaCatalogProvider.select(
            (c) => c.of(GenerateKind.video).any((e) => e.model.firstFrame || e.model.maxRefs > 0),
          ),
        );
    final generateModel = generate == null
        ? null
        : ref.watch(mediaCatalogProvider.select((c) => c.resolve(generate.model, generate.kind)?.model));
    // 引用追问: the passage waiting above this conversation's composer.
    final quote = ref.watch(composerQuoteProvider.select((quotes) => quotes[_draftKey]));
    // Mirror _send for ordinary text; attachments, quotes and generation
    // stay messages even while a question is waiting.
    final answerInComposer =
        (chat?.singleQuestion ?? false) && approval == null && _drafts.isEmpty && quote == null && generate == null;
    final modelDefaultWarning = sessionId != null && chat?.error == null && (chat?.defaultModelSaveFailed ?? false);
    final error = sessionId == null
        ? _localError
        : chat?.error ?? (modelDefaultWarning ? l10n.engineModelDefaultSaveFailed : null);
    // An error wins the slot; a notice shows when there is none.
    final notice = error == null && sessionId != null ? chat?.notice : null;
    // A phone on its side with the keyboard up keeps a strip of chat: the
    // header and the dock step aside until the keyboard goes, so the latest
    // messages stay in sight above the composer.
    final typing =
        MediaQuery.sizeOf(context).height < WindowClass.compactHeight && MediaQuery.viewInsetsOf(context).bottom > 0;
    // 权限进了输入栏控制行的「模式」胶囊（B2），不再顶在输入栏上方；这里只
    // 剩生成模式的胶囊（「图像 · 3:4 · 2 张」）。生成中权限仍由活动条旁边
    // 的 _stripRisk 报一句，安全信息不进菜单。
    final running = chat?.running ?? false;
    final pillsBesideStrip = sessionId != null && running && !typing;
    final pillsInCapsules = !readOnly && !running && !typing;
    final composerPills = _composerPills(readOnly ? null : generate);
    final headerHeight = typing ? MediaQuery.paddingOf(context).top + AppSpace.sm : ChatHeader.heightOf(context);

    Widget backdrop(Widget child) {
      final framed = widget.backdrop ? WallpaperBackdrop(child: child) : child;
      return _toTop == null ? framed : PrimaryScrollController(controller: _toTop, child: framed);
    }

    final screen = AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(Theme.of(context).brightness),
      child: backdrop(
        Scaffold(
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: true,
          // The pet stands over the page on the capsules above the
          // composer (they report themselves with PetPerch).
          body: NativeComposerScope(
            host: _nativeHost,
            ref: ref,
            child: PetStage(
              sessionId: sessionId,
              aside: typing,
              child: CustomMultiChildLayout(
                delegate: _ChatLayout(_veilHeight),
                children: [
                  LayoutId(
                    id: _Slot.body,
                    child: collabMode != ConversationMode.chat
                        ? ConversationModeHost(
                            mode: collabMode,
                            header: _collabHeader,
                            topInset: headerHeight,
                            // 议会/团队发消息时从这条会话的历史里检索资料。
                            parentSessionId: sessionId,
                          )
                        : sessionId == null || idleBlank
                        ? Padding(
                            padding: EdgeInsets.only(top: headerHeight, bottom: AppSpace.sm),
                            child: Align(
                              // B3：整块靠左上（原来居中偏上），下面留白给输入条。
                              alignment: const Alignment(0, -0.42),
                              child: SingleChildScrollView(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // The on-device engine stopped on its
                                    // own (a remote host has its own errors).
                                    if (failureCard)
                                      const EngineFailureCard(padding: EdgeInsets.fromLTRB(16, 0, 16, 20)),
                                    ChatEmptyState(
                                      connected: connected,
                                      tips: _emptyTips,
                                      suggestions: ref.watch(settingsProvider.select((s) => s.chatSuggestions))
                                          ? defaultSuggestions
                                          : const [],
                                      connecting: connAsync.isLoading,
                                      starting: starting,
                                      tidying: tidying,
                                      idle: idle,
                                      onReconnect: connAsync.hasError && !connAsync.isLoading && !failureCard
                                          ? _reconnect
                                          : null,
                                      onSuggestion: _onSuggestion,
                                      options: NewChatOptions(
                                        folderLabel: !hasFolders
                                            ? null
                                            : newFolder == null
                                            ? context.l10n.shellFolders
                                            : context.l10n.shellFolderLabel(newFolder.name),
                                        onFolder: hasFolders ? _pickNewChatFolder : null,
                                      ),
                                      workspace: workspace != null
                                          ? workspaceTitle(workspace)
                                          : inHostDefault
                                          ? context.l10n.viewEmptyHostDefaultDirectory
                                          : null,
                                      onWorkspace: () => showWorkspaceSheet(
                                        context,
                                        onManage: () =>
                                            Navigator.of(context)
                                                .push(MaterialPageRoute<void>(builder: (_) => const WorkspacesPage())),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          )
                        : _ChatTextScale(
                            child: MediaCardActions(
                              regenerate: readOnly ? null : (meta) => unawaited(_regenerateMedia(sessionId, meta)),
                              revise: readOnly || !mediaReady ? null : _reviseMedia,
                              edit: readOnly || !mediaEdit
                                  ? null
                                  : (meta, item) => unawaited(_reuseMedia(sessionId, meta, item, video: false)),
                              makeVideo: readOnly || !mediaVideo
                                  ? null
                                  : (meta, item) => unawaited(_reuseMedia(sessionId, meta, item, video: true)),
                              // Keyed by conversation: opening another one fades it in.
                              child: FluidFadeIn(
                                key: ValueKey(sessionId),
                                child: EdgeFade(
                                  // 顶部渐隐长度 = 状态栏 + 顶栏 + 48dp(headerHeight 已含 8dp)。
                                  // 原来只留 16dp 的尾巴，透明度在这么短的距离里走完，
                                  // 看着仍像一条带子；拉长到 48dp 才是「字慢慢没了」。
                                  top: headerHeight + 48,
                                  // B1 的顶栏没有胶囊了:顶栏那一段压到全透明,
                                  // 消息只在顶栏底边以下 48dp 里淡入。
                                  topHold: headerHeight,
                                  // 底部不再渐隐：消息区已裁在输入栏上沿，正文不会
                                  // 出现在玻璃下面，也就没有「字透出来」的问题。
                                  bottom: _zeroFade,
                                  child: ChatList(
                                    key: ValueKey(sessionId),
                                    sessionId: sessionId,
                                    toTop: _toTop,
                                    topInset: headerHeight,
                                    // 列表已在输入栏上方结束：不再需要「伸到输入栏
                                    // 下面」的留白或按输入栏高度做底部渐隐。
                                    bottomInset: _ChatLayout.overlap,
                                    scrolledUnder: _scrolledUnder,
                                    onWithdraw: _withdraw,
                                    onSendNow: _sendNow,
                                    onEditPrompt: _compose,
                                    onResend: _resend,
                                    onQuote: readOnly ? null : (passage) => _quote(sessionId, passage),
                                    onToast: _composerToast,
                                    onSwitchModel: readOnly ? null : _switchModel,
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
                  LayoutId(
                    id: _Slot.pluginOverlay,
                    // 协作模式不叠聊天会话的插件浮层。
                    child: collabMode != ConversationMode.chat
                        ? const SizedBox.shrink()
                        : ClipRect(
                            child: MediaQuery(
                              // The layout already reserves the native chrome and keyboard.
                              data: MediaQuery.of(context)
                                  .copyWith(padding: EdgeInsets.zero, viewInsets: EdgeInsets.zero),
                              child: PluginOverlayLayer(sessionId: sessionId),
                            ),
                          ),
                  ),
                  LayoutId(
                    id: _Slot.header,
                    child: _HeaderAside(
                      aside: typing,
                      // v4：三种模式共用真正的 ChatHeader。协作模式的标题/
                      // 状态/菜单由模式视图发布过来，顶部结构完全一致。
                      child: collabMode != ConversationMode.chat
                          ? ValueListenableBuilder<CollabHeaderInfo?>(
                              valueListenable: _collabHeader,
                              builder: (context, info, _) => ChatHeader(
                                title: info?.title ?? collabMode.label,
                                status: HeaderStatus(
                                  info?.failed == true
                                      ? StatusTone.error
                                      : (info?.busy ?? false)
                                      ? StatusTone.busy
                                      : StatusTone.ok,
                                  info?.subtitle ?? '',
                                ),
                                onOpenDrawer: widget.onOpenDrawer,
                                // S5：新对话是类型入口，顶栏那枚只是徽标。
                                onNewChat: () => _pickNewConversation(collabMode),
                                newChatKey: _newChatAnchor,
                                onTitleTap: info?.onTitleTap,
                                trailing: null,
                                mode: collabMode,
                                moreOverride: _CollabMoreKey(info: info),
                              ),
                            )
                          : ChatHeader(
                              scrolledUnder: sessionId == null ? null : _scrolledUnder,
                              title: title,
                              status: status,
                              detail: !narrow || isChild
                                  ? null
                                  : folderLabel(
                                      ref.watch(
                                        sessionsProvider.select(
                                          (s) => s.value
                                              ?.where((session) => session.sessionId == sessionId)
                                              .firstOrNull
                                              ?.cwd,
                                        ),
                                      ),
                                    ),
                              onOpenDrawer: widget.onOpenDrawer,
                              // S5：新对话是「会话类型」的唯一入口，空态也要在，
                              // 否则还没有会话时就建不了议会/团队。
                              onNewChat: isChild ? null : () => _pickNewConversation(ConversationMode.chat),
                              newChatKey: isChild ? null : _newChatAnchor,
                              // 第 4 步：语音通话搬进输入栏，顶栏这一格留给「伙伴」。
                              onCompanion: isChild ? null : () => openAppMode(context, AppMode.companion),
                              // The title pill opens the whole session's details (on a
                              // wide window it folds and unfolds the panel beside us).
                              onTitleTap: sessionId == null
                                  ? null
                                  : () => SessionDetailPage.open(context, sessionId, toggle: true),
                              // B5：模型选择搬进输入栏（控制行的厂商图标），顶栏
                              // 不再占一格写模型名，标题拿回整行宽度。子代理对话
                              // 本来就没有模型 chip：它的模型由上级路由。
                              trailing: null,
                              // v4：模式徽标在右侧操作区；子代理对话不参与模式切换。
                              // S5/D2：徽标只显示类型，切换入口在「新对话」。
                              mode: isChild ? null : ConversationMode.chat,
                            ),
                    ),
                  ),
                  LayoutId(
                    id: _Slot.palette,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: AppSpace.floatingWidth),
                        child: ListenableBuilder(
                          listenable: Listenable.merge([_input, _mentions]),
                          builder: (context, _) {
                            // The `@` word at the caret wins over a "/" line.
                            final live = connected && !readOnly;
                            final mention = live && _mentions.isOpen;
                            final content = live && !mention ? _slashContent(commands) : null;
                            // The pet steps aside while a panel is up.
                            return PopScope<Object?>(
                              canPop: content == null,
                              onPopInvokedWithResult: (didPop, _) {
                                if (!didPop) _dismissSlashPalette();
                              },
                              child: PetCover(
                                active: mention || content != null,
                                child: AnimatedSwitcher(
                                  duration: AppMotion.of(context, AppMotion.quick),
                                  switchInCurve: AppMotion.enter,
                                  switchOutCurve: AppMotion.exit,
                                  transitionBuilder: (child, animation) => FadeTransition(
                                    opacity: animation,
                                    child: ScaleTransition(
                                      alignment: Alignment.bottomCenter,
                                      scale: Tween(begin: 0.96, end: 1.0).animate(animation),
                                      child: child,
                                    ),
                                  ),
                                  child: mention
                                      ? MentionPicker(key: const ValueKey('mention'), controller: _mentions)
                                      : content == null
                                      ? const SizedBox(key: ValueKey('none'), width: double.infinity)
                                      : TextFieldTapRegion(
                                          key: ValueKey(content is PaletteHint),
                                          groupId: _composerGroup,
                                          onTapOutside: (_) => _dismissSlashPalette(),
                                          child: SlashPalette(content: content, onPick: _pick),
                                        ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  LayoutId(
                    id: _Slot.composer,
                    // 协作模式的输入栏在模式视图里（同一套 Composer）；
                    // 这里不再叠一条聊天输入栏。
                    child: collabMode != ConversationMode.chat
                        ? const SizedBox.shrink()
                        : _ComposerBottom(
                            child: Padding(
                              // A little air above the (transparent) gesture bar;
                              // 12 at the sides like the header's keys above.
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: AppSpace.floatingWidth),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      // Banners are capsules too: the pet stands on
                                      // the topmost one (an empty slot is 0 high).
                                      PetPerch(
                                        kind: PerchKind.banner,
                                        child: SmoothSize(
                                          duration: AppMotion.of(context, AppMotion.standard),
                                          curve: AppMotion.std,
                                          alignment: Alignment.bottomCenter,
                                          child: connected && sessionId != null && !(chat?.controlReady ?? true)
                                              ? Padding(
                                                  padding: const EdgeInsets.only(bottom: 8),
                                                  child: ErrorBanner(
                                                    maxLines: null,
                                                    info: !(chat?.streamLost ?? false),
                                                    message: chat?.streamLost ?? false
                                                        ? chat?.syncError ?? l10n.stateChatSyncInterrupted
                                                        : l10n.stateChatSynchronizing,
                                                    action: chat?.resyncing ?? false
                                                        ? null
                                                        : (
                                                            label: l10n.stateChatSyncRetry,
                                                            onPressed: () {
                                                              unawaited(
                                                                ref.read(chatProvider(sessionId).notifier).resync(),
                                                              );
                                                            },
                                                          ),
                                                  ),
                                                )
                                              : error == null && notice == null
                                              ? const SizedBox(width: double.infinity)
                                              : notice != null
                                              ? Padding(
                                                  padding: const EdgeInsets.only(bottom: 8),
                                                  child: ErrorBanner(
                                                    info: true,
                                                    message: notice,
                                                    onDismiss: () =>
                                                        ref.read(chatProvider(sessionId!).notifier).dismissNotice(),
                                                  ),
                                                )
                                              : Padding(
                                                  padding: const EdgeInsets.only(bottom: 8),
                                                  child: ErrorBanner(
                                                    message: error!,
                                                    onDismiss: () {
                                                      if (sessionId == null) {
                                                        setState(() => _localError = null);
                                                      } else if (modelDefaultWarning) {
                                                        ref
                                                            .read(chatProvider(sessionId).notifier)
                                                            .dismissDefaultModelSaveWarning();
                                                      } else {
                                                        ref.read(chatProvider(sessionId).notifier).dismissError();
                                                      }
                                                    },
                                                  ),
                                                ),
                                        ),
                                      ),
                                      PetPerch(
                                        kind: PerchKind.banner,
                                        child: SmoothSize(
                                          duration: AppMotion.of(context, AppMotion.standard),
                                          curve: AppMotion.std,
                                          alignment: Alignment.bottomCenter,
                                          child: connected
                                              ? const _BalanceBannerSlot()
                                              : const SizedBox(width: double.infinity),
                                        ),
                                      ),
                                      // Safe mode / trial banner; draws nothing otherwise.
                                      const PetPerch(
                                        kind: PerchKind.banner,
                                        child: SafeModeBanner(padding: EdgeInsets.only(bottom: 8)),
                                      ),
                                      if (connected && sessionId != null)
                                        PetPerch(
                                          kind: PerchKind.banner,
                                          child: UnknownResultsBanner(
                                            sessionId: sessionId,
                                            padding: const EdgeInsets.only(bottom: 8),
                                          ),
                                        ),
                                      SmoothSize(
                                        duration: AppMotion.of(context, AppMotion.standard),
                                        curve: AppMotion.std,
                                        alignment: Alignment.bottomLeft,
                                        child: switch (pillsInCapsules ? null : composerPills) {
                                          final pill? => Padding(
                                            padding: const EdgeInsets.only(bottom: 8),
                                            child: Align(
                                              alignment: Alignment.centerLeft,
                                              child: PetPerch(kind: PerchKind.banner, child: pill),
                                            ),
                                          ),
                                          null => const SizedBox(width: double.infinity),
                                        },
                                      ),
                                      // The status bars as one deck: the todo and
                                      // goal bars (official input dock), the
                                      // activity strip, a plugin's status line;
                                      // each zero high when empty. Folded, they take
                                      // one row (dock_stack.dart). They fold away
                                      // while a phone on its side types.
                                      _DockAside(
                                        aside: typing,
                                        child: BackdropGroup(
                                          child: DockStack(
                                            cards: [
                                              if (sessionId != null) ...[
                                                TodoDockSlot(sessionId: sessionId),
                                                GoalDockSlot(sessionId: sessionId),
                                                ActivityStripSlot(
                                                  sessionId: sessionId,
                                                  onTap: () => _openRunningTrajectory(sessionId),
                                                  // The todo bar shows it, unless it is folded behind the strip.
                                                  todoProgress: ref.watch(dockFoldedProvider),
                                                ),
                                              ],
                                              // It gives the activity strip its place while a reply generates.
                                              if (!readOnly) ComposerStripSlot(sessionId: sessionId, visible: !running),
                                            ],
                                            accessory: pillsBesideStrip
                                                ? _stripRisk(sessionId, autoApprove: chat?.autoApprove ?? false)
                                                : null,
                                          ),
                                        ),
                                      ),
                                      // The capsules (ui.json's and plugins'), led
                                      // by the chat's pills; they step aside while a
                                      // reply generates; nothing at all without any.
                                      if (!readOnly)
                                        _DockAside(
                                          aside: typing,
                                          child: NativeComposerBar(
                                            sessionId: sessionId,
                                            visible: !running,
                                            leading: pillsInCapsules ? composerPills : null,
                                            strip: false,
                                          ),
                                        ),
                                      if (_preparedPhoneSkill case final prepared?)
                                        Card(
                                          child: Padding(
                                            padding: const EdgeInsets.all(12),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.stretch,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(l10n.phoneSkillReplayReview),
                                                SelectableText(prepared.text),
                                                Row(
                                                  children: [
                                                    TextButton(
                                                      onPressed: _phoneSkillSending
                                                          ? null
                                                          : () => setState(_dropPreparedPhoneSkill),
                                                      child: Text(l10n.commonClose),
                                                    ),
                                                    FilledButton(
                                                      onPressed: _phoneSkillSending || readOnly || !connected
                                                          ? null
                                                          : _sendPhoneSkill,
                                                      child: Text(l10n.phoneSkillReplayQueue),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      if (readOnly)
                                        const ReadOnlyBar()
                                      else
                                        Composer(
                                          hardwareEnterSends: ref.watch(
                                            settingsProvider.select((s) => s.hardwareEnterSends),
                                          ),
                                          controller: _input,
                                          groupId: _composerGroup,
                                          // The page's context: Scaffold drops the keyboard inset below.
                                          maxLines: Composer.linesFor(context),
                                          tight: Composer.tightFor(context),
                                          focusNode: _focus,
                                          connected: connected,
                                          running: chat?.running ?? false,
                                          stopping: chat?.stopping ?? false,
                                          sessionReady: chat?.controlReady ?? true,
                                          busy: _creating != null || _syncWait != null,
                                          // The header, the tool row and the strip
                                          // already say an approval waits: the hint
                                          // stays the plain one.
                                          waiting: approval != null || question != null,
                                          modeLabel: question == null
                                              ? null
                                              : answerInComposer
                                              ? l10n.chatAnswerMode
                                              : l10n.chatMessageMode,
                                          waitHint: approval != null
                                              ? null
                                              : answerInComposer
                                              ? l10n.chatAnswerHint
                                              : question != null
                                              ? l10n.commonWaitingAnswer
                                              : null,
                                          placeholder: generate == null
                                              ? null
                                              : _editing && !generate.isVideo
                                              ? l10n.mediaHintEdit
                                              : generate.isVideo
                                              ? l10n.mediaHintVideo
                                              : l10n.mediaHintImage,
                                          onSend: _send,
                                          onSendOptions: chat?.controlReady ?? true ? _sendOptions : null,
                                          voice: _voice,
                                          onKeyEvent: _composerKey,
                                          onContentInserted: connected ? _pasteContent : null,
                                          onStop: _stop,
                                          hasAttachments: _drafts.isNotEmpty,
                                          leading: AttachButton(onPressed: connected ? _attach : null),
                                          onCall: isChild ? null : _callFromHeader,
                                          // B2：控制行左边的模式胶囊（新对话管预设与权限，
                                          // 已有会话管权限）。
                                          modePill: ComposerModePill(sessionId: sessionId),
                                          // v2：协作入口搬到左上角，输入栏不再放协作键。
                                          // B5：模型键跟着输入栏，显示当前模型是哪一家。
                                          modelKey: isChild
                                              ? null
                                              : ModelBrandMark(
                                                  key: const ValueKey('composer-model'),
                                                  brand: brandOf(effectiveModel?.provider, modelName),
                                                  semanticLabel: [
                                                    l10n.viewModelLabel(modelName),
                                                    if (effectiveModel?.reasoningEffort case final effort?)
                                                      l10n.viewModelEffortLabel(effortLabel(effort)),
                                                  ].join(l10n.viewListSeparator),
                                                  onTap: () => unawaited(_showModelSheet()),
                                                ),
                                          tray: ComposerTrayStack.maybe(
                                            quote: switch (quote) {
                                              final quote? => QuoteChip(
                                                quote: quote,
                                                onRemove: () =>
                                                    ref.read(composerQuoteProvider.notifier).clear(_draftKey),
                                              ),
                                              null => null,
                                            },
                                            attachments: _drafts.isEmpty
                                                ? null
                                                : ComposerTray(
                                                    items: _drafts,
                                                    onRemove: _removeDraft,
                                                    labels: frameLabels(generate, generateModel, _drafts.length),
                                                  ),
                                          ),
                                          accessory: sessionId == null || contextFraction == null
                                              ? null
                                              : ContextRing(
                                                  fraction: contextFraction,
                                                  onTap: () => _openUsage(sessionId, chat?.model),
                                                ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return UiTrace(scope: 'chat', child: screen);
  }

  /// 生成模式的胶囊（「图像 · 3:4 · 2 张」）；没在生成时 null。
  Widget? _composerPills(GenerateParams? generate) {
    if (generate == null) return null;
    return GenerateCapsule(params: generate, onTap: () => _openGenerateSheet(generate), onExit: _exitGenerate);
  }

  /// 「自动允许中」/「完全权限」 beside the activity strip while a reply generates.
  Widget? _stripRisk(String sessionId, {required bool autoApprove}) {
    if (autoApprove) {
      return StripRiskChip.autoApprove(
        context,
        onDisable: () => ref.read(chatProvider(sessionId).notifier).setAutoApprove(false),
      );
    }
    final risky = ref.watch(sessionModesProvider(sessionId).select((m) => m.risky ? m.preset : null));
    if (risky == null) return null;
    return StripRiskChip.permission(
      context,
      preset: risky,
      onTap: () => unawaited(showPermissionSheet(context, sessionId)),
    );
  }

  /// A capsule or a plugin's `insert`: into the composer at the caret as a
  /// word of its own, focused. Never sent.
  void _insertText(String text) {
    _input.value = insertComposerToken(_input.value, text);
    _focus.requestFocus();
  }

  /// The activity strip: the running turn's trajectory.
  void _openRunningTrajectory(String sessionId) {
    final turn = ref.read(chatProvider(sessionId)).runningTurn?.turn;
    if (turn == null) return;
    showTrajectorySheet(context, sessionId: sessionId, turn: turn);
  }

  static HeaderStatus _status({
    required bool connecting,
    required bool starting,
    required bool connected,
    String? idleLabel,
    required bool streamLost,
    required bool syncing,
    required String label,
    required DshConnectionState? connection,
    required bool running,
    required bool stopping,
    required String? waiting,
    String? spoken,
  }) {
    if (!connected) {
      if (starting) return HeaderStatus(StatusTone.busy, appL10n.chatStarting);
      return connecting
          ? HeaderStatus(StatusTone.busy, appL10n.chatConnecting)
          : HeaderStatus(StatusTone.idle, idleLabel ?? appL10n.commonNotConnected);
    }
    if (streamLost) {
      return HeaderStatus(StatusTone.error, appL10n.chatDisconnected);
    }
    switch (connection) {
      case DshConnectionState.reconnecting || DshConnectionState.connecting:
        return HeaderStatus(StatusTone.warn, appL10n.chatReconnecting);
      case DshConnectionState.unauthorized || DshConnectionState.closed:
        return HeaderStatus(StatusTone.error, appL10n.chatDisconnected);
      default:
        break;
    }
    if (syncing) return HeaderStatus(StatusTone.busy, appL10n.stateChatSynchronizing);
    if (stopping) return HeaderStatus(StatusTone.busy, appL10n.commonStopping);
    if (waiting != null) {
      return HeaderStatus(StatusTone.warn, waiting, spoken: spoken);
    }
    if (running) {
      return HeaderStatus(StatusTone.busy, appL10n.chatGenerating, spoken: spoken);
    }
    return HeaderStatus(StatusTone.ok, label, spoken: spoken);
  }
}

/// 议会/团队的 ⋯ 菜单：成员管理排第一，其余动作由模式视图发布。
/// 外观与普通聊天的 ⋯ 完全一致（44dp、同一枚图标）。
class _CollabMoreKey extends StatelessWidget {
  const _CollabMoreKey({required this.info});

  final CollabHeaderInfo? info;

  @override
  Widget build(BuildContext context) {
    final actions = info?.actions ?? const <CollabMenuAction>[];
    if (actions.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: headerPieceGap),
      child: PopupMenuButton<CollabMenuAction>(
        key: const ValueKey('chat-more'),
        tooltip: '更多',
        padding: EdgeInsets.zero,
        position: PopupMenuPosition.under,
        onSelected: (action) {
          if (!action.enabled) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(content: Text(action.disabledReason ?? '这个功能当前不可用')),
            );
            return;
          }
          action.onTap();
        },
        itemBuilder: (context) => [
          for (final action in actions)
            PopupMenuItem<CollabMenuAction>(
              key: ValueKey(action.key),
              value: action,
              enabled: action.enabled,
              child: Row(
                children: [
                  if (action.icon case final icon?) ...[
                    Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 12),
                  ],
                  Flexible(
                    child: Text(
                      action.enabled
                          ? action.label
                          : '${action.label}（${action.disabledReason ?? '当前不可用'}）',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: action.enabled ? null : theme.colorScheme.outline,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
        child: SizedBox.square(
          dimension: 44,
          child: Center(child: Icon(AppIcons.more, size: 22, color: theme.colorScheme.onSurface)),
        ),
      ),
    );
  }
}

/// The chat screen's composer, lent to plugin controls and capsules.
class _ChatComposerHost implements NativeComposerHost {
  _ChatComposerHost(this._state);

  final _ChatScreenState _state;

  @override
  String? get sessionId => _state.ref.read(currentSessionProvider);

  @override
  Object get draftOwner => _state._draftScope;

  @override
  String get draft => _state._input.text;

  @override
  void insert(String text) => _state._insertText(text);

  @override
  BuildContext? get context => _state.mounted ? _state.context : null;
}

/// 低余额横幅的位置:没有要说的时候是零高。
class _BalanceBannerSlot extends ConsumerWidget {
  const _BalanceBannerSlot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final show = ref.watch(balanceProvider.select((b) => b.showBanner));
    if (!show) return const SizedBox(width: double.infinity);
    return const Padding(padding: EdgeInsets.only(bottom: 8), child: LowBalanceBanner());
  }
}

/// The dock (todo / goal bars, the run strip) folding toward the composer
/// while a phone on its side types ([aside]).
///
/// Nothing but pass-through boxes at rest (no clip, no layer): the bars'
/// shadows and shared glass stay as they are, and the bars stay mounted, so
/// an open checklist is still open when the keyboard goes.
class _DockAside extends StatefulWidget {
  const _DockAside({required this.aside, required this.child});

  final bool aside;
  final Widget child;

  @override
  State<_DockAside> createState() => _DockAsideState();
}

class _DockAsideState extends State<_DockAside> with SingleTickerProviderStateMixin {
  late final AnimationController _shown = AnimationController(vsync: this, value: widget.aside ? 0 : 1);
  late final Animation<double> _height = CurvedAnimation(parent: _shown, curve: AppMotion.std);

  @override
  void didUpdateWidget(_DockAside oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.aside == oldWidget.aside) return;
    _shown.duration = AppMotion.of(context, AppMotion.standard);
    if (widget.aside) {
      _shown.reverse();
    } else {
      _shown.forward();
    }
  }

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _height,
    child: widget.child,
    builder: (context, child) {
      final t = _height.value;
      return IgnorePointer(
        ignoring: widget.aside,
        child: ExcludeSemantics(
          excluding: t == 0,
          child: TickerMode(
            enabled: t > 0,
            child: Align(
              alignment: Alignment.bottomCenter,
              heightFactor: t,
              // Gone before the space closes, so nothing shows over the
              // chat while it folds.
              child: Opacity(opacity: ((t - 0.4) / 0.6).clamp(0.0, 1.0), child: child),
            ),
          ),
        ),
      );
    },
  );
}

/// The header, stepping aside ([aside]) for the keyboard on a phone on its
/// side: it fades and lifts away, and a plain fade under the status bar
/// takes its place so the chat scrolling up there still reads cleanly.
class _HeaderAside extends StatelessWidget {
  const _HeaderAside({required this.aside, required this.child});

  final bool aside;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.of(context, AppMotion.standard);
    return Stack(
      // The header's own fade runs past its bar.
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: aside ? 1 : 0,
              duration: duration,
              curve: AppMotion.std,
              child: TopFade(height: MediaQuery.paddingOf(context).top + 12),
            ),
          ),
        ),
        IgnorePointer(
          ignoring: aside,
          child: ExcludeSemantics(
            excluding: aside,
            child: AnimatedSlide(
              offset: aside ? const Offset(0, -0.2) : Offset.zero,
              duration: duration,
              curve: AppMotion.std,
              child: AnimatedOpacity(opacity: aside ? 0 : 1, duration: duration, curve: AppMotion.std, child: child),
            ),
          ),
        ),
      ],
    );
  }
}

enum _Slot { body, pluginOverlay, header, palette, composer }

/// 整页布局:先排输入条区域,挂在它上沿的东西(列表的下沿、斜杠面板)在
/// 同一次布局里跟上。列表本体铺满整屏(A1 边缘渐隐),内容滚到输入栏后面
/// 由 EdgeFade 渐隐。
///
/// 不走「帧后报高度、下一帧再 setState」:那样胶囊升起 / 收回的每一帧列表
/// 都晚一拍,最后一条消息和胶囊之间时而压住、时而露出一道缝。
class _ChatLayout extends MultiChildLayoutDelegate {
  _ChatLayout(this.veilHeight);

  /// 列表底部与输入条上沿之间的呼吸：列表已裁在输入条上方，这里只留
  /// 一点点空隙，最后一行不贴着玻璃边。
  static const overlap = 6.0;

  /// 斜杠面板离屏幕两边、离输入条上沿的距离。
  static const _side = 12.0;
  static const _gap = 6.0;

  /// 输入栏高度。A1 前写给底色遮罩;现在作为列表的 bottomExtent 和
  /// composer toast 的定位高度。
  final ValueNotifier<double> veilHeight;

  @override
  void performLayout(Size size) {
    final width = size.width;
    // Height unbounded, as under a bottom-anchored Positioned: the slots
    // shrink-wrap their content (their Centers would fill a bounded height).
    final along = BoxConstraints(minWidth: width, maxWidth: width);
    final composer = layoutChild(_Slot.composer, along);
    final top = size.height - composer.height;
    positionChild(_Slot.composer, Offset(0, top));
    // A1 边缘渐隐:列表铺满整屏,内容滚到输入栏后面由 EdgeFade 渐隐。
    // veilHeight 现在存的是输入栏高度(给列表 bottomExtent 和 toast 定位)。
    // 通知放到这一帧之后:布局里同步 setState 会触发
    // 「Build scheduled during frame」(输入栏随键盘变高的那一帧)。
    if (veilHeight.value != composer.height) {
      final height = composer.height;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (veilHeight.value != height) veilHeight.value = height;
      });
    }

    // 真正的布局分离（方案第二部分）：消息区只拿到输入栏**上方**的空间，
    // 不再铺满整屏让正文钻到玻璃底下。最后一行因此一定完整可见；
    // 输入栏多行/附件托盘/键盘长高时 top 跟着变，消息区自动让位。
    layoutChild(_Slot.body, BoxConstraints.tight(Size(width, math.max(0, top))));
    positionChild(_Slot.body, Offset.zero);
    final header = layoutChild(_Slot.header, along);
    positionChild(_Slot.header, Offset.zero);
    // Web content cannot paint or receive touches on native navigation/input.
    layoutChild(_Slot.pluginOverlay, BoxConstraints.tight(Size(width, math.max(0, top - header.height))));
    positionChild(_Slot.pluginOverlay, Offset(0, header.height));

    final paletteWidth = math.max(0.0, width - 2 * _side);
    final palette = layoutChild(_Slot.palette, BoxConstraints(minWidth: paletteWidth, maxWidth: paletteWidth));
    positionChild(_Slot.palette, Offset(_side, top - _gap - palette.height));
    if (uiTraceEnabled) {
      uiTrace('chat', 'slots', {
        'width': size.width,
        'height': size.height,
        'composerHeight': composer.height,
        'composerTop': top,
        'bodyHeight': top,
        'paletteHeight': palette.height,
      });
    }
  }

  @override
  bool shouldRelayout(_ChatLayout oldDelegate) => oldDelegate.veilHeight != veilHeight;
}

/// Applies the 对话字号 setting to chat content only (header and composer
/// keep the system size), on top of the system font scale.
class _ChatTextScale extends ConsumerWidget {
  const _ChatTextScale({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final factor = ref.watch(settingsProvider.select((s) => s.chatTextScale));
    if (factor == 1.0) return child;
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(textScaler: _ChatScaler(media.textScaler, factor)),
      child: child,
    );
  }
}

/// The chat size on top of the system's: Android 14 scales large text less
/// than small, and that curve is kept.
class _ChatScaler extends TextScaler {
  const _ChatScaler(this.base, this.factor);
  final TextScaler base;
  final double factor;

  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  @override
  double get textScaleFactor => scale(1);

  @override
  bool operator ==(Object other) => other is _ChatScaler && other.base == base && other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);
}

/// 输入栏底部的留白（2026-11-23 修正）。
///
/// 之前这里无条件套 `SafeArea(minimum: bottom 8)`：外壳（TabShell）已经把整页
/// 抬到「导航高度 + 8 + 安全区」之上，SafeArea 又加了一遍安全区和 8dp，
/// 输入栏与底部导航之间就多出 30–50dp 的空隙，看着"隔得太远"。
///
/// 现在：在外壳里只用 8dp（安全区由外壳让出）；不在外壳里（宽屏/独立页面）才走 SafeArea。
class _ComposerBottom extends StatelessWidget {
  const _ComposerBottom({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (ShellInsets.maybeOf(context) != null) {
      return Padding(padding: const EdgeInsets.only(bottom: 8), child: child);
    }
    return SafeArea(top: false, minimum: const EdgeInsets.only(bottom: 8), child: child);
  }
}
