import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motor/motor.dart';

/// hover 行形状：M3E 规范 `ItemHoveredContainerExpressiveShape` = shape
/// medium（12dp）；press / focus / 选中是 shape large（16dp，取主题
/// `M3EListItemTheme.selectedRadius`）。
const BorderRadius _hoverRadius = BorderRadius.all(Radius.circular(12));

/// M3E 分段列表的卡片行表面（形状规范 + expressive 弹簧 morph）。
///
/// 静止形状按 [position]：内行 4dp、首末行外侧 16dp（`calculateCardRadius`）；
/// hover 12dp；press / focus / 选中 16dp，形状变化走 spatial 弹簧。
///
/// 为什么不直接用 `M3EListItem` / `M3EListRowSurface`（见 docs/pitfalls.md #20）：
/// 1. `M3EListItem` 的 supportingText 固定 `maxLines: 2`、容器高度是
///    `minHeight`，长文本会把行撑高，懒加载列表无法给出精确 extent；
/// 2. `M3EListRowSurface` 的圆角由 `M3EListItemTheme.radiusFor` 重算：
///    hover / press / focus / 选中一律跳到 `selectedRadius`（16dp）、无视
///    调用方传入的静止圆角，且瞬间切换（没有规范要求的 shape morph）。
///
/// 使用面：TrackRow（队列/收藏/历史/发现）、设置页行、AI 推荐卡等所有
/// 「分段列表 + 卡片行」的界面，保证形状与动效同源。
class CardListSurface extends StatefulWidget {
  const CardListSurface({
    super.key,
    required this.position,
    required this.onPressed,
    required this.child,
    this.selected = false,
    this.color,
    this.onLongPress,
    this.semanticLabel,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  /// 行在列表中的位置：决定静止形状（首/末行外侧 16dp、内行 4dp）。
  /// 由列表用 `calculateCardPosition(index, count)` 计算。
  final M3ECardPosition position;

  /// 选中态：底色取主题 selectedColor，形状取 16dp。
  final bool selected;

  /// 静止底色；缺省取 `surfaceContainerHighest`。
  final Color? color;

  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final String? semanticLabel;

  /// 行内边距（行高由内容决定，padding 由调用方给）。
  final EdgeInsetsGeometry padding;

  final Widget child;

  @override
  State<CardListSurface> createState() => _CardListSurfaceState();
}

class _CardListSurfaceState extends State<CardListSurface> {
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
    final Color fill = widget.selected
        ? itemTheme.selectedColor(scheme)
        : (widget.color ?? scheme.surfaceContainerHighest);

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
        padding: widget.padding,
        onPressed: widget.onPressed,
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
/// `M3ECardRadiusMotion`，但它是包内部件、未导出）。
///
/// 目标变化时把当前插值形状作为起点、重新起一根 expressive spatial 弹簧；
/// 直接用 motor（M3E 组件库同款驱动），`snapToEnd` 保证落定精确吸附目标。
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
  late final SingleMotionController _controller = SingleMotionController(
    motion: SpringMotion(widget.spring.toDescription(), snapToEnd: true),
    vsync: this,
    initialValue: 1,
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
  void dispose() {
    _controller.dispose();
    super.dispose();
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
    if (oldWidget.spring != widget.spring) {
      _controller.motion =
          SpringMotion(widget.spring.toDescription(), snapToEnd: true);
    }
    _controller.animateTo(1, from: 0, withVelocity: 0);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? _) {
        return widget.builder(
          context,
          BorderRadius.lerp(_from, _to, _controller.value) ?? _to,
        );
      },
    );
  }
}
