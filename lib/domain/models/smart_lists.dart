/// 七个内置智能列表（纯函数；不落库、不同步、没有用户规则）。
library;

import 'download.dart';
import 'library.dart';
import 'library_browse.dart';
import 'play_statistics.dart';

/// 智能列表稳定 id（合集 key / 滚动记录复用；永远不是 playlist id）。
abstract final class SmartListIds {
  static const String recentlyAdded = 'smart:recently-added';
  static const String recentlyPlayed = 'smart:recently-played';
  static const String mostPlayed = 'smart:most-played';
  static const String neverPlayed = 'smart:never-played';
  static const String localOnly = 'smart:local-only';
  static const String downloaded = 'smart:downloaded';
  static const String missingFiles = 'smart:missing-files';

  static const List<String> all = [
    recentlyAdded,
    recentlyPlayed,
    mostPlayed,
    neverPlayed,
    localOnly,
    downloaded,
    missingFiles,
  ];

  static bool isSmartList(String key) => key.startsWith('smart:');
}

/// 「最常播放」的指标（设备本地 UI 状态，不登记设置键）。
enum SmartListMetric { playCount, listeningTime }

class SmartListSources {
  const SmartListSources({
    required this.downloads,
    required this.history,
    required this.stats,
    required this.browse,
    this.playedKeys,
  });

  final List<DownloadedTrack> downloads;
  final List<PlayHistoryEntry> history;
  final List<PlayStatTrackEntry> stats;
  final LibraryBrowseIndex browse;

  /// 统计曲目表的全部键（null = 退化用 [stats] 的键）。
  final Set<String>? playedKeys;
}

/// 构建一个智能列表；缺失记录的排除规则按列表语义处理。
List<BrowseTrack> buildSmartList(
  String id,
  SmartListSources sources, {
  SmartListMetric metric = SmartListMetric.playCount,
  int cap = 100,
}) {
  final downloads = sources.downloads;
  switch (id) {
    case SmartListIds.recentlyAdded:
      return _dedupe(
        [
          for (final record in _audio(downloads))
            if (!record.isMissing) BrowseTrack.fromDownload(record),
        ]..sort((a, b) => b.addedAt.compareTo(a.addedAt)),
      );

    case SmartListIds.recentlyPlayed:
      final missing = _missingHistoryKeys(downloads);
      final seen = <String>{};
      final result = <BrowseTrack>[];
      for (final entry in sources.history) {
        final key = '${entry.sourceKey}:${entry.songId}';
        if (missing.contains(key)) continue;
        if (!seen.add(key)) continue;
        result.add(
          BrowseTrack(
            sourceKey: entry.sourceKey,
            songId: entry.songId,
            title: entry.title,
            artist: entry.artist,
            album: entry.album,
            coverUrl: entry.coverUrl,
            durationMs: entry.durationMs,
            raw: entry.raw,
            addedAt: entry.playedAt,
          ),
        );
      }
      return List.unmodifiable(result);

    case SmartListIds.mostPlayed:
      final libraryKeys = {
        for (final track in sources.browse.tracks) track.key,
      };
      final entries =
          [
            for (final entry in sources.stats)
              if (libraryKeys.contains(entry.key)) entry,
          ]..sort((a, b) {
            final byMetric = metric == SmartListMetric.listeningTime
                ? b.listenedMs.compareTo(a.listenedMs)
                : b.playCount.compareTo(a.playCount);
            return byMetric != 0
                ? byMetric
                : b.lastPlayedAt.compareTo(a.lastPlayedAt);
          });
      return List.unmodifiable([
        for (final entry in entries.take(cap))
          BrowseTrack(
            sourceKey: entry.sourceKey,
            songId: entry.songId,
            title: entry.title,
            artist: entry.artist,
            album: entry.album,
            coverUrl: entry.coverUrl,
            durationMs: entry.durationMs,
            raw: entry.raw,
            addedAt: entry.lastPlayedAt,
          ),
      ]);

    case SmartListIds.neverPlayed:
      final played = {
        for (final entry in sources.stats) entry.key,
        for (final entry in sources.history)
          '${entry.sourceKey}:${entry.songId}',
      };
      return List.unmodifiable([
        for (final track in sources.browse.tracks)
          if (!played.contains(track.key)) track,
      ]);

    case SmartListIds.localOnly:
      final imports = [
        for (final record in _audio(downloads))
          if (record.imported && !record.isMissing) record,
      ];
      final tracks =
          [for (final record in imports) BrowseTrack.fromDownload(record)]
            ..sort(
              (a, b) =>
                  normalizeBrowseText(a.title)
                      .compareTo(normalizeBrowseText(b.title)),
            );
      return List.unmodifiable(tracks);

    case SmartListIds.downloaded:
      return List.unmodifiable(
        [
          for (final record in _audio(downloads))
            if (!record.imported && !record.isMissing)
              BrowseTrack.fromDownload(record),
        ]..sort((a, b) => b.addedAt.compareTo(a.addedAt)),
      );

    case SmartListIds.missingFiles:
      final missing = [
        for (final record in _audio(downloads))
          if (record.isMissing) record,
      ]..sort((a, b) => (b.missingAt ?? 0).compareTo(a.missingAt ?? 0));
      return List.unmodifiable([
        for (final record in missing) BrowseTrack.fromDownload(record),
      ]);
    default:
      return const [];
  }
}

Iterable<DownloadedTrack> _audio(Iterable<DownloadedTrack> records) =>
    records.where((record) => record.hasAudio);

/// 缺失记录对应的历史 key（历史行 sourceKey = local、songId = localSongId）。
Set<String> _missingHistoryKeys(Iterable<DownloadedTrack> records) => {
  for (final record in records)
    if (record.hasAudio && record.isMissing)
      '$kLocalSourceKey:${record.localSongId}',
};

List<BrowseTrack> _dedupe(List<BrowseTrack> tracks) {
  final seen = <String>{};
  return List.unmodifiable([
    for (final track in tracks)
      if (seen.add(track.key)) track,
  ]);
}
