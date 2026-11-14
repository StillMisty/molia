import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/motion_policy.dart';

/// 内容整体交叉淡化：`value` 变化时旧内容淡出、新内容淡入，两层同时在场。
///
/// 与 `IconSwap`（`lib/widgets/icon_swap.dart`）的分工：那个是「同一按钮槽位
/// 换图标」的配方（带缩放、直连切换器）；这里换的是整块内容的身份（曲目
/// 文本块 / 骨架 / 列表），只做透明度，不缩放、不位移。
///
/// 为什么不用 `AnimatedSwitcher`：一是架构测试只允许图标切换用它
/// （`test/architecture/icon_usage_test.dart`）；二是它让新旧子树各自跑
/// 入场动画，这里需要的是「同一进度下旧出 / 新入」——一个控制器驱动两条
/// 相反的曲线，两层的半透明时长才会严格相等。
///
/// 为什么不「淡出空白再淡入」：中间会有一帧只剩背景（顶栏是固定高度槽，
/// 空白帧看起来像掉字）。保留旧层做离场层、与出场层叠在 `Stack` 里交叉，
/// 全程至少有一层不透明内容在场。
class CrossFadeSwap extends StatefulWidget {
  const CrossFadeSwap({super.key, required this.value, required this.child});

  /// 内容身份：只有它变化才触发过渡，同值重建只更新内容、不重播。
  final Object value;

  /// 当前内容。
  final Widget child;

  @override
  State<CrossFadeSwap> createState() => _CrossFadeSwapState();
}

class _CrossFadeSwapState extends State<CrossFadeSwap>
    with SingleTickerProviderStateMixin {
  /// effects 档位：与页头两态交叉淡化同档（`short4` 200ms）。整块内容换
  /// 身份比按钮图标反馈（`short3`）慢一档，读起来才是「换了一屏」而不是
  /// 「闪了一下」。
  static const Duration _duration = M3EMotion.short4;

  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: _duration,
  );

  /// 离场层（上一份内容）；null = 还没播过 / 过渡已落定，只剩一层。
  Widget? _outgoing;

  /// 出场层代次：同时充当 [KeyedSubtree] 的 key，让 `Stack` 按 key 认领
  /// 子元素而不是按位置——落定后出场层从 index 1 挪到 index 0 时，它的
  /// 状态（滚动位置、输入焦点、图片缓存订阅）不会被离场层的元素顶掉。
  int _generation = 0;

  /// 离场层代次：与上一帧的出场层同一个 key，整层原样继续渲染。
  int _outgoingGeneration = 0;

  @override
  void initState() {
    super.initState();
    _progress.addStatusListener(_handleStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // effects 时长随系统减弱动效归零（`Duration.zero` 即硬切）。
    _progress.duration = effectDurationOf(context, _duration);
  }

  @override
  void didUpdateWidget(covariant CrossFadeSwap oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同值重建（封面飞行、进度刷新）只更新内容：不动动画，也不换 key。
    if (oldWidget.value == widget.value) return;

    // 此刻屏幕上的出场层就是 `oldWidget.child`（同值重建时它一直在更新）。
    // 动画中途再次换值时把它整层冻结成离场层，过渡从当前画面续跑，不会
    // 闪回更早的内容。
    _outgoingGeneration = _generation;
    _generation += 1;

    if (_progress.duration == Duration.zero) {
      // 系统减弱动效：直接交换，不建过渡层、不播控制器。
      setState(() => _outgoing = null);
      _progress.value = 0;
      return;
    }
    setState(() => _outgoing = oldWidget.child);
    _progress.forward(from: 0);
  }

  void _handleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _outgoing == null) return;
    // 落下即丢掉离场层：留着就会常驻两棵子树（滚动视图、封面解码白挂一份），
    // 语义 / finder 也会继续命中已经离开的内容。
    setState(() => _outgoing = null);
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final incoming = KeyedSubtree(
      key: ValueKey<int>(_generation),
      child: widget.child,
    );
    final outgoing = _outgoing;
    return AnimatedBuilder(
      animation: _progress,
      // 每帧只重排两层；`child` 原样透传，同一实例不会重建子树。
      child: incoming,
      builder: (context, active) {
        final Widget current = active!;
        final Widget? previous = outgoing;
        // 结构恒定（永远是 `Stack`）：只有一层时也不拆掉，否则过渡开始 /
        // 结束时子树要在 `Stack` 内外搬一次，滚动位置与焦点都会重建。
        //
        // `passthrough` 把父级约束原样给两层：调用点的版式（Expanded 的
        // 紧约束、顶栏槽的松约束）与包装前逐像素一致。
        if (previous == null) {
          return Stack(
            fit: StackFit.passthrough,
            alignment: AlignmentDirectional.centerStart,
            children: [current],
          );
        }
        final double t = _progress.value;
        return Stack(
          fit: StackFit.passthrough,
          // 一 / 两行文本换身份时两层高度不同：居中对齐让矮的那层待在原
          // 位置的中心，落定后收窄也不会上下跳。
          alignment: AlignmentDirectional.centerStart,
          children: [
            // 离场层只负责画：不吃点击、不进语义树（读屏只播报当前内容）。
            IgnorePointer(
              child: ExcludeSemantics(
                child: Opacity(
                  opacity: 1 - M3EMotion.emphasizedAccelerate.transform(t),
                  child: KeyedSubtree(
                    key: ValueKey<int>(_outgoingGeneration),
                    child: previous,
                  ),
                ),
              ),
            ),
            Opacity(
              opacity: M3EMotion.emphasizedDecelerate.transform(t),
              child: current,
            ),
          ],
        );
      },
    );
  }
}
