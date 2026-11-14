import 'package:material_ui/material_ui.dart';

/// 渐隐方向：不透明侧贴住哪条边。
enum FadeEdge {
  /// 不透明侧朝上：屏幕顶部 chrome、钉住表头下缘都用它。
  top,

  /// 不透明侧朝下：屏幕底部。
  bottom,
}

/// 滚动内容的边缘渐隐：用与页面同色的渐变覆盖层压住内容边缘，滚动时不硬切。
///
/// 为什么是 surface 覆盖层而不是 `ShaderMask + BlendMode.dstIn`：两者视觉等价
/// （页面背景就是 `colorScheme.surface`，mask 的 alpha 与覆盖层不透明度互补），
/// 但 ShaderMask 会给整块内容建立 saveLayer —— 滚动歌词 / 队列时每帧都要重新
/// 合成整块区域；覆盖层只是一次普通渐变绘制。
///
/// 覆盖层不参与手势（[IgnorePointer]）与语义（[ExcludeSemantics]），调用方把它
/// 叠在滚动内容之上的 [Stack] 里、用 [Positioned] 给出 [extent] 即可。不额外包
/// [RepaintBoundary]：调用点要么已有，要么不需要。
class ScrollEdgeFade extends StatelessWidget {
  const ScrollEdgeFade({
    super.key,
    required this.edge,
    required this.extent,
    this.color,
  });

  /// 不透明侧（渐变从这一侧开始向内衰减）。
  final FadeEdge edge;

  /// 渐隐带高度（dp）：由调用方按内容边距 / 安全区给出。
  final double extent;

  /// 覆盖色：默认 `colorScheme.surface`（页面背景色）。
  final Color? color;

  /// 4 档色标（从边缘侧到内侧）：先厚后薄，避免整条带子看起来像一层灰膜。
  static const List<double> _stops = [0, .3, .65, 1];

  /// 与 [_stops] 对应的不透明度：边缘完全不透明，向内衰减到全透明。
  static const List<double> _alphas = [1, .9, .45, 0];

  @override
  Widget build(BuildContext context) {
    final Color base = color ?? Theme.of(context).colorScheme.surface;
    final bool fromTop = edge == FadeEdge.top;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              // 只翻转 begin / end：色标顺序始终「边缘 → 内侧」，
              // 上下两处共用同一组色标与不透明度。
              begin: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
              end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
              colors: [
                for (final double alpha in _alphas)
                  base.withValues(alpha: alpha),
              ],
              stops: _stops,
            ),
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
