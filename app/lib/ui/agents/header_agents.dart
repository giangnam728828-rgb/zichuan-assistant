// The chat header's multi-agent pieces (DSH Web shows
// them in its session header: the lineage breadcrumb and the subagent entry).
//
// Each piece reads the current conversation itself, so the header only places
// them: [HeaderLeadSlot] swaps the drawer key for a breadcrumb back to the
// parent in a subagent conversation, and [HeaderTitleText] names a child by its
// task (a child has no model chip: its model belongs to its parent's routing).
//
// B1 took the 「N 个子代理」 capsule off the bar; the entry now sits in the
// header's ⋯ menu, which speaks [agentsEntryLabel].

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/agents_state.dart';
import '../../state/sessions_state.dart';
import '../common/fluid_bits.dart';
import '../common/status_dot.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'lineage_sheet.dart';
import 'team_page.dart';

/// What the header shows for the conversation on screen; null for a new chat.
final _currentAgentsProvider = Provider.autoDispose<(String, HeaderAgents)?>((ref) {
  final sessionId = ref.watch(currentSessionProvider);
  if (sessionId == null) return null;
  return (sessionId, ref.watch(headerAgentsProvider(sessionId)));
});

/// Between the header's pieces: the model chip, 新对话, ⋯.
const headerPieceGap = 8.0;

/// 子代理入口对读屏说的话：「3 个子代理，1 个运行中」（团队时：「N 位成员」）。
String agentsEntryLabel(HeaderAgents agents, L10n l10n) {
  final team = agents.hasTeam ? agents.team : null;
  final count = team != null ? team.teammates.length : agents.children;
  if (team != null) return count > 0 ? l10n.botsTeamMemberCount(count) : l10n.botsAgentTeam;
  return agents.running > 0 ? l10n.botsSubagentRunningCount(count, agents.running) : l10n.botsSubagentCount(count);
}

/// The left key: [menu] (the drawer), or 「‹ 上级对话」 in a subagent
/// conversation.
class HeaderLeadSlot extends ConsumerWidget {
  const HeaderLeadSlot({super.key, required this.menu});

  final Widget menu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parent = ref.watch(_currentAgentsProvider)?.$2.parent;
    if (parent == null) return menu;
    return HeaderBackKey(parent: parent);
  }
}

/// The title pill's first line: a subagent conversation is named by the task
/// its parent gave it (its creation label, as DSH Web's breadcrumb does).
class HeaderTitleText extends ConsumerWidget {
  const HeaderTitleText(this.title, {super.key, this.style});

  final String title;
  final TextStyle? style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parent = ref.watch(_currentAgentsProvider)?.$2.parent;
    final shown = parent?.label ?? title;
    return FluidTextSwap(
      value: shown,
      child: Text(shown, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
    );
  }
}

/// 「‹ 上级对话标题」:回到派出这个子代理的对话。
class HeaderBackKey extends ConsumerWidget {
  const HeaderBackKey({super.key, required this.parent});

  final SubagentParent parent;

  static const height = 44.0;
  static const padding = 12.0;
  static const maxWidth = 132.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: l10n.botsBackToParent(parent.parentTitle),
      excludeSemantics: true,
      child: GlassSurface(
        tier: GlassTier.chrome,
        stadium: true,
        grouped: true,
        onTap: () => selectConversation(ref, parent.address.parentSessionId),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: height, minWidth: height, maxWidth: maxWidth),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: padding),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(AppIcons.back, size: 20, color: theme.colorScheme.onSurface),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    parent.parentTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
