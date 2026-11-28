import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/local_footprint.dart';
import '../../runtime/runtime_state.dart';
import '../../state/account_state.dart';
import '../../state/android_features.dart';
import '../../state/ask_ai.dart' show askAiAvailableProvider;
import '../../state/balance_state.dart';
import '../../state/connection_state.dart';
import '../../state/engine_settings_state.dart';
import '../../state/features_state.dart';
import '../../state/hosts_state.dart';
import '../../state/model_defaults_state.dart';
import '../../state/models_state.dart';
import '../../state/phone_state.dart';
import '../../state/plugins_state.dart';
import '../../state/sessions_state.dart';
import '../../state/settings_state.dart';
import '../../state/system_actions_state.dart';
import '../../state/ui_mode_state.dart';
import '../../state/update_state.dart';
import '../account/account_page.dart';
import '../account/account_widgets.dart';
import '../chat/balance_widgets.dart' show formatMoney;
import '../chat/model_sheet.dart' show effortLabel, modelShortName;
import '../common/ask_ai.dart';
import '../common/overview_card.dart';
import '../common/search_capsule.dart';
import '../common/status_chip.dart';
import '../engine/engine_screen.dart';
import '../engine/engine_status.dart';
import '../engine_settings/engine_settings_hub.dart';
import '../engine_settings/web_search_page.dart';
import '../features/feature_catalog.dart' show communityPage;
import '../features/feature_format.dart' show permissionName;
import '../features/permission_page.dart';
import 'media_settings_page.dart';
import '../onboarding/api_key_page.dart' show maskApiKey;
import '../pets/pet_settings_page.dart';
import '../phone/phone_control_screen.dart';
import '../phone/system_actions_page.dart';
import '../plugins/plugins_screen.dart';
import '../plugins/seats/plugin_settings_tiles.dart';
import '../plugins/seats/seat_probe.dart';
import '../providers/providers_page.dart';
import '../remote/host_status.dart';
import '../remote/remote_screen.dart';
import '../shell/brand_mark.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../update/update_tiles.dart' show UpdateBadge;
import 'about_page.dart';
import 'appearance/appearance_page.dart';
import 'background_guide_page.dart';
import 'diagnostics_page.dart';
import 'index/spot_anchor.dart' show anchorSpot;
import 'interface_page.dart';
import 'language_tile.dart';
import 'linux_environment_page.dart';
import 'notification_settings.dart';
import 'performance_page.dart';
import 'personalization_page.dart';
import 'privacy_page.dart';
import 'search/settings_search_page.dart';
import 'settings_widgets.dart';
import 'system_access_page.dart';
import 'voice_settings_page.dart';

/// Settings hub (B4, 去 DSH Go 化): a large title with the search box under
/// it, the 当前配置 card (account · host · model · state), then five panels —
/// 模型与协作, 能力, 外观与交互, 主机与连接, 通用与帮助. Every row says where
/// it stands on the right; none of them loosens a safeguard or deletes
/// anything: those live on their own pages.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(settingsProvider);
    final runtime = ref.watch(localRuntimeProvider);
    final engine = EngineStatusView.of(runtime);
    final colors = DshColors.of(context);
    final notifier = ref.read(settingsProvider.notifier);
    final android = ref.watch(androidSystemFeaturesProvider);
    final ios = ref.watch(operatingSystemProvider) == 'ios';
    final uiMode = ref.watch(uiModeProvider.select((s) => s.mode));
    final host = ref.watch(activeHostProvider);
    Widget? text(String? value, {Color? color}) =>
        value == null ? null : Text(value, style: color == null ? null : TextStyle(color: color));

    // 模型与协作.
    final permission = _permissionValue(ref);
    final prefs = canEditReplyPrefs(ref)
        ? (replyPrefsSummary(ref) == null ? l10n.commonNotSet : l10n.hubValueSet)
        : null;
    // 能力.
    final phone = android || ios ? ref.watch(phoneProvider) : null;
    final phoneValue = phone == null || !phone.loaded || !phone.status.ready
        ? null
        : !phone.status.enabled
        ? l10n.hubValueOff
        : (ios ? phone.status.bridgeListening : phone.status.a11y.ok)
        ? l10n.pluginsTurnedOn
        : l10n.hubValueOneStep;
    final plugins = ref.watch(installedPluginsProvider.select((s) => s.value?.length));
    // Read only once the host's settings are at hand: the hub asks for nothing.
    final search = ref.exists(engineSettingsProvider) ? ref.watch(engineSettingsProvider).value : null;
    final newApi = search == null
        ? null
        : search.valueOf(const FieldRef(WebSearchSettingsPage.webNs, ['searchProvider'])) == 'deepseek-search-api';
    // 通用与帮助. HarmonyOS has no battery exemption to report.
    final exempt = android ? ref.watch(batteryExemptProvider).value : null;
    // 主机与连接.
    final ssh = ref.watch(hostsProvider.select((s) => s.ssh.length));
    final hostName = host.isLocal ? l10n.commonThisPhone : ref.watch(hostNameProvider(host)) ?? l10n.commonRemoteHost;
    // 通用与帮助.
    final update = ref.watch(appUpdateProvider);
    final newVersion = update.hasUpdate && !update.isSkipped;

    final page = AppPage.list(
      title: l10n.commonSettings,
      // 设置是底部主标签之一：左上角不该出现「返回」。
      showBack: false,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SearchCapsuleButton(
            key: const ValueKey('settings-search'),
            hint: l10n.searchSettingsHint,
            onTap: () => Navigator.of(context).push(SettingsSearchPage.route()),
          ),
        ),
        const SettingsOverview(),
        SettingsSection(
          title: l10n.hubGroupModels,
          rowHeight: SettingsMetrics.hubRowHeight,
          rowHeightTwoLine: SettingsMetrics.hubRowHeightTwoLine,
          monochrome: true,
          children: [
            // 模型入口只保留顶部「当前配置」卡里的那一处（v4.4 · S2 ·
            // 任务书 4.3）：同名、同跳转的两个入口会让人以为进了两个不同的
            // 模型页。搜索索引的锚点已挪到那张卡的 _ConfigRow 上，仍可定位。
            SettingsTile(
              icon: AppIcons.permissions,
              spot: SettingsIndex.entry(SettingsPageId.permission),
              value: text(permission?.$1, color: permission?.$2 == true ? colors.warning : null),
              onTap: () => _push(context, PermissionPage(sessionId: ref.read(currentSessionProvider))),
            ),
            SettingsTile(
              icon: AppIcons.profile,
              spot: SettingsIndex.entry(SettingsPageId.personalization),
              value: text(prefs),
              onTap: () => _push(context, const PersonalizationPage()),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.hubGroupCapabilities,
          rowHeight: SettingsMetrics.hubRowHeight,
          rowHeightTwoLine: SettingsMetrics.hubRowHeightTwoLine,
          monochrome: true,
          children: [
            if (android || ios)
              SettingsTile(
                icon: AppIcons.phoneControl,
                spot: SettingsIndex.entry(SettingsPageId.phone),
                value: text(phoneValue, color: phoneValue == l10n.hubValueOneStep ? colors.warning : null),
                onTap: () => _push(context, const PhoneControlScreen()),
              )
            else
              SettingsTile(
                icon: AppIcons.phoneControl,
                spot: SettingsIndex.entry(SettingsPageId.systemActions),
                value: text(
                  ref.watch(systemActionsProvider.select((s) => s.enabled)) ? l10n.pluginsTurnedOn : l10n.hubValueOff,
                ),
                onTap: () => _push(context, const SystemActionsPage()),
              ),
            SettingsTile(
              icon: AppIcons.webSearch,
              spot: SettingsIndex.entry(SettingsPageId.webSearch),
              value: text(newApi == null ? null : (newApi ? l10n.engineSearchNewApiBadge : l10n.commonDefault)),
              onTap: () => _push(context, const WebSearchSettingsPage()),
            ),
            SettingsTile(
              icon: AppIcons.generateMedia,
              spot: SettingsIndex.entry(SettingsPageId.media),
              onTap: () => _push(context, const MediaSettingsPage()),
            ),
            if (ref.watch(operatingSystemProvider) == 'ohos') const LinuxEnvironmentTile(),
            SettingsTile(
              icon: AppIcons.plugin,
              spot: SettingsIndex.entry(SettingsPageId.plugins),
              value: plugins == null || plugins == 0
                  ? null
                  : Text(
                      l10n.hubValuePlugins(plugins),
                      style: AppType.tabular(Theme.of(context).textTheme.bodyMedium!),
                    ),
              onTap: () => _push(context, const PluginsScreen()),
            ),
            // The plugins' own settings sections, when the host has any.
            ...pluginSettingsTiles(ref),
          ],
        ),
        SettingsSection(
          title: l10n.hubSettingsAppearance,
          rowHeight: SettingsMetrics.hubRowHeight,
          rowHeightTwoLine: SettingsMetrics.hubRowHeightTwoLine,
          monochrome: true,
          children: [
            const AppearanceEntryTile(),
            SettingsSegmentTile<double>(
              icon: AppIcons.textSize,
              spot: Spots.chatTextSize,
              segments: [for (final (scale, label) in chatTextScales) PillSegment(scale, label)],
              selected: settings.chatTextScale,
              onChanged: (scale) => unawaited(notifier.setChatTextScale(scale)),
            ),
            SettingsSwitchTile(
              icon: AppIcons.foldTurns,
              spot: Spots.foldTurns,
              value: settings.foldCompletedTurns,
              onChanged: (v) => unawaited(notifier.setFoldCompletedTurns(v)),
            ),
            const PetEntryTile(),
            const PerformanceSettingsTile(),
          ],
        ),
        SettingsSection(
          title: l10n.hubGroupHosts,
          rowHeight: SettingsMetrics.hubRowHeight,
          rowHeightTwoLine: SettingsMetrics.hubRowHeightTwoLine,
          monochrome: true,
          children: [
            SettingsTile(
              icon: AppIcons.engine,
              spot: SettingsIndex.entry(SettingsPageId.engine),
              value: StatusChip(tone: engine.tone, label: engine.label),
              onTap: () => _push(context, const EngineScreen()),
            ),
            SettingsTile(
              icon: AppIcons.remoteHosts,
              spot: SettingsIndex.entry(SettingsPageId.remote),
              value: ssh == 0 ? null : Text(l10n.hubValueHosts(ssh)),
              onTap: () => _push(context, const RemoteScreen()),
            ),
            SettingsTile(
              icon: AppIcons.configure,
              spot: SettingsIndex.entry(SettingsPageId.engineParams),
              value: Text(hostName),
              onTap: () => _push(context, const EngineSettingsHubPage()),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.hubGroupGeneral,
          rowHeight: SettingsMetrics.hubRowHeight,
          rowHeightTwoLine: SettingsMetrics.hubRowHeightTwoLine,
          monochrome: true,
          children: [
            SettingsTile(
              icon: AppIcons.swap,
              spot: SettingsIndex.entry(SettingsPageId.interface),
              value: Text(uiMode.label),
              onTap: () => _push(context, const InterfacePage()),
            ),
            const LanguageSettingsTile(),
            const NotificationSettingsTile(),
            const VoiceSettingsTile(),
            SettingsTile(
              icon: AppIcons.keepAlive,
              spot: SettingsIndex.entry(SettingsPageId.background),
              value: text(
                exempt == null ? null : (exempt ? l10n.hubValueAllowed : l10n.hubValueNeedsSetup),
                color: exempt == false ? colors.warning : null,
              ),
              onTap: () => _push(context, const BackgroundGuidePage()),
            ),
            SettingsTile(
              icon: AppIcons.systemAccess,
              spot: SettingsIndex.entry(SettingsPageId.systemAccess),
              onTap: () => _push(context, const SystemAccessPage()),
            ),
            SettingsTile(
              icon: AppIcons.privacy,
              spot: SettingsIndex.entry(SettingsPageId.privacy),
              onTap: () => _push(context, const PrivacyPage()),
            ),
            if (ref.watch(askAiAvailableProvider))
              SettingsTile(
                key: const ValueKey('settings-ask-ai'),
                icon: AppIcons.askAi,
                spot: Spots.askAi,
                value: Text(l10n.askAiTooltip),
                onTap: () => unawaited(askAi(context, AskAiTopic.overview)),
              ),
            SettingsTile(
              icon: AppIcons.community,
              spot: Spots.community,
              onTap: () => _push(context, communityPage()),
            ),
            SettingsTile(
              icon: AppIcons.diagnostics,
              spot: SettingsIndex.entry(SettingsPageId.diagnostics),
              onTap: () => _push(context, const DiagnosticsPage()),
            ),
            SettingsTile(
              icon: AppIcons.info,
              spot: SettingsIndex.entry(SettingsPageId.about),
              value: newVersion
                  ? UpdateBadge(l10n.hubAboutNewVersion)
                  : Text(update.current.name, style: AppType.tabular(Theme.of(context).textTheme.bodyMedium!)),
              onTap: () => _push(context, const AboutPage()),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Center(child: BrandMark(size: 18, color: colors.textDisabled)),
        ),
      ],
    );
    // Reads which plugins sit where when the engine hasn't said yet; outside
    // the list, so it is built at once and never part of its layout.
    return Stack(
      fit: StackFit.expand,
      children: [
        page,
        const Positioned(left: 0, top: 0, child: SeatProbe()),
      ],
    );
  }

  /// Who is paying (DeepSeek account or API Key) and how the balance stands.
  (String, bool)? _permissionValue(WidgetRef ref) {
    final local = ref.watch(activeHostProvider).isLocal;
    final auto = ref.watch(settingsProvider.select((s) => s.autoApproveCommands));
    final safe = ref.watch(localRuntimeProvider.select((s) => s.status.inSafeMode));
    // On the phone, 完全权限 for new conversations is the app's own switch.
    if (local && auto && !safe) return (permissionName('danger-full-access'), true);
    if (ref.watch(activeConnectionProvider).value == null) return null;
    final state = ref.watch(permissionStateProvider(null)).value;
    final value = state?.hostDefault;
    if (state == null || value == null || state.invalidDefault) return null;
    final name = state.options.where((o) => o.value == value).firstOrNull?.name;
    return (permissionName(value, name), value == 'danger-full-access' || value == 'auto');
  }

}

/// The hub's 当前配置 card: who is signed in (or which host isn't this phone),
/// the host in use, the model new chats start on, and the state dot. The
/// header opens 账号 (or 远程主机 when this phone has no runtime and works
/// through one); the host row opens the engine/host page, the model row opens
/// 模型.
class SettingsOverview extends ConsumerStatefulWidget {
  const SettingsOverview({super.key});

  @override
  ConsumerState<SettingsOverview> createState() => _SettingsOverviewState();
}

class _SettingsOverviewState extends ConsumerState<SettingsOverview> {
  @override
  void initState() {
    super.initState();
    // Opening settings counts as "open": refresh the balance (throttled).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(balanceProvider.notifier).refresh();
    });
  }

  void _push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final account = ref.watch(accountProvider);
    final balance = ref.watch(balanceProvider);
    final wallets = ref.watch(accountWalletBalanceProvider);
    final runtime = ref.watch(localRuntimeProvider);
    final active = ref.watch(activeHostProvider);
    final remoteOnly = runtime.status.runtimeMissing && !active.isLocal;

    // The account's wallets when signed in; otherwise the key's balance.
    final money = account.signedIn && wallets != null ? balanceFromAccount(wallets) : balance.balance;
    final low = !account.signedIn && balance.isLow;
    final balanceLine = money == null
        ? null
        : low
        ? l10n.hubSettingsBalanceLow(formatMoney(money))
        : l10n.hubSettingsBalance(formatMoney(money));

    final Widget leading;
    final String title;
    final String subtitle;
    var warn = false;
    var mono = false;
    // Set when the card shows the remote host instead of the account.
    var hostCard = false;
    switch (account.phase) {
      case AccountPhase.signedIn:
        leading = AccountAvatar(profile: account.profile, size: OverviewCard.avatarSize);
        title = account.profile?.displayName ?? l10n.hubSettingsAccount;
        subtitle = balanceLine ?? account.profile?.contact ?? l10n.commonSignedIn;
      case AccountPhase.signingIn:
        leading = const OverviewGlyph(AppIcons.apiKey);
        title = l10n.hubSettingsAccount;
        subtitle = l10n.hubSettingsSigningIn;
      case _ when remoteOnly:
        leading = OverviewGlyph(hostKindIcon(active.kind), tint: hostKindTint(active.kind));
        title = ref.watch(hostNameProvider(active)) ?? l10n.commonRemoteHost;
        subtitle = l10n.commonRemoteHost;
        hostCard = true;
      case _ when ref.watch(settingsProvider).hasApiKey:
        leading = const OverviewGlyph(AppIcons.apiKey);
        title = l10n.hubSettingsApiKey;
        if (balance.status == BalanceStatus.invalidKey) {
          subtitle = l10n.hubSettingsInvalidKey;
          warn = true;
        } else {
          subtitle = balanceLine ?? maskApiKey(ref.watch(settingsProvider).apiKey);
          mono = balanceLine == null;
          warn = low;
        }
      case AccountPhase.unsupported:
        leading = const OverviewGlyph(AppIcons.apiKey);
        title = l10n.hubSettingsNoApiKey;
        subtitle = l10n.hubSettingsApiKeyHint;
      case AccountPhase.signedOut || AccountPhase.unknown:
        leading = const OverviewGlyph(AppIcons.apiKey);
        title = l10n.hubSettingsSignInAccount;
        subtitle = l10n.hubSettingsOrApiKey;
    }

    final status = watchHostStatus(ref, active);
    final hostName = ref.watch(hostNameProvider(active)) ?? (active.isLocal ? l10n.commonThisPhone : l10n.commonRemoteHost);
    final catalog = ref.watch(currentModelCatalogProvider);
    final settings = ref.exists(engineSettingsProvider) ? ref.watch(engineSettingsProvider).value : null;
    final model = (settings == null ? null : defaultModelSelection(settings)) ?? catalog?.defaultSelection;
    // 还不知道时留空，不写「未设置」：那像是在报错。
    final modelLabel = model == null ? null : modelShortName(model, catalog);
    final effort = model?.reasoningEffort;

    return SpotAnchor(
      spot: SettingsIndex.entry(SettingsPageId.account),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: GlassSurface(
          tier: GlassTier.card,
          borderRadius: AppShape.radiusLg,
          child: Material(
            // The row highlights paint on the glass, not under it.
            type: MaterialType.transparency,
            clipBehavior: Clip.antiAlias,
            shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusLg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  button: true,
                  label: hostCard
                      ? l10n.hubSettingsHostSemantics(title, status.label)
                      : l10n.hubSettingsAccountSemantics(title, subtitle),
                  excludeSemantics: true,
                  child: InkWell(
                    onTap: () => _push(hostCard ? const RemoteScreen() : const AccountPage()),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 8, 14),
                      child: Row(
                        children: [
                          SizedBox.square(
                            dimension: OverviewCard.avatarSize,
                            child: Center(child: leading),
                          ),
                          const SizedBox(width: OverviewCard.gap),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(color: scheme.onSurface),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  subtitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: mono
                                      ? AppType.monoLabel(color: scheme.onSurfaceVariant).copyWith(fontSize: 13, height: 1.5)
                                      : AppType.tabular(
                                          theme.textTheme.bodyMedium!.copyWith(
                                            color: warn ? colors.warning : scheme.onSurfaceVariant,
                                          ),
                                        ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AnimatedStatusDot(tone: status.tone, size: 8),
                                const SizedBox(width: 6),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 84),
                                  child: Text(
                                    status.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const OverviewChevron(),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    height: 0.5,
                    child: ColoredBox(
                      color: theme.brightness == Brightness.dark
                          ? Colors.white.withValues(alpha: 0.08)
                          : scheme.onSurface.withValues(alpha: 0.08),
                    ),
                  ),
                ),
                _ConfigRow(
                  icon: hostKindIcon(active.kind),
                  label: l10n.hubConfigHost,
                  value: hostName,
                  onTap: () => _push(active.isLocal ? const EngineScreen() : const RemoteScreen()),
                ),
                _ConfigRow(
                  icon: AppIcons.providers,
                  label: l10n.hubConfigModel,
                  value: modelLabel,
                  note: effort == null ? null : effortLabel(effort),
                  // 设置里唯一的模型入口：搜索「模型」也落到这一行。
                  spot: SettingsIndex.entry(SettingsPageId.models),
                  onTap: () => _push(const ProvidersPage()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One line of the 当前配置 card: 图标、名字、右侧的当前值与箭头。
class _ConfigRow extends StatelessWidget {
  const _ConfigRow({
    required this.icon,
    required this.label,
    required this.value,
    this.note,
    required this.onTap,
    this.spot,
  });

  final IconData icon;
  final String label;
  final String? value;

  /// A few words after the value (the effort level, a host's state).
  final String? note;
  final VoidCallback onTap;

  /// 设置索引的定位锚点（模型行用它保留「搜索 → 跳到模型」的能力）。
  final SettingSpot? spot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final note = this.note;
    return anchorSpot(
      spot,
      InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Row(
            children: [
              Icon(icon, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface)),
              const SizedBox(width: 12),
              Expanded(
                child: value == null
                    ? const SizedBox.shrink()
                    : Text.rich(
                        TextSpan(
                          text: value,
                          children: [
                            if (note != null)
                              TextSpan(text: ' · $note', style: TextStyle(color: colors.textTertiary)),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: AppType.tabular(theme.textTheme.bodyMedium!.copyWith(color: scheme.onSurfaceVariant)),
                      ),
              ),
              const SizedBox(width: 4),
              const OverviewChevron(),
            ],
          ),
        ),
      ),
      ),
    );
  }
}
