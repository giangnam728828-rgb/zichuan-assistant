// A group chat: every message with its speaker's face and name, the round's
// events, who speaks now, members waiting for approval, the `@` member
// picker over the chat's composer.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/settings_state.dart';
import '../../state/bots_state.dart';
import '../chat/composer.dart';
import '../chat/widgets/chat_card.dart';
import '../common/status_dot.dart';
import '../features/feature_kit.dart';
import '../shell/page_frame.dart';
import 'bot_stop_guard.dart';
import 'bot_action_scope.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../providers/provider_brand_icon.dart';
import 'bot_draft_send.dart';
import 'bot_avatar.dart';
import 'unavailable_message.dart';
import 'bot_chat_kit.dart';
import 'bot_chat_page.dart';
import 'bot_format.dart';
import 'bot_mention.dart';
import 'room_approval_action.dart';
import 'room_details_page.dart';
import 'room_full_text_sheet.dart';

class RoomChatPage extends ConsumerStatefulWidget {
  const RoomChatPage({super.key, required this.roomId, this.modeWarning, this.wantMode});

  final String roomId;

  /// 建好讨论室但协作方式没设上时的原因；进页面后仍可重试。
  final String? modeWarning;
  final String? wantMode;

  static Route<void> route(String roomId, {String? modeWarning, String? wantMode}) => MaterialPageRoute<void>(
    builder: (_) => RoomChatPage(roomId: roomId, modeWarning: modeWarning, wantMode: wantMode),
  );

  @override
  ConsumerState<RoomChatPage> createState() => _RoomChatPageState();
}

class _RoomChatPageState extends ConsumerState<RoomChatPage> {
  Object? _continueScope;
  int _continueRequest = 0;
  bool _continuing = false;
  String? _continuedPause;
  late final BotStopGuard _stopGuard;
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scrolled = ValueNotifier(0.0);
  late final DsBotViewingController _viewing;
  late final BotMentionController _mentions = BotMentionController(input: _input);
  late String? _modeWarning = widget.modeWarning;
  bool _retryingMode = false;

  @override
  void initState() {
    super.initState();
    _stopGuard = BotStopGuard(ref);
    _viewing = ref.read(dsBotViewingProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _viewing.set(widget.roomId);
    });
  }

  @override
  void dispose() {
    _stopGuard.dispose();
    _viewing.leave(widget.roomId);
    _mentions.dispose();
    _input.dispose();
    _focus.dispose();
    _scrolled.dispose();
    super.dispose();
  }

  Future<void> _send(BotActionScope target) async {
    if (!mounted || target.roomId != widget.roomId || !target.current(context, ref)) return;
    if (!ref.read(dsBotProvider).ready) return;
    await sendBotDraft(
      context,
      ref,
      _input,
      roomId: widget.roomId,
      send: (text) => ref.read(roomChatProvider(widget.roomId).notifier).send(text),
    );
  }

  Future<void> _continue(DsBotRoom room, BotActionScope target) async {
    // The rendered button belongs to this connection and these parked calls.
    // A click may arrive after a host/boot change but before the next frame.
    if (!mounted || !target.current(context, ref)) return;
    final hub = ref.read(dsBotProvider.notifier);
    final api = target.api;
    if (api == null || _continuing) return;
    final status = ref.read(dsBotProvider);
    final pause = room.pausedCallIds.join('\u0000');
    if (_continuedPause == pause) return;
    if (!status.ready || status.team?.room(room.id)?.pausedCallIds.join('\u0000') != pause) return;
    final scope = _continueScope;
    final request = ++_continueRequest;
    bool current() =>
        mounted &&
        scope == _continueScope &&
        request == _continueRequest &&
        ref.read(dsBotProvider.notifier).api == api &&
        ref.read(dsBotProvider).host == status.host &&
        ref.read(dsBotProvider).hello?.boot == status.hello?.boot;
    setState(() => _continuing = true);
    try {
      await api.continueRoom(room.id);
      if (!current()) return;
      // The queued round clears these calls asynchronously. Do not enqueue
      // another Continue while the same parked calls remain in state.
      setState(() => _continuedPause = pause);
      await hub.refresh();
    } catch (error) {
      if (mounted && current()) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(describeDsBotError(error))));
      }
    } finally {
      if (current()) setState(() => _continuing = false);
    }
  }

  /// 引用一条发言：带回群聊输入框。
  void _quote(String text) {
    final quoted = text.split('\n').map((line) => '> $line').join('\n');
    _input.text = '$quoted\n';
    _focus.requestFocus();
  }

  /// 建好后补设协作方式失败：用当初选的那个模式再试一次。
  Future<void> _retryMode(DsBotRoom room, BotActionScope target) async {
    final api = target.api;
    if (!mounted || api == null || _retryingMode || !target.current(context, ref)) return;
    final mode = widget.wantMode ?? room.mode;
    setState(() => _retryingMode = true);
    try {
      await api.updateRoom(room.id, mode: mode);
      if (!mounted) return;
      await ref.read(dsBotProvider.notifier).refresh();
      if (mounted) {
        setState(() {
          _modeWarning = null;
          _retryingMode = false;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _modeWarning = describeDsBotError(error);
        _retryingMode = false;
      });
    }
  }

  bool _fullTextOpen = false;

  Future<void> _showAll(DsBotItem item, BotActionScope scope) async {
    if (_fullTextOpen) return;
    _fullTextOpen = true;
    try {
      await showRoomFullText(context, ref, widget.roomId, item, scope: scope);
    } finally {
      _fullTextOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // 只订阅这一页的骨架：成员、只读、连接身份。运行中的活动每一两秒就变一次，
    // 让它牵动整页会把历史消息、输入框、成员条一起拖下水；那些小块各自订阅，
    // 谁的数据变了谁重建。
    final (team, granted, host, boot, availability) = ref.watch(
      dsBotProvider.select((s) => (s.team, s.readOnly, s.host, s.hello?.boot, s.availability)),
    );
    final status = ref.read(dsBotProvider);
    final api = ref.read(dsBotProvider.notifier).api;
    final scope = (host, boot, widget.roomId, api);
    if (_continueScope != scope) {
      _continueScope = scope;
      _continueRequest++;
      _continuing = false;
      _continuedPause = null;
    }
    final room = team?.room(widget.roomId);
    final continueTarget = BotActionScope(ref, roomId: widget.roomId);
    final fullTextScope = BotActionScope(ref, roomId: widget.roomId);
    final sendTarget = BotActionScope(ref, roomId: widget.roomId);
    final mobileUnavailable =
        availability == DsBotAvailability.missing || availability == DsBotAvailability.outdated;
    if (team == null || room == null || mobileUnavailable) {
      return AppPage.list(
        title: l10n.botsGroupChat,
        children: [
          DsBotUnavailableMessage(status: status, goneIcon: AppIcons.groupChat, goneTitle: l10n.botsRoomGone),
        ],
      );
    }
    final members = [for (final id in room.members) ?team.bot(id)];
    _mentions.setMembers(members, room.admin);
    final chat = ref.watch(roomChatProvider(widget.roomId));
    final readOnly = granted != null;
    // 谁在发言：只关心“换人”这一件事，工具备注怎么变都不重建整页。
    final speakingId =
        chat.speaking ?? ref.watch(dsBotProvider.select((s) => _speakingOf(s, room.id)));
    final speaker = room.members.contains(speakingId) ? team.bot(speakingId) : null;
    final typingPhrase = speaker == null
        ? null
        : ref.watch(
            dsBotProvider.select(
              (s) => workPhrase(s.live.bots[speaker.id]) ?? l10n.botsTyping,
            ),
          );
    final typing = speaker == null ? null : BotTypingRow(speaker, l10n.botsNamedActivity(speaker.name, typingPhrase!));
    final rows = transcriptRows(chat.items, pending: chat.pending, typing: typing);
    final topInset = BotChatHeader.heightOf(context);

    return BotChatFrame(
      header: _RoomHeader(
        room: room,
        team: team,
        speaking: speakingId,
        running: chat.running,
        scrolledUnder: _scrolled,
        onDetails: () => Navigator.of(context).push(RoomDetailsPage.route(room.id)),
      ),
      body: chat.loading && chat.items.isEmpty
          ? Padding(
              padding: EdgeInsets.only(top: topInset),
              child: const QuietSpinner(),
            )
          : Column(
              children: [
                // 有人说过话时，顶部留一条紧凑的参与状态；空房间直接看成员。
                if (chat.items.isNotEmpty && members.isNotEmpty) ...[
                  SizedBox(height: topInset),
                  _RoomMemberStrip(
                    roomId: room.id,
                    members: members,
                    speaking: speakingId,
                    spoke: {
                      for (final item in chat.items)
                        if (item.kind == DsBotItemKind.bot && item.botId != null) item.botId!,
                    },
                    failed: {
                      for (final item in chat.items)
                        if (item.kind == DsBotItemKind.event && item.event == 'failed' && item.botId != null)
                          item.botId!,
                    },
                    onOpen: (bot) => Navigator.of(context).push(BotChatPage.route(bot.id)),
                  ),
                ],
                Expanded(
                  child: BotTranscript(
                    rows: rows,
                    topInset: chat.items.isEmpty ? topInset : 0,
                    scrolledUnder: _scrolled,
                    hasEarlier: chat.hasEarlier,
                    loadingEarlier: chat.loadingEarlier,
                    onEarlier: () => ref.read(roomChatProvider(widget.roomId).notifier).loadEarlier(),
                    empty: _Members(room: room, team: team),
                    rowBuilder: (context, row) => Padding(
                      padding: rowPadding(row),
                      child: switch (row) {
                        BotTimeRow(:final time) => BotTimeLine(time),
                        BotPendingRow(:final pending) => BotUserMessage(text: pending.text, pending: true),
                        BotStreamingRow() => const SizedBox.shrink(),
                        BotQuestionRow() || BotViewRow() => const SizedBox.shrink(),
                        BotTypingRow(:final bot, :final label) => BotTypingLine(bot: bot, label: label),
                        BotItemRow(:final item, :final continued) => switch (item.kind) {
                          DsBotItemKind.user => BotUserMessage(text: item.text, images: item.images),
                          DsBotItemKind.bot => GroupMessage(
                            item: item,
                            bot: team.bot(item.botId),
                            continued: continued,
                            admin: item.botId != null && item.botId == room.admin,
                            onOpenBot: team.bot(item.botId) == null
                                ? null
                                : () => Navigator.of(context).push(BotChatPage.route(item.botId!)),
                            onShowAll: item.whole == null ? null : () => _showAll(item, fullTextScope),
                            onQuote: readOnly ? null : _quote,
                          ),
                          DsBotItemKind.event => BotEventLine(
                            text: roomEventText(item),
                            danger: item.event == 'failed',
                            icon: switch (item.event) {
                              'done' => AppIcons.completed,
                              'working' => AppIcons.working,
                              'approval' => AppIcons.approval,
                              'failed' => AppIcons.error,
                              'schedule' => AppIcons.scheduled,
                              _ => null,
                            },
                          ),
                          _ => const SizedBox.shrink(),
                        },
                      },
                    ),
                  ),
                ),
              ],
            ),
      bottom: [
        if (_modeWarning case final warning?)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ChatCard(
              key: const ValueKey('room-mode-warning'),
              icon: AppIcons.error,
              title: l10n.botsModeNotSet,
              tone: ChatCardTone.attention,
              trailing: CardCloseKey(onTap: () => setState(() => _modeWarning = null)),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(ChatCard.inset, 0, ChatCard.inset, ChatCard.inset),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(warning, style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.tonal(
                          key: const ValueKey('room-mode-retry'),
                          onPressed: readOnly || _retryingMode ? null : () => _retryMode(room, continueTarget),
                          child: Text(l10n.botsModeRetry),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (room.paused)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ChatCard(
              key: const ValueKey('room-paused'),
              icon: AppIcons.paused,
              title: l10n.commonPaused,
              tone: ChatCardTone.attention,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(ChatCard.inset, 0, ChatCard.inset, ChatCard.inset),
                  child: FilledButton.icon(
                    key: const ValueKey('room-continue'),
                    onPressed:
                        api == null || readOnly || _continuing || _continuedPause == room.pausedCallIds.join('\u0000')
                        ? null
                        : () => _continue(room, continueTarget),
                    icon: const Icon(AppIcons.play, size: 18),
                    label: Text(l10n.commonContinue),
                  ),
                ),
              ],
            ),
          ),
        _RoomApprovals(roomId: room.id, team: team, api: api),
        ListenableBuilder(
          listenable: _mentions,
          builder: (context, _) => AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.quick),
            switchInCurve: AppMotion.enter,
            switchOutCurve: AppMotion.exit,
            child: _mentions.isOpen
                ? Padding(
                    key: const ValueKey('mentions'),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: BotMentionPicker(controller: _mentions),
                  )
                : const SizedBox(key: ValueKey('none'), width: double.infinity),
          ),
        ),
        BotErrorSlot(
          error: chat.error,
          onDismiss: () => ref.read(roomChatProvider(widget.roomId).notifier).dismissError(),
        ),
        Composer(
          hardwareEnterSends: ref.watch(settingsProvider.select((s) => s.hardwareEnterSends)),
          controller: _input,
          placeholder: l10n.botsGroupComposerHint,
          focusNode: _focus,
          connected: api != null && !readOnly,
          running: chat.running,
          onSend: () => _send(sendTarget),
          onStop: _stopGuard.action(roomId: room.id),
          onKeyEvent: _mentions.handleKey,
          leading: MentionKey(
            onPressed: api == null || readOnly
                ? null
                : () {
                    _mentions.start();
                    _focus.requestFocus();
                  },
          ),
        ),
      ],
    );
  }
}

/// 顶栏自己订阅运行状态：换人发言、谁在等审批才刷这一行字，
/// 不把整页（尤其是历史消息）一起重建。
class _RoomHeader extends ConsumerWidget {
  const _RoomHeader({
    required this.room,
    required this.team,
    required this.speaking,
    required this.running,
    required this.scrolledUnder,
    required this.onDetails,
  });

  final DsBotRoom room;
  final DsBotTeam team;
  final String? speaking;
  final bool running;
  final ValueNotifier<double> scrolledUnder;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final (working, approvals) = ref.watch(
      dsBotProvider.select((s) => (s.live.rooms[room.id] ?? const <DsBotWork>[], s.live.approvals)),
    );
    final waiting = [
      for (final a in approvals)
        if (a.roomId == room.id && a.answerable) a,
    ];
    final speaker = team.bot(speaking);
    final (String label, StatusTone tone) = switch (()) {
      _ when waiting.isNotEmpty => (l10n.botsMemberNeedsApproval, StatusTone.warn),
      _ when speaker != null => (l10n.botsNamedSpeaking(speaker.name), StatusTone.busy),
      _ when working.isNotEmpty => (
        l10n.botsNamedActivity(
          team.bot(working.first.botId)?.name ?? 'Bot',
          workPhrase(working.first) ?? l10n.botsWorking,
        ),
        StatusTone.busy,
      ),
      _ when running => (l10n.botsDiscussing, StatusTone.busy),
      _ when room.paused => (l10n.commonPaused, StatusTone.warn),
      _ => (l10n.botsMemberCount(room.members.length), StatusTone.ok),
    };
    return BotChatHeader(
      face: RoomAvatar(room: room, team: team, size: BotChatHeader.faceSize),
      title: room.name,
      status: label,
      tone: tone,
      // 一起写清这个房间怎么协作：全员依次答，还是先交给主持人。
      identity: Text(
        room.mode == 'everyone' ? l10n.botsModeEveryone : l10n.botsModeAdmin,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: DshColors.of(context).textTertiary, height: 1.25),
      ),
      scrolledUnder: scrolledUnder,
      onDetails: onDetails,
    );
  }
}

/// 正在发言的人：真实事件里说“speaking”的那一个。
String? _speakingOf(DsBotStatus status, String roomId) {
  for (final work in status.live.rooms[roomId] ?? const <DsBotWork>[]) {
    if (work.speaking && work.botId != null) return work.botId;
  }
  return null;
}

/// 房间里的审批卡：只在真有审批时才出现在输入框上方。
class _RoomApprovals extends ConsumerWidget {
  const _RoomApprovals({required this.roomId, required this.team, required this.api});

  final String roomId;
  final DsBotTeam team;
  final DsBotApi? api;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final approvals = ref.watch(dsBotProvider.select((s) => s.live.approvals));
    final waiting = [
      for (final a in approvals)
        if (a.roomId == roomId && a.answerable) a,
    ];
    if (waiting.isEmpty) return const SizedBox.shrink();
    final origin = ref.read(dsBotProvider);
    final api = this.api;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final approval in waiting)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: api == null
                ? GroupApprovalCard(approval: approval, bot: team.bot(approval.botId), onAnswer: null)
                : RoomApprovalAction(
                    key: ValueKey((
                      origin.host,
                      origin.hello?.boot,
                      api,
                      approval.id,
                      approval.sessionId,
                      approval.botId,
                      approval.roomId,
                    )),
                    api: api,
                    origin: origin,
                    approval: approval,
                    builder: (answer) =>
                        GroupApprovalCard(approval: approval, bot: team.bot(approval.botId), onAnswer: answer),
                  ),
          ),
      ],
    );
  }
}

/// 顶部一条紧凑的参与状态：谁在分析、谁在发言、谁已说完、谁失败了。
///
/// 状态只来自真实事件：工作列表、群聊里的失败事件、以及真的发过言的成员。
/// 不在工作列表里不等于完成——没说过话的人显示为等待中。
///
/// 自己订阅运行状态：多模型讨论时工具备注每几秒变一次，只该刷新这条，
/// 不该带动整页（历史消息尤其贵）。
class _RoomMemberStrip extends ConsumerWidget {
  const _RoomMemberStrip({
    required this.roomId,
    required this.members,
    required this.speaking,
    required this.spoke,
    required this.failed,
    required this.onOpen,
  });

  final String roomId;
  final List<DsBot> members;

  /// 正在发言的人：`chat.speaking` 可能先于 working 列表到达。
  final String? speaking;
  final Set<String> spoke;
  final Set<String> failed;
  final void Function(DsBot bot) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final (working, activity) = ref.watch(
      dsBotProvider.select((s) => (s.live.rooms[roomId] ?? const <DsBotWork>[], s.live.activity)),
    );
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
        itemCount: members.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final bot = members[index];
          final work = working.where((w) => w.botId == bot.id).firstOrNull;
          final (String label, Color color) = switch (work) {
            final work? => (
              workPhrase(work, activity: activity[bot.id]) ?? l10n.botsWorking,
              theme.colorScheme.primary,
            ),
            _ when bot.id == speaking => (l10n.botsTyping, theme.colorScheme.primary),
            _ when failed.contains(bot.id) => (l10n.commonFailed, dsh.danger),
            _ when spoke.contains(bot.id) => (l10n.commonDone, dsh.textTertiary),
            _ => (l10n.botsIdle, dsh.textTertiary),
          };
          return InkWell(
            key: ValueKey('member-state-${bot.id}'),
            borderRadius: BorderRadius.circular(14),
            onTap: () => onOpen(bot),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  BotAvatar(bot: bot, size: 18, working: work != null),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 96),
                    child: Text(
                      bot.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(label, style: theme.textTheme.labelSmall?.copyWith(color: color)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A member waiting for the user's approval inside the group.
class GroupApprovalCard extends StatefulWidget {
  const GroupApprovalCard({super.key, required this.approval, required this.bot, required this.onAnswer});

  final DsBotApproval approval;
  final DsBot? bot;

  /// Null on a read-only team: both keys disabled.
  final Future<void> Function(bool allow)? onAnswer;

  @override
  State<GroupApprovalCard> createState() => _GroupApprovalCardState();
}

class _GroupApprovalCardState extends State<GroupApprovalCard> {
  bool _busy = false;

  Future<void> _answer(bool allow) async {
    final answer = widget.onAnswer;
    // A second tap can land before the rebuild that disables the keys.
    if (_busy || answer == null) return;
    setState(() => _busy = true);
    try {
      await answer(allow);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final name = widget.bot?.name ?? 'Bot';
    final reason = widget.approval.reason.trim();
    return ChatCard(
      icon: AppIcons.approval,
      title: approvalPhrase(name, widget.approval.tool),
      tone: ChatCardTone.attention,
      children: [
        if (reason.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(ChatCard.inset, 0, ChatCard.inset, 4),
            child: Text(
              reason,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(ChatCard.inset, 8, ChatCard.inset, ChatCard.inset),
          child: Row(
            spacing: 12,
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy || widget.onAnswer == null ? null : () => _answer(false),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    side: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.5)),
                  ),
                  child: Text(l10n.botsDecline),
                ),
              ),
              Expanded(
                child: FilledButton(
                  onPressed: _busy || widget.onAnswer == null ? null : () => _answer(true),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(l10n.botsAllowOnce),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The empty group: who is in it, and which model each of them uses.
class _Members extends StatelessWidget {
  const _Members({required this.room, required this.team});

  final DsBotRoom room;
  final DsBotTeam team;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final bots = [for (final id in room.members) ?team.bot(id)];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RoomAvatar(room: room, team: team, size: 64),
        const SizedBox(height: 12),
        Text(room.name, style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          room.mode == 'everyone' ? l10n.botsModeEveryone : l10n.botsModeAdmin,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
        ),
        if (bots.isNotEmpty) ...[
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              for (final bot in bots)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    BotAvatar(bot: bot, size: 22),
                    const SizedBox(width: 6),
                    Text(bot.name, style: theme.textTheme.bodyMedium),
                    if (botModelLabel(bot) case final model?) ...[
                      const SizedBox(width: 5),
                      ProviderBrandIcon(brand: botModelBrand(bot), size: 12),
                      const SizedBox(width: 3),
                      Text(
                        model,
                        style: theme.textTheme.labelSmall?.copyWith(color: dsh.textTertiary),
                      ),
                    ],
                  ],
                ),
            ],
          ),
        ],
      ],
    );
  }
}
