import 'dart:typed_data';

import '../models/library.dart';

/// 资料库的领域意图端口：调用方（provider / UI）表达「要做什么」，
/// 不感知存储形状（列名 / sortOrder / 墓碑 / 保留行名）。
///
/// 实现见 `lib/data/library_repository.dart`。同步面是另一条 seam
/// （[LibrarySyncStore]）：同一个实现类兼两者，组合根分别注入。
abstract interface class LibraryStore {
  /// 变更广播：事件类型即失效范围（见 [LibraryChange]）。
  Stream<LibraryChange> get changes;

  // ── 播放历史 ─────────────────────────────────────────────
  Future<void> addHistoryEntry(PlayHistoryEntry entry);
  Future<int> addHistoryEntries(List<PlayHistoryEntry> entries);

  /// 批量把列表曲目加入播放历史（最近播放置顶）。
  ///
  /// 批内 `playedAt` 与写入顺序由存储实现负责：调用方不再自己造时间戳。
  /// [playedAt] 非空时作为批内基准（测试 / 固定时刻用）。
  Future<int> addHistoryTracks(List<PlaylistTrack> tracks, {int? playedAt});
  Future<List<PlayHistoryEntry>> listHistory({int limit = kHistoryLimit});
  Future<void> deleteHistoryEntry(String sourceKey, String songId);
  Future<int> deleteHistoryEntries(List<TrackKey> keys);
  Future<bool> replaceHistoryEntry(
    TrackKey oldKey,
    PlayHistoryEntry replacement,
  );
  Future<void> clearHistory();

  // ── 列表集合 ─────────────────────────────────────────────
  Future<int> createPlaylist(String name);
  Future<PlaylistInfo?> findPlaylistByName(String name);
  Future<PlaylistInfo?> playlistById(int id);
  Future<List<PlaylistInfo>> listPlaylists();
  Future<void> renamePlaylist(int id, String name);
  Future<void> deletePlaylist(int id);

  // ── 列表曲目 ─────────────────────────────────────────────

  /// 列表内曲目，保持展示顺序。
  ///
  /// [limit] 非空时只在存储层取前 N 行（AI 画像等只需少量样本的调用方
  /// 用，避免把整表读进内存）；null = 全部。
  Future<List<PlaylistTrack>> listPlaylistTracks(int playlistId, {int? limit});
  Future<bool> addTrackToPlaylist(
    int playlistId,
    PlaylistTrack track, {
    bool favoriteChange = false,
  });
  Future<int> addTracksToPlaylist(
    int playlistId,
    List<PlaylistTrack> tracks, {
    bool favoriteChange = false,
  });
  Future<int> removeTrackFromPlaylist(
    int playlistId,
    String sourceKey,
    String songId, {
    bool favoriteChange = false,
  });
  Future<int> removeTracksFromPlaylist(
    int playlistId,
    List<TrackKey> keys, {
    bool favoriteChange = false,
  });
  Future<void> reorderPlaylistTracks(int playlistId, List<TrackKey> ordered);
  Future<bool> replacePlaylistTrack(
    int playlistId,
    TrackKey oldKey,
    PlaylistTrack replacement, {
    bool favoriteChange = false,
  });

  // ── 收藏 ─────────────────────────────────────────────────
  Future<Set<String>> favoriteKeys();
  Future<bool> toggleFavorite({
    required String sourceKey,
    required String songId,
    required String title,
    String artist = '',
    String album = '',
    String? coverUrl,
    int? durationMs,
    Map<String, dynamic> raw = const {},
  });
  Future<int> addFavorites(List<PlaylistTrack> tracks);
  Future<int> removeFavorites(List<TrackKey> keys);

  // ── 导入 ─────────────────────────────────────────────────
  Future<LxmcImportResult> importLxmcBytes(Uint8List bytes, {String? fileName});

  /// 把曲目导入同名列表（不存在则创建；重复导入幂等）。
  ///
  /// [created] 表示本次调用新建了列表：新列表的曲目就是本次写入的全量，
  /// 消费方可以据此直接建立缓存，不必再读一次库。
  ///
  /// [rows] 是写路径实际落库的行（已分配 `playlistId` / `sortOrder` /
  /// `addedAt`，按导入顺序）：消费方直接用它预置缓存，不要再做去重或重排。
  Future<({
    int playlistId,
    int added,
    int total,
    bool created,
    List<PlaylistTrack> rows,
  })> importTracks(
    String name,
    List<PlaylistTrack> tracks,
  );

  /// 释放资源（关闭变更广播）。
  Future<void> dispose();
}
