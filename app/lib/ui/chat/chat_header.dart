// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
// Local changes: rewritten as floating chrome-glass pieces sharing one
// BackdropGroup, on a measuring row that decides which piece gives way.
// B1 (总方案 v4): the pieces lost their fills — one transparent line, the
// title on the left with the host under it, the model name as a text button,
// 新对话 and ⋯ on the right (⋯ holds 伙伴 / 子代理 / 详情).

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/adaptive_layout_state.dart';
import '../../state/agents_state.dart';
import '../../state/conversation_mode_state.dart';
import '../../state/header_schedule_state.dart';
import '../../state/sessions_state.dart';
import '../agents/header_agents.dart';
import '../agents/lineage_sheet.dart';
import '../agents/team_page.dart';
import '../common/fluid_bits.dart';
import '../common/smooth_size.dart';
import '../common/status_dot.dart';
import '../shell/adaptive/adaptive_scaffold.dart' show AdaptiveChrome;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'conversation_mode_switcher.dart';
import 'header_schedule.dart';
import 'model_sheet.dart' show ModelChip;

/// 顶栏状态行的内容:状态点 + 一句人话。颜色从不单独表达状态。
/// 计时只在活动条里,这一行不走秒。
class HeaderStatus {
  const HeaderStatus(this.tone, this.label, {this.spoken});
  final StatusTone tone;
  final String label;

  /// What a screen reader announces instead of [label] (the approval itself,
  /// how the turn ended).
  final String? spoken;
}

/// 聊天顶栏:B1 之后是**一条透明的行**,没有任何胶囊或色带。标题直接站在
/// 页面上,下面一行是状态和主机;内容滚到它下面时由列表的 EdgeFade 渐隐(A1)。
/// 右端 `⋯` 收纳 伙伴 / 子代理 / 详情,对话有进行中的自动化任务时,标题行
/// 尾端仍是一颗与它同心的时钟键([HeaderScheduleCap])。
///
/// ```
/// ≡  修复登录重复提交              V4 Pro ⌄   ＋   ⋯
///    ● 生成中 · 本机
///
/// ≡  每天的构建检查 (◷)            V4 Pro ⌄   ＋   ⋯
///    ● 本机
/// ```
class ChatHeader extends ConsumerStatefulWidget {
  const ChatHeader({
    super.key,
    required this.title,
    required this.status,
    this.detail,
    this.trailing,
    this.onOpenDrawer,
    this.onTitleTap,
    this.onNewChat,
    this.onCompanion,
    this.scrolledUnder,
    this.mode,
    this.moreOverride,
  });

  final String title;
  final HeaderStatus status;

  /// 会话类型徽标（S5）：只显示类型，不响应点击。空则不画（子代理对话、
  /// 测试里只关心标题栏的场合）。类型切换入口在「新对话」。
  final ConversationMode? mode;

  /// 替换默认的 ⋯ 菜单（议会/团队用它放成员管理、导出等动作）。
  final Widget? moreOverride;

  /// What follows the status under the title (a phone: the workspace). Shortens first.
  final String? detail;

  /// 右侧件(模型胶囊 [ModelChip])。需要传 `grouped: true` 与顶栏共享一次
  /// 背景采样。顶栏按它的固有宽度(带不带「· 高」)和标题胶囊分地方。
  /// Null: the title has the room.
  final Widget? trailing;
  final VoidCallback? onOpenDrawer;
  final VoidCallback? onTitleTap;
  final VoidCallback? onNewChat;

  /// 「伙伴」: the 工作 ⇄ 伙伴 switch (总方案 v3 · 第 4 步). 语音通话 has moved into the
  /// composer's own row, so the header keeps only 标题 / 模型 / 伙伴 / 新对话.
  final VoidCallback? onCompanion;

  /// Whether content has scrolled under the bar, 0..1. A1 删除了顶栏纱幕,
  /// 渐隐改由列表的 EdgeFade 负责,此值当前不再驱动任何遮罩;保留参数以兼容
  /// 现有测试与未来的 B1 顶栏重做。
  final ValueListenable<double>? scrolledUnder;

  /// 顶栏的高度(不含状态栏),与二级页面的返回键栏一致。列表顶部留白按它算。
  static const barHeight = 56.0;

  /// The title pill: 44 like the keys beside it, taller when large text
  /// needs it for the title and the status line.
  static double pillHeightOf(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return math.max(44.0, scaler.scale(15) * 1.3 + scaler.scale(11) * 1.25 + 8);
  }

  static double barHeightOf(BuildContext context) => math.max(barHeight, pillHeightOf(context) + 12);

  static double heightOf(BuildContext context) => MediaQuery.paddingOf(context).top + barHeightOf(context) + 8;

  @override
  ConsumerState<ChatHeader> createState() => _ChatHeaderState();
}

class _ChatHeaderState extends ConsumerState<ChatHeader> {
  // Keep TextPainter's paragraph/layout cache across unrelated header rebuilds.
  // Its setters invalidate layout when the label, metrics or direction change.
  final _statusPainter = TextPainter(maxLines: 1);

  @override
  void initState() {
    super.initState();
    PaintingBinding.instance.systemFonts.addListener(_fontsChanged);
  }

  void _fontsChanged() => setState(_statusPainter.markNeedsLayout);

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(_fontsChanged);
    _statusPainter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final top = MediaQuery.paddingOf(context).top;
    final barHeight = ChatHeader.barHeightOf(context);
    final pillHeight = ChatHeader.pillHeightOf(context);
    final titleStyle = theme.textTheme.titleSmall?.copyWith(fontSize: 15, height: 1.3);
    final statusStyle = theme.textTheme.labelSmall?.copyWith(fontSize: 11, height: 1.25);
    final titleFloor = _titleFloor(context, statusStyle);
    // The schedule clock widens the pill by this much over its plain right
    // padding, while the bar can afford it (see [_HeaderRow]).
    final scheduled = ref.watch(headerSchedulesProvider.select((s) => s.shown));
    final clockExtra = scheduled ? HeaderScheduleCap.extraFor(pillHeight) : 0.0;
    // Wide windows: next to the rail (it has its own ≡) the key goes, and ≡
    // says what it does there (fold or unfold the list).
    final chrome = AdaptiveChrome.maybeOf(context);
    // A1 边缘渐隐:顶栏不再铺纱幕,内容滚到顶栏后面时由列表的 EdgeFade 渐隐,
    // 顶栏本身全透明。
    final showsMenu = widget.onOpenDrawer != null && (chrome?.showsMenuKey ?? true);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(12, top, 12, 0),
          child: BackdropGroup(
            child: SizedBox(
              key: const ValueKey('chat-header-bar'),
              height: barHeight,
              child: _HeaderRow(
                titleFloor: titleFloor,
                clockExtra: clockExtra,
                children: [
                  // A subagent conversation shows 「‹ 上级对话」 here.
                  HeaderLeadSlot(
                    // 3a：抽屉不再是主入口，没有 onOpenDrawer 时不画 ≡。
                    // v4：模式按钮搬去右侧操作区，这里只剩历史菜单。
                    menu: SizedBox(
                      height: 44,
                      child: showsMenu
                          ? SizedBox.square(
                              key: const ValueKey('chat-menu'),
                              dimension: 44,
                              child: GlassSurface(
                                tier: GlassTier.chrome,
                                // B1：顶栏去色块，键只剩图标和按下反馈。
                                bare: true,
                                circle: true,
                                grouped: true,
                                onTap: widget.onOpenDrawer,
                                child: Tooltip(
                                  message: l10n.chatHistory,
                                  child: Center(child: Icon(AppIcons.history, size: 22, color: colors.onSurface)),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                  Semantics(
                    button: widget.onTitleTap != null,
                    hint: widget.onTitleTap == null ? null : l10n.chatViewChatDetails,
                    child: GlassSurface(
                      tier: GlassTier.chrome,
                      // B1：标题不再有胶囊底，直接站在页面上（仍是整块可点）。
                      bare: true,
                      stadium: true,
                      grouped: true,
                      onTap: widget.onTitleTap,
                      // At least the 44 of the round key and the model
                      // chip beside it; 16 on the left, and on the right 16
                      // or the schedule clock, concentric with the end.
                      child: ConstrainedBox(
                        key: const ValueKey('chat-title-pill'),
                        constraints: BoxConstraints(minHeight: pillHeight),
                        child: Padding(
                          padding: const EdgeInsets.only(left: _pillPadding),
                          // A new title or status, or the clock coming and
                          // going, glides the pill to its new width instead
                          // of snapping.
                          child: SmoothSize(
                            duration: AppMotion.of(context, AppMotion.standard),
                            curve: AppMotion.std,
                            alignment: Alignment.centerLeft,
                            child: _PillContent(
                              textFloor: titleFloor - _pillPadding * 2,
                              text: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // B1：标题是淡色的一行（原来是胶囊里的实色标题）。
                                    HeaderTitleText(
                                      widget.title,
                                      style: titleStyle?.copyWith(color: colors.onSurface.withValues(alpha: 0.86)),
                                    ),
                                    _StatusLine(
                                      status: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          StatusDot(tone: widget.status.tone, size: _dot),
                                          const SizedBox(width: _dotGap),
                                          Flexible(
                                            child: _StatusLabel(
                                              status: widget.status,
                                              style: statusStyle?.copyWith(
                                                color: widget.status.tone == StatusTone.warn
                                                    ? dsh.warning
                                                    : dsh.textTertiary,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      detail: switch (widget.detail) {
                                        final detail? => FluidTextSwap(
                                          value: detail,
                                          child: Text(
                                            ' · $detail',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: statusStyle?.copyWith(color: dsh.textTertiary),
                                          ),
                                        ),
                                        null => const SizedBox.shrink(),
                                      },
                                    ),
                                  ],
                                ),
                              ),
                              end: HeaderScheduleCap(pillHeight: pillHeight),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // B1：子代理入口搬进 ⋯，右边只剩模型名（它原来在
                  // HeaderTrailingSlot 的 Row 里，现在直接进这一行）。
                  switch (widget.trailing) {
                    final trailing? => Padding(
                      padding: const EdgeInsets.only(left: headerPieceGap),
                      child: _ChipSlot(child: trailing),
                    ),
                    null => const SizedBox.shrink(),
                  },
                  // v4 右侧操作区：[类型徽标] [新对话] [⋯]。类型创建后不改
                  // （S5/D2），所以徽标只读，新对话才是类型入口。
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.mode case final mode?)
                        Padding(
                          padding: const EdgeInsets.only(left: headerPieceGap),
                          child: ConversationModeSwitcher(mode: mode),
                        ),
                      SmoothSize(
                        duration: AppMotion.of(context, AppMotion.quick),
                        child: widget.onNewChat == null
                            ? const SizedBox.shrink()
                            : Padding(
                                padding: const EdgeInsets.only(left: headerPieceGap),
                                child: SizedBox.square(
                                  key: const ValueKey('chat-new-chat'),
                                  dimension: 44,
                                  child: GlassSurface(
                                    tier: GlassTier.chrome,
                                    bare: true,
                                    circle: true,
                                    grouped: true,
                                    onTap: widget.onNewChat,
                                    child: Tooltip(
                                      message: l10n.commonNewChat,
                                      child: Center(child: Icon(AppIcons.newChat, size: 22, color: colors.onSurface)),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                      widget.moreOverride ??
                          _HeaderMoreKey(onCompanion: widget.onCompanion, showsDetails: chrome?.showsPanelKey ?? false),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The pill's text inset, both sides ([HeaderScheduleCap.padding] on the
  /// right, where the clock goes).
  static const _pillPadding = HeaderScheduleCap.padding;
  static const _dot = 6.0;
  static const _dotGap = 5.0;

  /// The least the title pill keeps against the model chip: the title's first
  /// four characters (or all of a shorter one) and the whole status line, the
  /// host's name included, up to eight characters' width.
  double _titleFloor(BuildContext context, TextStyle? statusStyle) {
    final scaler = MediaQuery.textScalerOf(context);
    _statusPainter
      ..text = TextSpan(text: widget.status.label, style: DefaultTextStyle.of(context).style.merge(statusStyle))
      ..textDirection = Directionality.of(context)
      ..textScaler = scaler
      ..layout();
    final statusLine = _dot + _dotGap + _statusPainter.width;
    final title = scaler.scale(15);
    return _pillPadding * 2 + math.max(title * 5, math.min(statusLine, title * 8));
  }
}

/// Marks the model chip inside the trailing pieces, so the bar can weigh its
/// widths apart from the agents capsule beside it.
class _ChipSlot extends SingleChildRenderObjectWidget {
  const _ChipSlot({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderChipSlot();
}

class _RenderChipSlot extends RenderProxyBox {}

/// The bar's pieces on one line: the left key (≡ or the breadcrumb), the
/// title pill, the trailing pieces (agents capsule, model chip) and the
/// 新对话 key. The title pill and the model chip share what the keys leave:
///
/// 1. both whole when they fit;
/// 2. else the chip drops its depth (「· 高」) first;
/// 3. then the title shortens, down to [titleFloor] (with the schedule clock
///    beside it, when the conversation has one);
/// 4. then the chip shortens the model's name, down to ✦ ⌄;
/// 5. then the schedule clock goes, [clockExtra] back to the title;
/// 6. only then does the title go under its floor.
///
/// The pill's content ([_PillContent]) reads step 5 off the width it gets.
///
/// The title pill sits 8 after the left key; the trailing pieces end at the
/// 新对话 key (they carry their own 8s); everything centred on one line.
class _HeaderRow extends MultiChildRenderObjectWidget {
  const _HeaderRow({required this.titleFloor, required this.clockExtra, required super.children})
    : assert(children.length == 4);

  final double titleFloor;

  /// How much the schedule clock widens the title pill; 0 without one.
  final double clockExtra;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderHeaderRow(titleFloor, clockExtra);

  @override
  void updateRenderObject(BuildContext context, _RenderHeaderRow renderObject) {
    renderObject
      ..titleFloor = titleFloor
      ..clockExtra = clockExtra;
  }
}

class _HeaderRowParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderHeaderRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _HeaderRowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _HeaderRowParentData> {
  _RenderHeaderRow(this._titleFloor, this._clockExtra);

  static const _gap = headerPieceGap;

  double _titleFloor;
  set titleFloor(double value) {
    if (value == _titleFloor) return;
    _titleFloor = value;
    markNeedsLayout();
  }

  double _clockExtra;
  set clockExtra(double value) {
    if (value == _clockExtra) return;
    _clockExtra = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _HeaderRowParentData) {
      child.parentData = _HeaderRowParentData();
    }
  }

  /// The model chip among the trailing pieces; null when there is none (a
  /// subagent conversation).
  static RenderBox? _chipIn(RenderObject trailing) {
    RenderBox? found;
    void visit(RenderObject node) {
      if (found != null) return;
      if (node is _RenderChipSlot) {
        found = node;
      } else {
        node.visitChildren(visit);
      }
    }

    trailing.visitChildren(visit);
    return found;
  }

  List<RenderBox> get _pieces => getChildrenAsList();

  @override
  double computeMinIntrinsicWidth(double height) =>
      _pieces.fold(_gap, (sum, child) => sum + child.getMinIntrinsicWidth(height));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _pieces.fold(_gap, (sum, child) => sum + child.getMaxIntrinsicWidth(height));

  @override
  double computeMinIntrinsicHeight(double width) =>
      _pieces.fold(0, (top, child) => math.max(top, child.getMinIntrinsicHeight(width)));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _pieces.fold(0, (top, child) => math.max(top, child.getMaxIntrinsicHeight(width)));

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    assert(constraints.hasBoundedWidth && constraints.hasBoundedHeight);
    final [lead, title, trailing, fresh] = _pieces;
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    final loose = BoxConstraints(maxWidth: width, maxHeight: height);
    lead.layout(loose, parentUsesSize: true);
    fresh.layout(loose, parentUsesSize: true);
    // What the title pill and the trailing pieces share.
    // No gap after an empty left piece (≡ handed to the rail).
    final leadEnd = lead.size.width == 0 ? 0.0 : lead.size.width + _gap;
    final room = math.max(0.0, width - leadEnd - fresh.size.width);
    final titleWhole = title.getMaxIntrinsicWidth(height);
    var trailingMax = room;
    if (_chipIn(trailing) case final chip?) {
      final chipWhole = chip.getMaxIntrinsicWidth(height);
      final others = trailing.getMaxIntrinsicWidth(height) - chipWhole;
      final named = others + chip.getMinIntrinsicWidth(height);
      final compact = others + ModelChip.compactWidth;
      // The pill's max intrinsic width no longer counts the clock (B1), so
      // its plain width is just that; the clock adds `_clockExtra` on top.
      final plainWhole = titleWhole;
      final plainFloor = math.min(_titleFloor, plainWhole);
      // Step 5: the clock stays while the title keeps its floor beside it
      // with the chip down to ✦ ⌄.
      final clock = _clockExtra > 0 && plainFloor + _clockExtra <= room - compact;
      final whole = clock ? titleWhole + _clockExtra : titleWhole;
      final floor = clock ? plainFloor + _clockExtra : plainFloor;
      final share = math.min(math.max(floor, math.min(whole, room - named)), math.max(0.0, room - compact));
      trailingMax = room - share;
    }
    trailing.layout(BoxConstraints(maxWidth: math.max(0.0, trailingMax), maxHeight: height), parentUsesSize: true);
    title.layout(
      BoxConstraints(maxWidth: math.max(0.0, room - trailing.size.width), maxHeight: height),
      parentUsesSize: true,
    );
    void place(RenderBox child, double x) =>
        (child.parentData! as _HeaderRowParentData).offset = Offset(x, (height - child.size.height) / 2);
    place(lead, 0);
    place(title, leadEnd);
    place(fresh, width - fresh.size.width);
    place(trailing, width - fresh.size.width - trailing.size.width);
    size = constraints.constrain(Size(width, height));
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// The title pill's content: the title and status lines, then the pill's
/// right end ([end]: its plain padding, or the schedule clock).
///
/// The clock shows while the lines keep their floor ([textFloor], or all of
/// a shorter title) beside it in the width the bar gives; otherwise the end
/// is the plain padding and the clock is neither painted, hit nor read out.
/// The bar ([_HeaderRow]) allocates by the same rule, so the clock goes
/// before the title would shorten under its floor.
class _PillContent extends MultiChildRenderObjectWidget {
  _PillContent({required this.textFloor, required Widget text, required Widget end}) : super(children: [text, end]);

  /// The least width the title and status lines keep beside the clock.
  final double textFloor;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPillContent(textFloor);

  @override
  void updateRenderObject(BuildContext context, _RenderPillContent renderObject) {
    renderObject.textFloor = textFloor;
  }
}

class _PillContentParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderPillContent extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PillContentParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PillContentParentData> {
  _RenderPillContent(this._textFloor);

  /// Rounding between the bar's arithmetic and the measured widths.
  static const _slack = 0.5;

  double _textFloor;
  set textFloor(double value) {
    if (value == _textFloor) return;
    _textFloor = value;
    markNeedsLayout();
  }

  /// Whether the end is the clock and on screen.
  bool _showsEnd = true;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PillContentParentData) {
      child.parentData = _PillContentParentData();
    }
  }

  RenderBox get _text => firstChild!;
  RenderBox get _end => lastChild!;

  @override
  double computeMinIntrinsicWidth(double height) => _text.getMinIntrinsicWidth(height) + _ChatHeaderState._pillPadding;

  /// B1: the pill's ideal width is its lines plus the plain side padding —
  /// the clock's room is added separately ([_RenderHeaderRow.clockExtra]),
  /// so a short title stops claiming it and leaves the width to the model name.
  @override
  double computeMaxIntrinsicWidth(double height) => _text.getMaxIntrinsicWidth(height) + _ChatHeaderState._pillPadding;

  @override
  double computeMinIntrinsicHeight(double width) =>
      math.max(_text.getMinIntrinsicHeight(width), _end.getMinIntrinsicHeight(width));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      math.max(_text.getMaxIntrinsicHeight(width), _end.getMaxIntrinsicHeight(width));

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) => constraints.constrain(
    Size(computeMaxIntrinsicWidth(constraints.maxHeight), computeMaxIntrinsicHeight(double.infinity)),
  );

  @override
  void performLayout() {
    final text = _text;
    final end = _end;
    final height = constraints.maxHeight;
    final endWhole = end.getMaxIntrinsicWidth(height);
    final clock = endWhole > _ChatHeaderState._pillPadding + _slack;
    final textFloor = math.min(_textFloor, text.getMaxIntrinsicWidth(height));
    _showsEnd = !clock || textFloor + endWhole <= constraints.maxWidth + _slack;
    end.layout(BoxConstraints(maxHeight: height), parentUsesSize: true);
    final endWidth = _showsEnd ? end.size.width : _ChatHeaderState._pillPadding;
    text.layout(
      BoxConstraints(maxWidth: math.max(0.0, constraints.maxWidth - endWidth), maxHeight: height),
      parentUsesSize: true,
    );
    size = constraints.constrain(
      Size(text.size.width + endWidth, math.max(text.size.height, _showsEnd ? end.size.height : 0)),
    );
    (text.parentData! as _PillContentParentData).offset = Offset(0, (size.height - text.size.height) / 2);
    (end.parentData! as _PillContentParentData).offset = Offset(text.size.width, (size.height - end.size.height) / 2);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    context.paintChild(_text, (_text.parentData! as _PillContentParentData).offset + offset);
    if (_showsEnd) {
      context.paintChild(_end, (_end.parentData! as _PillContentParentData).offset + offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in [if (_showsEnd) _end, _text]) {
      final offset = (child.parentData! as _PillContentParentData).offset;
      final hit = result.addWithPaintOffset(
        offset: offset,
        position: position,
        hitTest: (result, transformed) => child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    visitor(_text);
    if (_showsEnd) visitor(_end);
  }
}

/// 状态文字;读屏的实时区域,变了就播报 [HeaderStatus.spoken] 或文字本身。
/// The line under the title: the status first, whatever it needs, and the detail in what
/// is left. A flex would hold back a share for each, cutting one with room beside it.
class _StatusLine extends MultiChildRenderObjectWidget {
  _StatusLine({required Widget status, required Widget detail}) : super(children: [status, detail]);

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderStatusLine();
}

class _StatusLineParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderStatusLine extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _StatusLineParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _StatusLineParentData> {
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _StatusLineParentData) child.parentData = _StatusLineParentData();
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      getChildrenAsList().fold(0.0, (sum, child) => sum + child.getMinIntrinsicWidth(height));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      getChildrenAsList().fold(0.0, (sum, child) => sum + child.getMaxIntrinsicWidth(height));

  @override
  double computeMinIntrinsicHeight(double width) =>
      getChildrenAsList().fold(0.0, (most, child) => math.max(most, child.getMinIntrinsicHeight(width)));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      getChildrenAsList().fold(0.0, (most, child) => math.max(most, child.getMaxIntrinsicHeight(width)));

  (Size, Size) _measure(BoxConstraints constraints, ChildLayouter layoutChild) {
    final width = constraints.maxWidth;
    final status = layoutChild(firstChild!, BoxConstraints(maxWidth: width));
    final detail = layoutChild(lastChild!, BoxConstraints(maxWidth: math.max(0.0, width - status.width)));
    return (status, detail);
  }

  Size _sizeOf(BoxConstraints constraints, Size status, Size detail) =>
      constraints.constrain(Size(status.width + detail.width, math.max(status.height, detail.height)));

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final (status, detail) = _measure(constraints, ChildLayoutHelper.dryLayoutChild);
    return _sizeOf(constraints, status, detail);
  }

  @override
  void performLayout() {
    final (status, detail) = _measure(constraints, ChildLayoutHelper.layoutChild);
    size = _sizeOf(constraints, status, detail);
    (firstChild!.parentData! as _StatusLineParentData).offset = Offset(0, (size.height - status.height) / 2);
    (lastChild!.parentData! as _StatusLineParentData).offset = Offset(status.width, (size.height - detail.height) / 2);
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.status, required this.style});

  final HeaderStatus status;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: status.spoken ?? status.label,
    excludeSemantics: true,
    child: FluidTextSwap(
      value: status.label,
      child: Text(status.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
    ),
  );
}

/// ⋯ 菜单里的动作（B1）。
enum _MoreAction { companion, agents, details }

/// B1 的 ⋯：把 伙伴 / 子代理 / 详情 收进一枚键，顶栏因此只剩一行字与两枚图标。
/// 子代理在跑时键上带一颗呼吸点，信息没有藏进菜单；三项都不可用时整枚键不画。
class _HeaderMoreKey extends ConsumerWidget {
  const _HeaderMoreKey({required this.onCompanion, required this.showsDetails});

  final VoidCallback? onCompanion;

  /// 宽窗口才有「对话详情」可展开（[AdaptiveChrome.showsPanelKey]）。
  final bool showsDetails;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final sessionId = ref.watch(currentSessionProvider);
    final agents = sessionId == null ? null : ref.watch(headerAgentsProvider(sessionId));
    final hasTeam = agents?.hasTeam ?? false;
    final showsAgents = agents != null && (hasTeam || agents.children > 0);
    final running = (agents?.running ?? 0) > 0;
    if (onCompanion == null && !showsAgents && !showsDetails) return const SizedBox.shrink();
    void openAgents() {
      final id = sessionId;
      if (id == null) return;
      if (hasTeam) {
        Navigator.of(context).push(TeamPage.route(sessionId: id));
      } else {
        showLineageSheet(context, sessionId: id);
      }
    }

    return Padding(
      padding: const EdgeInsets.only(left: headerPieceGap),
      child: PopupMenuButton<_MoreAction>(
        key: const ValueKey('chat-more'),
        tooltip: l10n.commonMore,
        padding: EdgeInsets.zero,
        position: PopupMenuPosition.under,
        onSelected: (value) => switch (value) {
          _MoreAction.companion => onCompanion?.call(),
          _MoreAction.agents => openAgents(),
          _MoreAction.details => ref.read(layoutPrefsProvider.notifier).setPanelOpen(true),
        },
        itemBuilder: (context) => [
          if (onCompanion != null)
            PopupMenuItem<_MoreAction>(
              key: const ValueKey('chat-companion'),
              value: _MoreAction.companion,
              child: _MoreRow(icon: AppIcons.companionInvite, label: l10n.companionTitle),
            ),
          if (showsAgents)
            PopupMenuItem<_MoreAction>(
              key: const ValueKey('chat-agents'),
              value: _MoreAction.agents,
              child: Semantics(
                button: true,
                // 胶囊搬进菜单后，读屏仍听见「3 个子代理，1 个运行中」。
                label: agentsEntryLabel(agents, l10n),
                excludeSemantics: true,
                child: _MoreRow(
                  icon: hasTeam ? AppIcons.team : AppIcons.subagents,
                  label: hasTeam ? l10n.botsAgentTeam : l10n.botsSubagents,
                ),
              ),
            ),
          if (showsDetails)
            PopupMenuItem<_MoreAction>(
              key: const ValueKey('chat-panel-key'),
              value: _MoreAction.details,
              child: _MoreRow(icon: AppIcons.sidebar, label: l10n.shellChatDetails),
            ),
        ],
        child: SizedBox.square(
          dimension: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(AppIcons.more, size: 22, color: theme.colorScheme.onSurface),
              if (running) const Positioned(top: 11, right: 12, child: StatusDot(tone: StatusTone.busy, size: 6)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 菜单里的一行：图标 + 名字。
class _MoreRow extends StatelessWidget {
  const _MoreRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
        ),
      ],
    );
  }
}
