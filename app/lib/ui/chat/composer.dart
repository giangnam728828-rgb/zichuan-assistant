// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
// Local changes: chrome-tier glass with a 28 radius; a solid primary send
// key; model picking lives in the header chip; one send action, since DSH
// queues prompts sent mid-turn.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../common/expand_reveal.dart';
import '../common/smooth_size.dart';
import '../fx/voice_glow/voice_beam.dart';
import '../pets/pet_perch.dart';
import '../settings/voice_settings_page.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'voice/voice_controller.dart';
import 'voice/voice_widgets.dart';

/// The editor's line height, as a multiple of its font size.
const _lineHeight = 1.45;

/// 输入条（B2）：一张两行的卡片，常驻。上面是 1–6 行自动增高的输入区，
/// 下面一行控件：左 ＋ 与「模式」胶囊，右 上下文环、通话、语音 / 发送。
///
/// ```
/// ╭──────────────────────────────────────╮
/// │  给 DSH 发消息…                       │
/// │  (+) ( ⚒ 标准模式 ⌄ )      (◔) (☎) (🎙)│
/// ╰──────────────────────────────────────╯
/// ```
///
/// 卡片是半透明的实心底（不做真模糊）+ 1px 边线 + float 圆角 + 外投影，
/// 生成中沿边一层强调色流光（[_ThinkingEdge]）。键盘弹起不再改形状，只是
/// 增高，所以没有要跟着动的展开动画。
///
/// 语音([voice]):草稿为空时最右是麦克风(和 ＋ 键同样的淡底圆)，有字时与
/// 发送键 120ms 交叉淡入;听写时 ＋ 换成 ✕(取消)、发送键换成主色的停止键,
/// 中间文字处显示识别结果,停止键左边是音量条。按键始终同一位置、同一尺寸。
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.connected,
    required this.running,
    required this.onSend,
    required this.onStop,
    this.focusNode,
    this.groupId = EditableText,
    this.busy = false,
    this.stopping = false,
    this.sessionReady = true,
    this.accessory,
    this.leading,
    this.modePill,
    this.tray,
    this.hasAttachments = false,
    this.onSendOptions,
    this.voice,
    this.onKeyEvent,
    this.placeholder,
    this.waiting = false,
    this.waitHint,
    this.modeLabel,
    this.onContentInserted,
    this.maxLines = 6,
    this.hardwareEnterSends = false,
    this.sendWhenEmpty = false,
    this.onCall,
    this.emptySendLabel,
    this.tight = false,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;

  /// The text field and its attached controls share this tap region.
  final Object groupId;

  /// 已连上 DSH。没连上时可以先打字,但发不出去。
  final bool connected;

  /// 本轮正在生成:输入为空时发送键变成停止键。
  final bool running;

  /// 正在建会话 / 提交中:挡住连点。
  final bool busy;

  /// Stop was asked for: the stop key turns busy until the turn ends.
  final bool stopping;

  /// Ordinary send/stop controls require an applied session snapshot.
  final bool sessionReady;
  final VoidCallback onSend;
  final VoidCallback onStop;

  /// 发送键左边的小件(上下文环),40dp 高,底对齐。
  final Widget? accessory;

  /// 输入框左边的 40dp 件(＋ 附件)。
  final Widget? leading;

  /// 输入框上方的一条(引文、待发送的附件):出现时展开,拿掉时收起。
  final Widget? tray;

  /// 有附件时,没有文字也能发送。
  final bool hasAttachments;

  /// 长按发送键:生成中可选插话 / 停下先处理 / 排队。
  final VoidCallback? onSendOptions;

  /// 语音输入;null 或不可用时没有麦克风。
  final VoiceInputController? voice;

  /// Hardware keys in the text field first go here (the `@` picker's
  /// arrows / Enter / Esc).
  final FocusOnKeyEventCallback? onKeyEvent;

  /// The idle hint (「给 Chief 发消息…」 in a Bot chat); 「给 DSH 发消息…」
  /// by default.
  final String? placeholder;

  /// An approval or a question is waiting: the stop key steps back (the
  /// card's button is the one primary key) and the hint stops saying the
  /// turn is generating.
  final bool waiting;

  /// What the placeholder says while [waiting] (「等你回答」); null keeps the
  /// plain one.
  final String? waitHint;

  /// Persistent send intent, separate from the placeholder that typing hides.
  final String? modeLabel;

  /// Images from the keyboard (screenshots, stickers); null takes none.
  final ValueChanged<KeyboardInsertedContent>? onContentInserted;

  /// Visible editor lines. Multiline text remains scrollable when limited.
  final int maxLines;

  /// Opt-in physical Enter-to-send; never changes the software IME action.
  final bool hardwareEnterSends;

  /// An empty box sends too (the tavern: the character speaks next). The key
  /// is drawn quietly then, and labelled [emptySendLabel]; the mic, when
  /// there is one, still comes first.
  final bool sendWhenEmpty;
  final String? emptySendLabel;

  /// 「语音通话」 with this conversation: the key sits in the composer's own row now
  /// (第 4 步把顶栏的语音键挪到这里，顶栏只留 标题 / 模型 / 伙伴 / 新对话).
  final VoidCallback? onCall;

  /// 控制行左边的「模式」胶囊（B2）：新对话管预设与权限，已有会话管权限。
  /// 由页面接线（composer_mode_pill.dart），这里只负责摆。
  final Widget? modePill;

  /// 连一张完整的卡片都放不下时（横屏叠着键盘、分屏），把上留白与行距
  /// 各收紧一点：文字才落得到状态栏之下，对话也还露得出来。
  /// 由页面按 [tightFor] 算好传进来——卡片自己的 context 已经看不到键盘。
  final bool tight;

  /// Editor lines for a page whose [pageContext] still carries the keyboard
  /// inset: six, or as many as fit in two fifths of the height above the
  /// keyboard at the current text size, never under two (two keep newlines
  /// and the field's own scrolling). A phone on its side with the keyboard
  /// up, or very large text, would otherwise push the chat to nothing; an
  /// upright phone under a tall keyboard keeps six up to about 1.2× text.
  static int linesFor(BuildContext pageContext) {
    final available = MediaQuery.sizeOf(pageContext).height - MediaQuery.viewInsetsOf(pageContext).bottom;
    final line = MediaQuery.textScalerOf(pageContext).scale(_fontSize) * _lineHeight;
    if (line <= 0 || available <= 0) return 2;
    return (available * 0.4 / line).floor().clamp(2, 6);
  }

  /// 状态栏与键盘之间放不下一张完整卡片（空草稿也放不下）时收紧布局。
  /// 只在真正挤到放不下时成立：竖屏开了键盘仍然宽松，卡片尺寸不变，
  /// 键盘进出时输入栏不跳。
  static bool tightFor(BuildContext pageContext) {
    final media = MediaQuery.of(pageContext);
    final available =
        media.size.height - media.viewInsets.bottom - media.viewPadding.top - media.viewPadding.bottom;
    return available < 132;
  }

  @override
  State<Composer> createState() => _ComposerState();
}

const double _keySize = 36;
const double _keyGap = 6;

/// 卡片里文字与左右边的距离。
const double _textInset = 14;

/// 输入区上方的留白。
const double _textPadY = 10;

/// 引文 / 附件托盘与提示行离卡片左右的距离：与 28 圆角的圆心同心。
const double _trayInset = 12;

/// 控制行距卡片左右与底边：36 的键放进去，视觉上还有 6 的余量。
const double _rowInset = 6;

/// 输入区与控制行之间。
const double _rowGap = 2;

/// The composer's own text, a step under body text.
const double _fontSize = 15.0;

class _ComposerState extends State<Composer> {
  Duration? _lastEscape;
  // Keep the editor and its input connection across rebuilds.
  final _fieldKey = GlobalKey();
  late final _draftEmpty = ValueNotifier(widget.controller.text.trim().isEmpty);

  void _draftChanged() {
    _draftEmpty.value = widget.controller.text.trim().isEmpty;
  }

  /// The last tray shown: it stays while the tray folds away.
  late Widget? _tray = widget.tray;

  void _send() {
    if (!widget.connected || !widget.sessionReady || widget.busy) return;
    HapticFeedback.lightImpact();
    widget.onSend();
  }

  void _stop() {
    if (!widget.connected || !widget.sessionReady || widget.busy || widget.stopping) return;
    HapticFeedback.mediumImpact();
    widget.onStop();
  }

  /// Hardware keyboards: Ctrl/⌘+Enter sends; optionally plain Enter does too.
  /// Shift+Enter remains a new line. IME composition never sends.
  /// Two consecutive Esc presses within 500 ms stop the turn. The pair is
  /// local to the focused, eligible editor; a single Esc never leaves it.
  KeyEventResult _hardwareKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final composing = widget.controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      _lastEscape = null;
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.escape) _lastEscape = null;
    final sendEnter =
        keys.isControlPressed ||
        keys.isMetaPressed ||
        (widget.hardwareEnterSends && !keys.isShiftPressed && !keys.isAltPressed);
    if (sendEnter && (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter)) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      final draft = widget.controller.text.trim().isNotEmpty || widget.hasAttachments || widget.sendWhenEmpty;
      final dictating = widget.voice?.active ?? false;
      if (draft && widget.connected && !widget.busy && !dictating) _send();
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.ignored;
    if (key != LogicalKeyboardKey.escape || !widget.running) {
      _lastEscape = null;
      return KeyEventResult.ignored;
    }
    if (!widget.sessionReady || !widget.connected || widget.busy || widget.stopping) {
      _lastEscape = null;
      return KeyEventResult.handled;
    }
    final last = _lastEscape;
    _lastEscape = event.timeStamp;
    if (last != null && event.timeStamp - last <= const Duration(milliseconds: 500)) {
      _lastEscape = null;
      _stop();
    }
    return KeyEventResult.handled;
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_draftChanged);
    widget.voice?.onMessage = _voiceMessage;
  }

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_draftChanged);
      widget.controller.addListener(_draftChanged);
      _draftChanged();
    }
    if (oldWidget.sessionReady != widget.sessionReady ||
        oldWidget.connected != widget.connected ||
        oldWidget.running != widget.running ||
        oldWidget.controller != widget.controller ||
        oldWidget.focusNode != widget.focusNode ||
        oldWidget.busy != widget.busy ||
        oldWidget.stopping != widget.stopping) {
      _lastEscape = null;
    }
    _tray = widget.tray ?? _tray;
    if (oldWidget.voice != widget.voice) {
      if (oldWidget.voice?.onMessage == _voiceMessage) {
        oldWidget.voice?.onMessage = null;
      }
      widget.voice?.onMessage = _voiceMessage;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_draftChanged);
    _draftEmpty.dispose();
    if (widget.voice?.onMessage == _voiceMessage) {
      widget.voice?.onMessage = null;
    }
    super.dispose();
  }

  void _voiceMessage(VoiceMessage message) {
    if (!mounted) return;
    final voice = widget.voice;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message.text),
          persist: false,
          action: message.openSettings && voice != null
              ? SnackBarAction(label: appL10n.chatGoToSettings, onPressed: () => voice.bridge.openSettings())
              : message.change
              ? SnackBarAction(
                  label: appL10n.nearbyChange,
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VoiceSettingsPage())),
                )
              : null,
        ),
      );
  }

  void _startVoice() {
    final voice = widget.voice;
    if (voice == null) return;
    // Dictation shows the text in the field; the keyboard only covers it.
    (widget.focusNode ?? FocusManager.instance.primaryFocus)?.unfocus();
    voice.start();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final textStyle = theme.textTheme.bodyLarge?.copyWith(fontSize: _fontSize, height: _lineHeight);
    // One line centred in the keys' 40: the padding that makes it so, at
    // the current text size (very large text just grows the row).
    final line = MediaQuery.textScalerOf(context).scale(_fontSize) * _lineHeight;
    final textPad = math.max(4.0, (_keySize - line) / 2);
    final tight = widget.tight;
    final voice = widget.voice;
    voice?.ensureFresh();

    // The chat page's pet stands on the composer's top edge (outside a pet
    // stage this is a plain pass-through).
    return PetPerch(
      kind: PerchKind.composer,
      child: _ComposerCard(
        thinking: widget.running || widget.waiting,
        child: ListenableBuilder(
          // The editor listens to text, selection and composing changes itself.
          // Its surrounding controls only need the draft's empty/nonempty edge.
          listenable: Listenable.merge([_draftEmpty, ?voice]),
          builder: (context, _) {
            final phase = voice?.phase ?? VoicePhase.idle;
            final dictating = phase == VoicePhase.listening || phase == VoicePhase.transcribing;
            final empty = _draftEmpty.value && !widget.hasAttachments;
            final showStop = widget.running && empty && !dictating;
            final showMic = !dictating && !showStop && empty && !widget.busy && (voice?.available ?? false);
            final enabled =
                !widget.busy && widget.connected && widget.sessionReady && (showStop || !empty || widget.sendWhenEmpty);
            final emptySend = empty && widget.sendWhenEmpty && !showStop && !showMic && !dictating;
            final waiting = widget.waiting || widget.waitHint != null;
            final hint = switch (phase) {
              VoicePhase.listening => l10n.chatListeningEllipsis,
              VoicePhase.transcribing => l10n.chatTranscribingEllipsis,
              _ =>
                !widget.connected
                    ? l10n.chatConnectToSend
                    : !widget.sessionReady
                    ? l10n.stateChatSynchronizing
                    : widget.waitHint ??
                          (widget.running && !waiting
                              ? l10n.chatGeneratingSteerHint
                              : widget.placeholder ?? l10n.chatComposerHint),
            };
            final leading = dictating
                ? VoiceCancelKey(key: const ValueKey('voice-cancel'), onPressed: voice!.cancel)
                : widget.leading;
            final accessory = dictating
                ? VoiceWaveform(level: voice!.level, active: phase == VoicePhase.listening)
                : widget.accessory;

            final _KeyMode mode;
            if (dictating) {
              mode = _KeyMode.stopVoice;
            } else if (showStop) {
              mode = _KeyMode.stopRun;
            } else if (showMic) {
              mode = _KeyMode.mic;
            } else {
              mode = _KeyMode.send;
            }
            final keyBusy =
                widget.busy ||
                (showStop && widget.stopping) ||
                phase == VoicePhase.transcribing ||
                phase == VoicePhase.starting;

            final leadingKey = leading == null
                ? null
                : AnimatedSwitcher(
                    duration: AppMotion.of(context, AppMotion.quick),
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: ScaleTransition(scale: anim, child: child),
                    ),
                    child: KeyedSubtree(key: ValueKey(dictating), child: leading),
                  );
            final field = Focus(
              key: _fieldKey,
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _hardwareKey,
              onFocusChange: (hasFocus) {
                if (!hasFocus) _lastEscape = null;
              },
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: widget.onKeyEvent,
                child: TextField(
                  groupId: widget.groupId,
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  contentInsertionConfiguration: switch (widget.onContentInserted) {
                    final onInserted? => ContentInsertionConfiguration(
                      onContentInserted: onInserted,
                      allowedMimeTypes: const ['image/png', 'image/jpeg', 'image/gif', 'image/webp'],
                    ),
                    null => null,
                  },
                  readOnly: dictating || phase == VoicePhase.starting,
                  minLines: 1,
                  maxLines: widget.maxLines,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  textCapitalization: TextCapitalization.sentences,
                  style: textStyle,
                  cursorColor: theme.colorScheme.primary,
                  decoration: InputDecoration(
                    hintText: hint,
                    hintMaxLines: 1,
                    hintStyle: theme.textTheme.bodyLarge?.copyWith(
                      fontSize: _fontSize,
                      color: dsh.textTertiary,
                      height: 1.45,
                    ),
                    filled: false,
                    isDense: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: textPad),
                  ),
                ),
              ),
            );
            final sendKey = _SendButton(
              mode: mode,
              busy: keyBusy,
              quiet: (showStop && waiting && !widget.stopping) || emptySend,
              sendLabel: emptySend ? widget.emptySendLabel : null,
              enabled: switch (mode) {
                _KeyMode.mic => true,
                _KeyMode.stopVoice => phase == VoicePhase.listening,
                _ => enabled,
              },
              onLongPress: mode != _KeyMode.send || !enabled ? null : widget.onSendOptions,
              onTap: () {
                switch (mode) {
                  case _KeyMode.stopRun:
                    _stop();
                  case _KeyMode.send:
                    _send();
                  case _KeyMode.mic:
                    _startVoice();
                  case _KeyMode.stopVoice:
                    voice?.stop();
                }
              },
            );
            // 两行：上面输入，下面控制行。控制行左边是 ＋ 与模式胶囊，
            // 右边是上下文环、通话、语音 / 发送；中间的空位留给长标题。
            final row = Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (leadingKey != null) ...[leadingKey, const SizedBox(width: _keyGap)],
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: widget.modePill ?? const SizedBox.shrink(),
                  ),
                ),
                if (accessory != null) ...[accessory, const SizedBox(width: 2)],
                if (!dictating && widget.onCall != null) ...[
                  _CallKey(onTap: widget.onCall!),
                  const SizedBox(width: _keyGap),
                ],
                sendKey,
              ],
            );
            // The tray unfolds above the text and folds away again: the card
            // grows and shrinks, the text row never jumps.
            final content = Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.modeLabel case final label?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(_trayInset, 8, _trayInset, 0),
                    child: Text(
                      label,
                      style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ExpandReveal(
                  open: widget.tray != null,
                  child: Padding(padding: const EdgeInsets.fromLTRB(_trayInset, 8, _trayInset, 0), child: _tray),
                ),
                // 输入区独占一行；新的一行让卡片长高而不是跳一下，锚在底部，
                // 光标与按键都不动。
                Padding(
                  padding: EdgeInsets.fromLTRB(_textInset, tight ? 8 : _textPadY, _textInset, 0),
                  child: SmoothSize(
                    duration: AppMotion.of(context, AppMotion.quick),
                    curve: AppMotion.std,
                    alignment: Alignment.bottomCenter,
                    child: field,
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(_rowInset, tight ? 0 : _rowGap, _rowInset, tight ? 4 : _rowInset),
                  child: row,
                ),
              ],
            );
            // Dictating: the pet steps away from the voice controls, and a soft light
            // (Libraries.dev Voice) rises from the glass's bottom edge with the voice,
            // under the text and keys.
            return PetCover(
              active: dictating,
              child: voice == null
                  ? content
                  : Stack(
                      children: [
                        Positioned.fill(
                          child: IgnorePointer(
                            child: VoiceBeam(
                              active: dictating,
                              level: voice.level,
                              levelScale: voice.engine == VoiceEngine.system
                                  ? VoiceLevelScale.linear
                                  : VoiceLevelScale.playback,
                              borderRadius: AppShape.float,
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                        content,
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }
}

/// 输入条的底（B2）：半透明的实心填充 + 1px 边线 + float 圆角 + 外投影，
/// 不做真模糊——它天天在眼前，省掉一层 BackdropFilter，滚动更稳。
class _ComposerCard extends StatelessWidget {
  const _ComposerCard({required this.thinking, required this.child});

  /// 这一轮正在生成：[thinking] 时输入栏边缘有一层强调色流光呼吸（2400ms），
  /// 代替发送键上的转圈（第 4 步：思考流光流畅、同屏真模糊 ≤ 3）。
  final bool thinking;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final chrome = DshSurfaces.of(context).chrome;
    final card = GlassSurface(
      tier: GlassTier.chrome,
      borderRadius: AppShape.radiusFloat,
      style: GlassStyle(
        // 玻璃的填充色，但不模糊：透出来的是实色，不是毛玻璃。
        fill: chrome.fill,
        fallbackFill: chrome.fallbackFill,
        hairline: chrome.hairline,
        rim: const Color(0x00000000),
        hairlineWidth: 1,
        shadows: chrome.shadows,
        blurSigma: 0,
      ),
      child: child,
    );
    if (!thinking) return card;
    return _ThinkingEdge(child: card);
  }
}

/// 生成中的输入栏：外缘一圈强调色的流光，2400ms 一次呼吸（第 4 步）。
///
/// 只改 opacity 与一段 1.5dp 描边的颜色，不加模糊、不叠 BackdropFilter
/// （同屏真模糊仍有上限）；「减少动画」时停在半亮，不动。
class _ThinkingEdge extends StatefulWidget {
  const _ThinkingEdge({required this.child});

  final Widget child;

  @override
  State<_ThinkingEdge> createState() => _ThinkingEdgeState();
}

class _ThinkingEdgeState extends State<_ThinkingEdge> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(vsync: this, duration: _period);

  static const _period = Duration(milliseconds: 2400);

  @override
  void initState() {
    super.initState();
    _breath.repeat(reverse: true);
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    if (AppMotion.reduced(context)) {
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppShape.float),
          border: Border.all(color: accent.withValues(alpha: 0.45), width: 1.5),
        ),
        child: widget.child,
      );
    }
    return AnimatedBuilder(
      animation: _breath,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_breath.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppShape.float),
            border: Border.all(color: accent.withValues(alpha: 0.18 + 0.42 * t), width: 1.5),
            boxShadow: [
              BoxShadow(color: accent.withValues(alpha: 0.10 * t), blurRadius: 18, spreadRadius: 1),
            ],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// What the right-hand key does.
enum _KeyMode {
  /// ↑ send.
  send,

  /// ■ stop the running turn.
  stopRun,

  /// 🎙 start dictating (draft empty).
  mic,

  /// ■ stop dictating and keep the text.
  stopVoice,
}

/// 麦克风与发送交叉淡入的时长（B2：120ms）。
const _swap = AppMotion.glassIn;

/// 40 圆键:↑ 发送 / ■ 停止(实心主色);🎙 麦克风是 ＋ 键那样的淡底圆。
/// 禁用时是 onSurface 12% 的底。
class _SendButton extends StatefulWidget {
  const _SendButton({
    required this.mode,
    required this.busy,
    required this.enabled,
    required this.onTap,
    this.onLongPress,
    this.quiet = false,
    this.sendLabel,
  });

  final _KeyMode mode;

  /// In place of 发送, for what sending does just now.
  final String? sendLabel;

  /// Drawn like the mic key (something else on screen is primary).
  final bool quiet;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

/// 发送键的形状。**必须是正圆**：键只有 36dp，圆角半径一旦超过 18 就会在
/// 右下角「多出去一点」，看着像被啃掉一块（2026-11-22 用户实测反馈）。
/// 水滴形状只留在底部导航的水滴指示器上，别用在按键。
const _sendKeyShape = BoxShape.circle;

/// 输入栏里的「语音通话」键：和发送键同高、淡底，图标与顶栏原来那个一致。
class _CallKey extends StatelessWidget {
  const _CallKey({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: context.l10n.speechCallTile,
      child: SizedBox.square(
        key: const ValueKey('composer-call'),
        dimension: _keySize,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Center(
              child: Icon(AppIcons.call, size: 20, color: colors.onSurface.withValues(alpha: 0.78)),
            ),
          ),
        ),
      ),
    );
  }
}

class _SendButtonState extends State<_SendButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final fluid = AppMotion.fluid(context);
    final enabled = widget.enabled && !widget.busy;
    final mode = widget.mode;
    final mic = mode == _KeyMode.mic || widget.quiet;
    final active = enabled || widget.busy;
    final bg = mic
        ? colors.onSurface.withValues(alpha: 0.06)
        : active
        ? colors.primary
        : colors.onSurface.withValues(alpha: 0.12);
    final fg = mic
        ? colors.onSurface
        : active
        ? colors.onPrimary
        : colors.onSurface.withValues(alpha: 0.38);
    final (icon, size, label) = switch (mode) {
      _KeyMode.send => (AppIcons.send, 20.0, widget.sendLabel ?? l10n.commonSend),
      _KeyMode.stopRun => (AppIcons.stopGenerating, 18.0, l10n.chatStopGenerating),
      _KeyMode.mic => (AppIcons.voice, 20.0, l10n.chatVoiceInput),
      _KeyMode.stopVoice => (AppIcons.stopGenerating, 18.0, l10n.chatStopVoiceInput),
    };
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.busy && mode == _KeyMode.stopRun ? l10n.commonStopping : label,
      child: GestureDetector(
        onTap: enabled ? widget.onTap : null,
        onLongPress: widget.onLongPress == null
            ? null
            : () {
                setState(() => _pressed = false);
                HapticFeedback.mediumImpact();
                widget.onLongPress!();
              },
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.9 : 1,
          duration: fluid && !_pressed ? AppMotion.thumbCurve.duration : AppMotion.of(context, AppMotion.press),
          curve: fluid && !_pressed ? AppMotion.thumbCurve : AppMotion.std,
          child: AnimatedContainer(
            // B2：麦克风 ↔ 发送 120ms 交叉淡入，底色一起过，不闪。
            duration: _swap,
            width: _keySize,
            height: _keySize,
            decoration: BoxDecoration(color: bg, shape: _sendKeyShape),
            child: AnimatedSwitcher(
              duration: _swap,
              switchInCurve: AppMotion.enter,
              switchOutCurve: AppMotion.exit,
              transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
              child: widget.busy
                  ? Padding(
                      key: const ValueKey('busy'),
                      padding: const EdgeInsets.all(11),
                      child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                    )
                  : Icon(icon, key: ValueKey(mode), size: size, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}
