/// 听歌统计的唯一投影模块：窗口、日历、7×24 矩阵与海报输入。
///
/// 为什么单独成模块：页面、海报与年度入口过去各读一次 `DateTime.now()`，
/// 各自把 `byWeekdayHour` 摊平成 168 格或 7×24 矩阵。只要时钟在两次读取之间
/// 跨过午夜，同一个页面就可能出现「今天的格子」与「范围起点」不在同一天。
/// 这里把「范围 + 当前时刻」固定成 [StatisticsWindow]，所有派生值一次算好；
/// 调用方只负责 l10n 格式化与绘制。
///
/// 本文件纯 Dart：只依赖领域模型，不读 Flutter UI / l10n，也不查数据库。
library;

import '../../domain/models/play_statistics.dart';

/// 一次统计加载的时间窗口：范围 + 唯一时钟值。
///
/// [now] 必须由调用方（通常是 provider 的注入时钟）传入，且一次加载只取一次；
/// 窗口内的起点、今天与高亮边界都从这里派生，不再各自读墙钟。
class StatisticsWindow {
  const StatisticsWindow({required this.range, required this.now});

  /// 当前统计范围。
  final PlayStatisticsRange range;

  /// 本次加载读取到的当前时刻（本地时间）。
  final DateTime now;

  /// 范围起点（本地时间；`null` = 全部），同时是日历高亮的起点。
  ///
  /// 保留时间分量：日历高亮沿用「格子日零点早于起点则降透明」的既有行为。
  DateTime? get start => range.startOf(now);

  /// 查询用的毫秒纪元，与 [start] 是同一个窗口。
  int? get sinceMs => range.sinceMs(now);

  /// 「今天」的本地零点。
  DateTime get today => _dateOnly(now);
}

/// 海报渲染需要的最小投影（文案与星期标签仍由调用方提供）。
///
/// 海报不关心范围高亮，只需要当前范围的汇总、榜单、来源与摊平后的
/// 7×24 时长矩阵，因此单独收成一个只读值对象，避免海报再遍历一次快照。
class ListeningStatisticsPosterProjection {
  const ListeningStatisticsPosterProjection({
    required this.summary,
    required this.topTracks,
    required this.topArtists,
    required this.sources,
    required this.weekdayHour,
  });

  /// 当前范围的汇总数字。
  final PlayStatisticsSummary summary;

  /// 当前范围 Top 曲目（顺序与快照一致）。
  final List<PlayStatTrackEntry> topTracks;

  /// 当前范围 Top 歌手（顺序与快照一致）。
  final List<PlayStatArtistEntry> topArtists;

  /// 当前范围来源分布（海报只取第一名做「最常使用」）。
  final List<SourceListened> sources;

  /// 7×24 行优先摊平（weekday 0 = 周一），单位毫秒，长度固定 168。
  ///
  /// 非法 weekday / hour 行会被跳过；海报据此省略热力图块。
  final List<int> weekdayHour;
}

/// 一份统计快照在固定窗口下的全部页面投影。
///
/// 日历（全量历史）、作息矩阵（随范围过滤）、数据起始日与「今天」都从这里
/// 读取；页面与海报不再各自推导。同一份快照 + 同一个 [window] 的输出稳定。
class ListeningStatisticsView {
  ListeningStatisticsView._({
    required this.snapshot,
    required this.window,
    required this._calendarByDuration,
    required this._calendarByCount,
    required this._weekdayHourByDuration,
    required this._weekdayHourByCount,
    required this.firstDay,
    required this.poster,
  });

  /// 从快照与窗口构建投影；只做内存分桶，不做 I/O。
  factory ListeningStatisticsView.from(
    ListeningStatisticsSnapshot snapshot,
    StatisticsWindow window,
  ) {
    final calendarByDuration = <DateTime, int>{};
    final calendarByCount = <DateTime, int>{};
    for (final entry in snapshot.daily) {
      calendarByDuration[entry.day] = entry.listenedMs;
      calendarByCount[entry.day] = entry.playCount;
    }

    final firstPlayedAt = snapshot.summary.firstPlayedAt;
    final firstDay = firstPlayedAt == null
        ? window.today
        : _dateOnly(DateTime.fromMillisecondsSinceEpoch(firstPlayedAt));

    return ListeningStatisticsView._(
      snapshot: snapshot,
      window: window,
      calendarByDuration: Map.unmodifiable(calendarByDuration),
      calendarByCount: Map.unmodifiable(calendarByCount),
      weekdayHourByDuration: _denseWeekdayHour(
        snapshot.byWeekdayHour,
        duration: true,
      ),
      weekdayHourByCount: _denseWeekdayHour(
        snapshot.byWeekdayHour,
        duration: false,
      ),
      firstDay: firstDay,
      poster: ListeningStatisticsPosterProjection(
        summary: snapshot.summary,
        topTracks: List.unmodifiable(snapshot.topTracks),
        topArtists: List.unmodifiable(snapshot.topArtists),
        sources: List.unmodifiable(snapshot.sources),
        weekdayHour: _flattenWeekdayHour(snapshot.byWeekdayHour),
      ),
    );
  }

  /// 当前范围的聚合快照（页面榜单 / 指标仍直接消费）。
  final ListeningStatisticsSnapshot snapshot;

  /// 构建本投影时固定的窗口（范围 + 唯一时钟值）。
  final StatisticsWindow window;

  final Map<DateTime, int> _calendarByDuration;
  final Map<DateTime, int> _calendarByCount;
  final List<List<int>> _weekdayHourByDuration;
  final List<List<int>> _weekdayHourByCount;

  /// 日历热力图的起始日（本地零点；无首播记录时退回今天）。
  final DateTime firstDay;

  /// 日历热力图的「今天」（本地零点）。
  DateTime get today => window.today;

  /// 日历高亮起点（与查询同一窗口；`null` = 全部）。
  DateTime? get windowStart => window.start;

  /// 日历值：按收听时长。
  Map<DateTime, int> get calendarByDuration => _calendarByDuration;

  /// 日历值：按有效播放次数。
  Map<DateTime, int> get calendarByCount => _calendarByCount;

  /// 日历值按维度取值（页面切换 时长/次数 时用）。
  Map<DateTime, int> calendarValues({required bool duration}) =>
      duration ? _calendarByDuration : _calendarByCount;

  /// 作息矩阵：按收听时长（7 行 × 24 列，weekday 0 = 周一）。
  List<List<int>> get weekdayHourByDuration => _weekdayHourByDuration;

  /// 作息矩阵：按有效播放次数。
  List<List<int>> get weekdayHourByCount => _weekdayHourByCount;

  /// 作息矩阵按维度取值。
  List<List<int>> weekdayHourValues({required bool duration}) =>
      duration ? _weekdayHourByDuration : _weekdayHourByCount;

  /// 海报输入（汇总 / 榜单 / 来源 / 摊平矩阵）。
  final ListeningStatisticsPosterProjection poster;
}

/// 本地日零点；与 Flutter `DateUtils.dateOnly` 同义，但本模块不依赖 UI 层。
DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// weekday × hour 是否落在 7×24 网格内（损坏数据降级为跳过）。
bool _validSlot(int weekday, int hour) =>
    weekday >= 0 && weekday <= 6 && hour >= 0 && hour <= 23;

/// 7×24 稠密矩阵；非法行跳过，避免损坏数据让整页热力图抛异常。
List<List<int>> _denseWeekdayHour(
  List<WeekdayHourListened> rows, {
  required bool duration,
}) {
  final values = [
    for (var weekday = 0; weekday < 7; weekday++) List<int>.filled(24, 0),
  ];
  for (final entry in rows) {
    if (!_validSlot(entry.weekday, entry.hour)) continue;
    values[entry.weekday][entry.hour] = duration
        ? entry.listenedMs
        : entry.playCount;
  }
  return List.unmodifiable([
    for (final row in values) List<int>.unmodifiable(row),
  ]);
}

/// 海报的 168 槽摊平（行优先，按收听时长）；非法行跳过。
List<int> _flattenWeekdayHour(List<WeekdayHourListened> rows) {
  final values = List<int>.filled(7 * 24, 0);
  for (final entry in rows) {
    if (!_validSlot(entry.weekday, entry.hour)) continue;
    values[entry.weekday * 24 + entry.hour] = entry.listenedMs;
  }
  return List.unmodifiable(values);
}
