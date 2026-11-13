/// 智能列表的重复版本展示行（代表行 + 按需展开的版本行）。
///
/// 纯函数：不改记录、不做持久化；调用方负责在模式 / 合集 / 搜索 / 排序变化
/// 时清空展开集合。
library;

import '../domain/models/library_browse.dart';
import '../providers/collection_presenter.dart';

class SmartListDisplayRows {
  const SmartListDisplayRows({required this.rows, required this.versionCounts});

  final List<CollectionRow> rows;

  /// 代表行 key → 版本数（只有多版本才出现）。
  final Map<String, int> versionCounts;
}

SmartListDisplayRows buildSmartListDisplayRows(
  List<CollectionRow> rows,
  Set<String> expanded,
) {
  final byBrowseKey = <String, CollectionRow>{
    for (final row in rows)
      '${row.favoriteKey.sourceKey}:${row.favoriteKey.songId}': row,
  };
  final browse = [
    for (final row in rows)
      BrowseTrack(
        sourceKey: row.favoriteKey.sourceKey,
        songId: row.favoriteKey.songId,
        title: row.title,
        artist: row.artist,
        album: row.album,
        coverUrl: row.artworkUrl,
        durationMs: row.durationMs,
      ),
  ];
  final groups = groupDuplicates(browse);
  final representativeOf = <String, String>{};
  final versions = <String, List<BrowseTrack>>{};
  for (final group in groups) {
    final rep = group.representative.key;
    versions[rep] = group.versions;
    for (final version in group.versions) {
      representativeOf[version.key] = rep;
    }
  }
  final counts = <String, int>{};
  final display = <CollectionRow>[];
  for (final track in browse) {
    if (representativeOf[track.key] != track.key) continue;
    final row = byBrowseKey[track.key];
    if (row == null) continue;
    final groupVersions = versions[track.key] ?? const <BrowseTrack>[];
    counts[row.key] = groupVersions.length;
    display.add(row);
    if (expanded.contains(track.key)) {
      for (final version in groupVersions) {
        if (version.key == track.key) continue;
        final versionRow = byBrowseKey[version.key];
        if (versionRow != null) display.add(versionRow);
      }
    }
  }
  return SmartListDisplayRows(
    rows: List.unmodifiable(display),
    versionCounts: Map.unmodifiable(counts),
  );
}
