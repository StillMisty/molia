/// 听歌统计页的页面内模型与格式化。
///
/// 这里只放「页面自己定义、但不止一个拆分文件要用」的值：热力图投影、
/// 紧凑日期与海报数据拼装。统计口径 / DTO 本体仍在领域层
/// `lib/domain/models/play_statistics.dart`，本文件不复制口径。
library;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../domain/models/play_statistics.dart';
import '../../domain/ports/source_registry.dart';
import '../../l10n/app_localizations.dart';
import '../../services/listening_stats_poster_service.dart';
import '../../widgets/labels/listened_duration.dart';

/// 日历热力图的值投影：按当前维度取时长或次数。
Map<DateTime, int> statisticsCalendarValues(
  ListeningStatisticsSnapshot? snapshot, {
  required bool duration,
}) {
  if (snapshot == null) return const {};
  return {
    for (final entry in snapshot.daily)
      entry.day: duration ? entry.listenedMs : entry.playCount,
  };
}

/// 作息热力图的 7×24 矩阵（0=周一），值按当前维度取。
List<List<int>> statisticsWeekdayHourValues(
  ListeningStatisticsSnapshot snapshot, {
  required bool duration,
}) {
  final values = [
    for (final row in List.generate(7, (_) => List.filled(24, 0)))
      List<int>.of(row),
  ];
  for (final entry in snapshot.byWeekdayHour) {
    if (entry.weekday < 0 || entry.weekday > 6) continue;
    values[entry.weekday][entry.hour] = duration
        ? entry.listenedMs
        : entry.playCount;
  }
  return values;
}

/// 紧凑日期：同年 `M/d`、跨年 `yyyy/M`（完整日期会在窄块里被裁切）。
String formatCompactStatisticsDate(int epochMs, {DateTime? now}) {
  final date = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final today = now ?? DateTime.now();
  return date.year == today.year
      ? '${date.month}/${date.day}'
      : '${date.year}/${date.month}';
}

/// 来源显示名：注册表命中用平台名，否则回退原始 key。
String statisticsSourceName(BuildContext context, String sourceKey) {
  final registry = context.read<SourceRegistry?>();
  for (final descriptor in registry?.descriptors ?? const []) {
    if (descriptor.key == sourceKey) return descriptor.displayName;
  }
  return sourceKey;
}

/// 听歌统计海报数据：把当前范围快照拼成离线渲染输入。
///
/// [narrowWeekdays] 是 `MaterialLocalizations.narrowWeekdays`（周日开头），
/// 这里重排成周一开头的 7 个标签，与作息热力图的行顺序一致。
ListeningStatsPosterData buildListeningStatsPosterData({
  required AppLocalizations l10n,
  required ListeningStatisticsSnapshot? snapshot,
  required PlayStatisticsRange range,
  required List<String> narrowWeekdays,
  required String Function(String sourceKey) sourceName,
}) {
  final summary = snapshot?.summary ?? PlayStatisticsSummary.empty;
  final sources = snapshot?.sources ?? const <SourceListened>[];
  final rangeLabel = switch (range) {
    PlayStatisticsRange.week => l10n.statsRangeWeek,
    PlayStatisticsRange.month => l10n.statsRangeMonth,
    PlayStatisticsRange.all => l10n.statsRangeAll,
  };
  final weekdayLabels = <String>[
    for (var day = 1; day < 7; day++) narrowWeekdays[day],
    narrowWeekdays.first,
  ];
  final weekdayHour = List<int>.filled(168, 0);
  for (final entry
      in snapshot?.byWeekdayHour ?? const <WeekdayHourListened>[]) {
    if (entry.weekday < 0 ||
        entry.weekday > 6 ||
        entry.hour < 0 ||
        entry.hour > 23) {
      continue;
    }
    weekdayHour[entry.weekday * 24 + entry.hour] = entry.listenedMs;
  }
  return ListeningStatsPosterData(
    title: l10n.statsPosterTitle,
    rangeLabel: rangeLabel,
    listenedLabel: formatListenedDuration(l10n, summary.totalListenedMs),
    listenedCaption: l10n.statsListened,
    playsLabel: '${summary.qualifiedPlayCount}',
    playsCaption: l10n.statsPlays,
    tracksLabel: '${summary.uniqueTrackCount}',
    tracksCaption: l10n.statsTracks,
    completionLabel: '${(summary.completionRate * 100).round()}%',
    completionCaption: l10n.statsCompleteRate,
    topTracksTitle: l10n.statsTopTracks,
    topTracks: [
      for (final track in snapshot?.topTracks ?? const <PlayStatTrackEntry>[])
        ListeningStatsPosterRow(
          title: track.title,
          subtitle: [
            if (track.artist.trim().isNotEmpty) track.artist.trim(),
            l10n.statsPlaysCount(track.playCount),
            formatListenedDuration(l10n, track.listenedMs),
          ].join(' · '),
        ),
    ],
    topArtistsTitle: l10n.statsTopArtists,
    topArtists: [
      for (final artist
          in snapshot?.topArtists ?? const <PlayStatArtistEntry>[])
        ListeningStatsPosterRow(
          title: artist.artist,
          subtitle:
              '${l10n.statsPlaysCount(artist.playCount)} · '
              '${formatListenedDuration(l10n, artist.listenedMs)}',
        ),
    ],
    weekdayHourTitle: l10n.statsWeekdayHour,
    weekdayLabels: weekdayLabels,
    weekdayHour: weekdayHour,
    platformLabel: sources.isEmpty
        ? null
        : l10n.annualReportTopPlatform(sourceName(sources.first.sourceKey)),
  );
}
