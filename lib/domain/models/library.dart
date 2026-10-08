/// 本地资料库领域模型（纯 Dart，无 Flutter/provider 依赖）。
///
/// 设计对齐 LX Music：持久化**曲目元数据 + 取链参数（raw payload）**，
/// **不持久化播放直链**（直链有时效）；播放时用 [raw] 按需重新取链。
library;

/// 曲目在列表/播放历史中的唯一键（`sourceKey` + `songId`）。
///
/// 列表与历史都以该组合为唯一约束，批量操作（移除/排序/删除）按此定位。
typedef TrackKey = ({String sourceKey, String songId});

/// 播放历史条目（`play_history` 表）。
///
/// 唯一键为 `(sourceKey, songId)`：重复播放只更新时间，不产生新行。
class PlayHistoryEntry {
  final String sourceKey;
  final String songId;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final int? durationMs;

  /// 取链参数：音源脚本 `musicUrl/lyric/pic` 需要的原始平台字段
  /// （`SourceTrack.raw` / 领域 `Track.payload` 的持久化形态）。
  final Map<String, dynamic> raw;
  final int playedAt;

  const PlayHistoryEntry({
    required this.sourceKey,
    required this.songId,
    required this.title,
    this.artist = '',
    this.album = '',
    this.coverUrl,
    this.durationMs,
    this.raw = const {},
    required this.playedAt,
  });

  String get key => '$sourceKey:$songId';

  PlayHistoryEntry copyWith({int? playedAt}) => PlayHistoryEntry(
        sourceKey: sourceKey,
        songId: songId,
        title: title,
        artist: artist,
        album: album,
        coverUrl: coverUrl,
        durationMs: durationMs,
        raw: raw,
        playedAt: playedAt ?? this.playedAt,
      );

  @override
  String toString() => 'PlayHistoryEntry($key, $title)';
}

/// 用户列表（`playlists` 表）概要，附带曲目数（列表页展示用）。
class PlaylistInfo {
  final int id;
  final String name;
  final int createdAt;
  final int trackCount;

  const PlaylistInfo({
    required this.id,
    required this.name,
    required this.createdAt,
    this.trackCount = 0,
  });

  @override
  String toString() => 'PlaylistInfo($id, $name, $trackCount)';
}

/// 列表内曲目（`playlist_tracks` 表）。
///
/// 唯一键为 `(playlistId, sourceKey, songId)`：重复导入/收藏幂等。
class PlaylistTrack {
  final int playlistId;
  final String sourceKey;
  final String songId;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final int? durationMs;
  final Map<String, dynamic> raw;
  final int addedAt;
  final int sortOrder;

  const PlaylistTrack({
    required this.playlistId,
    required this.sourceKey,
    required this.songId,
    required this.title,
    this.artist = '',
    this.album = '',
    this.coverUrl,
    this.durationMs,
    this.raw = const {},
    required this.addedAt,
    this.sortOrder = 0,
  });

  String get key => '$sourceKey:$songId';

  /// 播放历史条目 → 列表曲目（收藏页「历史复制到列表」等场景共用）。
  factory PlaylistTrack.fromHistoryEntry(
    PlayHistoryEntry entry, {
    int playlistId = 0,
    required int addedAt,
  }) {
    return PlaylistTrack(
      playlistId: playlistId,
      sourceKey: entry.sourceKey,
      songId: entry.songId,
      title: entry.title,
      artist: entry.artist,
      album: entry.album,
      coverUrl: entry.coverUrl,
      durationMs: entry.durationMs,
      raw: entry.raw,
      addedAt: addedAt,
    );
  }

  @override
  String toString() => 'PlaylistTrack($key, $title)';
}
