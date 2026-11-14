/// 通用加载骨架：呼吸脉冲 + 可复用的块 / 行 / 网格卡占位。
///
/// 为什么共享：骨架块的颜色、圆角与呼吸节奏只在本文件演进。各页面各写一份
/// 灰块时，同一屏很容易出现两种灰度 / 两种节奏的占位，加载完成后视觉跳变；
/// AI 推荐与发现详情页早先共用同一份 [SkeletonPulse]，这里把占位块也收进来。
library;

import 'package:material_ui/material_ui.dart';

import '../theme/m3e_context.dart';
import '../theme/motion_policy.dart';
import 'row_extent.dart';
import 'track_row.dart';

/// 通用加载骨架脉冲：让子树做呼吸式明暗变化。
///
/// AI 推荐与发现详情页共用同一份实现；每处各写一个 AnimationController
/// 会让「减弱动效」的判定与周期漂移，最终出现同一屏两种呼吸节奏。
class SkeletonPulse extends StatelessWidget {
  const SkeletonPulse({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _SkeletonPulseBuilder(
    builder: (opacity) => opacity == null
        ? child
        : FadeTransition(opacity: opacity, child: child),
  );
}

/// 骨架脉冲的 sliver 版本：`SliverGrid` / `SliverFixedExtentList` 不能作为
/// [SkeletonPulse] 的子节点（它是 box 组件），这里用 [SliverFadeTransition]
/// 包同一套动画，避免再写一份周期与减弱动效判定。
class SliverSkeletonPulse extends StatelessWidget {
  const SliverSkeletonPulse({super.key, required this.sliver});

  final Widget sliver;

  @override
  Widget build(BuildContext context) => _SkeletonPulseBuilder(
    builder: (opacity) => opacity == null
        ? sliver
        : SliverFadeTransition(opacity: opacity, sliver: sliver),
  );
}

/// 两个脉冲版式共用的动画宿主：只在这里维护周期与「减弱动效」判定。
class _SkeletonPulseBuilder extends StatefulWidget {
  const _SkeletonPulseBuilder({required this.builder});

  /// 入参为空表示当前应关闭动效（减弱动效 / 平台禁用）。
  final Widget Function(Animation<double>? opacity) builder;

  @override
  State<_SkeletonPulseBuilder> createState() => _SkeletonPulseBuilderState();
}

class _SkeletonPulseBuilderState extends State<_SkeletonPulseBuilder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _opacity = Tween<double>(
      begin: 0.5,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotionOf(context)) {
      _controller.stop();
      _controller.value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(reduceMotionOf(context) ? null : _opacity);
}

/// 骨架块：宽度缺省铺满可用宽，[widthFactor] 用于长短不一的文字行占位。
///
/// 颜色 / 圆角集中在这里，页面不要再自建 `Container + surfaceContainerHigh`。
class SkeletonBlock extends StatelessWidget {
  const SkeletonBlock({
    super.key,
    required this.height,
    this.width,
    this.widthFactor,
    this.radius = 8,
  });

  /// 块高。文字行占位传 `scaledLineHeightOf` 的结果，随系统字号增长。
  final double height;

  /// 固定宽度；为空且 [widthFactor] 为空时铺满可用宽。
  final double? width;

  /// 相对可用宽的占比（左对齐）。
  final double? widthFactor;

  /// 圆角；封面类占位通常给 10，文字行保持默认 8。
  final double radius;

  @override
  Widget build(BuildContext context) {
    final block = Container(
      width: width ?? double.infinity,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
    final factor = widthFactor;
    if (factor == null) return block;
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: factor,
      child: block,
    );
  }
}

/// 曲目行骨架：方形封面块 + 不等宽文字块，底部留出列表行距。
///
/// [gap] 由调用方按当前列表 token 传入（与真实 `itemExtent` 同源），骨架
/// 行距才能和加载完成后的行距一致；[lines] 默认 2（标题 / 副标题）。
class SkeletonRow extends StatelessWidget {
  const SkeletonRow({
    super.key,
    required this.gap,
    this.lines = 2,
    this.coverSize = TrackRow.defaultCoverSize,
  });

  /// 底部行距。
  final double gap;

  /// 文字块行数：第一行按 bodyLarge 排，其余按 bodyMedium。
  final int lines;

  /// 封面块边长：默认与曲目行同档；列表型卡片（如歌单）传宿主自己的封面尺寸。
  final double coverSize;

  static const List<double> _widthFactors = [0.55, 0.35];

  @override
  Widget build(BuildContext context) {
    final type = context.typeScale;
    return Padding(
      padding: EdgeInsets.only(bottom: gap),
      child: Row(
        children: [
          SkeletonBlock(width: coverSize, height: coverSize, radius: 10),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < lines; i++) ...[
                  if (i > 0) const SizedBox(height: 4),
                  SkeletonBlock(
                    widthFactor: _widthFactors[i % _widthFactors.length],
                    height: scaledLineHeightOf(
                      context,
                      i == 0 ? type.bodyLarge : type.bodyMedium,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 歌单网格卡骨架：方形封面块 + 两行文字块。
///
/// [coverSize] 由调用方按真实卡片的封面公式给出（`tileWidth - 卡片内边距`）：
/// 用「网格单元高度减去文字块」反推会在字体余量（`scaledRowExtentOf` 的
/// allowance）上差几个 dp，加载完成时封面会缩一下。
class SkeletonGridTile extends StatelessWidget {
  const SkeletonGridTile({super.key, required this.coverSize});

  /// 封面块边长（与真实卡片同一份计算）。
  final double coverSize;

  /// 卡片内边距，与 M3E 卡片一致。
  static const double _padding = 8;

  @override
  Widget build(BuildContext context) {
    final type = context.typeScale;
    final titleLine = scaledLineHeightOf(context, type.titleSmall);
    final subtitleLine = scaledLineHeightOf(context, type.bodySmall);
    return Padding(
      padding: const EdgeInsets.all(_padding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBlock(width: coverSize, height: coverSize, radius: 10),
          const SizedBox(height: 8),
          // 与真实卡片同高：标题占两行、副标题一行，加载完成后文字基线不跳。
          SkeletonBlock(height: titleLine * 2, widthFactor: 0.8),
          const SizedBox(height: 2),
          SkeletonBlock(height: subtitleLine, widthFactor: 0.5),
        ],
      ),
    );
  }
}
