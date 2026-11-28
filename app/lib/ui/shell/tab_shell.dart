// 川水 · 窄屏四标签外壳。
//
// - IndexedStack 懒加载：首次进入才构建，之后保活（切标签不丢状态）。
// - 隐藏标签用 TickerMode 暂停动画；TideGlow 只由最外层 AppBackdrop 画，这里不再放。
// - 四个页面用固定 GlobalKey：宽窄屏切换时搬家而不是重建；同一时刻只有一套布局。
// - 外壳统一做 200ms 淡入 + 8dp 方向位移；减少动画时直接切换。
// - 键盘弹起导航收起，收起后延迟 120ms 再显示，和列表留白用同一条曲线。
// - 滚动收起由 [NavigationCollapseController] 判定：只认手指拖动，程序滚动
//   （流式跟随、animateTo、恢复位置）一律不参与；双阈值迟滞防抖动。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/shared/conversation_transition.dart';
import '../features/all_features_page.dart';
import '../settings/settings_screen.dart';
import '../theme/theme.dart';
import '../../state/drawer_view_state.dart' show drawerSelectionProvider;
import '../sessions/sessions_page.dart';
import '../tasks/task_center_page.dart';
import 'bottom_nav.dart';
import 'nav_collapse.dart';
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
  RootTab _last = RootTab.chat;
  double _direction = 1;

  /// 收缩判定（v4.4 · S1）：只认手指拖动，双阈值迟滞，接近底部强制展开。
  ///
  /// 动画仍然只有一条 [_reveal]：导航位移、页面抬升、列表留白共用它，
  /// 不会出现两个控制器抢同一段底部几何。
  late final _nav = NavigationCollapseController(onChange: _onNavChanged);

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

  /// 目标状态变了才动动画：收起立刻、展开已在控制器里等过 120ms。
  void _onNavChanged(bool collapsed) {
    if (!mounted) return;
    if (collapsed) {
      _reveal.reverse();
    } else {
      _reveal.forward();
    }
  }

  /// 外壳的滚动入口：先过滤掉「不是当前聊天列表」的通知，再交给判定器。
  ///
  /// - 任务 / 工具 / 设置页滚动不该影响聊天（任务书 2.7）。
  /// - 历史页仍是「读得更早」的同一套体感，保留参与。
  bool _onScroll(ScrollNotification n) {
    final tab = ref.read(rootTabProvider);
    if (tab != RootTab.chat && tab != RootTab.history) return false;
    return _nav.handle(n);
  }

  void _syncKeyboard(bool up) => _nav.setKeyboard(up);

  @override
  void dispose() {
    _warm?.cancel();
    _nav.dispose();
    _reveal.dispose();
    _switch.dispose();
    super.dispose();
  }

  void _onTabChanged(RootTab tab, {required bool reduce}) {
    // build 里直接改集合：这一帧本来就会重建，不需要 setState。
    _built.add(tab);
    if (tab == _last) return;
    // 真的换了标签才归零：手势残量与收起状态都重来，免得拿上一个标签的
    // 位置判方向（任务书 2.6「新对话 / 换会话时导航正常显示」）。
    // 不能放在上面的 return 之前——每次 build（角标刷新等）都 reset 会把
    // 一次手势的累计位移清掉，滚动就再也判不出来了。
    _nav.reset();
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
