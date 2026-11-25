// 新建群聊: pick at least two Bots, optionally a
// name; the admin is DS Bot's default (a Main Bot among them). The admin
// greets the new group and asks what it is for.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'bot_avatar.dart';
import 'room_chat_page.dart';
import 'bot_creation_scope.dart';

/// DS Bot's limit on members of one group.
const roomMaxMembers = 12;

Future<void> showNewRoomSheet(BuildContext context) async {
  final navigator = Navigator.of(context);
  final container = ProviderScope.containerOf(context, listen: false);
  final api = container.read(dsBotProvider.notifier).api;
  final origin = container.read(dsBotProvider);
  final created = await showAppSheet<({String roomId, String? warning, String wantMode})>(
    context,
    dismissal: SheetDismissal.button,
    isScrollControlled: true,
    builder: (sheet) => const NewRoomSheet(),
  );
  if (!context.mounted || created == null) return;
  final current = container.read(dsBotProvider);
  if (!identical(api, container.read(dsBotProvider.notifier).api) ||
      current.host != origin.host ||
      (origin.hello?.boot != null && current.hello?.boot != origin.hello?.boot)) {
    return;
  }
  await navigator.push(
    RoomChatPage.route(created.roomId, modeWarning: created.warning, wantMode: created.wantMode),
  );
}

class NewRoomSheet extends ConsumerStatefulWidget {
  const NewRoomSheet({super.key});

  @override
  ConsumerState<NewRoomSheet> createState() => _NewRoomSheetState();
}

class _NewRoomSheetState extends ConsumerState<NewRoomSheet> {
  final _name = TextEditingController();
  final List<String> _picked = [];
  // 「全员依次回答」是多模型讨论的常态，默认选它；主持人优先留给有人管的群。
  String _mode = 'everyone';
  bool _saving = false;
  BotCreationScope? _scope;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _toggle(String id) {
    HapticFeedback.selectionClick();
    setState(() {
      _error = null;
      if (_picked.contains(id)) {
        _picked.remove(id);
      } else if (_picked.length < roomMaxMembers) {
        _picked.add(id);
      }
    });
  }

  Future<void> _create() async {
    final scope = _scope;
    if (_saving || scope == null || !scope.writable(ref) || !_validMembers(ref.read(dsBotProvider).team)) return;
    final hub = ref.read(dsBotProvider.notifier);
    final api = scope.api;
    setState(() => _saving = true);
    try {
      final name = _name.text.trim();
      final mode = _mode;
      // greet: false —— 不让管理员先发一轮「你们要讨论什么」，人进去就能说话。
      final room = await api.createRoom(
        members: List.of(_picked),
        name: name.isEmpty ? null : name,
        greet: false,
      );
      if (!mounted || !scope.connected(ref)) return;
      // createRoom 目前不收 mode：建好后补一条 updateRoom。设不上也不能把
      // 已经建好的讨论室丢掉，把原因带回聊天页显示，并留一个重试入口。
      String? warning;
      try {
        await api.updateRoom(room.id, mode: mode);
      } catch (error) {
        warning = describeDsBotError(error);
      }
      try {
        await hub.refresh();
      } catch (error) {
        warning ??= describeDsBotError(error);
      }
      if (mounted && scope.connected(ref)) {
        Navigator.of(context).pop((roomId: room.id, warning: warning, wantMode: mode));
      }
    } catch (error) {
      if (!mounted || !scope.connected(ref)) return;
      setState(() {
        _saving = false;
        _error = describeDsBotError(error);
      });
    }
  }

  bool _validMembers(DsBotTeam? team) => _picked.length >= 2 && _picked.every((id) => team?.bot(id) != null);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final status = ref.watch(dsBotProvider);
    final team = status.team;
    _scope ??= BotCreationScope.capture(ref);
    final changed = _scope != null && !_scope!.connected(ref);
    final saving = _saving && !changed;
    final writable = _scope?.writable(ref) ?? false;
    if (status.ready && !changed) _picked.removeWhere((id) => team?.bot(id) == null);
    final bots = [
      for (final id in team?.mainBotIds ?? const <String>[]) ?team?.bot(id),
      for (final bot in team?.bots ?? const <DsBot>[])
        if (!(team?.isMain(bot.id) ?? false)) bot,
    ];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(l10n.botsNewGroup),
              Padding(
                padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 8),
                child: TextField(
                  key: const ValueKey('room-name'),
                  controller: _name,
                  inputFormatters: [LengthLimitingTextInputFormatter(60)],
                  decoration: InputDecoration(hintText: l10n.botsGroupNameOptional),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    SheetSectionLabel(l10n.botsRoomMode),
                    SheetGroup(
                      children: [
                        for (final (mode, title, hint) in [
                          ('everyone', l10n.botsModeEveryone, l10n.botsModeEveryoneHint),
                          ('admin', l10n.botsModeAdmin, l10n.botsModeAdminHint),
                        ])
                          InkWell(
                            key: ValueKey('mode-$mode'),
                            onTap: saving || !writable
                                ? null
                                : () {
                                    HapticFeedback.selectionClick();
                                    setState(() => _mode = mode);
                                  },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(title, style: theme.textTheme.bodyLarge?.copyWith(fontSize: 15)),
                                        const SizedBox(height: 2),
                                        Text(
                                          hint,
                                          style: theme.textTheme.bodySmall?.copyWith(
                                            color: dsh.textTertiary,
                                            height: 1.35,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Icon(
                                    _mode == mode ? AppIcons.radioOn : AppIcons.radioOff,
                                    size: 22,
                                    color: _mode == mode ? theme.colorScheme.primary : dsh.textTertiary,
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                    SheetSectionLabel(
                      _picked.isEmpty ? l10n.botsMembers : l10n.botsMembersSelected(_picked.length),
                    ),
                    SheetGroup(
                      children: [
                        for (final bot in bots)
                          InkWell(
                            key: ValueKey('member-${bot.id}'),
                            onTap: saving || !writable ? null : () => _toggle(bot.id),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 56),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                child: Row(
                                  children: [
                                    BotAvatar(bot: bot, size: 32),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            bot.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodyLarge?.copyWith(fontSize: 15),
                                          ),
                                          if (bot.role.isNotEmpty)
                                            Text(
                                              bot.role,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                                            ),
                                        ],
                                      ),
                                    ),
                                    Icon(
                                      _picked.contains(bot.id) ? AppIcons.radioOn : AppIcons.radioOff,
                                      size: 22,
                                      color: _picked.contains(bot.id) ? theme.colorScheme.primary : dsh.textTertiary,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (changed)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: SheetTitleBar.inset),
                  child: Text(l10n.botsCreationConnectionChanged, style: TextStyle(color: dsh.danger)),
                ),
              if (_error case final error? when !changed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 8, SheetTitleBar.inset, 0),
                  child: Text(error, style: theme.textTheme.bodySmall?.copyWith(color: dsh.danger)),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 12, SheetTitleBar.inset, 16),
                child: FilledButton(
                  key: const ValueKey('room-create'),
                  onPressed: _validMembers(team) && writable && !saving ? _create : null,
                  child: Text(
                    saving ? l10n.botsCreating : (_picked.length < 2 ? l10n.botsPickTwoBots : l10n.commonCreate),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
