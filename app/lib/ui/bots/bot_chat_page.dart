// A Bot's own chat: the whole conversation across its parts as DS Bot lays
// it out, the reply it is writing, its cards (a question, a view, a model to
// pick, a DSH approval) and the chat's composer.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/settings_state.dart';
import '../../state/bots_state.dart';
import '../../state/connection_state.dart';
import '../chat/composer.dart';
import '../chat/dsh_ui/dsh_ui.dart';
import '../chat/model_sheet.dart';
import '../chat/widgets/approval_card.dart';
import '../common/status_dot.dart';
import '../common/typing_indicator.dart';
import '../features/feature_kit.dart';
import '../providers/provider_brand_icon.dart';
import '../shell/page_frame.dart';
import 'bot_stop_guard.dart';
import 'bot_action_scope.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'bot_draft_send.dart';
import 'bot_avatar.dart';
import 'unavailable_message.dart';
import 'bot_chat_kit.dart';
import 'bot_details_page.dart';
import 'bot_format.dart';
import 'bot_pending_card.dart';

class BotChatPage extends ConsumerStatefulWidget {
  const BotChatPage({super.key, required this.botId});

  final String botId;

  static Route<void> route(String botId) => MaterialPageRoute<void>(builder: (_) => BotChatPage(botId: botId));

  @override
  ConsumerState<BotChatPage> createState() => _BotChatPageState();
}

class _BotChatPageState extends ConsumerState<BotChatPage> {
  late final BotStopGuard _stopGuard;
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scrolled = ValueNotifier(0.0);
  late final DsBotViewingController _viewing;

  @override
  void initState() {
    super.initState();
    _stopGuard = BotStopGuard(ref);
    _viewing = ref.read(dsBotViewingProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _viewing.set(widget.botId);
    });
  }

  @override
  void dispose() {
    _stopGuard.dispose();
    _viewing.leave(widget.botId);
    _input.dispose();
    _focus.dispose();
    _scrolled.dispose();
    super.dispose();
  }

  /// Whether what the person sends now still goes to this page's Bot.
  bool _sendsTo(BotActionScope target, String part) {
    if (!mounted || target.botId != widget.botId || !target.current(context, ref)) return false;
    final status = ref.read(dsBotProvider);
    return status.ready && status.team?.bot(widget.botId)?.sessionId == part;
  }

  Future<void> _send(BotActionScope target, String part) async {
    if (!_sendsTo(target, part)) return;
    final status = ref.read(dsBotProvider);
    final bot = status.team?.bot(widget.botId);
    final question = bot == null ? null : status.team?.questionOf(bot);
    final controller = ref.read(botChatProvider(widget.botId).notifier);
    // 有待回答的问题时，输入框里的字就是那个回答：走 answerQuestion 的
    // custom，而不是普通消息——否则服务端会认为问题仍没答。
    if (question != null && status.readOnly == null) {
      await sendBotDraft(
        context,
        ref,
        _input,
        botId: widget.botId,
        send: (text) => controller.answer(question.id, text),
      );
      return;
    }
    await sendBotDraft(
      context,
      ref,
      _input,
      botId: widget.botId,
      send: (text) => controller.send(text),
    );
  }

  /// A card's answer, sent as the person's message (`[dsh-ui reply] …`).
  Future<bool> _reply(BotActionScope target, String part, String text) async =>
      _sendsTo(target, part) && await ref.read(botChatProvider(widget.botId).notifier).send(text);

  /// 引用一段回复：带回输入框，按 Markdown 引用块排好。
  void _quote(String text) {
    final quoted = text.split('\n').map((line) => '> $line').join('\n');
    _input.text = '$quoted\n';
    _focus.requestFocus();
  }

  Future<void> _pickModel(DsBot bot, BotActionScope scope) => pickBotModel(context, ref, bot, scope: scope);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // 只订阅这一页的骨架：成员、只读、连接身份、这个 Bot 是不是正在跑。
    // 跑到哪一步（工具备注每几秒一换）由顶栏自己订阅，不牵动整段对话。
    final (team, granted, host, ownTurn, availability) = ref.watch(
      dsBotProvider.select(
        (s) => (
          s.team,
          s.readOnly,
          s.host,
          s.live.bots.containsKey(widget.botId) && s.live.bots[widget.botId]!.roomId == null,
          s.availability,
        ),
      ),
    );
    final status = ref.read(dsBotProvider);
    final bot = team?.bot(widget.botId);
    final mobileUnavailable =
        availability == DsBotAvailability.missing || availability == DsBotAvailability.outdated;
    if (team == null || bot == null || mobileUnavailable) {
      return AppPage.list(
        title: 'Bot',
        children: [DsBotUnavailableMessage(status: status, goneIcon: AppIcons.bot, goneTitle: l10n.botsBotGone)],
      );
    }
    final chat = ref.watch(botChatProvider(widget.botId));
    final question = team.questionOf(bot);
    final view = team.viewOf(bot);
    final api = ref.read(dsBotProvider.notifier).api;
    final rows = transcriptRows(
      chat.items,
      pending: chat.pending,
      streaming: ownTurn ? chat.streaming : null,
      // 问题与视图卡在时间线里，不再压在输入框上。
      question: api == null ? null : question,
      view: api == null ? null : view,
    );
    final topInset = BotChatHeader.heightOf(context);
    final rooms = {for (final room in team.rooms) room.id: room.name};
    final readOnly = granted != null;
    final modelScope = BotActionScope(ref, botId: bot.id);
    final sendTarget = BotActionScope(ref, botId: bot.id);

    return BotChatFrame(
      header: _BotHeader(
        bot: bot,
        team: team,
        question: question,
        view: view,
        identity: _modelIdentity(context, bot),
        scrolledUnder: _scrolled,
        onDetails: () => Navigator.of(context).push(BotDetailsPage.route(bot.id)),
      ),
      body: chat.loading && chat.items.isEmpty
          ? Padding(
              padding: EdgeInsets.only(top: topInset),
              child: const QuietSpinner(),
            )
          : BotTranscript(
              rows: rows,
              topInset: topInset,
              scrolledUnder: _scrolled,
              hasEarlier: chat.hasEarlier,
              loadingEarlier: chat.loadingEarlier,
              onEarlier: () => ref.read(botChatProvider(widget.botId).notifier).loadEarlier(),
              empty: _Intro(bot: bot),
              rowBuilder: (context, row) => Padding(
                padding: rowPadding(row),
                child: switch (row) {
                  BotTimeRow(:final time) => BotTimeLine(time),
                  BotPendingRow(:final pending) => BotUserMessage(text: pending.text, pending: true),
                  BotStreamingRow(:final text) =>
                    text.isEmpty
                        ? const Align(alignment: Alignment.centerLeft, child: _Thinking())
                        : BotReplyText(text: text, streaming: true),
                  BotTypingRow() => const SizedBox.shrink(),
                  BotQuestionRow(:final question) => api == null
                      ? const SizedBox.shrink()
                      : BotPendingCard(
                          // 身份由卡片内部的 _current() 校验（Host、boot、api、
                          // session）；key 只跟「哪一个问题」走，刷新状态时不
                          // 重建，已经点好的选项不会被清掉。
                          key: ValueKey((status.host, bot.id, bot.sessionId, question.id)),
                          api: api,
                          origin: status,
                          bot: bot,
                          question: question,
                        ),
                  BotViewRow(:final view) => api == null
                      ? const SizedBox.shrink()
                      : BotPendingCard(
                          key: ValueKey((status.host, bot.id, bot.sessionId, view.id)),
                          api: api,
                          origin: status,
                          bot: bot,
                          view: view,
                        ),
                  BotItemRow(:final item) => switch (item.kind) {
                    DsBotItemKind.user => BotUserMessage(text: item.text, images: item.images),
                    DsBotItemKind.bot => _WithCards(
                      chat: chat,
                      item: item,
                      sessionId: bot.sessionId,
                      running: ownTurn,
                      onReply: readOnly ? null : (text) => _reply(sendTarget, bot.sessionId, text),
                      child: BotReplyText(text: item.text, onQuote: readOnly ? null : _quote),
                    ),
                    DsBotItemKind.event => BotEventLine(
                      text: chatEventText(item, roomName: rooms[item.roomId]),
                      icon: AppIcons.swap,
                    ),
                    DsBotItemKind.answer => BotEventLine(text: l10n.botsAnsweredQuestion, icon: AppIcons.done),
                    DsBotItemKind.divider => BotEventLine(text: l10n.botsEarlierMessages, icon: AppIcons.history),
                    DsBotItemKind.unknown => const SizedBox.shrink(),
                  },
                },
              ),
            ),
      bottom: [
        if (bot.waiting && !readOnly)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: BotModelCard(name: bot.name, onPick: () => _pickModel(bot, modelScope)),
          ),
        _OwnApprovals(sessionId: bot.sessionId),
        BotErrorSlot(
          error: chat.error,
          onDismiss: () => ref.read(botChatProvider(widget.botId).notifier).dismissError(),
        ),
        Composer(
          hardwareEnterSends: ref.watch(settingsProvider.select((s) => s.hardwareEnterSends)),
          controller: _input,
          focusNode: _focus,
          connected: api != null && !readOnly,
          running: ownTurn || chat.answering,
          onSend: () => _send(sendTarget, bot.sessionId),
          onStop: _stopGuard.action(botId: bot.id),
          placeholder: l10n.botsComposerHint(bot.name),
        ),
      ],
    );
  }
}

/// 顶栏自己订阅这个 Bot 的运行状态：跑到哪一步只刷这行字，
/// 不把整段历史（Markdown 排版很贵）跟着重建。
class _BotHeader extends ConsumerWidget {
  const _BotHeader({
    required this.bot,
    required this.team,
    required this.question,
    required this.view,
    required this.identity,
    required this.scrolledUnder,
    required this.onDetails,
  });

  final DsBot bot;
  final DsBotTeam team;
  final DsBotQuestion? question;
  final DsBotViewCard? view;
  final Widget? identity;
  final ValueNotifier<double> scrolledUnder;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final (work, activity) = ref.watch(
      dsBotProvider.select((s) => (s.live.bots[bot.id], s.live.activity[bot.id])),
    );
    final (String label, StatusTone tone) = switch (()) {
      _ when question != null || view != null => (l10n.commonWaitingAnswer, StatusTone.warn),
      _ when bot.waiting => (l10n.botsWaitingModel, StatusTone.warn),
      _ when work != null => (
        [
          workPhrase(work, activity: activity) ?? l10n.botsThinking,
          ?team.room(work.roomId)?.name,
        ].join(' · '),
        StatusTone.busy,
      ),
      _ => (bot.role.isEmpty ? (team.isMain(bot.id) ? l10n.botsMainBot : l10n.botsIdle) : bot.role, StatusTone.ok),
    };
    return BotChatHeader(
      face: BotAvatar(bot: bot, size: BotChatHeader.faceSize),
      title: bot.name,
      status: label,
      tone: tone,
      identity: identity,
      scrolledUnder: scrolledUnder,
      onDetails: onDetails,
    );
  }
}

/// 顶栏状态行上的模型身份：厂商标记 + 实际在用的模型名。
Widget? _modelIdentity(BuildContext context, DsBot bot) {
  final model = botModelLabel(bot);
  if (model == null) return null;
  final dsh = DshColors.of(context);
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ProviderBrandIcon(brand: botModelBrand(bot), size: 12),
      const SizedBox(width: 3),
      Flexible(
        child: Text(
          model,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: dsh.textTertiary, height: 1.25),
        ),
      ),
    ],
  );
}

/// Picks [bot]'s model in the chat's model sheet and saves it.
Future<void> pickBotModel(BuildContext context, WidgetRef ref, DsBot bot, {BotActionScope? scope}) {
  final target = scope ?? BotActionScope(ref, botId: bot.id);
  if (!target.current(context, ref)) return Future.value();
  final hub = ref.read(dsBotProvider.notifier);
  final api = target.api;
  bool current() => target.current(context, ref);

  if (!current()) return Future.value();
  final messenger = ScaffoldMessenger.maybeOf(context);
  return showModelSheet(
    context,
    current: botModelSelection(bot),
    onSelected: (selection) async {
      // A modal can outlive a host switch, reconnect, or removal of this Bot.
      // Check before any write; never redirect an old choice through hub.api.
      if (!current()) return;
      try {
        await api!.updateBot(
          bot.id,
          model: '${selection.provider}/${selection.model}',
          // A model without levels clears the previous Bot override.
          // Omission means "keep" to DS Bot, not "use the default".
          effort: selection.reasoningEffort ?? '',
        );
        if (current()) await hub.refresh();
      } catch (error) {
        if (current()) messenger?.showSnackBar(SnackBar(content: Text(describeDsBotError(error))));
      }
    },
  );
}

/// A Bot's model as the model sheet names it.
ModelSelection? botModelSelection(DsBot bot) {
  final ref = bot.modelRef;
  if (ref == null) return null;
  final slash = ref.indexOf('/');
  if (slash <= 0) return null;
  return ModelSelection(
    provider: ref.substring(0, slash),
    model: ref.substring(slash + 1),
    reasoningEffort: bot.effort,
  );
}

class _Thinking extends StatelessWidget {
  const _Thinking();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: TypingIndicator(color: DshColors.of(context).textTertiary),
    ),
  );
}

/// The empty chat: the Bot's face, name and role.
class _Intro extends StatelessWidget {
  const _Intro({required this.bot});

  final DsBot bot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        BotAvatar(bot: bot, size: 64),
        const SizedBox(height: 12),
        Text(bot.name, style: theme.textTheme.titleLarge),
        if (bot.role.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(bot.role, style: theme.textTheme.bodyMedium?.copyWith(color: DshColors.of(context).textTertiary)),
        ],
      ],
    );
  }
}

/// DSH's own approval requests in the Bot's chat (a member's in a group are
/// answered in the group's details).
class _OwnApprovals extends ConsumerStatefulWidget {
  const _OwnApprovals({required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<_OwnApprovals> createState() => _OwnApprovalsState();
}

class _OwnApprovalsState extends ConsumerState<_OwnApprovals> {
  StreamSubscription<HostEvent>? _sub;
  DshClient? _client;
  List<ApprovalRequest> _requests = const [];

  void _attach(DshClient? client) {
    if (identical(client, _client)) return;
    unawaited(_sub?.cancel());
    _client = client;
    _sub = client?.hostEvents.listen((_) => _read());
    _read();
  }

  void _read() {
    final client = _client;
    final next = [
      for (final event in client?.mux.pendingRequests ?? const <HostEvent>[])
        if (event is ApprovalRequestedEvent && event.request.sessionId == widget.sessionId) event.request,
    ];
    if (!mounted) return;
    if (next.length != _requests.length || !next.every((r) => _requests.any((o) => o.eventId == r.eventId))) {
      setState(() => _requests = next);
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _attach(ref.watch(activeConnectionProvider.select((c) => c.value?.client)));
    final client = _client;
    if (_requests.isEmpty || client == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final request in _requests)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ApprovalCard(
              key: ValueKey(request.eventId),
              request: request,
              onRespond: (request, decision) async {
                await client.respondApproval(request, decision);
                _read();
              },
            ),
          ),
      ],
    );
  }
}

/// A reply's dsh-ui cards, answered here as in a chat: whether one still can be comes from
/// what followed it in this Bot's transcript.
class _WithCards extends StatelessWidget {
  const _WithCards({
    required this.chat,
    required this.item,
    required this.sessionId,
    required this.running,
    required this.onReply,
    required this.child,
  });

  final BotChatState chat;
  final DsBotItem item;
  final String sessionId;
  final bool running;
  final DshUiSend? onReply;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final index = chat.items.indexOf(item);
    final state = index < 0 || (!item.text.contains('dsh-ui') && !item.text.contains('{'))
        ? DshUiState.expired
        : dshUiStateAfter(
            [
              for (final later in chat.items.skip(index + 1))
                if (later.kind == DsBotItemKind.user)
                  (user: true, text: later.text)
                else if (later.kind == DsBotItemKind.bot)
                  (user: false, text: later.text),
            ],
            running: running,
            pending: [for (final p in chat.pending) p.text],
          );
    return DshUiScope(
      sessionId: sessionId,
      messageId: item.id ?? '',
      state: state,
      onReply: onReply,
      onAskResend: onReply,
      child: child,
    );
  }
}
