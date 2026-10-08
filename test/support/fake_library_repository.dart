import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:molia/data/library_repository.dart';
import 'package:molia/data/lxmc_decoder.dart';
import 'package:molia/domain/models/library.dart';

/// 内存版资料库仓库：widget 测试专用。
///
/// widget 测试运行在 fake-async 区，真实 sqflite I/O 不会完成（会触发
/// 「database has been locked」并让加载动画永不停止）；因此 UI 交互测试
/// 一律使用本假实现，真实 DB 行为由 library_repository_test 覆盖。
class FakeLibraryRepository extends LibraryRepository {
  FakeLibraryRepository()
      : super(databaseProvider: () async => throw UnimplementedError());

  /// sync: true —— 变更事件在写入调用栈内同步派发，provider 的重载
  /// Future 在 widget 测试的 fake-async 区内正常完成（否则跨 zone 挂起）。
  final StreamController<void> _changes =
      StreamController<void>.broadcast(sync: true);
  final List<PlayHistoryEntry> _history = [];
  final Map<int, PlaylistInfo> _playlists = {};
  final Map<int, List<PlaylistTrack>> _tracks = {};
  final Set<String> _favorites = {};
  int _nextPlaylistId = 1;
  int _nextOrder = 0;

  LibraryChangeKind _lastKind = LibraryChangeKind.playlists;
  int? _lastPlaylistId;

  @override
  Stream<void> get changes => _changes.stream;

  /// 模拟真实仓库的变更类型（provider 依此决定缓存失效范围）。
  @override
  LibraryChangeKind get lastChangeKind => _lastKind;

  @override
  int? get lastChangePlaylistId => _lastPlaylistId;

  void _changed({
    LibraryChangeKind kind = LibraryChangeKind.playlists,
    int? playlistId,
  }) {
    _lastKind = kind;
    _lastPlaylistId = playlistId;
    if (!_changes.isClosed) _changes.add(null);
  }

  // -------------------------------------------------------------------------
  // 播放历史
  // -------------------------------------------------------------------------

  @override
  Future<void> addHistoryEntry(PlayHistoryEntry entry) async {
    _history.removeWhere(
        (e) => e.sourceKey == entry.sourceKey && e.songId == entry.songId);
    _history.add(entry);
    _history.sort((a, b) => b.playedAt.compareTo(a.playedAt));
    _changed(kind: LibraryChangeKind.history);
  }

  @override
  Future<List<PlayHistoryEntry>> listHistory(
          {int limit = LibraryRepository.historyLimit}) async =>
      _history.take(limit).toList();

  @override
  Future<void> deleteHistoryEntry(String sourceKey, String songId) async {
    _history
        .removeWhere((e) => e.sourceKey == sourceKey && e.songId == songId);
    _changed(kind: LibraryChangeKind.history);
  }

  @override
  Future<int> deleteHistoryEntries(List<TrackKey> keys) async {
    if (keys.isEmpty) return 0;
    final known = {
      for (final key in keys) '${key.sourceKey}:${key.songId}',
    };
    final before = _history.length;
    _history.removeWhere((e) => known.contains('${e.sourceKey}:${e.songId}'));
    final removed = before - _history.length;
    if (removed > 0) _changed(kind: LibraryChangeKind.history);
    return removed;
  }

  @override
  Future<int> addHistoryEntries(List<PlayHistoryEntry> entries) async {
    if (entries.isEmpty) return 0;
    for (final entry in entries) {
      _history.removeWhere(
          (e) => e.sourceKey == entry.sourceKey && e.songId == entry.songId);
      _history.add(entry);
    }
    _history.sort((a, b) => b.playedAt.compareTo(a.playedAt));
    if (_history.length > LibraryRepository.historyLimit) {
      _history.removeRange(LibraryRepository.historyLimit, _history.length);
    }
    _changed(kind: LibraryChangeKind.history);
    return entries.length;
  }

  @override
  Future<void> clearHistory() async {
    _history.clear();
    _changed(kind: LibraryChangeKind.history);
  }

  // -------------------------------------------------------------------------
  // 列表
  // -------------------------------------------------------------------------

  @override
  Future<int> createPlaylist(String name) async {
    final id = _nextPlaylistId++;
    _playlists[id] = PlaylistInfo(
      id: id,
      name: name,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    _tracks[id] = [];
    _changed();
    return id;
  }

  @override
  Future<PlaylistInfo?> findPlaylistByName(String name) async {
    for (final playlist in _playlists.values) {
      if (playlist.name == name) return playlist;
    }
    return null;
  }

  @override
  Future<PlaylistInfo?> playlistById(int id) async => _playlists[id];

  @override
  Future<List<PlaylistInfo>> listPlaylists() async =>
      _playlists.values.toList();

  @override
  Future<void> renamePlaylist(int id, String name) async {
    final playlist = _playlists[id];
    if (playlist == null) return;
    _playlists[id] = PlaylistInfo(
      id: playlist.id,
      name: name,
      createdAt: playlist.createdAt,
      trackCount: playlist.trackCount,
    );
    _changed();
  }

  @override
  Future<void> deletePlaylist(int id) async {
    _playlists.remove(id);
    _tracks.remove(id);
    _changed();
  }

  @override
  Future<List<PlaylistTrack>> listPlaylistTracks(int playlistId) async =>
      List.of(_tracks[playlistId] ?? const []);

  @override
  Future<bool> addTrackToPlaylist(
    int playlistId,
    PlaylistTrack track, {
    bool favoriteChange = false,
  }) async {
    final list = _tracks.putIfAbsent(playlistId, () => []);
    final exists = list.any(
        (t) => t.sourceKey == track.sourceKey && t.songId == track.songId);
    if (exists) return false;
    list.add(track);
    _syncTrackCount(playlistId);
    _changed(kind: LibraryChangeKind.playlistTracks, playlistId: playlistId);
    return true;
  }

  @override
  Future<int> removeTrackFromPlaylist(
    int playlistId,
    String sourceKey,
    String songId, {
    bool favoriteChange = false,
  }) async {
    final list = _tracks[playlistId];
    if (list == null) return 0;
    final before = list.length;
    list.removeWhere((t) => t.sourceKey == sourceKey && t.songId == songId);
    final removed = before - list.length;
    if (removed > 0) {
      _syncTrackCount(playlistId);
      _changed(kind: LibraryChangeKind.playlistTracks, playlistId: playlistId);
    }
    return removed;
  }

  @override
  Future<int> removeTracksFromPlaylist(
    int playlistId,
    List<TrackKey> keys, {
    bool favoriteChange = false,
  }) async {
    if (keys.isEmpty) return 0;
    final list = _tracks[playlistId];
    if (list == null) return 0;
    final known = {
      for (final key in keys) '${key.sourceKey}:${key.songId}',
    };
    final before = list.length;
    list.removeWhere((t) => known.contains('${t.sourceKey}:${t.songId}'));
    final removed = before - list.length;
    if (removed > 0) {
      _syncTrackCount(playlistId);
      _changed(
        kind: favoriteChange
            ? LibraryChangeKind.favorites
            : LibraryChangeKind.playlistTracks,
        playlistId: playlistId,
      );
    }
    return removed;
  }

  @override
  Future<int> addTracksToPlaylist(
    int playlistId,
    List<PlaylistTrack> tracks, {
    bool favoriteChange = false,
  }) async {
    if (tracks.isEmpty) return 0;
    final list = _tracks.putIfAbsent(playlistId, () => []);
    var added = 0;
    for (final track in tracks) {
      final exists = list.any(
          (t) => t.sourceKey == track.sourceKey && t.songId == track.songId);
      if (exists) continue;
      list.add(
        PlaylistTrack(
          playlistId: playlistId,
          sourceKey: track.sourceKey,
          songId: track.songId,
          title: track.title,
          artist: track.artist,
          album: track.album,
          coverUrl: track.coverUrl,
          durationMs: track.durationMs,
          raw: track.raw,
          addedAt: track.addedAt,
          sortOrder: list.length,
        ),
      );
      added++;
    }
    if (added > 0) {
      _syncTrackCount(playlistId);
      _changed(
        kind: favoriteChange
            ? LibraryChangeKind.favorites
            : LibraryChangeKind.playlistTracks,
        playlistId: playlistId,
      );
    }
    return added;
  }

  @override
  Future<void> reorderPlaylistTracks(
    int playlistId,
    List<TrackKey> ordered,
  ) async {
    final list = _tracks[playlistId];
    if (list == null || ordered.isEmpty) return;
    final byKey = {
      for (final track in list) '${track.sourceKey}:${track.songId}': track,
    };
    final reordered = <PlaylistTrack>[];
    for (final key in ordered) {
      final track = byKey.remove('${key.sourceKey}:${key.songId}');
      if (track != null) reordered.add(track);
    }
    reordered.addAll(byKey.values);
    _tracks[playlistId] = [
      for (var i = 0; i < reordered.length; i++)
        PlaylistTrack(
          playlistId: playlistId,
          sourceKey: reordered[i].sourceKey,
          songId: reordered[i].songId,
          title: reordered[i].title,
          artist: reordered[i].artist,
          album: reordered[i].album,
          coverUrl: reordered[i].coverUrl,
          durationMs: reordered[i].durationMs,
          raw: reordered[i].raw,
          addedAt: reordered[i].addedAt,
          sortOrder: i,
        ),
    ];
    _changed(kind: LibraryChangeKind.playlistTracks, playlistId: playlistId);
  }

  void _syncTrackCount(int playlistId) {
    final playlist = _playlists[playlistId];
    if (playlist == null) return;
    _playlists[playlistId] = PlaylistInfo(
      id: playlist.id,
      name: playlist.name,
      createdAt: playlist.createdAt,
      trackCount: _tracks[playlistId]?.length ?? 0,
    );
  }

  // -------------------------------------------------------------------------
  // 收藏
  // -------------------------------------------------------------------------

  @override
  Future<Set<String>> favoriteKeys() async => Set.of(_favorites);

  @override
  Future<bool> toggleFavorite({
    required String sourceKey,
    required String songId,
    required String title,
    String artist = '',
    String album = '',
    String? coverUrl,
    int? durationMs,
    Map<String, dynamic> raw = const {},
  }) async {
    final key = '$sourceKey:$songId';
    final added = _favorites.add(key);
    if (!added) {
      _favorites.remove(key);
      final favoritesId = (await findPlaylistByName(kFavoritesPlaylistName))?.id;
      if (favoritesId != null) {
        await removeTrackFromPlaylist(favoritesId, sourceKey, songId);
      }
    } else {
      final favoritesId = await _ensureFavoritesPlaylist();
      await addTrackToPlaylist(
        favoritesId,
        PlaylistTrack(
          playlistId: favoritesId,
          sourceKey: sourceKey,
          songId: songId,
          title: title,
          artist: artist,
          album: album,
          coverUrl: coverUrl,
          durationMs: durationMs,
          raw: raw,
          addedAt: DateTime.now().millisecondsSinceEpoch,
          sortOrder: _nextOrder++,
        ),
      );
    }
    _changed(kind: LibraryChangeKind.favorites);
    return added;
  }

  Future<int> _ensureFavoritesPlaylist() async {
    final existing = await findPlaylistByName(kFavoritesPlaylistName);
    if (existing != null) return existing.id;
    return createPlaylist(kFavoritesPlaylistName);
  }

  @override
  Future<int> addFavorites(List<PlaylistTrack> tracks) async {
    if (tracks.isEmpty) return 0;
    final favoritesId = await _ensureFavoritesPlaylist();
    for (final track in tracks) {
      _favorites.add('${track.sourceKey}:${track.songId}');
    }
    return addTracksToPlaylist(
      favoritesId,
      tracks,
      favoriteChange: true,
    );
  }

  @override
  Future<int> removeFavorites(List<TrackKey> keys) async {
    if (keys.isEmpty) return 0;
    final favorites = await findPlaylistByName(kFavoritesPlaylistName);
    if (favorites == null) return 0;
    for (final key in keys) {
      _favorites.remove('${key.sourceKey}:${key.songId}');
    }
    return removeTracksFromPlaylist(
      favorites.id,
      keys,
      favoriteChange: true,
    );
  }

  // -------------------------------------------------------------------------
  // .lxmc 导入（复用真实解码器，落库为内存）
  // -------------------------------------------------------------------------

  @override
  Future<LxmcImportResult> importLxmcBytes(Uint8List bytes,
      {String? fileName}) async {
    final decoded = decodeLxmcBytes(bytes, fileName: fileName);
    final existing = await findPlaylistByName(decoded.name);
    final playlistId = existing?.id ?? await createPlaylist(decoded.name);
    var imported = 0;
    for (final track in decoded.tracks) {
      final added = await addTrackToPlaylist(
        playlistId,
        PlaylistTrack(
          playlistId: playlistId,
          sourceKey: track.sourceKey,
          songId: track.songId,
          title: track.title,
          artist: track.artist,
          album: track.album,
          coverUrl: track.coverUrl,
          durationMs: track.durationMs,
          raw: track.raw,
          addedAt: DateTime.now().millisecondsSinceEpoch,
          sortOrder: _nextOrder++,
        ),
      );
      if (added) imported++;
    }
    return LxmcImportResult(
      playlistId: playlistId,
      playlistName: decoded.name,
      total: decoded.tracks.length + decoded.skipped,
      imported: imported,
      skipped: decoded.skipped,
      reusedPlaylist: existing != null,
    );
  }

  @override
  Future<({int playlistId, int added, int total})> importTracks(
    String name,
    List<PlaylistTrack> tracks,
  ) async {
    if (tracks.isEmpty) return (playlistId: -1, added: 0, total: 0);
    final existing = await findPlaylistByName(name);
    final playlistId = existing?.id ?? await createPlaylist(name);
    final added = await addTracksToPlaylist(playlistId, tracks);
    return (playlistId: playlistId, added: added, total: tracks.length);
  }

  @override
  Future<void> dispose() async {
    await _changes.close();
  }
}
