/// 本地资料库领域模型（纯 Dart，无 Flutter/provider 依赖）。
///
/// 设计对齐 LX Music：持久化**曲目元数据 + 取链参数（raw payload）**，
/// **不持久化播放直链**（直链有时效）；播放时用 [raw] 按需重新取链。
library;

import 'device_sync.dart';
import 'track.dart';

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

  /// 是否为默认收藏列表（存储层的保留行名只在实现内；调用方用本概念）。
  final bool isFavorites;

  const PlaylistInfo({
    required this.id,
    required this.name,
    required this.createdAt,
    this.trackCount = 0,
    this.isFavorites = false,
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

  /// 领域曲目 → 列表曲目（专辑页等「加入列表」场景共用）。
  ///
  /// payload 浅拷贝原样透传（取链依赖平台字段）；歌手以 `, ` 连接，
  /// 与列表 / 历史的既有展示口径一致。
  factory PlaylistTrack.fromTrack(
    Track track, {
    int playlistId = 0,
    required int addedAt,
  }) {
    return PlaylistTrack(
      playlistId: playlistId,
      sourceKey: track.id.sourceKey,
      songId: track.id.id,
      title: track.title,
      artist: track.artistLabel,
      album: track.album ?? '',
      coverUrl: track.artwork?.uri.toString(),
      durationMs: track.duration?.inMilliseconds,
      raw: Map<String, dynamic>.from(track.payload),
      addedAt: addedAt,
    );
  }

  @override
  String toString() => 'PlaylistTrack($key, $title)';
}

/// 单次收藏切换的增量载荷：provider 据此只改缓存里的一行，不重查整表。
///
/// 加入收藏时携带写入行的完整 [track]（含真实 `sortOrder` / `addedAt`）；
/// 取消收藏只需要键。[track] 在 `favorite == true` 时必须有值。
final class FavoriteToggle {
  const FavoriteToggle({
    required this.sourceKey,
    required this.songId,
    required this.favorite,
    this.track,
  }) : assert(!favorite || track != null, '加入收藏必须带写入行');

  /// 加入收藏（[track] 是实际落库的列表行，位置字段已由写路径填好）。
  factory FavoriteToggle.add(PlaylistTrack track) => FavoriteToggle(
        sourceKey: track.sourceKey,
        songId: track.songId,
        favorite: true,
        track: track,
      );

  /// 取消收藏。
  factory FavoriteToggle.remove({
    required String sourceKey,
    required String songId,
  }) =>
      FavoriteToggle(
        sourceKey: sourceKey,
        songId: songId,
        favorite: false,
      );

  final String sourceKey;
  final String songId;

  /// 切换后的收藏状态（true = 已收藏）。
  final bool favorite;

  /// 仅加入收藏时有值：可直接插入缓存收藏列表的列表行。
  final PlaylistTrack? track;

  String get key => '$sourceKey:$songId';
}

/// 资料库变更事件：`LibraryStore.changes` 广播的载荷，类型即失效范围。
///
/// 收藏切换只做局部刷新（避免列表闪动 / 滚动位置丢失），所以事件必须携带
/// 「变了什么、变的是哪个列表」——`Stream<void>` + 事后回读 `lastChangeKind`
/// / `lastChangePlaylistId` 的侧信道里，消费方在异步边界之后读到的是「最近
/// 一次」而不是「本次」，并发写入下有歧义。
sealed class LibraryChange {
  const LibraryChange();

  /// 播放历史变化。
  ///
  /// [entry] 非空表示「单条写入」：消费方可以直接把这条记录合并进内存
  /// （重播原位替换、新条目置前），不必回查数据库。批量写入 / 删除 / 清空 /
  /// 同步落地等无法用单条表达的变化仍传 null，由消费方整表重载。
  const factory LibraryChange.history({PlayHistoryEntry? entry}) =
      LibraryHistoryChange;

  /// 列表集合（新建 / 重命名 / 删除）变化。
  const factory LibraryChange.playlists() = LibraryPlaylistsChange;

  /// 单个列表内曲目变化。
  const factory LibraryChange.playlistTracks(int playlistId) =
      LibraryPlaylistTracksChange;

  /// 收藏状态变化。
  ///
  /// [toggle] 非空表示「单曲收藏切换」：消费方可以就地增删收藏列表的一行并
  /// 校准计数；批量收藏 / 换源 / 同步 / 导入等传 null，走整表校准。
  const factory LibraryChange.favorites({FavoriteToggle? toggle}) =
      LibraryFavoritesChange;

  /// `.lxmc` 批量导入（历史 / 列表 / 收藏都可能变化）。
  const factory LibraryChange.import() = LibraryImportChange;
}

final class LibraryHistoryChange extends LibraryChange {
  const LibraryHistoryChange({this.entry});

  /// 单条写入的完整记录（null = 无法增量表达，需要整表重载）。
  final PlayHistoryEntry? entry;
}

final class LibraryPlaylistsChange extends LibraryChange {
  const LibraryPlaylistsChange();
}

final class LibraryPlaylistTracksChange extends LibraryChange {
  const LibraryPlaylistTracksChange(this.playlistId);

  final int playlistId;
}

final class LibraryFavoritesChange extends LibraryChange {
  const LibraryFavoritesChange({this.toggle});

  /// 单曲收藏切换的增量载荷（null = 需要整表校准）。
  final FavoriteToggle? toggle;
}

/// 资料库变更 → 受影响的同步类别（组合根据此标记待外发；蜂窝小类别轮
/// 只外发部分类别，标记按类别维护）。
extension LibraryChangeSyncCategories on LibraryChange {
  Set<SyncCategory> get syncCategories => switch (this) {
        LibraryHistoryChange() => const {SyncCategory.history},
        LibraryPlaylistsChange() => const {SyncCategory.playlists},
        LibraryPlaylistTracksChange() ||
        LibraryFavoritesChange() =>
          const {SyncCategory.playlists, SyncCategory.playlistTracks},
        LibraryImportChange() => const {
            SyncCategory.history,
            SyncCategory.playlists,
            SyncCategory.playlistTracks,
          },
      };
}

final class LibraryImportChange extends LibraryChange {
  const LibraryImportChange();
}

/// `.lxmc` 导入结果。
class LxmcImportResult {
  /// 落库列表 id（同名列表重复导入时复用）。
  final int playlistId;
  final String playlistName;

  /// 文件中的条目总数。
  final int total;

  /// 本次实际新增的曲目数（重复导入为 0）。
  final int imported;

  /// 解码时跳过的非法条目数。
  final int skipped;

  /// 是否复用了同名已存在列表。
  final bool reusedPlaylist;

  const LxmcImportResult({
    required this.playlistId,
    required this.playlistName,
    required this.total,
    required this.imported,
    required this.skipped,
    required this.reusedPlaylist,
  });

  @override
  String toString() =>
      'LxmcImportResult($playlistName, imported=$imported/$total)';
}

/// 播放历史上限（超出删最旧，避免无限增长）；实现与端口共用同一常量。
const int kHistoryLimit = 500;
