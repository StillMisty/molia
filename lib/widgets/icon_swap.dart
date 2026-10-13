import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 图标按钮的状态图标切换（同一按钮槽位换图标）：交叉淡入 + 轻微缩放。
///
/// 配方集中在这里，调用点只声明「状态 → 图标」：
/// - 入 `emphasizedDecelerate`、出 `emphasizedAccelerate`（`short3` 150ms）；
/// - 缩放只做 0.85→1 的轻微收放，避免与 [M3EIconButton] 自身的按压缩放
///   （`morphSpring`）叠成两段明显的动效；
/// - `disableAnimations`（系统减弱动效）时直接跳变，不播过渡。
///
/// 用 [AnimatedSwitcher] 而不是自绘驱动器，是为了白拿三条既有语义：
/// 首次挂载不播（页面入场时图标不会一起做缩放入场）；父级每帧重建
/// （封面飞行、进度刷新）只更新不重播；动画中途再换值时旧图标从当前
/// 进度反向续跑，连点播放模式不会跳变。
class IconSwap<T extends Object> extends StatelessWidget {
  const IconSwap({super.key, required this.value, required this.builder});

  /// 状态标识：`bool` / `enum` / 数字等可比较值。变化才触发切换。
  final T value;

  /// 按当前状态构建图标；动画期间新旧两份并存。
  final Widget Function(BuildContext context, T value) builder;

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return AnimatedSwitcher(
      duration: reduceMotion ? Duration.zero : M3EMotion.short3,
      switchInCurve: M3EMotion.emphasizedDecelerate,
      switchOutCurve: M3EMotion.emphasizedAccelerate,
      transitionBuilder: (child, animation) => FadeTransition(
        // 与 defaultTransitionBuilder 同一套键：切换时新旧两个 FadeTransition
        // 在 Stack 里按 child key 区分，避免元素被就地复用。
        key: ValueKey<Key?>(child.key),
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.85, end: 1).animate(animation),
          child: child,
        ),
      ),
      // 换值才换 key；同值重建只更新内容，不重播动画。
      child: KeyedSubtree(
        key: ValueKey<Object>(value),
        child: builder(context, value),
      ),
    );
  }
}
