/// 年度听歌报告的领域模型与纯聚合。
///
/// 输入是既有统计表查询出的年度快照（`AnnualStatisticsSnapshot`）与本地年份
/// 窗口；输出是不可变的报告模型。月份分桶、平台占比、最长连续天数、首末播放、
/// 覆盖范围与「数据不完整」判定都在这里完成，不依赖 Flutter / provider / I/O。
/// 注入的 [DateTime] 只用于当前年「截至今天」与默认年份，不改写事件时间。
library;

import 'library.dart' show PlaylistTrack;
import 'play_statistics.dart';

/// 一年报告的本地时间窗口：`[1 月 1 日 00:00, 次年 1 月 1 日 00:00)`。
class AnnualReportWindow {
  AnnualReportWindow(this.year)
    : start = DateTime(year),
      end = DateTime(year + 1);

  final int year;
  final DateTime start;

  /// 排他上界。
  final DateTime end;

  int get startMs => start.millisecondsSinceEpoch;
  int get endMs => end.millisecondsSinceEpoch;

  bool contains(DateTime local) =>
      !local.isBefore(start) && local.isBefore(end);

  @override
  bool operator ==(Object other) =>
      other is AnnualReportWindow && other.year == year;

  @override
  int get hashCode => year.hashCode;
}

/// 年度第一次 / 最后一次可统计播放（展示只读标题、歌手与本地日期）。
class AnnualPlayMoment {
  const AnnualPlayMoment({
    required this.title,
    required this.artist,
    required this.startedAt,
  });

  final String title;
  final String artist;

  /// 本地时间毫秒。
  final int startedAt;

  DateTime get localTime => DateTime.fromMillisecondsSinceEpoch(startedAt);

  DateTime get localDay =>
      DateTime(localTime.year, localTime.month, localTime.day);
}

/// 年度平台分布（未知平台合并为 `other`）。
class AnnualPlatformShare {
  const AnnualPlatformShare({
    required this.sourceKey,
    required this.listenedMs,
    required this.playCount,
    required this.share,
  });

  final String sourceKey;
  final int listenedMs;
  final int playCount;

  /// 占年度总时长的比例（0–1）。
  final double share;
}

/// 报告的数据完整性提示。
enum AnnualReportNotice {
  /// 数据覆盖完整（或当前年照常进行中）。
  none,

  /// 听歌统计已关闭：报告只包含关闭前的记录。
  recordingOff,

  /// 统计保留 / 晚开始导致年份不完整。
  partialCoverage,
}

/// 仓库一次年度查询的全部聚合。
class AnnualStatisticsSnapshot {
  const AnnualStatisticsSnapshot({
    required this.summary,
    required this.topTracks,
    required this.topArtists,
    required this.topAlbums,
    required this.sources,
    required this.daily,
    required this.uniqueArtistCount,
    this.firstPlay,
    this.lastPlay,
  });

  final PlayStatisticsSummary summary;

  /// 最多 50 条（页面只展示前 5，歌单动作使用全部）。
  final List<PlayStatTrackEntry> topTracks;

  /// 最多 5 条。
  final List<PlayStatArtistEntry> topArtists;

  /// 最多 5 条（空专辑名已排除）。
  final List<PlayStatAlbumEntry> topAlbums;

  final List<SourceListened> sources;

  /// 本地时间窗口内的按日聚合。
  final List<DayListened> daily;

  /// 至少一次有效播放的歌手名数量（沿用既有拆分规则）。
  final int uniqueArtistCount;

  final AnnualPlayMoment? firstPlay;
  final AnnualPlayMoment? lastPlay;
}

/// Top 专辑条目。
class PlayStatAlbumEntry {
  const PlayStatAlbumEntry({
    required this.album,
    required this.playCount,
    required this.listenedMs,
  });

  final String album;
  final int playCount;
  final int listenedMs;
}

/// 最长连续天数（年内，只有收听时长 > 0 的本地日才计入）。
class AnnualListeningStreak {
  const AnnualListeningStreak({required this.days, this.start, this.end});

  static const AnnualListeningStreak none = AnnualListeningStreak(days: 0);

  final int days;
  final DateTime? start;
  final DateTime? end;
}

/// 一年报告（只读）。
class AnnualReport {
  const AnnualReport({
    required this.year,
    required this.totalListenedMs,
    required this.countablePlayCount,
    required this.qualifiedPlayCount,
    required this.uniqueTrackCount,
    required this.uniqueArtistCount,
    required this.topTracks,
    required this.topArtists,
    required this.topAlbums,
    required this.platforms,
    required this.monthlyListenedMs,
    required this.streak,
    required this.firstPlay,
    required this.lastPlay,
    required this.coverageStart,
    required this.coverageEnd,
    required this.notice,
    required this.asOfToday,
  });

  /// 页面最多展示的 Top 歌曲 / 歌手 / 专辑条数。
  static const int pageTopLimit = 5;

  /// 歌单动作最多保留的曲目数。
  static const int playlistLimit = 50;

  final int year;
  final int totalListenedMs;

  /// 已收尾且非 error 的播放次数（报告空态判据）。
  final int countablePlayCount;

  /// 有效播放次数（与统计页「有效播放」同口径）。
  final int qualifiedPlayCount;
  final int uniqueTrackCount;
  final int uniqueArtistCount;

  /// 最多 [playlistLimit] 条；页面只展示前 [pageTopLimit] 条。
  final List<PlayStatTrackEntry> topTracks;
  final List<PlayStatArtistEntry> topArtists;
  final List<PlayStatAlbumEntry> topAlbums;
  final List<AnnualPlatformShare> platforms;

  /// 12 个月桶（1–12 月，零填充）。
  final List<int> monthlyListenedMs;

  final AnnualListeningStreak streak;
  final AnnualPlayMoment? firstPlay;
  final AnnualPlayMoment? lastPlay;

  /// 本地数据实际覆盖范围；没有数据时为 null。
  final DateTime? coverageStart;
  final DateTime? coverageEnd;

  final AnnualReportNotice notice;

  /// 当前年报告标记「截至今天」。
  final bool asOfToday;

  bool get hasData => countablePlayCount > 0;

  bool get hasTopTracks => topTracks.isNotEmpty;

  List<PlayStatTrackEntry> get pageTopTracks =>
      topTracks.take(pageTopLimit).toList(growable: false);

  List<PlayStatArtistEntry> get pageTopArtists =>
      topArtists.take(pageTopLimit).toList(growable: false);

  List<PlayStatAlbumEntry> get pageTopAlbums =>
      topAlbums.take(pageTopLimit).toList(growable: false);
}

/// 年度聚合：纯函数、无 I/O、确定性（相同输入 → 相同输出）。
AnnualReport buildAnnualReport({
  required int year,
  required AnnualStatisticsSnapshot data,
  required DateTime now,
  required Map<String, String> knownSourceNames,
  bool recordingEnabled = true,
}) {
  final window = AnnualReportWindow(year);
  final daily = [
    for (final day in data.daily)
      if (window.contains(day.day)) day,
  ]..sort((a, b) => a.day.compareTo(b.day));

  final monthly = List<int>.filled(12, 0);
  for (final day in daily) {
    final index = day.day.month - 1;
    if (index < 0 || index > 11) continue;
    monthly[index] += day.listenedMs;
  }

  final totalMs = data.summary.totalListenedMs;
  final platformTotals = <String, ({int listenedMs, int playCount})>{};
  for (final source in data.sources) {
    final key = knownSourceNames.containsKey(source.sourceKey)
        ? source.sourceKey
        : 'other';
    final current = platformTotals[key] ?? (listenedMs: 0, playCount: 0);
    platformTotals[key] = (
      listenedMs: current.listenedMs + source.listenedMs,
      playCount: current.playCount + source.playCount,
    );
  }
  final platforms =
      [
        for (final entry in platformTotals.entries)
          AnnualPlatformShare(
            sourceKey: entry.key,
            listenedMs: entry.value.listenedMs,
            playCount: entry.value.playCount,
            share: totalMs <= 0 ? 0 : entry.value.listenedMs / totalMs,
          ),
      ]..sort((a, b) {
        final byTime = b.listenedMs.compareTo(a.listenedMs);
        if (byTime != 0) return byTime;
        return a.sourceKey.compareTo(b.sourceKey);
      });

  // 覆盖率只使用真实有收听的本地日：零时长 / error 事件不延长连续天数。
  final activeDays = [
    for (final day in daily)
      if (day.listenedMs > 0) day.day,
  ];
  final streak = _longestStreak(activeDays);

  final coverageStart = activeDays.isEmpty
      ? null
      : (data.summary.firstPlayedAt == null
            ? activeDays.first
            : DateTime.fromMillisecondsSinceEpoch(data.summary.firstPlayedAt!));
  final lastActiveDay = activeDays.isEmpty ? null : activeDays.last;
  final currentYear = now.year == year;
  final coverageEnd = activeDays.isEmpty
      ? null
      : (currentYear ? DateTime(now.year, now.month, now.day) : lastActiveDay);

  final startsAtYearStart =
      coverageStart != null && !coverageStart.isAfter(window.start);
  final endsAtYearEnd =
      currentYear ||
      (lastActiveDay != null &&
          !lastActiveDay.isBefore(DateTime(year, 12, 31)));

  final notice = !recordingEnabled
      ? AnnualReportNotice.recordingOff
      : (!startsAtYearStart || !endsAtYearEnd
            ? AnnualReportNotice.partialCoverage
            : AnnualReportNotice.none);

  return AnnualReport(
    year: year,
    totalListenedMs: totalMs,
    countablePlayCount: data.summary.playCount,
    qualifiedPlayCount: data.summary.qualifiedPlayCount,
    uniqueTrackCount: data.summary.uniqueTrackCount,
    uniqueArtistCount: data.uniqueArtistCount,
    topTracks: List.unmodifiable(
      data.topTracks.take(AnnualReport.playlistLimit),
    ),
    topArtists: List.unmodifiable(
      data.topArtists.take(AnnualReport.pageTopLimit),
    ),
    topAlbums: List.unmodifiable(
      data.topAlbums.take(AnnualReport.pageTopLimit),
    ),
    platforms: List.unmodifiable(platforms),
    monthlyListenedMs: List.unmodifiable(monthly),
    streak: streak,
    firstPlay: data.firstPlay,
    lastPlay: data.lastPlay,
    coverageStart: coverageStart,
    coverageEnd: coverageEnd,
    notice: notice,
    asOfToday: currentYear,
  );
}

AnnualListeningStreak _longestStreak(List<DateTime> days) {
  if (days.isEmpty) return AnnualListeningStreak.none;
  final unique = <DateTime>[];
  for (final day in days) {
    final normalized = DateTime(day.year, day.month, day.day);
    if (unique.isEmpty || unique.last != normalized) unique.add(normalized);
  }
  var bestDays = 1;
  var bestStart = unique.first;
  var bestEnd = unique.first;
  var currentDays = 1;
  var currentStart = unique.first;
  for (var index = 1; index < unique.length; index++) {
    final previous = unique[index - 1];
    final day = unique[index];
    final nextAfterPrevious = DateTime(
      previous.year,
      previous.month,
      previous.day + 1,
    );
    final consecutive = day == nextAfterPrevious;
    if (consecutive) {
      currentDays++;
    } else {
      currentDays = 1;
      currentStart = day;
    }
    if (currentDays > bestDays) {
      bestDays = currentDays;
      bestStart = currentStart;
      bestEnd = day;
    }
  }
  return AnnualListeningStreak(days: bestDays, start: bestStart, end: bestEnd);
}

/// 年度 Top 50 → 歌单条目（纯映射，写入走既有资料库导入引擎）。
///
/// 缺失载荷仍生成条目：播放时按既有路径重新解析。
List<PlaylistTrack> buildAnnualPlaylistTracks(
  AnnualReport report, {
  required int addedAt,
}) => [
  for (final entry in report.topTracks.take(AnnualReport.playlistLimit))
    PlaylistTrack(
      playlistId: 0,
      sourceKey: entry.sourceKey,
      songId: entry.songId,
      title: entry.title,
      artist: entry.artist,
      album: entry.album,
      coverUrl: entry.coverUrl,
      durationMs: entry.durationMs,
      raw: entry.raw,
      addedAt: addedAt,
    ),
];
