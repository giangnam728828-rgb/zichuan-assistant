// 川水 · 窄屏四标签外壳。
//
// - IndexedStack 懒加载：首次进入才构建，之后保活（切标签不丢状态）。
// - 隐藏标签用 TickerMode 暂停动画；TideGlow 只由最外层 AppBackdrop 画，这里不再放。
// - 四个页面用固定 GlobalKey：宽窄屏切换时搬家而不是重建；同一时刻只有一套布局。
// - 外壳统一做 200ms 淡入 + 8dp 方向位移；减少动画时直接切换。
// - 键盘弹起导航收起，收起后延迟 120ms 再显示，和列表留白用同一条曲线。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/shared/conversation_transition.dart';
import '../features/all_features_page.dart';
import '../settings/settings_screen.dart';
import '../theme/theme.dart';
import '../../state/drawer_view_state.dart' show drawerSelectionProvider;
import '../sessions/sessions_page.dart';
import '../tasks/task_center_page.dart';
import 'bottom_nav.dart';
import 'root_tab.dart';
import 'shell_insets.dart';

class TabShell extends ConsumerStatefulWidget {
  const TabShell({
    super.key,
    required this.chat,
    required this.onReselect,
    this.pageKeys,
  });

  /// 共享的 ChatScreen（含它的 GlobalKey），从外层传进来以便宽窄屏搬家。
  final Widget chat;

  /// 四个页面的固定 key，由外层持有，跨布局复用。
  final Map<RootTab, GlobalKey>? pageKeys;

  final void Function(RootTab tab) onReselect;

  @override
  ConsumerState<TabShell> createState() => _TabShellState();
}

class _TabShellState extends ConsumerState<TabShell> with TickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: AppMotion.standard,
    value: 1,
  );
  /// 标签切换的淡入：时长与曲线跟聊天模式切换同一套规格
  /// （[ConversationTransition]）。减少动画时由 build 直接呈现，不跑这条。
  late final AnimationController _switch = AnimationController(
    vsync: this,
    // 字段初始化时还读不到 MediaQuery：先用标准档，didChangeDependencies
    // 里按当前动效档位校准（减少动画 → 0）。
    duration: AppMotion.standard,
  );

  /// 已构建过的标签（懒加载）。
  final Set<RootTab> _built = {RootTab.chat};

  /// 首次进入才构建。
  final Map<RootTab, GlobalKey> _keys = {
    for (final tab in RootTab.values) tab: GlobalKey(debugLabel: 'tab:${tab.name}'),
  };

  Timer? _warm;
  Timer? _navBack;
  RootTab _last = RootTab.chat;
  double _direction = 1;
  bool _keyboardUp = false;

  /// 滚动收起（方案第 3 步 IA：滚动收起 / 恢复）。
  ///
  /// 内容往下翻时导航让位（读得多的时候屏幕更大），往上翻或停下就回来。
  /// 和键盘联动共用同一条 [_reveal]，所以底部留白、输入栏位置都跟着连续变；
  /// 键盘在的时候以键盘为准（别和输入法抢）。
  bool _scrolledAway = false;
  Timer? _scrollBack;

  /// 上一次滚动位置：用像素差判断方向（dragDetails 在合成滚动里不总带 delta）。
  double _lastPixels = 0;

  bool get _reduce => MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  bool get _compact => MediaQuery.sizeOf(context).height < ShellMetrics.compactHeight;

  @override
  void initState() {
    super.initState();
    _switch.value = 1;
    // 首帧后空闲预热其余三页：保留懒加载的启动速度，第一次切换也不白屏。
    _warm = Timer(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() => _built.addAll(RootTab.values));
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncKeyboard(MediaQuery.viewInsetsOf(context).bottom > 0);
    // 系统「移除动画」/ 用户关动画是异步翻的：时长跟着调，切换才不会拖一条
    // 半透明的尾巴。
    final duration = ConversationTransition.duration(context);
    if (_switch.duration != duration) _switch.duration = duration;
  }

  @override
  void didUpdateWidget(TabShell old) {
    super.didUpdateWidget(old);
    _syncKeyboard(MediaQuery.of(context).viewInsets.bottom > 0);
  }

  /// 列表滚动：向下累计超过阈值就收起，向上或停止 180ms 内恢复。
  bool _onScroll(ScrollNotification n) {

    if (_keyboardUp) return false;
    if (n.metrics.axis != Axis.vertical) return false;
    switch (n) {
      case ScrollUpdateNotification(:final metrics):
        final delta = metrics.pixels - _lastPixels;
        _lastPixels = metrics.pixels;
        if (delta > 1 && !_scrolledAway && metrics.pixels > 24) {
          _scrolledAway = true;
          _scrollBack?.cancel();
          _reveal.reverse();
        } else if ((delta < -1 || metrics.pixels <= 0) && _scrolledAway) {
          _scheduleNavBack();
        }
      case OverscrollNotification(:final metrics):
        // 已经拖到列表顶（往回翻的尽头）：导航立刻回来。
        if (metrics.pixels <= 0 && _scrolledAway) _scheduleNavBack();
      case UserScrollNotification(direction: ScrollDirection.reverse):
        // 往回翻（手指往下推、看更早的内容）：导航回来。
        if (_scrolledAway) _scheduleNavBack();
      case ScrollEndNotification():
      case UserScrollNotification(direction: ScrollDirection.idle):
        // 停下来不抢着弹回来：往下读时导航保持让位（常用 App 的习性）。
        // 只有往上翻或回到顶部才恢复（见上面 ScrollUpdateNotification 的分支）。
        break;
      default:
        break;
    }
    return false;
  }

  void _scheduleNavBack() {

    _scrolledAway = false;
    _scrollBack?.cancel();
    // 与键盘收起同一条延迟：滚动刚停时不立刻弹回来，避免抖动。
    _scrollBack = Timer(ShellMetrics.navReturnDelay, () {
      if (mounted && !_keyboardUp) _reveal.forward();
    });
  }

  void _syncKeyboard(bool up) {
    if (up == _keyboardUp) return;
    _keyboardUp = up;
    _navBack?.cancel();
    if (up) {
      _scrollBack?.cancel();
      _scrolledAway = false;
    }
    if (up) {
      // 键盘弹起：导航立刻收起。
      _reveal.reverse();
    } else {
      // 键盘收起：延迟 120ms，避开输入法动画，导航和列表留白共用同一条曲线。
      _navBack = Timer(ShellMetrics.navReturnDelay, () {
        if (mounted) _reveal.forward();
      });
    }
  }

  @override
  void dispose() {
    _warm?.cancel();
    _navBack?.cancel();
    _scrollBack?.cancel();
    _reveal.dispose();
    _switch.dispose();
    super.dispose();
  }

  void _onTabChanged(RootTab tab, {required bool reduce}) {
    // 换标签等于换一份列表：滚动基线归零，免得用上一个标签的位置判方向。
    _lastPixels = 0;
    // build 里直接改集合：这一帧本来就会重建，不需要 setState。
    _built.add(tab);
    if (tab == _last) return;
    // 真正离开历史标签：那里的多选跟着结束（预热不算，因为预热不改变 _last）。
    if (_last == RootTab.history) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(drawerSelectionProvider.notifier).end();
      });
    }
    _direction = tab.index >= _last.index ? 1 : -1;
    _last = tab;
    if (reduce) {
      _switch.value = 1;
    } else {
      // 在下一帧启动，避免在 build 中改 AnimationController。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _switch.value = 0;
        _switch.forward();
      });
    }
  }

  Widget _page(RootTab tab) {
    final keys = widget.pageKeys ?? _keys;
    return switch (tab) {
      RootTab.chat => KeyedSubtree(key: keys[RootTab.chat], child: widget.chat),
      RootTab.tasks => KeyedSubtree(key: keys[RootTab.tasks], child: const TaskCenterPage()),
      // 抽屉里的历史仍走这个隐藏标签；底部导航不再出现它。
      RootTab.history => KeyedSubtree(key: keys[RootTab.history], child: const SessionsPage()),
      RootTab.tools => KeyedSubtree(key: keys[RootTab.tools], child: const AllFeaturesPage()),
      RootTab.settings => KeyedSubtree(key: keys[RootTab.settings], child: const SettingsScreen()),
    };
  }

  @override
  Widget build(BuildContext context) {
    final tab = ref.watch(rootTabProvider);
    final reduce = _reduce;
    final compact = _compact;
    _onTabChanged(tab, reduce: reduce);

    final direction = _direction;
    final safeBottom = MediaQuery.paddingOf(context).bottom;

    return ShellInsets(
      progress: _reveal,
      hasComposer: tab == RootTab.chat,
      compact: compact,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 四页统一动画：200ms 淡入 + 8dp 方向位移；隐藏标签暂停 ticker。
          // AnimatedBuilder 必须监听：只读一次 _switch.value 会在切换后永久停在该值。
          // 内容整块抬到导航上方（padding 跟随 _reveal 连续变），输入栏才不会被盖住。
          NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: AnimatedBuilder(
            animation: Listenable.merge([_switch, _reveal]),
            builder: (context, child) {
              final fade = reduce ? 1.0 : _switch.value.clamp(0.0, 1.0);
              // 与 ShellInsets 同一个公式：抬页面和列表留白不会各算一份漂开。
              final lift = ShellMetrics.extentAt(_reveal.value, safeBottom: safeBottom);
              return Padding(
                padding: EdgeInsets.only(bottom: lift),
                child: Opacity(
                  opacity: fade,
                  child: Transform.translate(
                    offset: Offset(reduce ? 0 : (1 - fade) * ConversationTransition.shift * direction, 0),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // 淡入时 Opacity 会开一个离屏层:层里没有背景,输入栏的玻璃
                        // 模糊就采到透明,两侧透出一块灰。垫一层与外壳同源的背景,
                        // 玻璃才采得到真背景;淡入结束(不再有离屏层)立刻撤掉,光斑照旧。
                        if (fade < 1) const BackdropFill() else const SizedBox.shrink(),
                        child ?? const SizedBox.shrink(),
                      ],
                    ),
                  ),
                ),
              );
            },
            child: IndexedStack(
              index: tab.index,
              children: [
                for (final t in RootTab.values)
                  TickerMode(
                    enabled: t == tab,
                    child: _built.contains(t) ? _page(t) : const SizedBox.shrink(),
                  ),
              ],
            ),
            ),
          ),
          // 底部导航：随键盘/滚动动画连续收起/展开，底部间距 = 安全区 + 8dp。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: BottomNav(
              reveal: _reveal,
              compact: compact,
              onReselect: widget.onReselect,
            ),
          ),
        ],
      ),
    );
  }
}
