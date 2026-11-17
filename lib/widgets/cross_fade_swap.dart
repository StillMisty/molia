import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/motion_policy.dart';

/// 内容身份的过渡配方。
enum CrossFadeMode {
  /// 同进度交叉淡化（默认）：新旧两层全程同时在场，不透明度互补。
  ///
  /// 适合大块内容（骨架 ↔ 正文 / 失败态）：两层面积大、形状不同，交叉时
  /// 读到的是「换了一屏」，不是两份字叠在一起。
  crossFade,

  /// 顺序交接（M3 fade-through）：旧层先快速淡出，新层随后淡入。
  ///
  /// 适合窄槽里的文本（顶栏 / 底栏歌名作者）：新旧标题长度不同、位置完全
  /// 重合，同进度交叉会让两串字在整段过渡里糊在一起。顺序交接把两层同时
  /// 可见的窗口压到十毫秒级，旧层归零前新层也已经开始入场，固定高度槽
  /// 不会出现真的空白帧。
  fadeThrough,
}

/// 内容整体交叉淡化：`value` 变化时旧内容淡出、新内容淡入。
///
/// 与 `IconSwap`（`lib/widgets/icon_swap.dart`）的分工：那个是「同一按钮槽位
/// 换图标」的配方（带缩放、直连切换器）；这里换的是整块内容的身份（曲目
/// 文本块 / 骨架 / 列表），只做透明度，不缩放、不位移。
///
/// 为什么不用 `AnimatedSwitcher`：一是架构测试只允许图标切换用它
/// （`test/architecture/icon_usage_test.dart`）；二是它让新旧子树各自跑
/// 入场动画，这里需要的是一个控制器驱动「旧出 / 新入」两条曲线。
///
/// 为什么不「淡出空白再淡入」：中间会有一帧只剩背景（顶栏是固定高度槽，
/// 空白帧看起来像掉字）。保留旧层做离场层、与新内容叠在 `Stack` 里，
/// 全程至少有一层内容在场。
class CrossFadeSwap extends StatefulWidget {
  const CrossFadeSwap({
    super.key,
    required this.value,
    required this.child,
    this.mode = CrossFadeMode.crossFade,
  });

  /// 内容身份：只有它变化才触发过渡，同值重建只更新内容、不重播。
  final Object value;

  /// 当前内容。
  final Widget child;

  /// 过渡配方；窄槽文本用 [CrossFadeMode.fadeThrough]。
  final CrossFadeMode mode;

  @override
  State<CrossFadeSwap> createState() => _CrossFadeSwapState();
}

class _CrossFadeSwapState extends State<CrossFadeSwap>
    with SingleTickerProviderStateMixin {
  /// effects 档位：与页头两态交叉淡化同档（`short4` 200ms）。整块内容换
  /// 身份比按钮图标反馈（`short3`）慢一档，读起来才是「换了一屏」而不是
  /// 「闪了一下」。
  static const Duration _duration = M3EMotion.short4;

  /// fade-through 的离场结束点（总进度占比）：旧层在这之后不再参与绘制。
  static const double _fadeThroughOutgoingEnd = 0.4;

  /// fade-through 的入场起点：与离场尾部只留 5% 重叠，保证任一时段都有
  /// 内容在场，又不会让两层同时清晰可读。
  static const double _fadeThroughIncomingStart = 0.35;

  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: _duration,
  );

  /// 离场层（上一份内容）；null = 还没播过 / 过渡已落定，只剩一层。
  Widget? _outgoing;

  /// 出场层代次：同时充当入场层 `Opacity` 的 key，让 `Stack` 按 key 认领
  /// 子元素而不是按位置——过渡开始 / 落定后入场层在 index 0 / 1 之间挪动时，
  /// 它的状态（滚动位置、输入焦点、图片缓存订阅）不会被离场层的元素顶掉。
  int _generation = 0;

  /// 离场层代次：充当离场层 `IgnorePointer` 的 key，整层原样继续渲染。
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

  /// 入场层不透明度。
  double _incomingOpacity(double t) {
    if (widget.mode == CrossFadeMode.fadeThrough) {
      if (t <= _fadeThroughIncomingStart) return 0;
      final local =
          (t - _fadeThroughIncomingStart) / (1 - _fadeThroughIncomingStart);
      return M3EMotion.emphasizedDecelerate.transform(local);
    }
    return M3EMotion.emphasizedDecelerate.transform(t);
  }

  /// 离场层不透明度。
  double _outgoingOpacity(double t) {
    if (widget.mode == CrossFadeMode.fadeThrough) {
      if (t >= _fadeThroughOutgoingEnd) return 0;
      return 1 -
          M3EMotion.emphasizedAccelerate.transform(t / _fadeThroughOutgoingEnd);
    }
    // 必须与入场层严格互补：`emphasizedDecelerate` 起步就冲到 0.8，再用
    // `1 - emphasizedAccelerate` 做离场，两层合计最高到 1.8——整段过渡里
    // 新旧内容都是近乎不透明地叠着。
    return 1 - _incomingOpacity(t);
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget? previous = _outgoing;
    return AnimatedBuilder(
      animation: _progress,
      // 每帧只重排两层；`child` 原样透传，同一实例不会重建子树。
      child: widget.child,
      builder: (context, active) {
        // 入场层在两种结构里都是同一个 keyed `Opacity`（落定时透明度 1）：
        // 过渡结束丢掉离场层时，子树（滚动位置、焦点、输入框）原地保留。
        // 不能让入场层在 `Opacity` 内 / 外搬家——那会重建整棵子树，懒列表
        // 的滚动位置也会归零。
        final Widget current = Opacity(
          key: ValueKey<int>(_generation),
          opacity: previous == null ? 1 : _incomingOpacity(_progress.value),
          child: active!,
        );
        // 结构恒定（永远是 `Stack` + 带 key 的入场层）：只有一层时也不
        // 拆掉入场层，否则过渡结束要在 `Stack` 内外搬一次。
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
              key: ValueKey<int>(_outgoingGeneration),
              child: ExcludeSemantics(
                child: Opacity(opacity: _outgoingOpacity(t), child: previous),
              ),
            ),
            current,
          ],
        );
      },
    );
  }
}
