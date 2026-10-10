import 'package:flutter/physics.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'library_cover.dart';

/// hover 行形状：M3E 规范 `ItemHoveredContainerExpressiveShape` = shape
/// medium（12dp）；press / focus / 选中是 shape large（16dp，取主题
/// `M3EListItemTheme.selectedRadius`）。
const BorderRadius _hoverRadius =
    BorderRadius.all(Radius.circular(12));

/// 固定行高的曲目行（队列 / 收藏 / 历史 / 发现页共用）。
///
/// 行高固定为 [extent]（标题/歌手都单行省略），列表可以传 `itemExtent`
/// 预取高度（分段列表再加 [gapOf] 行距），滚动条拇指尺寸与拖动定位精确。
///
/// 表面用底层 [M3ECard] 自绘，形状按 M3E 列表规范（Compose `ListTokens`）：
/// 静止内 4dp / 首末外侧 16dp（[calculateCardRadius]），hover 12dp，
/// press / focus / 选中 16dp，并带 expressive spatial 弹簧的 shape morph。
///
/// 为什么不用 `M3EListItem` / `M3EListRowSurface`（见 docs/pitfalls.md #20）：
/// 1. `M3EListItem` 的 supportingText 固定 `maxLines: 2`、容器高度是
///    `minHeight`，长歌手名会把行撑高，懒加载列表无法给出精确 extent；
/// 2. `M3EListRowSurface` 的圆角由 `M3EListItemTheme.radiusFor` 重算：
///    hover / press / focus / 选中一律跳到 `selectedRadius`（16dp）、无视
///    调用方传入的静止圆角，且瞬间切换（没有规范要求的 shape morph）。
class TrackRow extends StatelessWidget {
  const TrackRow({
    super.key,
    required this.title,
    this.artist = '',
    this.coverUrl,
    this.coverSize = 44,
    this.trailingText,
    this.trailing,
    this.selected = false,
    this.showCheckWhenSelected = true,
    this.position = M3ECardPosition.single,
    this.onTap,
    this.onLongPress,
  });

  /// 固定行高：可直接作为 `itemExtent` / `SliverFixedExtentList` 的高度
  /// （分段列表需再加 [gapOf] 行距）。
  static const double extent = 72;

  final String title;
  final String artist;
  final String? coverUrl;
  final double coverSize;

  /// 行尾元信息（时长/计数），未知时传 null 不占位。
  final String? trailingText;

  /// 行尾插槽（排序把手、菜单按钮等）。
  final Widget? trailing;

  final bool selected;

  /// 多选态下把封面翻转为勾选图标；播放队列的选中行不需要。
  final bool showCheckWhenSelected;

  /// 行在列表中的位置：决定静止形状（首/末行外侧 16dp、内行 4dp）。
  /// 由列表用 `calculateCardPosition(index, count)` 计算。
  final M3ECardPosition position;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 分段列表的相邻行距（M3E 列表卡片 token）。
  /// 列表 itemExtent 用 `TrackRow.extent + TrackRow.gapOf(context)`。
  static double gapOf(BuildContext context) =>
      M3ETheme.of(context).listTheme.cardList.gap;

  @override
  Widget build(BuildContext context) {
    final M3EThemeData m3e = M3ETheme.of(context);
    final M3EColorScheme scheme = m3e.colorScheme;
    final M3ETypeScale type = m3e.typeScale;
    final Color contentColor =
        selected ? scheme.onSecondaryContainer : scheme.onSurface;
    final Color supportingColor =
        selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;

    return _TrackRowSurface(
      position: position,
      selected: selected,
      color: scheme.surfaceContainerHighest,
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel: artist.isEmpty ? title : '$title, $artist',
      child: SizedBox(
        height: extent,
        child: Row(
          children: [
            _buildLeading(context, scheme),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.bodyLarge.copyWith(color: contentColor),
                  ),
                  if (artist.isNotEmpty)
                    Text(
                      artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.bodyMedium.copyWith(color: supportingColor),
                    ),
                ],
              ),
            ),
            if (trailingText != null) ...[
              const SizedBox(width: 12),
              Text(
                trailingText!,
                style: type.labelSmall.copyWith(color: supportingColor),
              ),
            ],
            if (trailing != null) ...[
              const SizedBox(width: 12),
              IconTheme.merge(
                data: IconThemeData(color: supportingColor, size: 20),
                child: trailing!,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 缩略图 / 多选勾选翻转（M3E 列表的 selectedIcon 语义）。
  Widget _buildLeading(BuildContext context, M3EColorScheme scheme) {
    final Widget cover = LibraryCoverThumb(url: coverUrl, size: coverSize);
    if (!showCheckWhenSelected) return cover;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: selected
          ? Icon(
              Icons.check_circle_rounded,
              key: const ValueKey<String>('selected'),
              size: coverSize * 0.7,
              color: scheme.onSecondaryContainer,
            )
          : KeyedSubtree(
              key: const ValueKey<String>('cover'),
              child: cover,
            ),
    );
  }
}

/// 曲目行表面：按交互状态计算目标形状，交给 [_RadiusMorph] 做弹簧 morph。
class _TrackRowSurface extends StatefulWidget {
  const _TrackRowSurface({
    required this.position,
    required this.selected,
    required this.color,
    required this.onTap,
    required this.onLongPress,
    required this.semanticLabel,
    required this.child,
  });

  final M3ECardPosition position;
  final bool selected;

  /// 静止底色（选中行取主题 selectedColor）。
  final Color color;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String semanticLabel;
  final Widget child;

  @override
  State<_TrackRowSurface> createState() => _TrackRowSurfaceState();
}

class _TrackRowSurfaceState extends State<_TrackRowSurface> {
  M3EInteractionState _interaction = const M3EInteractionState();

  void _onStateChanged(M3EInteractionState state) {
    if (state == _interaction) return;
    setState(() => _interaction = state);
  }

  @override
  Widget build(BuildContext context) {
    final M3EThemeData m3e = M3ETheme.of(context);
    final M3EColorScheme scheme = m3e.colorScheme;
    final M3EListItemTheme itemTheme = m3e.listTheme.item;
    final M3EListCardListTheme cardList = m3e.listTheme.cardList;
    final M3ECardTheme cardTheme = m3e.cardTheme;

    // 静止形状：分段列表的内/外圆角（中间行 4dp，首末行外侧 16dp）。
    final BorderRadius resting = calculateCardRadius(
      position: widget.position,
      outerRadius: cardList.outerRadius,
      innerRadius: cardList.innerRadius,
    );
    // press / focus / 选中 = shape large（16dp）；hover = shape medium（12dp）。
    final BorderRadius active =
        BorderRadius.circular(itemTheme.selectedRadius);
    final BorderRadius target;
    if (widget.selected || _interaction.pressed || _interaction.focused) {
      target = active;
    } else if (_interaction.hovered) {
      target = _hoverRadius;
    } else {
      target = resting;
    }
    final Color fill =
        widget.selected ? itemTheme.selectedColor(scheme) : widget.color;

    return _RadiusMorph(
      radius: target,
      spring: cardList.radiusSpring,
      builder: (BuildContext context, BorderRadius radius) => M3ECard(
        variant: M3ECardVariant.filled,
        borderRadius: radius,
        color: fill,
        // 显式传静止档：行不因 hover/press 抬升阴影（对齐 M3EListRowSurface）。
        elevation:
            cardTheme.elevation(M3ECardVariant.filled, hovered: false),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        onPressed: widget.onTap,
        onLongPress: widget.onLongPress,
        trackHover: true,
        // 焦点环/焦点填充保持关闭（与既有列表行一致；键盘焦点形状仍会 morph）。
        showFocusRing: false,
        showFocusFill: false,
        width: double.infinity,
        animationDuration: Duration.zero,
        semanticLabel: widget.semanticLabel,
        onStateChanged: _onStateChanged,
        child: widget.child,
      ),
    );
  }
}

/// 弹簧驱动的 `BorderRadius` morph（对齐包内 `M3ECardListItem` 的
/// `M3ECardRadiusMotion`，但它是包内部件，未导出）。
///
/// 目标变化时把当前插值形状作为起点、重新起一根 expressive spatial 弹簧；
/// 结束帧吸附到目标值，避免弹簧容差带来的亚像素偏差。
class _RadiusMorph extends StatefulWidget {
  const _RadiusMorph({
    required this.radius,
    required this.spring,
    required this.builder,
  });

  final BorderRadius radius;
  final M3ESpring spring;
  final Widget Function(BuildContext context, BorderRadius radius) builder;

  @override
  State<_RadiusMorph> createState() => _RadiusMorphState();
}

class _RadiusMorphState extends State<_RadiusMorph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  late BorderRadius _from;
  late BorderRadius _to;

  @override
  void initState() {
    super.initState();
    _from = widget.radius;
    _to = widget.radius;
  }

  @override
  void didUpdateWidget(covariant _RadiusMorph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.radius == widget.radius &&
        oldWidget.spring == widget.spring) {
      return;
    }
    _from = BorderRadius.lerp(_from, _to, _controller.value) ?? _to;
    _to = widget.radius;
    _controller.value = 0;
    final TickerFuture flight = _controller.animateWith(
      SpringSimulation(widget.spring.toDescription(), 0, 1, 0),
    );
    // 弹簧在容差范围内结束（终点值可能略偏）：收尾时吸附到精确目标。
    flight.whenCompleteOrCancel(() {
      if (mounted && !_controller.isAnimating) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? _) {
        final BorderRadius radius = _controller.isAnimating
            ? (BorderRadius.lerp(_from, _to, _controller.value) ?? _to)
            : widget.radius;
        return widget.builder(context, radius);
      },
    );
  }
}
