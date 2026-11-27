import 'package:flutter/widgets.dart';

/// 动效的三档，按「缺了它，界面还能不能被看懂」分层。
///
/// 分层的意义不在于分类好看，而在于**谁能关掉谁**：低端机、发热降级只该关
/// 第三档，用户关「动画」关到第二档为止，系统「移除动画」才允许一刀切。
/// 在这之前全仓只有一个 `reduceMotion`，档位一降就把转场、按压、菜单一起归零，
/// 界面看起来像坏了——V4.2 · S3 要修的正是这个。
enum MotionTier {
  /// 状态本身：加载、进度、成功 / 失败提示。关掉它只会让人以为卡死。
  essential,

  /// 界面结构变化：页面转场、菜单展开、列表进出、按钮按压反馈。
  standard,

  /// 纯装饰：灵动动效、陀螺仪光斑、背景呼吸、宠物动作。
  decorative,
}

/// 当前这棵子树允许哪些档的动效。
///
/// 三个输入互相独立，不要合并成一个 bool：
/// - [systemReduced]：系统设置里的「移除动画」，无障碍要求，最高优先级；
/// - [userMuted]：用户在本 App 里关掉了动画（设置 → 性能 → 动画）；
/// - [lightweight]：低端机档位或发热降级，只降装饰层。
@immutable
class MotionPolicy {
  const MotionPolicy({required this.systemReduced, required this.userMuted, required this.lightweight});

  /// 系统「移除动画」。为真时三档全关，包括状态动效。
  final bool systemReduced;

  /// 用户在 App 内关掉了动画。为真时只留 [MotionTier.essential]。
  final bool userMuted;

  /// 低端机档位或发热降级。只改 [decorativeByDefault]，不是硬闸——
  /// 用户在设置里显式打开灵动动效时仍然算数。
  final bool lightweight;

  bool allows(MotionTier tier) => switch (tier) {
    MotionTier.essential => !systemReduced,
    MotionTier.standard => !systemReduced && !userMuted,
    // 档位不是硬闸：低端机默认关装饰，但用户仍可在设置里单独打开。
    MotionTier.decorative => !systemReduced && !userMuted,
  };

  /// 装饰档在这一档性能配置下的默认值。用户显式选择优先于它。
  bool get decorativeByDefault => allows(MotionTier.decorative) && !lightweight;

  /// 给 `MediaQuery.disableAnimations` 用：系统或用户要求减少动画。
  ///
  /// 这与 [allows] 不矛盾：Flutter 自己的组件（路由、ScrollView、SnackBar）只认
  /// 这一个开关，要让它们也降下来，必须把用户的意愿写进 MediaQuery。
  bool get muted => systemReduced || userMuted;

  /// 系统设置变化时重新求值；其余输入不变。
  MotionPolicy withSystemReduced(bool value) => value == systemReduced
      ? this
      : MotionPolicy(systemReduced: value, userMuted: userMuted, lightweight: lightweight);

  /// 读最近一层 [MotionPolicyScope]；没有就按 MediaQuery 推一个（测试、独立预览）。
  static MotionPolicy of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<MotionPolicyScope>();
    if (scope != null) return scope.policy;
    return MotionPolicy(
      systemReduced: MediaQuery.maybeDisableAnimationsOf(context) ?? false,
      userMuted: false,
      lightweight: false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MotionPolicy &&
      other.systemReduced == systemReduced &&
      other.userMuted == userMuted &&
      other.lightweight == lightweight;

  @override
  int get hashCode => Object.hash(systemReduced, userMuted, lightweight);

  @override
  String toString() => 'MotionPolicy(systemReduced: $systemReduced, userMuted: $userMuted, lightweight: $lightweight)';
}

/// 把 [MotionPolicy] 放进树里。挂在 `MaterialApp.builder` 的 `AppMotionScope` 旁边。
class MotionPolicyScope extends InheritedWidget {
  const MotionPolicyScope({super.key, required this.policy, required super.child});

  final MotionPolicy policy;

  @override
  bool updateShouldNotify(MotionPolicyScope oldWidget) => policy != oldWidget.policy;
}
