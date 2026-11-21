/// 听歌统计的投影模块：窗口、日历、7×24 矩阵与海报输入。
///
/// [ListeningStatisticsWindow] 固定一次加载的范围与时钟值；
/// [ListeningStatisticsView] 从聚合快照派生页面需要的值。调用方只负责
/// l10n 格式化与绘制。本文件纯 Dart：只依赖领域模型，不读 Flutter UI /
/// l10n，也不查数据库。
library;

import '../../domain/models/play_statistics.dart';

/// 一次统计加载的时间窗口：范围 + 唯一时钟值。
///
/// [now] 由调用方（通常是 provider 的注入时钟）传入，且一次加载只取一次；
/// 窗口内的起点、今天与高亮边界都从这里派生。
class ListeningStatisticsWindow {
  const ListeningStatisticsWindow({required this.range, required this.now});

  /// 当前统计范围。
  final PlayStatisticsRange range;

  /// 本次加载读取到的当前时刻（本地时间）。
  final DateTime now;

  /// 范围起点（本地时间；`null` = 全部），同时是日历高亮的起点。
  ///
  /// 保留时间分量：日历高亮按「格子日零点早于起点则降透明」判断。
  DateTime? get start => range.startOf(now);

  /// 查询用的毫秒纪元，与 [start] 是同一个窗口。
  int? get sinceMs => range.sinceMs(now);

  /// 「今天」的本地零点。
  DateTime get today => _dateOnly(now);
}

/// 一份统计快照在固定窗口下的全部页面投影。
///
/// 日历（全量历史）、作息矩阵（随范围过滤）、数据起始日与「今天」都从这里
/// 读取；同一份快照 + 同一个 [window] 的输出稳定。
class ListeningStatisticsView {
  ListeningStatisticsView._({
    required this.snapshot,
    required this.window,
    required this._calendarByDuration,
    required this._calendarByCount,
    required this._weekdayHourByDuration,
    required this._weekdayHourByCount,
    required this.posterWeekdayHour,
    required this.firstDay,
  });

  /// 从快照与窗口构建投影；只做内存分桶，不做 I/O。
  factory ListeningStatisticsView.from(
    ListeningStatisticsSnapshot snapshot,
    ListeningStatisticsWindow window,
  ) {
    final calendarByDuration = <DateTime, int>{};
    final calendarByCount = <DateTime, int>{};
    for (final entry in snapshot.daily) {
      calendarByDuration[entry.day] = entry.listenedMs;
      calendarByCount[entry.day] = entry.playCount;
    }

    final weekdayHour = _weekdayHourMatrices(snapshot.byWeekdayHour);
    final firstPlayedAt = snapshot.summary.firstPlayedAt;

    return ListeningStatisticsView._(
      snapshot: snapshot,
      window: window,
      calendarByDuration: Map.unmodifiable(calendarByDuration),
      calendarByCount: Map.unmodifiable(calendarByCount),
      weekdayHourByDuration: weekdayHour.duration,
      weekdayHourByCount: weekdayHour.count,
      posterWeekdayHour: _flattenWeekdayHour(weekdayHour.duration),
      firstDay: firstPlayedAt == null
          ? window.today
          : _dateOnly(DateTime.fromMillisecondsSinceEpoch(firstPlayedAt)),
    );
  }

  /// 当前范围的聚合快照（页面榜单 / 指标仍直接消费）。
  final ListeningStatisticsSnapshot snapshot;

  /// 构建本投影时固定的窗口（范围 + 唯一时钟值）。
  final ListeningStatisticsWindow window;

  final Map<DateTime, int> _calendarByDuration;
  final Map<DateTime, int> _calendarByCount;
  final List<List<int>> _weekdayHourByDuration;
  final List<List<int>> _weekdayHourByCount;

  /// 日历热力图的起始日（本地零点；无首播记录时退回今天）。
  final DateTime firstDay;

  /// 日历热力图的「今天」（本地零点）。
  DateTime get today => window.today;

  /// 日历值按维度取值（页面切换 时长/次数 时用）。
  Map<DateTime, int> calendarValues({required bool duration}) =>
      duration ? _calendarByDuration : _calendarByCount;

  /// 作息矩阵按维度取值（7 行 × 24 列，weekday 0 = 周一）。
  List<List<int>> weekdayHourValues({required bool duration}) =>
      duration ? _weekdayHourByDuration : _weekdayHourByCount;

  /// 海报的 168 槽摊平（行优先，按收听时长）；非法行已跳过。
  final List<int> posterWeekdayHour;
}

/// 本地日零点；与 Flutter `DateUtils.dateOnly` 同义，但本模块不依赖 UI 层。
DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// weekday × hour 是否落在 7×24 网格内（损坏数据降级为跳过）。
bool _validSlot(int weekday, int hour) =>
    weekday >= 0 && weekday <= 6 && hour >= 0 && hour <= 23;

/// 一次遍历 `byWeekdayHour`，同时产出时长与次数两张稠密矩阵。
///
/// 非法 weekday / hour 行跳过，避免损坏数据让整页热力图抛异常。
({List<List<int>> duration, List<List<int>> count}) _weekdayHourMatrices(
  List<WeekdayHourListened> rows,
) {
  final duration = [
    for (var weekday = 0; weekday < 7; weekday++) List<int>.filled(24, 0),
  ];
  final count = [
    for (var weekday = 0; weekday < 7; weekday++) List<int>.filled(24, 0),
  ];
  for (final entry in rows) {
    if (!_validSlot(entry.weekday, entry.hour)) continue;
    duration[entry.weekday][entry.hour] = entry.listenedMs;
    count[entry.weekday][entry.hour] = entry.playCount;
  }
  return (duration: _freeze(duration), count: _freeze(count));
}

/// 从时长矩阵摊平成海报的 168 槽（行优先）。
List<int> _flattenWeekdayHour(List<List<int>> matrix) {
  final values = List<int>.filled(7 * 24, 0);
  for (var weekday = 0; weekday < 7; weekday++) {
    for (var hour = 0; hour < 24; hour++) {
      values[weekday * 24 + hour] = matrix[weekday][hour];
    }
  }
  return List.unmodifiable(values);
}

/// 冻结 7×24 矩阵，防止调用方改写投影。
List<List<int>> _freeze(List<List<int>> matrix) =>
    List.unmodifiable([for (final row in matrix) List<int>.unmodifiable(row)]);
