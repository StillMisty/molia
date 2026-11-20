/// 热力图的网格级交互 / 绘制实现（`listening_heatmap.dart` 的 part）。
///
/// 拆出本文件只为守住 800 行棘轮；本 part 与宿主共享私有声明
/// （[_HeatGridState] / [_MorphCellClipCache] / [_HeatLevels] 等）。
part of 'listening_heatmap.dart';

/// 格子轮廓路径缓存：`Morph(square → puffy)` 按进度取值并适配到格子尺寸
/// （与包内 `M3EShapeClipper` 同一套 polygon → Path → 缩放配方）。
///
/// 为什么要缓存：`Morph.toPath` 每次都要重新插值全部 cubic 并重建 Path。
/// profile 微基准（Linux / AOT，`integration_test/morph_benchmark_test.dart`）
/// 单次 p50 8µs、均值 13–14µs；开页首帧所有格子都是 progress = 0，日历 +
/// 作息合计 700+ 格逐个计算 ≈ 6ms，cubic / Path 的分配还会推高同帧 GC。
/// 缓存后静态格子共用一条已适配的 Path，命中成本实测 0.01µs。
///
/// 键是**精确** progress + 尺寸：静止格子恒为 0 / 1，命中率接近 100%；悬停
/// 动画每帧只产生一个新键，不会出现量化带来的形状阶梯。LRU 上限 256，
/// 持续划过很多格子也不会无限增长。
class _MorphCellClipCache {
  _MorphCellClipCache._();

  /// Morph 构造会做曲线匹配（较重），只构建一次。
  static final Morph _morph = Morph(
    M3EMaterialNewShapes.square,
    M3EMaterialNewShapes.puffy,
  );

  static const int _maxEntries = 256;

  /// `(progress, width, height) → 已适配 Path`，按访问顺序淘汰最旧项。
  static final LinkedHashMap<(double, double, double), Path> _cache =
      LinkedHashMap();

  static Path of(double progress, Size size) {
    if (size.isEmpty) return Path();
    final key = (progress, size.width, size.height);
    final cached = _cache.remove(key);
    if (cached != null) {
      // 重新插入把它移到队尾（LRU）。
      _cache[key] = cached;
      return cached;
    }
    final path = _build(progress, size);
    if (path == null) return Path();
    _cache[key] = path;
    if (_cache.length > _maxEntries) _cache.remove(_cache.keys.first);
    return path;
  }

  static Path? _build(double progress, Size size) {
    final source = _morph.toPath(progress: progress);
    final bounds = source.getBounds();
    if (bounds.isEmpty) return null;
    final matrix = Matrix4.identity()
      ..scaleByDouble(
        size.width / bounds.width,
        size.height / bounds.height,
        1,
        1,
      )
      ..translateByDouble(-bounds.left, -bounds.top, 0, 1);
    return source.transform(matrix.storage);
  }
}

/// 单个格子的绘制配方：缓存的 morph 路径按进度缩放后填充（选中态多一圈描边）。
///
/// 网格底色 / 选中格 / 悬停格共用这一份实现，形状与改动前一致。
final Paint _cellPaint = Paint();

/// 悬停最多放大 25%（原实现放大外层 SizedBox，现在在 painter 里缩放路径）。
const double _hoverScale = 0.25;

void _paintHeatCell(
  Canvas canvas,
  Size size,
  double progress, {
  required double cellSize,
  required Color color,
  required Color outlineColor,
  required bool selected,
}) {
  final side = cellSize * (1 + _hoverScale * progress);
  if (side <= 0) return;
  final origin = Offset((size.width - side) / 2, (size.height - side) / 2);
  final outer = _MorphCellClipCache.of(progress, Size.square(side));

  canvas
    ..save()
    ..translate(origin.dx, origin.dy);
  if (selected && side > 3) {
    // 选中描边：外圈 primary 形状 + 内缩 1.5dp 的格子色。
    const inset = 1.5;
    canvas
      ..drawPath(outer, _cellPaint..color = outlineColor)
      ..save()
      ..translate(inset, inset)
      ..drawPath(
        _MorphCellClipCache.of(progress, Size.square(side - inset * 2)),
        _cellPaint..color = color,
      )
      ..restore();
  } else {
    canvas.drawPath(outer, _cellPaint..color = color);
  }
  canvas.restore();
}

/// 一个网格级的可交互热力格子图层。
///
/// 颜色 / tooltip / 命中全部按扁平索引（行优先）处理；网格只负责：
/// - 用 `_HeatGridPainter` 一次画完所有底色格（数据不变就不 repaint）；
/// - 用指针局部坐标反算格子，悬停时只更新一个放大格 overlay 与一个 Tooltip；
/// - 通过 `semanticsBuilder` 给每格生成纯语义节点。
class _HeatGrid extends StatefulWidget {
  const _HeatGrid({
    required this.rows,
    required this.columns,
    required this.cellSize,
    required this.cellGap,
    required this.colors,
    required this.tooltipAt,
    this.selectedIndex,
    this.onTapAt,
    this.gridKey,
  });

  final int rows;
  final int columns;
  final double cellSize;
  final double cellGap;

  /// 行优先色值，长度必须等于 `rows * columns`；null = 该格不存在
  /// （不绘制、不命中、无语义）。
  final List<Color?> colors;

  /// 单格 tooltip / 语义文案；null = 该格无提示（补位空日、今天之后）。
  /// 惰性调用：开页时不预先格式化 400+ 条日期文案。
  final String? Function(int index) tooltipAt;

  /// 选中格索引（日历热力图）；在网格上方单独绘制放大 + 描边。
  final int? selectedIndex;

  /// 可点格回调；null = 整张图不可点。
  final void Function(int index)? onTapAt;

  /// 供测试定位网格（每张热力图只有一个 `CustomPaint` 承载全部格子）。
  final Key? gridKey;

  double get pitch => cellSize + cellGap;

  @override
  State<_HeatGrid> createState() => _HeatGridState();
}

class _HeatGridState extends State<_HeatGrid>
    with SingleTickerProviderStateMixin {
  /// 当前缩放进度：只驱动悬停 overlay 的 painter，不重建 / 重绘网格。
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);

  /// 弹簧控制器按需创建：没有悬停 / 按压时没有 ticker。
  SingleMotionController? _motion;

  int? _hoverIndex;
  int? _pressedIndex;

  /// 当前放大格（过渡期间保留到缩回 1.0，避免退出时瞬间跳变）。
  int? _overlayIndex;

  /// 当前挂载 Tooltip 的格子；空 = 不占 Tooltip / OverlayPortal 成本。
  int? _tooltipIndex;
  GlobalKey<TooltipState>? _tooltipKey;
  Timer? _tooltipHideTimer;

  /// 每格语义节点的分帧预算：首帧只给一小批，后续帧按批补齐。
  ///
  /// 为什么要分帧：本机开启语义树时，首帧一次建 568 个格子节点（含 4 次
  /// GC）实测 10–19ms，是开页首帧剩下的唯一 >8.33ms 的来源。逐帧补齐后
  /// 每个节点的内容不变，只是晚 ~10 帧（120Hz 下 <100ms）出现；读屏不会
  /// 在开页几十毫秒内就开始逐格朗读，换来的是一直平滑的开页。
  ///
  /// 无障碍在页面打开后才开启时预算已是全量（见 [initState]），不会让
  /// 读屏再等一轮补齐。
  int _semanticsLimit = 0;
  bool _semanticsGrowthScheduled = false;
  static const int _initialSemanticsCells = 48;
  static const int _semanticsCellsPerFrame = 48;

  bool get _semanticsEnabled => SemanticsBinding.instance.semanticsEnabled;

  /// 单格文案缓存（index → tooltip / 语义文案）。
  ///
  /// 语义节点分帧补齐时会反复重放前缀；不缓存的话每补一批都要重新格式化
  /// 数百条日期 / 时长文案（开页帧的纯分配开销）。数据整体替换（colors
  /// 换 list）时清空，悬停 / 长按也走同一份缓存。
  List<Color?>? _textCacheColors;
  final Map<int, String?> _textCache = <int, String?>{};

  String? _textAt(int index) {
    if (!identical(_textCacheColors, widget.colors)) {
      _textCacheColors = widget.colors;
      _textCache.clear();
    }
    return _textCache.putIfAbsent(index, () => widget.tooltipAt(index));
  }

  @override
  void initState() {
    super.initState();
    _semanticsLimit = _semanticsEnabled
        ? _initialSemanticsCells
        : widget.colors.length;
  }

  @override
  void dispose() {
    _tooltipHideTimer?.cancel();
    _motion?.dispose();
    _progress.dispose();
    super.dispose();
  }

  /// 分帧补齐语义节点：每帧最多再暴露 [_semanticsCellsPerFrame] 格。
  void _scheduleSemanticsGrowth() {
    if (_semanticsGrowthScheduled ||
        _semanticsLimit >= widget.colors.length ||
        !_semanticsEnabled) {
      return;
    }
    _semanticsGrowthScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _semanticsGrowthScheduled = false;
      if (!mounted ||
          !_semanticsEnabled ||
          _semanticsLimit >= widget.colors.length) {
        return;
      }
      setState(() {
        _semanticsLimit = math.min(
          _semanticsLimit + _semanticsCellsPerFrame,
          widget.colors.length,
        );
      });
    });
  }

  @override
  void didUpdateWidget(covariant _HeatGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 数据整体替换（切换范围 / 时长↔次数）时，旧索引可能已指向空格。
    final active = _hoverIndex ?? _pressedIndex;
    if (active != null && !_isLive(active)) {
      _hoverIndex = null;
      _pressedIndex = null;
      _overlayIndex = null;
      _progress.value = 0;
    }
    if (_tooltipIndex != null && _textAt(_tooltipIndex!) == null) {
      _tooltipHideTimer?.cancel();
      _tooltipIndex = null;
      _tooltipKey = null;
    }
  }

  bool _isLive(int index) =>
      index >= 0 &&
      index < widget.colors.length &&
      widget.colors[index] != null;

  /// 局部坐标 → 格子索引。命中区 = 格子 + 格距（与改动前逐格容器一致）。
  int? _indexAt(Offset local) {
    final pitch = widget.pitch;
    if (pitch <= 0 || local.dx < 0 || local.dy < 0) return null;
    final col = local.dx ~/ pitch;
    final row = local.dy ~/ pitch;
    if (col >= widget.columns || row >= widget.rows) return null;
    final index = row * widget.columns + col;
    return _isLive(index) ? index : null;
  }

  void _setHover(int? index) {
    if (_hoverIndex == index) return;
    _hoverIndex = index;
    _syncActive();
    if (index == null) {
      _scheduleTooltipHide();
      return;
    }
    if (_tooltipIndex == index) return;
    _tooltipHideTimer?.cancel();
    _tooltipHideTimer = null;
    if (_textAt(index) == null) {
      if (_tooltipIndex != null) {
        setState(() {
          _tooltipIndex = null;
          _tooltipKey = null;
        });
      }
      return;
    }
    _tooltipKey = GlobalKey<TooltipState>();
    setState(() => _tooltipIndex = index);
  }

  void _setPressed(int? index) {
    if (_pressedIndex == index) return;
    _pressedIndex = index;
    _syncActive();
  }

  /// 悬停优先于按压：鼠标按下后移出再抬起仍保持悬停态。
  void _syncActive() {
    final next = _hoverIndex ?? _pressedIndex;
    if (next == null) {
      _animateTo(0);
      return;
    }
    if (_overlayIndex != next) setState(() => _overlayIndex = next);
    _animateTo(1);
  }

  void _scheduleTooltipHide() {
    if (_tooltipIndex == null) return;
    _tooltipHideTimer?.cancel();
    // Tooltip 默认 dismissDelay 也是 ~100ms：先保持可见，再卸载。
    _tooltipHideTimer = Timer(const Duration(milliseconds: 100), () {
      _tooltipHideTimer = null;
      if (!mounted || _hoverIndex != null) return;
      setState(() {
        _tooltipIndex = null;
        _tooltipKey = null;
      });
    });
  }

  void _animateTo(double target) {
    var motion = _motion;
    if (motion == null) {
      if (target == _progress.value) return;
      motion = SingleMotionController(
        motion: const MaterialSpringMotion.standardSpatialFast(snapToEnd: true),
        vsync: this,
        initialValue: _progress.value,
      )..addListener(_onMotionTick);
      _motion = motion;
    }
    motion.animateTo(target);
  }

  void _onMotionTick() {
    final motion = _motion;
    if (motion == null) return;
    final value = motion.value;
    _progress.value = value;
    // 缩回到 1.0（progress 0）后卸掉 overlay：静止时没有额外 RenderObject。
    if (value <= 0.001 &&
        _overlayIndex != null &&
        _hoverIndex == null &&
        _pressedIndex == null) {
      setState(() => _overlayIndex = null);
    }
  }

  void _handleTap(Offset local) {
    final onTap = widget.onTapAt;
    if (onTap == null) return;
    final index = _indexAt(local);
    if (index == null || _textAt(index) == null) return;
    onTap(index);
  }

  void _handleLongPressStart(Offset local) {
    final index = _indexAt(local);
    if (index == null) return;
    if (_textAt(index) == null) return;
    _tooltipHideTimer?.cancel();
    _tooltipHideTimer = null;
    _tooltipKey = GlobalKey<TooltipState>();
    setState(() => _tooltipIndex = index);
    // 触摸端没有鼠标 enter，Tooltip 自己不会排 show 计时；长按结束前保持可见。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tooltipKey?.currentState?.ensureTooltipVisible();
    });
  }

  void _handleLongPressEnd() {
    if (_hoverIndex != null) return;
    _scheduleTooltipHide();
  }

  Widget _cellLayer(int index, CustomPainter painter) {
    final pitch = widget.pitch;
    final col = index % widget.columns;
    final row = index ~/ widget.columns;
    return Positioned(
      left: col * pitch,
      top: row * pitch,
      width: pitch,
      height: pitch,
      child: IgnorePointer(child: CustomPaint(painter: painter)),
    );
  }

  Widget _tooltipLayer(String text) {
    final index = _tooltipIndex!;
    final pitch = widget.pitch;
    final col = index % widget.columns;
    final row = index ~/ widget.columns;
    return Positioned(
      left: col * pitch,
      top: row * pitch,
      width: pitch,
      height: pitch,
      child: Tooltip(
        key: _tooltipKey,
        message: text,
        // 语义由网格 painter 的 semanticsBuilder 提供，避免重复节点。
        excludeFromSemantics: true,
        waitDuration: const Duration(milliseconds: 400),
        child: const SizedBox.expand(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pitch = widget.pitch;
    final overlay = _overlayIndex;
    final selected = widget.selectedIndex;
    final tooltipText = _tooltipIndex == null ? null : _textAt(_tooltipIndex!);
    _scheduleSemanticsGrowth();

    return MouseRegion(
      onHover: (event) => _setHover(_indexAt(event.localPosition)),
      onExit: (_) {
        _hoverIndex = null;
        _syncActive();
        _scheduleTooltipHide();
      },
      child: Listener(
        onPointerDown: (event) => _setPressed(_indexAt(event.localPosition)),
        onPointerUp: (_) => _setPressed(null),
        onPointerCancel: (_) => _setPressed(null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => _handleTap(details.localPosition),
          onLongPressStart: (details) =>
              _handleLongPressStart(details.localPosition),
          onLongPressEnd: (_) => _handleLongPressEnd(),
          child: SizedBox(
            width: widget.columns * pitch,
            height: widget.rows * pitch,
            child: Stack(
              // 放大格会画出自己的命中盒；与改动前逐格绘制一样不裁剪。
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    key: widget.gridKey,
                    painter: _HeatGridPainter(
                      rows: widget.rows,
                      columns: widget.columns,
                      cellSize: widget.cellSize,
                      cellGap: widget.cellGap,
                      colors: widget.colors,
                      tooltipAt: _textAt,
                      onTapAt: widget.onTapAt,
                      textDirection: Directionality.of(context),
                      semanticsLimit: _semanticsLimit,
                    ),
                  ),
                ),
                if (selected != null &&
                    selected != overlay &&
                    _isLive(selected))
                  _cellLayer(
                    selected,
                    _StaticHeatCellPainter(
                      cellSize: widget.cellSize,
                      color: widget.colors[selected]!,
                      outlineColor: scheme.primary,
                    ),
                  ),
                if (overlay != null && _isLive(overlay))
                  _cellLayer(
                    overlay,
                    _AnimatedHeatCellPainter(
                      progress: _progress,
                      cellSize: widget.cellSize,
                      color: widget.colors[overlay]!,
                      outlineColor: scheme.primary,
                      selected: overlay == selected,
                    ),
                  ),
                if (tooltipText != null) _tooltipLayer(tooltipText),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 网格底色：一次画完所有格子（共用一条 progress = 0 的缓存路径）。
class _HeatGridPainter extends CustomPainter {
  _HeatGridPainter({
    required this.rows,
    required this.columns,
    required this.cellSize,
    required this.cellGap,
    required this.colors,
    required this.tooltipAt,
    required this.onTapAt,
    required this.textDirection,
    required this.semanticsLimit,
  });

  final int rows;
  final int columns;
  final double cellSize;
  final double cellGap;
  final List<Color?> colors;
  final String? Function(int index) tooltipAt;
  final void Function(int index)? onTapAt;
  final TextDirection textDirection;

  /// 本次语义构建最多输出多少格（分帧补齐；见 [_HeatGridState]）。
  final int semanticsLimit;

  @override
  void paint(Canvas canvas, Size size) {
    final pitch = cellSize + cellGap;
    final inset = cellGap / 2;
    final path = _MorphCellClipCache.of(0, Size.square(cellSize));
    canvas
      ..save()
      ..translate(inset, inset);
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < columns; col++) {
        final color = colors[row * columns + col];
        if (color != null) canvas.drawPath(path, _cellPaint..color = color);
        canvas.translate(pitch, 0);
      }
      canvas.translate(-columns * pitch, pitch);
    }
    canvas.restore();
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder => (Size size) {
    final pitch = cellSize + cellGap;
    final inset = cellGap / 2;
    final nodes = <CustomPainterSemantics>[];
    for (var index = 0; index < colors.length; index++) {
      if (nodes.length >= semanticsLimit) break;
      if (colors[index] == null) continue;
      final text = tooltipAt(index);
      if (text == null) continue;
      final col = index % columns;
      final row = index ~/ columns;
      final onTap = onTapAt;
      nodes.add(
        CustomPainterSemantics(
          rect: Rect.fromLTWH(
            col * pitch + inset,
            row * pitch + inset,
            cellSize,
            cellSize,
          ),
          properties: SemanticsProperties(
            tooltip: text,
            textDirection: textDirection,
            onTap: onTap == null ? null : () => onTap(index),
          ),
        ),
      );
    }
    return nodes;
  };

  @override
  bool shouldRepaint(covariant _HeatGridPainter oldDelegate) =>
      oldDelegate.rows != rows ||
      oldDelegate.columns != columns ||
      oldDelegate.cellSize != cellSize ||
      oldDelegate.cellGap != cellGap ||
      !identical(oldDelegate.colors, colors);

  @override
  bool shouldRebuildSemantics(covariant _HeatGridPainter oldDelegate) =>
      oldDelegate.semanticsLimit != semanticsLimit ||
      shouldRepaint(oldDelegate);
}

/// 悬停 / 按压格：progress 由弹簧驱动（动画期间只 markNeedsPaint）。
class _AnimatedHeatCellPainter extends CustomPainter {
  _AnimatedHeatCellPainter({
    required this.progress,
    required this.cellSize,
    required this.color,
    required this.outlineColor,
    required this.selected,
  }) : super(repaint: progress);

  final ValueNotifier<double> progress;
  final double cellSize;
  final Color color;
  final Color outlineColor;
  final bool selected;

  @override
  void paint(Canvas canvas, Size size) => _paintHeatCell(
    canvas,
    size,
    progress.value,
    cellSize: cellSize,
    color: color,
    outlineColor: outlineColor,
    selected: selected,
  );

  @override
  bool shouldRepaint(covariant _AnimatedHeatCellPainter oldDelegate) =>
      oldDelegate.cellSize != cellSize ||
      oldDelegate.color != color ||
      oldDelegate.outlineColor != outlineColor ||
      oldDelegate.selected != selected;
}

/// 选中格（弹层打开期间保持放大 + 描边）：静止在 progress = 1。
class _StaticHeatCellPainter extends CustomPainter {
  _StaticHeatCellPainter({
    required this.cellSize,
    required this.color,
    required this.outlineColor,
  });

  final double cellSize;
  final Color color;
  final Color outlineColor;

  @override
  void paint(Canvas canvas, Size size) => _paintHeatCell(
    canvas,
    size,
    1,
    cellSize: cellSize,
    color: color,
    outlineColor: outlineColor,
    selected: true,
  );

  @override
  bool shouldRepaint(covariant _StaticHeatCellPainter oldDelegate) =>
      oldDelegate.cellSize != cellSize ||
      oldDelegate.color != color ||
      oldDelegate.outlineColor != outlineColor;
}
