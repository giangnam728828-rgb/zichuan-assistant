// 川水 · 窄屏四标签外壳。
//
// - IndexedStack 懒加载：首次进入才构建，之后保活（切标签不丢状态）。
// - 隐藏标签用 TickerMode 暂停动画；TideGlow 只由最外层 AppBackdrop 画，这里不再放。
// - 四个页面用固定 GlobalKey：宽窄屏切换时搬家而不是重建；同一时刻只有一套布局。
// - 外壳统一做 200ms 淡入 + 8dp 方向位移；减少动画时直接切换。
// - 键盘弹起导航收起，收起后延迟 120ms 再显示，和列表留白用同一条曲线。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/all_features_page.dart';
import '../settings/settings_screen.dart';
import '../theme/theme.dart';
import '../../state/drawer_view_state.dart' show drawerSelectionProvider;
import '../sessions/sessions_page.dart';
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
  late final AnimationController _switch = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));

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
  }

  @override
  void didUpdateWidget(TabShell old) {
    super.didUpdateWidget(old);
    _syncKeyboard(MediaQuery.of(context).viewInsets.bottom > 0);
  }

  void _syncKeyboard(bool up) {
    if (up == _keyboardUp) return;
    _keyboardUp = up;
    _navBack?.cancel();
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
    _reveal.dispose();
    _switch.dispose();
    super.dispose();
  }

  void _onTabChanged(RootTab tab, {required bool reduce}) {
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
          AnimatedBuilder(
            animation: Listenable.merge([_switch, _reveal]),
            builder: (context, child) {
              final fade = reduce ? 1.0 : _switch.value.clamp(0.0, 1.0);
              final lift = (ShellMetrics.navHeight + ShellMetrics.navGap + safeBottom) * _reveal.value;
              return Padding(
                padding: EdgeInsets.only(bottom: lift),
                child: Opacity(
                  opacity: fade,
                  child: Transform.translate(
                    offset: Offset(reduce ? 0 : (1 - fade) * 8 * direction, 0),
                    child: child,
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
          // 底部导航：随键盘动画连续收起/展开，底部间距 = 安全区 + 8dp。
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
