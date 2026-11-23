// The key that folds 对话详情 away, at the end of the panel's own bar.
//
// The way *back* used to be a matching key in the chat header's corner; B1
// moved it into the header's ⋯ menu (lib/ui/chat/chat_header.dart), so the
// two keys no longer take turns on one spot.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/adaptive_layout_state.dart';
import '../../theme/app_icons.dart';
import '../page_frame.dart' show GlassIconButton;

/// The glyph of the panel keys: a frame with a column on its right.
const detailPanelIcon = AppIcons.sidebar;

/// The panel's own key, at the end of its bar: folds it away.
class DetailPanelCollapseKey extends ConsumerWidget {
  const DetailPanelCollapseKey({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => GlassIconButton(
    key: const ValueKey('panel-collapse'),
    icon: detailPanelIcon,
    tooltip: context.l10n.shellCollapseDetails,
    onPressed: () => ref.read(layoutPrefsProvider.notifier).setPanelOpen(false),
  );
}
