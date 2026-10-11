/// 听歌数据导出：把统计查询结果组装成面向 AI 消费的 JSON。
///
/// 约定：
/// - 汇总与榜单覆盖**全量**（不受统计页当前范围影响）；
/// - 明细取最近 [PlayStatisticsLimits.exportEventLimit] 条，**不含 raw**
///   （LLM 用不到，且减小体积、少暴露平台内部字段）；
/// - `instructions` 为固定的英文提示语，方便直接整份粘贴给 AI；
/// - 文件只出不进（统计不支持导入）。
library;

import '../domain/models/play_statistics.dart';

/// 导出 JSON 的 schema 版本（字段变化时递增）。
const int playStatisticsExportVersion = 1;

/// 面向 AI 的固定提示语（与 UI 语言无关，英文更通用）。
const String playStatisticsExportInstructions =
    'This is my music listening history exported from Molia. '
    'Please analyze my listening habits and taste, then recommend songs, '
    'artists, or albums I might like. Avoid recommending songs that already '
    'appear frequently in my history.';

/// 组装导出 JSON（ISO8601 时间字符串，方便人读与模型消费）。
Map<String, dynamic> buildPlayStatisticsExport({
  required PlayStatisticsSummary summary,
  required List<PlayStatTrackEntry> topTracks,
  required List<PlayStatArtistEntry> topArtists,
  required List<DayListened> daily,
  required List<HourListened> hourly,
  required List<SourceListened> sources,
  required List<PlayEvent> recentEvents,
  required DateTime exportedAt,
}) {
  String? iso(int? epochMs) => epochMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(epochMs).toIso8601String();
  String day(DateTime value) => '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  return {
    'app': 'Molia',
    'version': playStatisticsExportVersion,
    'exportedAt': exportedAt.toIso8601String(),
    'instructions': playStatisticsExportInstructions,
    'summary': {
      'firstPlayedAt': iso(summary.firstPlayedAt),
      'playCount': summary.playCount,
      'qualifiedPlayCount': summary.qualifiedPlayCount,
      'totalListenedMs': summary.totalListenedMs,
      'uniqueTrackCount': summary.uniqueTrackCount,
      'completionRate': summary.completionRate,
      'skipRate': summary.skipRate,
    },
    'topTracks': [
      for (final entry in topTracks)
        {
          'title': entry.title,
          'artist': entry.artist,
          'album': entry.album,
          'source': entry.sourceKey,
          'songId': entry.songId,
          'durationMs': entry.durationMs,
          'playCount': entry.playCount,
          'listenedMs': entry.listenedMs,
          'lastPlayedAt': iso(entry.lastPlayedAt),
        },
    ],
    'topArtists': [
      for (final entry in topArtists)
        {
          'artist': entry.artist,
          'playCount': entry.playCount,
          'listenedMs': entry.listenedMs,
        },
    ],
    'dailyListened': [
      for (final entry in daily)
        {
          'date': day(entry.day),
          'listenedMs': entry.listenedMs,
          'playCount': entry.playCount,
        },
    ],
    'hourlyListened': [
      for (final entry in hourly)
        {
          'hour': entry.hour,
          'listenedMs': entry.listenedMs,
          'playCount': entry.playCount,
        },
    ],
    'sourceDistribution': [
      for (final entry in sources)
        {
          'source': entry.sourceKey,
          'listenedMs': entry.listenedMs,
          'playCount': entry.playCount,
        },
    ],
    'recentEvents': [
      for (final event in recentEvents)
        {
          'startedAt': iso(event.startedAt),
          'title': event.title,
          'artist': event.artist,
          'album': event.album,
          'source': event.sourceKey,
          'songId': event.songId,
          'durationMs': event.durationMs,
          'listenedMs': event.listenedMs,
          'endReason': event.endReason?.storageValue,
        },
    ],
  };
}
