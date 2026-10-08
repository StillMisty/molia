/// 本地资料库数据仓库：播放历史 / 用户列表 / 收藏 / `.lxmc` 导入。
///
/// 纯数据操作（sqflite），返回 [PlayHistoryEntry] / [PlaylistInfo] /
/// [PlaylistTrack] 等领域模型；**不持久化播放直链**（只存元数据 + raw 取链
/// 参数），播放时由上层按需重新取链（对齐 LX Music 的设计）。
///
/// 所有写操作后通过 [changes] 广播变更，provider 据此失效内存缓存。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../domain/models/library.dart';
import 'database_helper.dart';
import 'lxmc_decoder.dart';

/// 默认收藏列表的内部保留名（UI 显示时映射为本地化文案，不直接展示）。
const String kFavoritesPlaylistName = '__favorites__';

/// 资料库变更类型：provider 据此决定失效范围（收藏切换不再整体清缓存，
/// 避免列表闪动/滚动位置丢失）。
enum LibraryChangeKind {
  /// 播放历史变化。
  history,

  /// 列表集合（新建/重命名/删除）变化。
  playlists,

  /// 单个列表内曲目变化。
  playlistTracks,

  /// 收藏状态变化。
  favorites,

  /// `.lxmc` 批量导入（历史/列表/收藏都可能变化）。
  import,
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

class LibraryRepository {
  /// [databaseProvider] 仅测试注入（in-memory sqflite FFI）；生产走
  /// [DatabaseHelper.instance]（版本迁移 v2 → v3）。
  LibraryRepository({Future<Database> Function()? databaseProvider})
      : _databaseProvider =
            databaseProvider ?? (() => DatabaseHelper.instance.database);

  final Future<Database> Function() _databaseProvider;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  LibraryChangeKind _lastChangeKind = LibraryChangeKind.playlists;
  int? _lastChangePlaylistId;

  /// 最近一次变更的类型（与 [changes] 事件同步更新，供 provider 判定失效范围）。
  LibraryChangeKind get lastChangeKind => _lastChangeKind;

  /// 最近一次「单列表曲目」变更对应的列表 id（其余类型为 null）。
  int? get lastChangePlaylistId => _lastChangePlaylistId;

  /// 播放历史上限（超出删最旧，避免无限增长）。
  static const int historyLimit = 500;

  /// 资料库变更广播（history / playlists / favorites 任一写操作后触发）。
  Stream<void> get changes => _changes.stream;

  Future<Database> get _db => _databaseProvider();

  void _notifyChanged({
    LibraryChangeKind kind = LibraryChangeKind.playlists,
    int? playlistId,
  }) {
    _lastChangeKind = kind;
    _lastChangePlaylistId = playlistId;
    if (!_changes.isClosed) _changes.add(null);
  }

  // 播放历史

  /// 写入/更新时间播放记录（唯一键 `(sourceKey, songId)`），并裁剪到上限。
  Future<void> addHistoryEntry(PlayHistoryEntry entry) async {
    final db = await _db;
    await db.insert(
      'play_history',
      {
        'sourceKey': entry.sourceKey,
        'songId': entry.songId,
        'title': entry.title,
        'artist': entry.artist,
        'album': entry.album,
        'coverUrl': entry.coverUrl,
        'durationMs': entry.durationMs,
        'raw': jsonEncode(entry.raw),
        'playedAt': entry.playedAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _trimHistory(db);
    _notifyChanged(kind: LibraryChangeKind.history);
  }

  /// 超出 [historyLimit] 时删除最旧记录。
  Future<void> _trimHistory(Database db) async {
    await db.rawDelete(
      'DELETE FROM play_history WHERE rowid NOT IN ('
      'SELECT rowid FROM play_history ORDER BY playedAt DESC, rowid DESC LIMIT ?)',
      [historyLimit],
    );
  }

  /// 最近播放（playedAt 倒序）。
  Future<List<PlayHistoryEntry>> listHistory({int limit = historyLimit}) async {
    final db = await _db;
    final rows = await db.query(
      'play_history',
      orderBy: 'playedAt DESC, rowid DESC',
      limit: limit,
    );
    return [for (final row in rows) _historyFromRow(row)];
  }

  Future<void> deleteHistoryEntry(String sourceKey, String songId) async {
    final db = await _db;
    await db.delete(
      'play_history',
      where: 'sourceKey = ? AND songId = ?',
      whereArgs: [sourceKey, songId],
    );
    _notifyChanged(kind: LibraryChangeKind.history);
  }

  /// 批量删除历史记录（事务；返回实际删除数，变更只广播一次）。
  Future<int> deleteHistoryEntries(List<TrackKey> keys) async {
    if (keys.isEmpty) return 0;
    final db = await _db;
    var removed = 0;
    await db.transaction((txn) async {
      for (final key in keys) {
        removed += await txn.delete(
          'play_history',
          where: 'sourceKey = ? AND songId = ?',
          whereArgs: [key.sourceKey, key.songId],
        );
      }
    });
    if (removed > 0) _notifyChanged(kind: LibraryChangeKind.history);
    return removed;
  }

  /// 批量写入播放历史（唯一键 upsert + 裁剪上限；单次广播）。
  ///
  /// 供「加入列表 → 播放历史」使用：把曲目记为最近播放。
  Future<int> addHistoryEntries(List<PlayHistoryEntry> entries) async {
    if (entries.isEmpty) return 0;
    final db = await _db;
    final batch = db.batch();
    for (final entry in entries) {
      batch.insert(
        'play_history',
        {
          'sourceKey': entry.sourceKey,
          'songId': entry.songId,
          'title': entry.title,
          'artist': entry.artist,
          'album': entry.album,
          'coverUrl': entry.coverUrl,
          'durationMs': entry.durationMs,
          'raw': jsonEncode(entry.raw),
          'playedAt': entry.playedAt,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    await _trimHistory(db);
    _notifyChanged(kind: LibraryChangeKind.history);
    return entries.length;
  }

  Future<void> clearHistory() async {
    final db = await _db;
    await db.delete('play_history');
    _notifyChanged(kind: LibraryChangeKind.history);
  }

  // 用户列表

  Future<int> createPlaylist(String name) async {
    final db = await _db;
    final id = await db.insert('playlists', {
      'name': name,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });
    _notifyChanged(kind: LibraryChangeKind.playlists);
    return id;
  }

  Future<PlaylistInfo?> findPlaylistByName(String name) async {
    final db = await _db;
    final rows = await db.query(
      'playlists',
      where: 'name = ?',
      whereArgs: [name],
      orderBy: 'id ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _playlistFromRow(rows.first);
  }

  Future<PlaylistInfo?> playlistById(int id) async {
    final db = await _db;
    final rows = await db.query(
      'playlists',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _playlistFromRow(rows.first);
  }

  /// 全部列表（默认收藏置顶，其余新列表在前），带曲目数。
  Future<List<PlaylistInfo>> listPlaylists() async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT p.id, p.name, p.createdAt, COUNT(t.id) AS trackCount
      FROM playlists p
      LEFT JOIN playlist_tracks t ON t.playlistId = p.id
      GROUP BY p.id
      ORDER BY CASE WHEN p.name = ? THEN 0 ELSE 1 END, p.createdAt DESC, p.id DESC
    ''', [kFavoritesPlaylistName]);
    return [for (final row in rows) _playlistFromRow(row)];
  }

  Future<void> renamePlaylist(int id, String name) async {
    final db = await _db;
    await db.update(
      'playlists',
      {'name': name},
      where: 'id = ?',
      whereArgs: [id],
    );
    _notifyChanged(kind: LibraryChangeKind.playlists);
  }

  Future<void> deletePlaylist(int id) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.delete('playlist_tracks',
          where: 'playlistId = ?', whereArgs: [id]);
      await txn.delete('playlists', where: 'id = ?', whereArgs: [id]);
    });
    _notifyChanged(kind: LibraryChangeKind.playlists);
  }

  /// 列表内曲目（sortOrder 升序，其次加入时间）。
  Future<List<PlaylistTrack>> listPlaylistTracks(int playlistId) async {
    final db = await _db;
    final rows = await db.query(
      'playlist_tracks',
      where: 'playlistId = ?',
      whereArgs: [playlistId],
      orderBy: 'sortOrder ASC, addedAt ASC, id ASC',
    );
    return [for (final row in rows) _trackFromRow(row)];
  }

  /// 加入列表（`(playlistId, sourceKey, songId)` 唯一，重复加入返回 false）。
  ///
  /// [favoriteChange] 为 true 时（收藏切换内部调用）变更类型标记为
  /// [LibraryChangeKind.favorites]，provider 只做局部刷新。
  Future<bool> addTrackToPlaylist(
    int playlistId,
    PlaylistTrack track, {
    bool favoriteChange = false,
  }) async {
    final db = await _db;
    final existing = await db.query(
      'playlist_tracks',
      columns: ['id'],
      where: 'playlistId = ? AND sourceKey = ? AND songId = ?',
      whereArgs: [playlistId, track.sourceKey, track.songId],
      limit: 1,
    );
    if (existing.isNotEmpty) return false;

    final maxRow = await db.rawQuery(
      'SELECT MAX(sortOrder) AS m FROM playlist_tracks WHERE playlistId = ?',
      [playlistId],
    );
    final nextOrder = ((maxRow.first['m'] as int?) ?? -1) + 1;

    await db.insert(
      'playlist_tracks',
      {
        'playlistId': playlistId,
        'sourceKey': track.sourceKey,
        'songId': track.songId,
        'title': track.title,
        'artist': track.artist,
        'album': track.album,
        'coverUrl': track.coverUrl,
        'durationMs': track.durationMs,
        'raw': jsonEncode(track.raw),
        'addedAt': track.addedAt,
        'sortOrder': nextOrder,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    _notifyChanged(
      kind: favoriteChange
          ? LibraryChangeKind.favorites
          : LibraryChangeKind.playlistTracks,
      playlistId: playlistId,
    );
    return true;
  }

  Future<int> removeTrackFromPlaylist(
    int playlistId,
    String sourceKey,
    String songId, {
    bool favoriteChange = false,
  }) async {
    final db = await _db;
    final removed = await db.delete(
      'playlist_tracks',
      where: 'playlistId = ? AND sourceKey = ? AND songId = ?',
      whereArgs: [playlistId, sourceKey, songId],
    );
    if (removed > 0) {
      _notifyChanged(
        kind: favoriteChange
            ? LibraryChangeKind.favorites
            : LibraryChangeKind.playlistTracks,
        playlistId: playlistId,
      );
    }
    return removed;
  }

  /// 批量移除列表曲目（事务；返回实际移除数，变更只广播一次）。
  ///
  /// [favoriteChange] 为 true 时（默认收藏批量操作）变更类型标记为
  /// [LibraryChangeKind.favorites]，provider 只做局部刷新。
  Future<int> removeTracksFromPlaylist(
    int playlistId,
    List<TrackKey> keys, {
    bool favoriteChange = false,
  }) async {
    if (keys.isEmpty) return 0;
    final db = await _db;
    var removed = 0;
    await db.transaction((txn) async {
      for (final key in keys) {
        removed += await txn.delete(
          'playlist_tracks',
          where: 'playlistId = ? AND sourceKey = ? AND songId = ?',
          whereArgs: [playlistId, key.sourceKey, key.songId],
        );
      }
    });
    if (removed > 0) {
      _notifyChanged(
        kind: favoriteChange
            ? LibraryChangeKind.favorites
            : LibraryChangeKind.playlistTracks,
        playlistId: playlistId,
      );
    }
    return removed;
  }

  /// 批量加入列表（跳过重复并追加到末尾；返回实际新增数）。
  ///
  /// [tracks] 来自任意合集（收藏/历史/其他列表）的复制：曲目级字段原样写入，
  /// `playlistId` 以本方法参数为准。[favoriteChange] 语义同
  /// [removeTracksFromPlaylist]。
  Future<int> addTracksToPlaylist(
    int playlistId,
    List<PlaylistTrack> tracks, {
    bool favoriteChange = false,
  }) async {
    if (tracks.isEmpty) return 0;
    final db = await _db;
    final rows = await db.query(
      'playlist_tracks',
      columns: ['sourceKey', 'songId'],
      where: 'playlistId = ?',
      whereArgs: [playlistId],
    );
    final known = {
      for (final row in rows) '${row['sourceKey']}:${row['songId']}',
    };
    final maxRow = await db.rawQuery(
      'SELECT MAX(sortOrder) AS m FROM playlist_tracks WHERE playlistId = ?',
      [playlistId],
    );
    var nextOrder = ((maxRow.first['m'] as int?) ?? -1) + 1;
    var added = 0;
    final batch = db.batch();
    for (final track in tracks) {
      final key = '${track.sourceKey}:${track.songId}';
      if (!known.add(key)) continue;
      batch.insert(
        'playlist_tracks',
        {
          'playlistId': playlistId,
          'sourceKey': track.sourceKey,
          'songId': track.songId,
          'title': track.title,
          'artist': track.artist,
          'album': track.album,
          'coverUrl': track.coverUrl,
          'durationMs': track.durationMs,
          'raw': jsonEncode(track.raw),
          'addedAt': track.addedAt,
          'sortOrder': nextOrder++,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      added++;
    }
    if (added > 0) {
      await batch.commit(noResult: true);
      _notifyChanged(
        kind: favoriteChange
            ? LibraryChangeKind.favorites
            : LibraryChangeKind.playlistTracks,
        playlistId: playlistId,
      );
    }
    return added;
  }

  /// 按给定顺序重写 `sortOrder`（事务；仅更新仍存在于列表中的键）。
  Future<void> reorderPlaylistTracks(
    int playlistId,
    List<TrackKey> ordered,
  ) async {
    if (ordered.isEmpty) return;
    final db = await _db;
    await db.transaction((txn) async {
      for (var index = 0; index < ordered.length; index++) {
        final key = ordered[index];
        await txn.update(
          'playlist_tracks',
          {'sortOrder': index},
          where: 'playlistId = ? AND sourceKey = ? AND songId = ?',
          whereArgs: [playlistId, key.sourceKey, key.songId],
        );
      }
    });
    _notifyChanged(
      kind: LibraryChangeKind.playlistTracks,
      playlistId: playlistId,
    );
  }

  // 收藏（默认列表）

  Future<int> _ensureFavoritesPlaylist() async {
    final existing = await findPlaylistByName(kFavoritesPlaylistName);
    if (existing != null) return existing.id;
    return createPlaylist(kFavoritesPlaylistName);
  }

  /// 收藏键集合（`sourceKey:songId`），供 provider 一次性缓存。
  Future<Set<String>> favoriteKeys() async {
    final db = await _db;
    final playlist = await findPlaylistByName(kFavoritesPlaylistName);
    if (playlist == null) return {};
    final rows = await db.query(
      'playlist_tracks',
      columns: ['sourceKey', 'songId'],
      where: 'playlistId = ?',
      whereArgs: [playlist.id],
    );
    return {
      for (final row in rows) '${row['sourceKey']}:${row['songId']}',
    };
  }

  /// 切换收藏；返回切换后的状态（true = 已收藏）。
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
    final playlistId = await _ensureFavoritesPlaylist();
    final removed = await removeTrackFromPlaylist(
      playlistId,
      sourceKey,
      songId,
      favoriteChange: true,
    );
    if (removed > 0) return false;
    await addTrackToPlaylist(
      playlistId,
      PlaylistTrack(
        playlistId: playlistId,
        sourceKey: sourceKey,
        songId: songId,
        title: title,
        artist: artist,
        album: album,
        coverUrl: coverUrl,
        durationMs: durationMs,
        raw: raw,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      ),
      favoriteChange: true,
    );
    return true;
  }

  /// 批量加入默认收藏（跳过已收藏；返回新增数）。
  Future<int> addFavorites(List<PlaylistTrack> tracks) async {
    if (tracks.isEmpty) return 0;
    final playlistId = await _ensureFavoritesPlaylist();
    return addTracksToPlaylist(playlistId, tracks, favoriteChange: true);
  }

  /// 批量取消收藏（返回移除数；无收藏列表时为 0）。
  Future<int> removeFavorites(List<TrackKey> keys) async {
    if (keys.isEmpty) return 0;
    final playlist = await findPlaylistByName(kFavoritesPlaylistName);
    if (playlist == null) return 0;
    return removeTracksFromPlaylist(playlist.id, keys, favoriteChange: true);
  }

  // .lxmc 导入

  /// 导入 `.lxmc` 收藏夹：同名列表复用（重复导入幂等），逐曲 INSERT OR IGNORE。
  Future<LxmcImportResult> importLxmcBytes(
    Uint8List bytes, {
    String? fileName,
  }) async {
    final decoded = decodeLxmcBytes(bytes, fileName: fileName);
    if (decoded.tracks.isEmpty) {
      throw const LxmcDecodeException('no_tracks');
    }

    final db = await _db;
    final existingPlaylist = await findPlaylistByName(decoded.name);
    final playlistId =
        existingPlaylist?.id ?? await createPlaylist(decoded.name);

    final rows = await db.query(
      'playlist_tracks',
      columns: ['sourceKey', 'songId'],
      where: 'playlistId = ?',
      whereArgs: [playlistId],
    );
    final knownKeys = {
      for (final row in rows) '${row['sourceKey']}:${row['songId']}',
    };

    final maxRow = await db.rawQuery(
      'SELECT MAX(sortOrder) AS m FROM playlist_tracks WHERE playlistId = ?',
      [playlistId],
    );
    var nextOrder = ((maxRow.first['m'] as int?) ?? -1) + 1;

    final now = DateTime.now().millisecondsSinceEpoch;
    var imported = 0;
    final batch = db.batch();
    for (final track in decoded.tracks) {
      final key = '${track.sourceKey}:${track.songId}';
      if (knownKeys.contains(key)) continue;
      knownKeys.add(key);
      batch.insert(
        'playlist_tracks',
        {
          'playlistId': playlistId,
          'sourceKey': track.sourceKey,
          'songId': track.songId,
          'title': track.title,
          'artist': track.artist,
          'album': track.album,
          'coverUrl': track.coverUrl,
          'durationMs': track.durationMs,
          'raw': jsonEncode(track.raw),
          'addedAt': now,
          'sortOrder': nextOrder++,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      imported++;
    }
    if (imported > 0) {
      await batch.commit(noResult: true);
    }

    _notifyChanged(kind: LibraryChangeKind.import, playlistId: playlistId);
    return LxmcImportResult(
      playlistId: playlistId,
      playlistName: decoded.name,
      total: decoded.tracks.length,
      imported: imported,
      skipped: decoded.skipped,
      reusedPlaylist: existingPlaylist != null,
    );
  }

  /// 把曲目导入同名列表（不存在则创建；重复导入幂等）。
  ///
  /// 返回 `(playlistId, 本次新增数, 曲目总数)`；供五平台链接导入与
  /// 发现页歌单导入使用（总数用于区分空歌单与全部重复）。
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

  // 行映射

  PlayHistoryEntry _historyFromRow(Map<String, Object?> row) =>
      PlayHistoryEntry(
        sourceKey: row['sourceKey'] as String? ?? '',
        songId: row['songId'] as String? ?? '',
        title: row['title'] as String? ?? '',
        artist: row['artist'] as String? ?? '',
        album: row['album'] as String? ?? '',
        coverUrl: row['coverUrl'] as String?,
        durationMs: row['durationMs'] as int?,
        raw: _decodeRaw(row['raw']),
        playedAt: row['playedAt'] as int? ?? 0,
      );

  PlaylistInfo _playlistFromRow(Map<String, Object?> row) => PlaylistInfo(
        id: row['id'] as int? ?? -1,
        name: row['name'] as String? ?? '',
        createdAt: row['createdAt'] as int? ?? 0,
        trackCount: row['trackCount'] as int? ?? 0,
      );

  PlaylistTrack _trackFromRow(Map<String, Object?> row) => PlaylistTrack(
        playlistId: row['playlistId'] as int? ?? -1,
        sourceKey: row['sourceKey'] as String? ?? '',
        songId: row['songId'] as String? ?? '',
        title: row['title'] as String? ?? '',
        artist: row['artist'] as String? ?? '',
        album: row['album'] as String? ?? '',
        coverUrl: row['coverUrl'] as String?,
        durationMs: row['durationMs'] as int?,
        raw: _decodeRaw(row['raw']),
        addedAt: row['addedAt'] as int? ?? 0,
        sortOrder: row['sortOrder'] as int? ?? 0,
      );

  Map<String, dynamic> _decodeRaw(Object? raw) {
    if (raw is! String || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      // 损坏数据降级为空 raw，不影响列表展示。
    }
    return const {};
  }

  Future<void> dispose() async {
    await _changes.close();
  }
}
