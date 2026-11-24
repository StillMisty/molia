/// 听歌统计页的页面内模型与格式化：紧凑日期与海报数据拼装。
///
/// 统计投影（日历 / 7×24 矩阵 / 起始日）来自
/// `lib/services/statistics/listening_statistics.dart`，本文件只做展示格式化。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/play_statistics.dart';
import '../../domain/ports/source_registry.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_providers.dart';
import '../../services/listening_stats_poster_service.dart';
import '../../services/statistics/listening_statistics.dart';
import '../../widgets/labels/listened_duration.dart';

/// 紧凑日期：同年 `M/d`、跨年 `yyyy/M`（完整日期会在窄块里被裁切）。
///
/// [now] 由统计窗口提供，用于判断同年 `M/d` 还是跨年 `yyyy/M`。
String formatCompactStatisticsDate(int epochMs, {required DateTime now}) {
  final date = DateTime.fromMillisecondsSinceEpoch(epochMs);
  return date.year == now.year
      ? '${date.month}/${date.day}'
      : '${date.year}/${date.month}';
}

/// 来源显示名：注册表命中用平台名，否则回退原始 key。
String statisticsSourceName(WidgetRef ref, String sourceKey) {
  final SourceRegistry? registry = ref.read(sourceRegistryProvider);
  for (final descriptor in registry?.descriptors ?? const []) {
    if (descriptor.key == sourceKey) return descriptor.displayName;
  }
  return sourceKey;
}

/// 听歌统计海报数据：把统计投影拼成离线渲染输入。
///
/// [narrowWeekdays] 是 `MaterialLocalizations.narrowWeekdays`（周日开头），
/// 这里重排成周一开头的 7 个标签，与作息热力图的行顺序一致。矩阵本身来自
/// [ListeningStatisticsView.posterWeekdayHour]，本函数只做 l10n 格式化。
ListeningStatsPosterData buildListeningStatsPosterData({
  required AppLocalizations l10n,
  required ListeningStatisticsView view,
  required List<String> narrowWeekdays,
  required String Function(String sourceKey) sourceName,
}) {
  final summary = view.snapshot.summary;
  final sources = view.snapshot.sources;
  final rangeLabel = switch (view.window.range) {
    PlayStatisticsRange.week => l10n.statsRangeWeek,
    PlayStatisticsRange.month => l10n.statsRangeMonth,
    PlayStatisticsRange.all => l10n.statsRangeAll,
  };
  final weekdayLabels = <String>[
    for (var day = 1; day < 7; day++) narrowWeekdays[day],
    narrowWeekdays.first,
  ];
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
      for (final track in view.snapshot.topTracks)
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
      for (final artist in view.snapshot.topArtists)
        ListeningStatsPosterRow(
          title: artist.artist,
          subtitle:
              '${l10n.statsPlaysCount(artist.playCount)} · '
              '${formatListenedDuration(l10n, artist.listenedMs)}',
        ),
    ],
    weekdayHourTitle: l10n.statsWeekdayHour,
    weekdayLabels: weekdayLabels,
    weekdayHour: view.posterWeekdayHour,
    platformLabel: sources.isEmpty
        ? null
        : l10n.annualReportTopPlatform(sourceName(sources.first.sourceKey)),
  );
}
