/// 合集行的搜索过滤与排序（收藏 / 自建列表 / 播放历史 / 本地歌曲共用）。
///
/// 过滤与三种排序口径都是纯函数：收藏页只提供查询串与当前口径，不重复
/// 实现（原先三份逐行重复的过滤 + 一份排序开关）。
library;

import '../domain/models/library.dart';

/// 合集曲目的排序口径（搜索行 ⋮ 菜单）。
enum CollectionTrackSort {
  /// 默认口径：维护顺序（收藏 / 添加顺序）。
  added,

  /// 标题升序。
  title,

  /// 歌手升序；同歌手按标题。
  artist,
}

/// 合集行搜索过滤：标题 / 歌手包含查询串（忽略大小写与首尾空白）。
///
/// 四种行共用同一语义；行字段经 [fields] 取（行类型本身不必实现公共接口）。
/// 查询为空时原样返回 [rows]（不过滤、不复制）。
List<T> filterRowsByQuery<T>(
  List<T> rows, {
  required String query,
  required ({String title, String artist}) Function(T row) fields,
}) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return rows;
  return [
    for (final row in rows)
      if (_matches(fields(row), normalized)) row,
  ];
}

/// 按口径排序曲目（不改动入参，返回新列表）；默认口径保持传入顺序。
///
/// 标题 / 歌手排序用「装饰排序」：`toLowerCase` 对每行只求一次，避免旧实现
/// 在 comparator 里对同一行反复求值（n log n 次字符串分配）。
List<PlaylistTrack> sortCollectionTracks(
  List<PlaylistTrack> tracks,
  CollectionTrackSort sort,
) {
  switch (sort) {
    case CollectionTrackSort.added:
      return List<PlaylistTrack>.of(tracks);
    case CollectionTrackSort.title:
      return _sortedBy(tracks, (track) => track.title);
    case CollectionTrackSort.artist:
      return _sortedBy(
        tracks,
        (track) => track.artist,
        tieBreak: (track) => track.title,
      );
  }
}

/// 装饰排序：主键（小写）升序，同主键按次键（小写）升序。
List<PlaylistTrack> _sortedBy(
  List<PlaylistTrack> tracks,
  String Function(PlaylistTrack) key, {
  String Function(PlaylistTrack)? tieBreak,
}) {
  final decorated = [
    for (final track in tracks)
      (
        key: key(track).toLowerCase(),
        tie: (tieBreak?.call(track) ?? '').toLowerCase(),
        track: track,
      ),
  ];
  decorated.sort((a, b) {
    final byKey = a.key.compareTo(b.key);
    if (byKey != 0) return byKey;
    return a.tie.compareTo(b.tie);
  });
  return [for (final entry in decorated) entry.track];
}

bool _matches(({String title, String artist}) row, String query) =>
    row.title.toLowerCase().contains(query) ||
    row.artist.toLowerCase().contains(query);
