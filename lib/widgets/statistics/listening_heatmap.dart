/// 听歌热力图：日历热力图（hero）与星期 × 时段作息热力图。
///
/// 形状与动效：
/// - 静默格子 = `M3EShapeKind.square`（小圆角方，密集可读），色阶主导：
///   空日 `surfaceContainerHighest`，有数据 `primary` 四档 alpha
///   （0.30 / 0.50 / 0.75 / 1.0）——**卡片底色必须比空日格低一档**
///   （页面传 `surfaceContainerLow`），否则空格与卡片同色不可见；
/// - 日历网格最少填满卡片宽度，且首播日之前的补位日渲染为空方格
///   （GitHub 式底格），不可点、无 tooltip；
/// - 悬停/按压 → `Morph(square → puffy)` 多边形形变 + 放大 1.25×，
///   motor standard spatial fast 弹簧（快进快出、速度续跑）；
/// - 选中的一天保持放大 + `primary` 1.5dp 描边（弹层关闭后复原）；
/// - 命中区 = 格子 + 格距（相邻格无死区，手机 ≈17dp）；范围外（早于
///   高亮起点）的格子降透明度而非包 `Opacity`，避免逐格合成层；
/// - 星期标签隔行显示（一/三/五/日）：行距小于字高时全显示会互相遮挡。
///
/// 性能结构（为什么不是「每格一个 Widget」）：
/// 开页首帧曾为 700+ 格各建一个 `MouseRegion` / `Listener` /
/// `GestureDetector` / `CustomPaint` / `State`。`ListView` 与 `LayoutBuilder`
/// 都在 layout 阶段建子树，profile 下首帧 LAYOUT ≈45–51ms（嵌套 build ≈27ms
/// + 同帧 GC 17–27ms），是统计页开页的唯一大头。现在整张网格只有：
/// 一个 `CustomPaint`（色块批量绘制）+ 一个指针区域（按局部坐标反算格子）+
/// 一个按需挂载的 `Tooltip`。格子不再有 Element / RenderObject，悬停只移动
/// 一个放大格的 overlay，不重建网格、不 repaint 网格。
///
/// 语义（读屏）仍按格提供：`CustomPainter.semanticsBuilder` 为每格生成一个
/// 纯语义节点（tooltip 文案与悬停同源），不额外建 Widget；显式语义树只在
/// 系统开启无障碍时构建，且 `shouldRebuildSemantics` 只跟随数据 / 尺寸变化。
///
/// 语义节点分帧补齐：一次性建 568 个节点在开页帧实测 10–19ms（含 4 次 GC），
/// 会把已经降到 ~25ms 的内容帧重新推回 40ms+。[_HeatGridState] 首帧只暴露
/// 48 格，之后每帧补 48 格；节点内容不变，只是晚 ~10 帧（120Hz <100ms）出现，
/// 换掉的是整页唯一超过 8.33ms 的语义尖峰。单格文案按格缓存，补齐时重放前缀
/// 不再重复格式化日期 / 时长。最终内容帧剩余的大头是统计页其它卡片与文案
/// （summary / 指标 / 榜单的首轮 text layout ≈15–20ms），不属于本文件。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/semantics.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motor/motor.dart';

import '../../theme/m3e_context.dart';

part 'heatmap_grid.dart';

/// 色阶档位数（0 = 无数据 + 4 档有数据）。
const int heatmapLevelCount = 5;

/// 月份标签去掉 4 位年份（zh 的 `2026年9月` / en 的 `September 2026`）。
///
/// 每列都会走一次；`RegExp` 构造含 pattern 解析，提到顶层复用。
final RegExp _yearInMonthLabel = RegExp(r'\s*\d{4}\s*年?');

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
    final labelStyle = context.typeScale.labelSmall.copyWith(
      color: scheme.onSurfaceVariant,
      fontSize: 10,
      height: 1.0,
    );
    final narrow = MaterialLocalizations.of(context).narrowWeekdays;
    final levels = _HeatLevels.of(widget.values.values);
    final highlightFrom = widget.highlightFrom;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 最少窗口：不足时向左补列（补位日渲染为空方格），保证网格铺满卡片。
        final rawWeeks = _weekCount;
        final pitch = widget.cellSize + widget.cellGap;
        final minWeeks = math.max(
          1,
          ((constraints.maxWidth - _labelWidth) / pitch).ceil(),
        );
        final weeks = math.max(rawWeeks, minWeeks);
        final gridStart = _gridStart.subtract(
          Duration(days: (weeks - rawWeeks) * 7),
        );

        // 行优先色值：行 = 星期（0 = 周一），列 = 周。null = 今天之后（无格）。
        // 档位颜色只算 5 次（外加 5 个降透明度变体）：逐格 `withValues` 会
        // 在开页帧产生数百次颜色空间换算 / 分配。
        final levelColors = [
          for (var level = 0; level < heatmapLevelCount; level++)
            heatmapLevelColor(scheme, level),
        ];
        final dimmedLevelColors = [
          for (final color in levelColors)
            color.withValues(alpha: color.a * 0.35),
        ];
        final colors = List<Color?>.filled(7 * weeks, null);
        // 索引 → 日期由 gridStart + (col * 7 + row) 直接反算，不预建
        // DateTime / 文案（tooltip 只在悬停或语义树构建时按需格式化）。
        for (var col = 0; col < weeks; col++) {
          for (var row = 0; row < 7; row++) {
            final day = gridStart.add(Duration(days: col * 7 + row));
            if (day.isAfter(widget.lastDay)) continue;
            final inRange =
                !day.isBefore(widget.firstDay) && !day.isAfter(widget.lastDay);
            final value = inRange ? (widget.values[day] ?? 0) : 0;
            final level = levels.levelOf(value);
            // 范围外降透明度（查预计算的色板，避免逐格 Opacity 合成层）。
            final dim =
                inRange && highlightFrom != null && day.isBefore(highlightFrom);
            colors[row * weeks + col] = dim
                ? dimmedLevelColors[level]
                : levelColors[level];
          }
        }

        DateTime dayAt(int index) {
          final row = index ~/ weeks;
          final col = index % weeks;
          return gridStart.add(Duration(days: col * 7 + row));
        }

        int? selectedIndex;
        final selectedDay = widget.selectedDay;
        if (selectedDay != null) {
          final offset = selectedDay.difference(gridStart).inDays;
          if (offset >= 0 && offset < weeks * 7) {
            final row = offset % 7;
            final col = offset ~/ 7;
            final index = row * weeks + col;
            final inRange =
                !selectedDay.isBefore(widget.firstDay) &&
                !selectedDay.isAfter(widget.lastDay);
            if (inRange && colors[index] != null) selectedIndex = index;
          }
        }

        String? tooltipAt(int index) {
          final day = dayAt(index);
          final inRange =
              !day.isBefore(widget.firstDay) && !day.isAfter(widget.lastDay);
          if (!inRange) return null;
          return widget.tooltipFor(day, widget.values[day] ?? 0);
        }

        final onDayTap = widget.onDayTap;
        final monthLabels = <Widget>[];
        for (var week = 0; week < weeks; week++) {
          // 月份标签：本周包含某月 1 日时在列首显示。只保留月份名（去 4 位
          // 年份），否则 "September 2026" 这类长标签会与下个月标签重叠。
          String? monthLabel;
          for (var i = 0; i < 7; i++) {
            final day = gridStart.add(Duration(days: week * 7 + i));
            if (day.day == 1) {
              final raw = MaterialLocalizations.of(context)
                  .formatMonthYear(day);
              monthLabel = raw.replaceAll(_yearInMonthLabel, ' ').trim();
              break;
            }
          }
          if (monthLabel == null) continue;
          monthLabels.add(
            Positioned(
              left: week * pitch,
              top: 0,
              height: _headerHeight,
              // 列宽只有一格，月份标签向右溢出。顶部对齐：旧实现的
              // OverflowBox 把 16dp 紧约束传给 Text，行盒从顶边开始画；
              // 居中会多出约 3dp 的垂直偏移。
              width: 84,
              child: Align(
                alignment: Alignment.topLeft,
                child: Text(monthLabel, style: labelStyle),
              ),
            ),
          );
        }

        return SizedBox(
          height: _headerHeight + 7 * pitch,
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
                        height: pitch,
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
                child: SingleChildScrollView(
                  controller: _controller,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: weeks * pitch,
                    height: _headerHeight + 7 * pitch,
                    child: Column(
                      children: [
                        SizedBox(
                          height: _headerHeight,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: monthLabels,
                          ),
                        ),
                        _HeatGrid(
                          rows: 7,
                          columns: weeks,
                          cellSize: widget.cellSize,
                          cellGap: widget.cellGap,
                          colors: colors,
                          tooltipAt: tooltipAt,
                          selectedIndex: selectedIndex,
                          onTapAt: onDayTap == null
                              ? null
                              : (index) {
                                  onDayTap(dayAt(index));
                                },
                          gridKey: const Key('calendarHeatmapGrid'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
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
    final labelStyle = context.typeScale.labelSmall.copyWith(
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
        final pitch = cell + cellGap;
        final contentWidth = labelWidth + 24 * pitch;
        final levelColors = [
          for (var level = 0; level < heatmapLevelCount; level++)
            heatmapLevelColor(scheme, level),
        ];
        final colors = <Color?>[
          for (var weekday = 0; weekday < 7; weekday++)
            for (var hour = 0; hour < 24; hour++)
              levelColors[levels.levelOf(values[weekday][hour])],
        ];
        String? tooltipAt(int index) {
          final weekday = index ~/ 24;
          final hour = index % 24;
          return tooltipFor(weekday, hour, values[weekday][hour]);
        }

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
                      width: 6 * pitch,
                      height: 14,
                      child: Text('$hour', style: labelStyle),
                    ),
                ],
              ),
            ),
            Row(
              children: [
                SizedBox(
                  width: labelWidth,
                  height: 7 * pitch,
                  child: Column(
                    children: [
                      for (var weekday = 0; weekday < 7; weekday++)
                        SizedBox(
                          height: pitch,
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
                    ],
                  ),
                ),
                _HeatGrid(
                  rows: 7,
                  columns: 24,
                  cellSize: cell,
                  cellGap: cellGap,
                  colors: colors,
                  tooltipAt: tooltipAt,
                  gridKey: const Key('weekdayHourHeatmapGrid'),
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
              borderRadius: M3EShapes.radiusExtraSmall,
            ),
          ),
        ],
      ],
    );
  }
}
