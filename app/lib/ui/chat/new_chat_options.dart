// The new conversation's options on the empty state: the drawer folder it is
// filed in — one light row under the workspace chip. (B2 moved the agent preset
// and the permissions into the composer's 模式 pill, so what applies to this
// chat is chosen right where the message is typed.) Preset and permission picks
// are held in pendingNewChatModesProvider and applied when the first message
// creates the session (chat_screen.dart `_ensureSession`), before the prompt.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_state.dart';
import '../../state/connection_state.dart';
import '../../state/features_state.dart';
import '../../state/new_chat_modes.dart';
import '../../state/settings_state.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/sheet_title_bar.dart';
import '../features/feature_format.dart';
import '../features/permission_page.dart' show confirmPermission;
import '../theme/app_icons.dart';
import 'empty_actions.dart';

/// The longest a single option may grow before its label is cut.
const _itemMaxWidth = 200.0;

/// Presets a new chat can start with, in the Host's order.
List<AgentPresetInfo> newChatPresets(List<AgentPresetInfo>? all) => [
  for (final preset in all ?? const <AgentPresetInfo>[])
    if (!hiddenNewChatPresets.contains(preset.id)) preset,
];

/// The Host's default preset among [presets] (the first when none is marked,
/// or when the marked one is hidden from new chats).
AgentPresetInfo? defaultPreset(List<AgentPresetInfo> presets) {
  for (final preset in presets) {
    if (preset.isDefault) return preset;
  }
  return presets.isEmpty ? null : presets.first;
}

/// The preset to apply to a new session for [picked] (null: the offered
/// default), given the Host's whole list [all]. A pick the Host no longer
/// offers falls back to the default, as its chip already shows. When the
/// Host's own default is a hidden preset, the offered default is applied
/// explicitly: the session would otherwise start in the hidden one. Null
/// keeps the Host default.
String? newChatPresetToApply(List<AgentPresetInfo>? all, String? picked) {
  if (all == null) return picked;
  final presets = newChatPresets(all);
  if (picked != null && presets.any((p) => p.id == picked && p.broken == null)) return picked;
  final hiddenDefault = all.any((p) => p.isDefault && hiddenNewChatPresets.contains(p.id));
  final fallback = defaultPreset(presets);
  return hiddenDefault && fallback != null && fallback.broken == null ? fallback.id : null;
}

/// The permission to apply to a new session for [picked]: null (keep the
/// effective default) when nothing is picked or the Host no longer offers it.
String? newChatPermissionToApply(PermissionState? state, String? picked) {
  if (picked == null || state == null) return picked;
  return state.options.any((o) => o.value == picked) ? picked : null;
}

IconData presetIcon(String id) => switch (id) {
  'standard' => AppIcons.presetStandard,
  'ptc' => AppIcons.presetPtc,
  'minimal' => AppIcons.presetMinimal,
  'cordis' => AppIcons.presetCordis,
  _ => AppIcons.configure,
};

/// The permission a new session gets without a pick: on this device with
/// 自动批准命令 on (and outside safe mode) session creation switches to full
/// access (sessions_state.dart `createForConnection`); elsewhere the Host's
/// default for new sessions.
String effectiveNewChatPermission(
  PermissionState state, {
  required bool local,
  required bool autoApprove,
  required bool safeMode,
}) => local && autoApprove && !safeMode ? 'danger-full-access' : state.hostDefault;

/// The options row: the drawer folder this new chat is filed in — a light item
/// in one centred line. (The preset and the permissions are the composer's
/// 模式 pill now.)
class NewChatOptions extends StatelessWidget {
  const NewChatOptions({super.key, this.folderLabel, this.onFolder});

  /// The drawer-folder item, when there are folders.
  final String? folderLabel;
  final VoidCallback? onFolder;

  @override
  Widget build(BuildContext context) {
    final folderLabel = this.folderLabel;
    final onFolder = this.onFolder;
    if (folderLabel == null || onFolder == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 2,
      children: [
        ConstrainedBox(
          key: const ValueKey('new-chat-folder'),
          constraints: const BoxConstraints(maxWidth: _itemMaxWidth),
          child: SetupItem(
            icon: AppIcons.folder,
            label: folderLabel,
            semanticsLabel: '${l10n.viewNewChatFolder}: $folderLabel',
            onTapHint: l10n.viewNewChatChange,
            onTap: onFolder,
          ),
        ),
      ],
    );
  }
}

/// What a new chat starts with, and what its 模式 pill says: the preset, the
/// permission, and their names as this host spells them.
class NewChatMode {
  const NewChatMode({
    required this.preset,
    required this.presetName,
    required this.permission,
    required this.permissionName,
    required this.defaultPermission,
  });

  /// The preset that will be applied (null: the Host has said nothing yet).
  final AgentPresetInfo? preset;
  final String? presetName;

  /// The permission that will be applied, and the one a fresh chat would get
  /// without a pick (its row is marked 默认).
  final String? permission;
  final String? permissionName;
  final String? defaultPermission;

  /// Looser than 工作区内修改: safety comes first on the pill.
  bool get risky => permission == 'danger-full-access' || permission == 'auto';

  /// The pill's one line: the permission when the person picked a looser or
  /// tighter one (or it is a risky one — safety first), else the preset.
  String? get label {
    final picked = permission != null && (risky || permission != defaultPermission);
    if (picked) return permissionName;
    return presetName ?? permissionName;
  }
}

/// Reads the pending new-chat mode out of the providers (call it from build).
NewChatMode readNewChatMode(WidgetRef ref) {
  final permissions = ref.watch(permissionStateProvider(null)).value;
  final pending = ref.watch(pendingNewChatModesProvider);
  final presets = newChatPresets(ref.watch(agentPresetsProvider).value);
  AgentPresetInfo? shown = defaultPreset(presets);
  for (final preset in presets) {
    if (preset.id == pending.preset && preset.broken == null) shown = preset;
  }
  final name = shown == null ? null : agentPresetName(shown);
  if (permissions == null || permissions.options.isEmpty) {
    return NewChatMode(
      preset: shown,
      presetName: name,
      permission: null,
      permissionName: null,
      defaultPermission: null,
    );
  }
  final local = ref.watch(activeConnectionProvider.select((c) => c.value?.isLocal ?? false));
  final autoApprove = ref.watch(settingsProvider.select((s) => s.autoApproveCommands));
  final safeMode = ref.watch(localRuntimeProvider.select((s) => s.status.inSafeMode));
  final fallback = effectiveNewChatPermission(
    permissions,
    local: local,
    autoApprove: autoApprove,
    safeMode: safeMode,
  );
  final permission = pending.permission ?? fallback;
  String? hostName;
  for (final option in permissions.options) {
    if (option.value == permission) hostName = option.name;
  }
  return NewChatMode(
    preset: shown,
    presetName: name,
    permission: permission,
    permissionName: permissionName(permission, hostName),
    defaultPermission: fallback,
  );
}

/// 模式: the preset (when there is a real choice) and the permissions in one
/// table — the pill's tap target. Picks go to pendingNewChatModesProvider and
/// the sheet closes; the next message applies them.
Future<void> showNewChatModeSheet(BuildContext context) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (sheet) => const _NewChatModeSheet(),
  );
}

class _NewChatModeSheet extends ConsumerWidget {
  const _NewChatModeSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pending = ref.watch(pendingNewChatModesProvider);
    final presets = newChatPresets(ref.watch(agentPresetsProvider).value);
    final fallback = defaultPreset(presets);
    final mode = readNewChatMode(ref);
    final permissions = ref.watch(permissionStateProvider(null)).value;
    final pickedPreset = pending.preset ?? fallback?.id;
    final pickedPermission = pending.permission ?? mode.defaultPermission;

    Widget check(bool selected) => selected
        ? Icon(AppIcons.selected, size: 20, color: scheme.primary)
        : const SizedBox(width: 20);

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(l10n.chatComposerMode),
              if (presets.length > 1)
                SheetGroup(
                  margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                  children: [
                    for (final preset in presets)
                      ListPageRow(
                        key: ValueKey('mode-preset-${preset.id}'),
                        icon: presetIcon(preset.id),
                        title: agentPresetName(preset),
                        subtitle: preset.broken != null ? l10n.viewNewChatUnavailable : agentPresetDescription(preset),
                        subtitleMaxLines: 2,
                        meta: preset.id == fallback?.id ? l10n.viewNewChatDefault : null,
                        trailing: check(preset.id == pickedPreset),
                        onTap: preset.broken != null
                            ? null
                            : () {
                                ref
                                    .read(pendingNewChatModesProvider.notifier)
                                    .selectPreset(preset.id == fallback?.id ? null : preset.id);
                                Navigator.of(context).pop();
                              },
                      ),
                  ],
                ),
              if (permissions != null && permissions.options.isNotEmpty)
                SheetGroup(
                  margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                  children: [
                    for (final option in permissions.options)
                      ListPageRow(
                        key: ValueKey('mode-permission-${option.value}'),
                        icon: option.value == 'danger-full-access' || option.value == 'auto'
                            ? AppIcons.securityWarning
                            : AppIcons.permissions,
                        title: permissionName(option.value, option.name),
                        subtitle: permissionHint(option.value, option.description),
                        subtitleMaxLines: 2,
                        meta: option.value == mode.defaultPermission ? l10n.viewNewChatDefault : null,
                        trailing: check(option.value == pickedPermission),
                        onTap: () async {
                          // Full access and auto review ask once, as everywhere.
                          if (option.value != mode.defaultPermission &&
                              !await confirmPermission(context, option.value)) {
                            return;
                          }
                          ref
                              .read(pendingNewChatModesProvider.notifier)
                              .selectPermission(
                                option.value == mode.defaultPermission ? null : option.value,
                              );
                          if (context.mounted) Navigator.of(context).pop();
                        },
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
