/// 听歌热力图：日历热力图（hero）与星期 × 时段作息热力图。
///
/// 形状与动效（issue #8 已拍板 + 首轮实机反馈修订）：
/// - 静默格子 = `M3EShapeKind.square`（小圆角方，密集可读），色阶主导：
///   空日 `surfaceContainerHighest`，有数据 `primary` 四档 alpha
///   （0.30 / 0.50 / 0.75 / 1.0）——**卡片底色必须比空日格低一档**
///   （页面传 `surfaceContainerLow`），否则空格与卡片同色不可见；
/// - 日历网格最少填满卡片宽度，且首播日之前的补位日渲染为空方格
///   （GitHub 式底格），不可点、无 tooltip；
/// - 悬停/按压 → `Morph(square → puffy)` 多边形形变 + 放大 1.25×，
///   120ms `easeOutCubic` 进入、200ms 回弹；
/// - 选中的一天保持放大 + `primary` 1.5dp 描边（弹层关闭后复原）；
/// - 命中区 = 格子 + 格距（相邻格无死区，手机 ≈17dp）；范围外（早于
///   高亮起点）的格子降透明度而非包 `Opacity`，避免逐格合成层；
/// - 星期标签隔行显示（一/三/五/日）：行距小于字高时全显示会互相遮挡。
library;

import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 色阶档位数（0 = 无数据 + 4 档有数据）。
const int heatmapLevelCount = 5;

/// 档位 → 颜色（唯一色阶来源；图例与格子共用）。
Color heatmapLevelColor(ColorScheme scheme, int level) => switch (level) {
      0 => scheme.surfaceContainerHighest,
      1 => scheme.primary.withValues(alpha: 0.30),
      2 => scheme.primary.withValues(alpha: 0.50),
      3 => scheme.primary.withValues(alpha: 0.75),
      _ => scheme.primary,
    };

/// 色阶阈值：从非零值取四分位（自适应数据密度）。
class _HeatLevels {
  const _HeatLevels(this.t1, this.t2, this.t3);

  final int t1;
  final int t2;
  final int t3;

  factory _HeatLevels.of(Iterable<int> values) {
    final positive = [
      for (final value in values)
        if (value > 0) value,
    ]..sort();
    if (positive.isEmpty) return const _HeatLevels(0, 0, 0);
    int at(double p) =>
        positive[math.min(positive.length - 1, (positive.length * p).floor())];
    return _HeatLevels(at(0.25), at(0.5), at(0.75));
  }

  int levelOf(int value) {
    if (value <= 0) return 0;
    if (value <= t1) return 1;
    if (value <= t2) return 2;
    if (value <= t3) return 3;
    return 4;
  }
}

/// 格子轮廓：`Morph(square → puffy)` 按进度取值并适配到格子尺寸
/// （与包内 `M3EShapeClipper` 同一套 polygon → Path → 缩放配方）。
class _MorphCellClipper extends CustomClipper<Path> {
  const _MorphCellClipper(this.progress);

  final double progress;

  /// Morph 构造会做曲线匹配（较重），只构建一次。
  static final Morph _morph = Morph(
    M3EMaterialNewShapes.square,
    M3EMaterialNewShapes.puffy,
  );

  @override
  Path getClip(Size size) {
    if (size.isEmpty) return Path();
    final source = _morph.toPath(progress: progress);
    final bounds = source.getBounds();
    if (bounds.isEmpty) return Path();
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

  @override
  bool shouldReclip(covariant _MorphCellClipper oldClipper) =>
      oldClipper.progress != progress;
}

/// 单个热力格子（悬停/按压形变 + 放大；选中态描边）。
class _HeatCell extends StatefulWidget {
  const _HeatCell({
    super.key,
    required this.size,
    required this.gap,
    required this.color,
    this.selected = false,
    this.tooltip,
    this.onTap,
  });

  final double size;
  final double gap;
  final Color color;
  final bool selected;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  State<_HeatCell> createState() => _HeatCellState();
}

class _HeatCellState extends State<_HeatCell>
    with SingleTickerProviderStateMixin {
  static const Duration _expandDuration = Duration(milliseconds: 120);
  static const Duration _settleDuration = Duration(milliseconds: 200);
  static const double _hoverScale = 0.25;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _expandDuration,
  );
  late final Animation<double> _progress = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInOutCubic,
  );

  bool _hovered = false;
  bool _pressed = false;

  bool get _active => widget.selected || _hovered || _pressed;

  @override
  void initState() {
    super.initState();
    if (widget.selected) _controller.value = 1;
  }

  @override
  void didUpdateWidget(covariant _HeatCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) _sync();
  }

  void _setHovered(bool value) {
    if (_hovered == value) return;
    _hovered = value;
    _sync();
  }

  void _setPressed(bool value) {
    if (_pressed == value) return;
    _pressed = value;
    _sync();
  }

  void _sync() {
    if (_active) {
      _controller.duration = _expandDuration;
      _controller.forward();
    } else {
      _controller.duration = _settleDuration;
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hitSize = widget.size + widget.gap;

    final content = MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: Listener(
        onPointerDown: (_) => _setPressed(true),
        onPointerUp: (_) => _setPressed(false),
        onPointerCancel: (_) => _setPressed(false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: SizedBox(
            width: hitSize,
            height: hitSize,
            child: Center(
              child: AnimatedBuilder(
                animation: _progress,
                builder: (context, _) {
                  final side =
                      widget.size * (1 + _hoverScale * _progress.value);
                  final clipper = _MorphCellClipper(_progress.value);
                  return SizedBox(
                    width: side,
                    height: side,
                    child: ClipPath(
                      clipper: clipper,
                      child: widget.selected
                          // 选中描边：略大的 primary 形状 + 内嵌格子色。
                          ? ColoredBox(
                              color: scheme.primary,
                              child: Padding(
                                padding: const EdgeInsets.all(1.5),
                                child: ClipPath(
                                  clipper: clipper,
                                  child: ColoredBox(color: widget.color),
                                ),
                              ),
                            )
                          : ColoredBox(color: widget.color),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    final tooltip = widget.tooltip;
    if (tooltip == null) return content;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: content,
    );
  }
}

/// 日历热力图（横轴周、纵轴星期一~日；横向滚动，初始对齐"今天"）。
class CalendarHeatmap extends StatefulWidget {
  const CalendarHeatmap({
    super.key,
    required this.values,
    required this.firstDay,
    required this.lastDay,
    required this.tooltipFor,
    this.selectedDay,
    this.highlightFrom,
    this.onDayTap,
    this.cellSize = 12,
    this.cellGap = 3,
  });

  /// 日期（本地日零点）→ 值（收听毫秒或有效播放次数）。
  final Map<DateTime, int> values;

  /// 数据范围（含；必须为日零点）。
  final DateTime firstDay;
  final DateTime lastDay;

  /// 单格 tooltip 文案（由页面提供 l10n）。
  final String Function(DateTime day, int value) tooltipFor;

  final DateTime? selectedDay;

  /// 高亮起点（更早的天降透明度）；null = 全部高亮。
  final DateTime? highlightFrom;

  final ValueChanged<DateTime>? onDayTap;
  final double cellSize;
  final double cellGap;

  @override
  State<CalendarHeatmap> createState() => _CalendarHeatmapState();
}

class _CalendarHeatmapState extends State<CalendarHeatmap> {
  static const double _headerHeight = 16;
  static const double _labelWidth = 24;

  final ScrollController _controller = ScrollController();

  /// 网格起点：第一天的所在周（周一）。
  DateTime get _gridStart =>
      widget.firstDay.subtract(Duration(days: widget.firstDay.weekday - 1));

  int get _weekCount {
    final days = widget.lastDay.difference(_gridStart).inDays + 1;
    return (days / 7).ceil();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jumpToToday();
    });
  }

  @override
  void didUpdateWidget(covariant CalendarHeatmap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lastDay != widget.lastDay ||
        oldWidget.firstDay != widget.firstDay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToToday();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _jumpToToday() {
    if (!_controller.hasClients) return;
    _controller.jumpTo(_controller.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontSize: 10,
          height: 1.0,
        );
    final narrow = MaterialLocalizations.of(context).narrowWeekdays;
    final levels = _HeatLevels.of(widget.values.values);
    final rowHeight = widget.cellSize + widget.cellGap;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 最少窗口：不足时向左补列（补位日渲染为空方格），保证网格铺满卡片。
        final rawWeeks = _weekCount;
        final pitch = widget.cellSize + widget.cellGap;
        final minWeeks =
            math.max(1, ((constraints.maxWidth - _labelWidth) / pitch).ceil());
        final weeks = math.max(rawWeeks, minWeeks);
        final gridStart =
            _gridStart.subtract(Duration(days: (weeks - rawWeeks) * 7));

        return SizedBox(
          height: _headerHeight + 7 * rowHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: _labelWidth,
                child: Column(
                  children: [
                    const SizedBox(height: _headerHeight),
                    for (var row = 0; row < 7; row++)
                      SizedBox(
                        height: rowHeight,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            // 星期一 / 三 / 五（narrowWeekdays 0 = 周日）。
                            row == 0 || row == 2 || row == 4
                                ? narrow[(row + 1) % 7]
                                : '',
                            style: labelStyle,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: _controller,
                  scrollDirection: Axis.horizontal,
                  itemCount: weeks,
                  itemBuilder: (context, week) => _buildWeek(
                    context,
                    gridStart.add(Duration(days: week * 7)),
                    levels,
                    labelStyle,
                    rowHeight,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildWeek(
    BuildContext context,
    DateTime start,
    _HeatLevels levels,
    TextStyle? labelStyle,
    double rowHeight,
  ) {
    // 月份标签：本周包含某月 1 日时在列首显示。只保留月份名（去 4 位年份），
    // 否则 "September 2026" 这类长标签会与下个月标签重叠（列距只有 4 周）。
    String? monthLabel;
    for (var i = 0; i < 7; i++) {
      final day = start.add(Duration(days: i));
      if (day.day == 1) {
        final raw = MaterialLocalizations.of(context).formatMonthYear(day);
        monthLabel = raw.replaceAll(RegExp(r'\s*\d{4}\s*年?'), ' ').trim();
        break;
      }
    }

    return Column(
      children: [
        SizedBox(
          // 列宽与格子一致；月份标签允许向右溢出（横向列表里必须给定宽，
          // 否则 OverflowBox 在无界宽度下无法布局）。
          width: widget.cellSize + widget.cellGap,
          height: _headerHeight,
          child: monthLabel == null
              ? null
              : OverflowBox(
                  maxWidth: 84,
                  alignment: Alignment.centerLeft,
                  child: Text(monthLabel, style: labelStyle),
                ),
        ),
        for (var i = 0; i < 7; i++)
          _buildDayCell(
            context,
            start.add(Duration(days: i)),
            levels,
            rowHeight,
          ),
      ],
    );
  }

  Widget _buildDayCell(
    BuildContext context,
    DateTime day,
    _HeatLevels levels,
    double rowHeight,
  ) {
    final hitWidth = widget.cellSize + widget.cellGap;
    // 今天之后不渲染（窗口右端 = 今天）。
    if (day.isAfter(widget.lastDay)) {
      return SizedBox(width: hitWidth, height: rowHeight);
    }
    final inRange =
        !day.isBefore(widget.firstDay) && !day.isAfter(widget.lastDay);
    // 数据范围之前：补位空方格（GitHub 式底格），不可点、无 tooltip。
    final value = inRange ? (widget.values[day] ?? 0) : 0;
    var color = heatmapLevelColor(
      Theme.of(context).colorScheme,
      levels.levelOf(value),
    );
    final highlightFrom = widget.highlightFrom;
    if (inRange && highlightFrom != null && day.isBefore(highlightFrom)) {
      // 范围外降透明度（Color 直算，避免逐格 Opacity 合成层）。
      color = color.withValues(alpha: color.a * 0.35);
    }

    final onDayTap = widget.onDayTap;
    return _HeatCell(
      key: ValueKey<int>(day.millisecondsSinceEpoch),
      size: widget.cellSize,
      gap: widget.cellGap,
      color: color,
      selected: inRange && widget.selectedDay == day,
      tooltip: inRange ? widget.tooltipFor(day, value) : null,
      onTap: inRange && onDayTap != null ? () => onDayTap(day) : null,
    );
  }
}

/// 星期 × 时段作息热力图（7 行 × 24 列，自适应填满宽度，不滚动）。
class WeekdayHourHeatmap extends StatelessWidget {
  const WeekdayHourHeatmap({
    super.key,
    required this.values,
    required this.tooltipFor,
    this.cellGap = 3,
    this.maxCellSize = 24,
  });

  /// `[weekday 0=周一][hour 0-23]` 的值（收听毫秒或有效播放次数）。
  final List<List<int>> values;

  final String Function(int weekday, int hour, int value) tooltipFor;
  final double cellGap;
  final double maxCellSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontSize: 10,
          height: 1.0,
        );
    final narrow = MaterialLocalizations.of(context).narrowWeekdays;
    final levels = _HeatLevels.of([for (final row in values) ...row]);
    const labelWidth = 24.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 每格占位 = cell + gap（末尾也算 gap），保证 24 列与分组表头对齐。
        final ideal = (constraints.maxWidth - labelWidth) / 24 - cellGap;
        final cell = ideal.clamp(6.0, maxCellSize);
        final contentWidth = labelWidth + 24 * (cell + cellGap);
        final rowHeight = cell + cellGap;
        final grid = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 小时标签：每 6 小时一组（左对齐组宽，无溢出）。
            Padding(
              padding: const EdgeInsets.only(left: labelWidth),
              child: Row(
                children: [
                  for (var hour = 0; hour < 24; hour += 6)
                    SizedBox(
                      width: 6 * (cell + cellGap),
                      height: 14,
                      child: Text('$hour', style: labelStyle),
                    ),
                ],
              ),
            ),
            for (var weekday = 0; weekday < 7; weekday++)
              Row(
                children: [
                  SizedBox(
                    width: labelWidth,
                    height: rowHeight,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          // 隔行显示（一/三/五/日）：行距小于字高时
                          // 全显示会互相遮挡。
                          weekday.isEven ? narrow[(weekday + 1) % 7] : '',
                          style: labelStyle,
                        ),
                      ),
                    ),
                  ),
                  for (var hour = 0; hour < 24; hour++)
                    _HeatCell(
                      size: cell,
                      gap: cellGap,
                      color: heatmapLevelColor(
                        scheme,
                        levels.levelOf(values[weekday][hour]),
                      ),
                      tooltip: tooltipFor(
                        weekday,
                        hour,
                        values[weekday][hour],
                      ),
                    ),
                ],
              ),
          ],
        );
        // 极窄屏（逻辑宽 < ~310dp）放不下时退化为横向滚动，避免溢出。
        if (contentWidth <= constraints.maxWidth + 0.5) return grid;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: contentWidth, child: grid),
        );
      },
    );
  }
}

/// 色阶图例（5 档色块，浅 → 深）。
class HeatmapLegend extends StatelessWidget {
  const HeatmapLegend({super.key, this.cellSize = 12, this.cellGap = 3});

  final double cellSize;
  final double cellGap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var level = 0; level < heatmapLevelCount; level++) ...[
          if (level > 0) SizedBox(width: cellGap),
          Container(
            width: cellSize,
            height: cellSize,
            decoration: BoxDecoration(
              color: heatmapLevelColor(scheme, level),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ],
      ],
    );
  }
}
