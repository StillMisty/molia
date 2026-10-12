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
import 'dart:math';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../domain/models/device_sync.dart';
import '../domain/models/library.dart';
import '../domain/ports/library_store.dart';
import '../domain/ports/library_sync_store.dart';
import 'database_helper.dart';
import 'lxmc_decoder.dart';

/// 默认收藏列表的保留行名：实现内部细节（UI 显示走本地化文案，调用方
/// 判定收藏用 [PlaylistInfo.isFavorites]）。
const String _favoritesPlaylistName = '__favorites__';

class LibraryRepository implements LibraryStore, LibrarySyncStore {
  /// [databaseProvider] 仅测试注入（in-memory sqflite FFI）；生产走
  /// [DatabaseHelper.instance]（版本迁移 v2 → v3）。
  ///
  /// [deviceIdProvider] / [clock] 供跨设备同步打写入时间戳与来源设备；
  /// 缺省（测试、同步未启用）时设备为空串，时间戳仍按当前时钟写入。
  LibraryRepository({
    Future<Database> Function()? databaseProvider,
    String Function()? deviceIdProvider,
    int Function()? clock,
  })  : _databaseProvider =
            databaseProvider ?? (() => DatabaseHelper.instance.database),
        _deviceIdProvider = deviceIdProvider ?? (() => ''),
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Future<Database> Function() _databaseProvider;
  final String Function() _deviceIdProvider;
  final int Function() _clock;
  final Random _random = Random.secure();
  final StreamController<LibraryChange> _changes =
      StreamController<LibraryChange>.broadcast();

  /// 播放历史上限（超出删最旧，避免无限增长）。
  static const int historyLimit = kHistoryLimit;

  /// 资料库变更广播（history / playlists / favorites 任一写操作后触发）。
  ///
  /// 事件类型即失效范围（见 [LibraryChange]）；写入调用栈内同步派发。
  @override
  Stream<LibraryChange> get changes => _changes.stream;

  Future<Database> get _db => _databaseProvider();

  int _nowMs() => _clock();

  String _deviceId() => _deviceIdProvider();

  /// 收藏列表用固定 syncId；其余列表按随机 128bit 生成（跨设备稳定，
  /// 自增 id 只在本机有效）。
  String _newSyncId(String name) {
    if (name == _favoritesPlaylistName) {
      return SyncRecordKeys.favoritesPlaylistSyncId;
    }
    final buffer = StringBuffer();
    for (var i = 0; i < 32; i++) {
      buffer.write('0123456789abcdef'[_random.nextInt(16)]);
    }
    return buffer.toString();
  }

  Future<void> _recordTombstone(
    DatabaseExecutor executor,
    String category,
    String key, {
    required int updatedAt,
    required String updatedBy,
  }) async {
    await executor.insert(
      'sync_tombstones',
      {
        'category': category,
        'key': key,
        'updatedAt': updatedAt,
        'updatedBy': updatedBy,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> _playlistSyncIdById(DatabaseExecutor executor, int id) async {
    final rows = await executor.query(
      'playlists',
      columns: ['syncId'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['syncId'] as String?;
  }

  /// 写入用同步戳（updatedAt 按当前时钟，updatedBy 为设备 id）。
  Map<String, Object?> _stamp() => {
        'updatedAt': _nowMs(),
        'updatedBy': _deviceId(),
      };

  void _notifyChanged(LibraryChange change) {
    if (!_changes.isClosed) _changes.add(change);
  }

  /// 写入/更新时间播放记录（唯一键 `(sourceKey, songId)`），并裁剪到上限。
  @override
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
    // 重新播放让条目复活：清除该曲目的历史删除墓碑。
    await _clearHistoryTombstone(db, entry.sourceKey, entry.songId);
    await _trimHistory(db);
    _notifyChanged(const LibraryChange.history());
  }

  /// 超出 [historyLimit] 时删除最旧记录。
  Future<void> _trimHistory(DatabaseExecutor db) async {
    await db.rawDelete(
      'DELETE FROM play_history WHERE rowid NOT IN ('
      'SELECT rowid FROM play_history ORDER BY playedAt DESC, rowid DESC LIMIT ?)',
      [historyLimit],
    );
  }

  /// 最近播放（playedAt 倒序）。
  @override
  Future<List<PlayHistoryEntry>> listHistory({int limit = historyLimit}) async {
    final db = await _db;
    final rows = await db.query(
      'play_history',
      orderBy: 'playedAt DESC, rowid DESC',
      limit: limit,
    );
    return [for (final row in rows) _historyFromRow(row)];
  }

  @override
  Future<void> deleteHistoryEntry(String sourceKey, String songId) async {
    final db = await _db;
    final removed = await db.delete(
      'play_history',
      where: 'sourceKey = ? AND songId = ?',
      whereArgs: [sourceKey, songId],
    );
    if (removed > 0) {
      await _recordTombstone(
        db,
        SyncCategory.history.name,
        SyncRecordKeys.history(sourceKey, songId),
        updatedAt: _nowMs(),
        updatedBy: _deviceId(),
      );
    }
    _notifyChanged(const LibraryChange.history());
  }

  /// 批量删除历史记录（事务；返回实际删除数，变更只广播一次）。
  @override
  Future<int> deleteHistoryEntries(List<TrackKey> keys) async {
    if (keys.isEmpty) return 0;
    final db = await _db;
    var removed = 0;
    await db.transaction((txn) async {
      final now = _nowMs();
      final deviceId = _deviceId();
      for (final key in keys) {
        final count = await txn.delete(
          'play_history',
          where: 'sourceKey = ? AND songId = ?',
          whereArgs: [key.sourceKey, key.songId],
        );
        removed += count;
        if (count > 0) {
          await _recordTombstone(
            txn,
            SyncCategory.history.name,
            SyncRecordKeys.history(key.sourceKey, key.songId),
            updatedAt: now,
            updatedBy: deviceId,
          );
        }
      }
    });
    if (removed > 0) _notifyChanged(const LibraryChange.history());
    return removed;
  }

  /// 换源：播放历史**原位替换**条目（保留 `playedAt` 与时间排序）。
  ///
  /// 旧键不存在返回 false；目标键行已存在时先删（历史唯一键语义），
  /// 保留旧行的 `playedAt`——换源不改变「何时听的」。
  @override
  Future<bool> replaceHistoryEntry(
    TrackKey oldKey,
    PlayHistoryEntry replacement,
  ) async {
    final db = await _db;
    var updated = 0;
    await db.transaction((txn) async {
      final sameKey = replacement.sourceKey == oldKey.sourceKey &&
          replacement.songId == oldKey.songId;
      if (!sameKey) {
        await txn.delete(
          'play_history',
          where: 'sourceKey = ? AND songId = ?',
          whereArgs: [replacement.sourceKey, replacement.songId],
        );
      }
      updated = await txn.update(
        'play_history',
        {
          'sourceKey': replacement.sourceKey,
          'songId': replacement.songId,
          'title': replacement.title,
          'artist': replacement.artist,
          'album': replacement.album,
          'coverUrl': replacement.coverUrl,
          'durationMs': replacement.durationMs,
          'raw': jsonEncode(replacement.raw),
        },
        where: 'sourceKey = ? AND songId = ?',
        whereArgs: [oldKey.sourceKey, oldKey.songId],
      );
    });
    if (updated > 0) _notifyChanged(const LibraryChange.history());
    return updated > 0;
  }

  /// 批量写入播放历史（唯一键 upsert + 裁剪上限；单次广播）。
  ///
  /// 供「加入列表 → 播放历史」使用：把曲目记为最近播放。
  @override
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
    for (final entry in entries) {
      await _clearHistoryTombstone(db, entry.sourceKey, entry.songId);
    }
    await _trimHistory(db);
    _notifyChanged(const LibraryChange.history());
    return entries.length;
  }

  @override
  Future<void> clearHistory() async {
    final db = await _db;
    await db.transaction((txn) async {
      final rows = await txn.query('play_history',
          columns: ['sourceKey', 'songId']);
      if (rows.isEmpty) return;
      await txn.delete('play_history');
      final now = _nowMs();
      final deviceId = _deviceId();
      for (final row in rows) {
        await _recordTombstone(
          txn,
          SyncCategory.history.name,
          SyncRecordKeys.history(
            row['sourceKey'] as String? ?? '',
            row['songId'] as String? ?? '',
          ),
          updatedAt: now,
          updatedBy: deviceId,
        );
      }
    });
    _notifyChanged(const LibraryChange.history());
  }

  Future<void> _clearHistoryTombstone(
    DatabaseExecutor executor,
    String sourceKey,
    String songId,
  ) async {
    await executor.delete(
      'sync_tombstones',
      where: 'category = ? AND key = ?',
      whereArgs: [
        SyncCategory.history.name,
        SyncRecordKeys.history(sourceKey, songId),
      ],
    );
  }

  @override
  Future<int> createPlaylist(String name) async {
    final db = await _db;
    final now = _nowMs();
    final id = await db.insert('playlists', {
      'name': name,
      'createdAt': now,
      'syncId': _newSyncId(name),
      'updatedAt': now,
      'updatedBy': _deviceId(),
    });
    _notifyChanged(const LibraryChange.playlists());
    return id;
  }

  @override
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

  @override
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
  @override
  Future<List<PlaylistInfo>> listPlaylists() async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT p.id, p.name, p.createdAt, COUNT(t.id) AS trackCount
      FROM playlists p
      LEFT JOIN playlist_tracks t ON t.playlistId = p.id
      GROUP BY p.id
      ORDER BY CASE WHEN p.name = ? THEN 0 ELSE 1 END, p.createdAt DESC, p.id DESC
    ''', [_favoritesPlaylistName]);
    return [for (final row in rows) _playlistFromRow(row)];
  }

  @override
  Future<void> renamePlaylist(int id, String name) async {
    final db = await _db;
    await db.update(
      'playlists',
      {'name': name, ..._stamp()},
      where: 'id = ?',
      whereArgs: [id],
    );
    _notifyChanged(const LibraryChange.playlists());
  }

  @override
  Future<void> deletePlaylist(int id) async {
    final db = await _db;
    final rows = await db.query(
      'playlists',
      columns: ['syncId'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final syncId = rows.isEmpty ? null : rows.first['syncId'] as String?;
    await db.transaction((txn) async {
      await txn.delete('playlist_tracks',
          where: 'playlistId = ?', whereArgs: [id]);
      await txn.delete('playlists', where: 'id = ?', whereArgs: [id]);
      if (syncId != null && syncId.isNotEmpty) {
        await _recordTombstone(
          txn,
          SyncCategory.playlists.name,
          syncId,
          updatedAt: _nowMs(),
          updatedBy: _deviceId(),
        );
      }
    });
    _notifyChanged(const LibraryChange.playlists());
  }

  /// 列表内曲目（sortOrder 升序，其次加入时间）。
  @override
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
  /// [LibraryFavoritesChange]，provider 只做局部刷新。
  @override
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
        ..._stamp(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    _notifyChanged(favoriteChange
        ? const LibraryChange.favorites()
        : LibraryChange.playlistTracks(playlistId));
    return true;
  }

  @override
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
      final syncId = await _playlistSyncIdById(db, playlistId);
      if (syncId != null && syncId.isNotEmpty) {
        await _recordTombstone(
          db,
          SyncCategory.playlistTracks.name,
          SyncRecordKeys.playlistTrack(syncId, sourceKey, songId),
          updatedAt: _nowMs(),
          updatedBy: _deviceId(),
        );
      }
      _notifyChanged(favoriteChange
          ? const LibraryChange.favorites()
          : LibraryChange.playlistTracks(playlistId));
    }
    return removed;
  }

  /// 批量移除列表曲目（事务；返回实际移除数，变更只广播一次）。
  ///
  /// [favoriteChange] 为 true 时（默认收藏批量操作）变更类型标记为
  /// [LibraryFavoritesChange]，provider 只做局部刷新。
  @override
  Future<int> removeTracksFromPlaylist(
    int playlistId,
    List<TrackKey> keys, {
    bool favoriteChange = false,
  }) async {
    if (keys.isEmpty) return 0;
    final db = await _db;
    var removed = 0;
    await db.transaction((txn) async {
      final syncId = await _playlistSyncIdById(txn, playlistId);
      final now = _nowMs();
      final deviceId = _deviceId();
      for (final key in keys) {
        final count = await txn.delete(
          'playlist_tracks',
          where: 'playlistId = ? AND sourceKey = ? AND songId = ?',
          whereArgs: [playlistId, key.sourceKey, key.songId],
        );
        removed += count;
        if (count > 0 && syncId != null && syncId.isNotEmpty) {
          await _recordTombstone(
            txn,
            SyncCategory.playlistTracks.name,
            SyncRecordKeys.playlistTrack(syncId, key.sourceKey, key.songId),
            updatedAt: now,
            updatedBy: deviceId,
          );
        }
      }
    });
    if (removed > 0) {
      _notifyChanged(favoriteChange
          ? const LibraryChange.favorites()
          : LibraryChange.playlistTracks(playlistId));
    }
    return removed;
  }

  /// 批量加入列表（跳过重复并追加到末尾；返回实际新增数）。
  ///
  /// [tracks] 来自任意合集（收藏/历史/其他列表）的复制：曲目级字段原样写入，
  /// `playlistId` 以本方法参数为准。[favoriteChange] 语义同
  /// [removeTracksFromPlaylist]。
  @override
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
    final stamp = _stamp();
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
          ...stamp,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      added++;
    }
    if (added > 0) {
      await batch.commit(noResult: true);
      _notifyChanged(favoriteChange
          ? const LibraryChange.favorites()
          : LibraryChange.playlistTracks(playlistId));
    }
    return added;
  }

  /// 按给定顺序重写 `sortOrder`（事务；仅更新仍存在于列表中的键）。
  @override
  Future<void> reorderPlaylistTracks(
    int playlistId,
    List<TrackKey> ordered,
  ) async {
    if (ordered.isEmpty) return;
    final db = await _db;
    final stamp = _stamp();
    await db.transaction((txn) async {
      for (var index = 0; index < ordered.length; index++) {
        final key = ordered[index];
        await txn.update(
          'playlist_tracks',
          {'sortOrder': index, ...stamp},
          where: 'playlistId = ? AND sourceKey = ? AND songId = ? '
              'AND sortOrder <> ?',
          whereArgs: [playlistId, key.sourceKey, key.songId, index],
        );
      }
    });
    _notifyChanged(LibraryChange.playlistTracks(playlistId));
  }

  /// 换源：列表内**原位替换**曲目（保留 `id/sortOrder/addedAt` 与列表位置）。
  ///
  /// 旧键不存在返回 false；目标键行已存在时先在事务内删除（去重），
  /// 再把旧行更新为新曲目数据（`playlistId` 以参数为准，忽略
  /// [replacement] 内的值）。[favoriteChange] 语义同
  /// [removeTracksFromPlaylist]：收藏列表内换源只做局部刷新。
  @override
  Future<bool> replacePlaylistTrack(
    int playlistId,
    TrackKey oldKey,
    PlaylistTrack replacement, {
    bool favoriteChange = false,
  }) async {
    final db = await _db;
    var updated = 0;
    await db.transaction((txn) async {
      final sameKey = replacement.sourceKey == oldKey.sourceKey &&
          replacement.songId == oldKey.songId;
      if (!sameKey) {
        await txn.delete(
          'playlist_tracks',
          where: 'playlistId = ? AND sourceKey = ? AND songId = ?',
          whereArgs: [playlistId, replacement.sourceKey, replacement.songId],
        );
      }
      updated = await txn.update(
        'playlist_tracks',
        {
          'sourceKey': replacement.sourceKey,
          'songId': replacement.songId,
          'title': replacement.title,
          'artist': replacement.artist,
          'album': replacement.album,
          'coverUrl': replacement.coverUrl,
          'durationMs': replacement.durationMs,
          'raw': jsonEncode(replacement.raw),
        },
        where: 'playlistId = ? AND sourceKey = ? AND songId = ?',
        whereArgs: [playlistId, oldKey.sourceKey, oldKey.songId],
      );
    });
    if (updated > 0) {
      _notifyChanged(favoriteChange
          ? const LibraryChange.favorites()
          : LibraryChange.playlistTracks(playlistId));
    }
    return updated > 0;
  }

  Future<int> _ensureFavoritesPlaylist() async {
    final existing = await findPlaylistByName(_favoritesPlaylistName);
    if (existing != null) return existing.id;
    return createPlaylist(_favoritesPlaylistName);
  }

  /// 收藏键集合（`sourceKey:songId`），供 provider 一次性缓存。
  @override
  Future<Set<String>> favoriteKeys() async {
    final db = await _db;
    final playlist = await findPlaylistByName(_favoritesPlaylistName);
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
  @override
  Future<int> addFavorites(List<PlaylistTrack> tracks) async {
    if (tracks.isEmpty) return 0;
    final playlistId = await _ensureFavoritesPlaylist();
    return addTracksToPlaylist(playlistId, tracks, favoriteChange: true);
  }

  /// 批量取消收藏（返回移除数；无收藏列表时为 0）。
  @override
  Future<int> removeFavorites(List<TrackKey> keys) async {
    if (keys.isEmpty) return 0;
    final playlist = await findPlaylistByName(_favoritesPlaylistName);
    if (playlist == null) return 0;
    return removeTracksFromPlaylist(playlist.id, keys, favoriteChange: true);
  }

  /// 导入 `.lxmc` 收藏夹：同名列表复用（重复导入幂等），逐曲 INSERT OR IGNORE。
  @override
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
    final stamp = {
      'updatedAt': _nowMs(),
      'updatedBy': _deviceId(),
    };
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
          ...stamp,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      imported++;
    }
    if (imported > 0) {
      await batch.commit(noResult: true);
    }

    _notifyChanged(const LibraryChange.import());
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

  // 跨设备同步（data/sync 适配器消费）
  //
  // 契约：导出只读本机视图并补齐缺失的 syncId；应用端逐行按
  // `(updatedAt, updatedBy)` 取新，写入沿用远端时间戳（幂等，不制造新的
  // 本地变更），删除经墓碑表表达；旧行（v5 前）在导出/应用前一次性补齐。

  /// 导出列表头（类型化记录；列名不出实现）。
  @override
  Future<List<PlaylistSyncRecord>> syncExportPlaylists() async {
    final db = await _db;
    await _ensurePlaylistSyncIds(db);
    final rows = await db.query(
      'playlists',
      columns: ['syncId', 'name', 'createdAt', 'updatedAt', 'updatedBy'],
    );
    return [
      for (final row in rows)
        PlaylistSyncRecord(
          syncId: row['syncId'] as String? ?? '',
          name: row['name'] as String? ?? '',
          createdAt: (row['createdAt'] as num?)?.toInt() ?? 0,
          updatedAt: (row['updatedAt'] as num?)?.toInt() ?? 0,
          updatedBy: row['updatedBy'] as String? ?? '',
        ),
    ];
  }

  /// 导出列表曲目（携带所属列表 syncId；自增 id 不出本机）。
  @override
  Future<List<PlaylistTrackSyncRecord>> syncExportPlaylistTracks() async {
    final db = await _db;
    await _ensurePlaylistSyncIds(db);
    final rows = await db.rawQuery('''
      SELECT p.syncId AS playlistSyncId, t.sourceKey, t.songId, t.title,
             t.artist, t.album, t.coverUrl, t.durationMs, t.raw, t.addedAt,
             t.sortOrder, t.updatedAt, t.updatedBy
      FROM playlist_tracks t
      JOIN playlists p ON p.id = t.playlistId
      WHERE p.syncId IS NOT NULL
    ''');
    return [
      for (final row in rows)
        PlaylistTrackSyncRecord(
          playlistSyncId: row['playlistSyncId'] as String? ?? '',
          sourceKey: row['sourceKey'] as String? ?? '',
          songId: row['songId'] as String? ?? '',
          title: row['title'] as String? ?? '',
          artist: row['artist'] as String? ?? '',
          album: row['album'] as String? ?? '',
          coverUrl: row['coverUrl'] as String?,
          durationMs: (row['durationMs'] as num?)?.toInt(),
          raw: row['raw'] as String? ?? '{}',
          addedAt: (row['addedAt'] as num?)?.toInt() ?? 0,
          sortOrder: (row['sortOrder'] as num?)?.toInt() ?? 0,
          updatedAt: (row['updatedAt'] as num?)?.toInt() ?? 0,
          updatedBy: row['updatedBy'] as String? ?? '',
        ),
    ];
  }

  /// 导出资料库墓碑（类别见 [SyncCategory]；非资料库类别在此忽略）。
  @override
  Future<List<SyncTombstoneRecord>> syncExportTombstones(
    Iterable<String> categories,
  ) async {
    final list = categories.toList();
    if (list.isEmpty) return const [];
    final db = await _db;
    final placeholders = List.filled(list.length, '?').join(', ');
    final rows = await db.query(
      'sync_tombstones',
      where: 'category IN ($placeholders)',
      whereArgs: list,
    );
    return [
      for (final row in rows)
        SyncTombstoneRecord(
          category: row['category'] as String? ?? '',
          key: row['key'] as String? ?? '',
          updatedAt: (row['updatedAt'] as num?)?.toInt() ?? 0,
          updatedBy: row['updatedBy'] as String? ?? '',
        ),
    ];
  }

  /// 导出播放历史（唯一键 `(sourceKey, songId)`；时间戳 = playedAt）。
  @override
  Future<List<PlayHistorySyncRecord>> syncExportHistory() async {
    final db = await _db;
    final rows = await db.query(
      'play_history',
      columns: [
        'sourceKey',
        'songId',
        'title',
        'artist',
        'album',
        'coverUrl',
        'durationMs',
        'raw',
        'playedAt',
      ],
      orderBy: 'playedAt ASC',
    );
    return [
      for (final row in rows)
        PlayHistorySyncRecord(
          sourceKey: row['sourceKey'] as String? ?? '',
          songId: row['songId'] as String? ?? '',
          title: row['title'] as String? ?? '',
          artist: row['artist'] as String? ?? '',
          album: row['album'] as String? ?? '',
          coverUrl: row['coverUrl'] as String?,
          durationMs: (row['durationMs'] as num?)?.toInt(),
          raw: row['raw'] as String? ?? '{}',
          playedAt: (row['playedAt'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  /// 应用远端播放历史：逐条按 playedAt 取新，删除经墓碑（同键复活时清墓碑）。
  ///
  /// 结束统一裁剪到 [historyLimit]；裁剪不产生墓碑（上限淘汰不是用户删除）。
  @override
  Future<({int applied, int skipped})> syncApplyHistory({
    List<PlayHistorySyncRecord> entries = const [],
    List<SyncTombstoneRecord> tombstones = const [],
  }) async {
    if (entries.isEmpty && tombstones.isEmpty) {
      return (applied: 0, skipped: 0);
    }
    final entryRows = [for (final entry in entries) entry.toJson()];
    final tombstoneRows = [for (final record in tombstones) record.toJson()];
    final db = await _db;
    var applied = 0;
    var skipped = 0;
    await db.transaction((txn) async {
      final category = SyncCategory.history.name;
      for (final row in tombstoneRows) {
        if ((row['category'] as String? ?? '') != category) {
          skipped++;
          continue;
        }
        final parsed = SyncRecordKeys.parseHistory(row['key'] as String? ?? '');
        final updatedAt = (row['updatedAt'] as num?)?.toInt();
        if (parsed == null || updatedAt == null) {
          skipped++;
          continue;
        }
        final updatedBy = row['updatedBy'] as String? ?? '';
        final existingTombstone = await txn.query(
          'sync_tombstones',
          columns: ['updatedAt', 'updatedBy'],
          where: 'category = ? AND key = ?',
          whereArgs: [category, row['key']],
          limit: 1,
        );
        if (existingTombstone.isEmpty ||
            _isNewer(updatedAt, updatedBy, _stampOf(existingTombstone.first))) {
          await _recordTombstone(
            txn,
            category,
            row['key'] as String,
            updatedAt: updatedAt,
            updatedBy: updatedBy,
          );
        }
        final local = await txn.query(
          'play_history',
          columns: ['playedAt'],
          where: 'sourceKey = ? AND songId = ?',
          whereArgs: [parsed.sourceKey, parsed.songId],
          limit: 1,
        );
        if (local.isNotEmpty &&
            _isNewer(
              updatedAt,
              updatedBy,
              (
                updatedAt: (local.first['playedAt'] as num?)?.toInt() ?? 0,
                updatedBy: '',
              ),
            )) {
          await txn.delete(
            'play_history',
            where: 'sourceKey = ? AND songId = ?',
            whereArgs: [parsed.sourceKey, parsed.songId],
          );
          applied++;
        } else {
          skipped++;
        }
      }

      for (final row in entryRows) {
        final sourceKey = row['sourceKey'] as String? ?? '';
        final songId = row['songId'] as String? ?? '';
        final playedAt = (row['playedAt'] as num?)?.toInt();
        if (sourceKey.isEmpty || songId.isEmpty || playedAt == null) {
          skipped++;
          continue;
        }
        final key = SyncRecordKeys.history(sourceKey, songId);
        final tombstone = await txn.query(
          'sync_tombstones',
          columns: ['updatedAt', 'updatedBy'],
          where: 'category = ? AND key = ?',
          whereArgs: [category, key],
          limit: 1,
        );
        if (tombstone.isNotEmpty) {
          final tombstoneAt =
              (tombstone.first['updatedAt'] as num?)?.toInt() ?? 0;
          if (playedAt <= tombstoneAt) {
            skipped++;
            continue;
          }
          // 晚于删除的播放记录复活该曲目。
          await txn.delete(
            'sync_tombstones',
            where: 'category = ? AND key = ?',
            whereArgs: [category, key],
          );
        }
        final local = await txn.query(
          'play_history',
          columns: ['playedAt'],
          where: 'sourceKey = ? AND songId = ?',
          whereArgs: [sourceKey, songId],
          limit: 1,
        );
        if (local.isEmpty ||
            playedAt > ((local.first['playedAt'] as num?)?.toInt() ?? 0)) {
          await txn.insert(
            'play_history',
            {
              'sourceKey': sourceKey,
              'songId': songId,
              'title': row['title'] as String? ?? '',
              'artist': row['artist'] as String? ?? '',
              'album': row['album'] as String? ?? '',
              'coverUrl': row['coverUrl'] as String?,
              'durationMs': (row['durationMs'] as num?)?.toInt(),
              'raw': row['raw'] as String? ?? '{}',
              'playedAt': playedAt,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          applied++;
        } else {
          skipped++;
        }
      }
      await _trimHistory(txn);
    });
    if (applied > 0) _notifyChanged(const LibraryChange.history());
    return (applied: applied, skipped: skipped);
  }

  /// 应用远端合并结果（列表 + 曲目 + 墓碑）。
  ///
  /// 单事务执行，成功落地后广播一次 [LibraryImportChange]（历史/列表/
  /// 收藏都可能变化，消费方全量失效最稳妥）。返回落地与跳过计数。
  @override
  Future<({int applied, int skipped})> syncApplyLibrary({
    List<PlaylistSyncRecord> playlists = const [],
    List<PlaylistTrackSyncRecord> tracks = const [],
    List<SyncTombstoneRecord> tombstones = const [],
  }) async {
    if (playlists.isEmpty && tracks.isEmpty && tombstones.isEmpty) {
      return (applied: 0, skipped: 0);
    }
    final playlistRows = [for (final record in playlists) record.toJson()];
    final trackRows = [for (final record in tracks) record.toJson()];
    final tombstoneRows = [for (final record in tombstones) record.toJson()];
    final db = await _db;
    var applied = 0;
    var skipped = 0;
    await db.transaction((txn) async {
      await _ensurePlaylistSyncIds(txn);

      // 1) 墓碑先行：删除本地旧行并保留墓碑供后续轮次继续传播。
      for (final row in tombstoneRows) {
        final category = row['category'] as String? ?? '';
        final key = row['key'] as String? ?? '';
        final updatedAt = (row['updatedAt'] as num?)?.toInt();
        if (key.isEmpty || updatedAt == null) {
          skipped++;
          continue;
        }
        final updatedBy = row['updatedBy'] as String? ?? '';
        final existing = await txn.query(
          'sync_tombstones',
          columns: ['updatedAt', 'updatedBy'],
          where: 'category = ? AND key = ?',
          whereArgs: [category, key],
          limit: 1,
        );
        if (existing.isEmpty ||
            _isNewer(updatedAt, updatedBy, _stampOf(existing.first))) {
          await txn.insert(
            'sync_tombstones',
            {
              'category': category,
              'key': key,
              'updatedAt': updatedAt,
              'updatedBy': updatedBy,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }

        if (category == SyncCategory.playlists.name) {
          final local = await _playlistRowBySyncId(txn, key);
          if (local != null &&
              _isNewer(
                updatedAt,
                updatedBy,
                (updatedAt: local.updatedAt, updatedBy: local.updatedBy),
              )) {
            await txn.delete('playlist_tracks',
                where: 'playlistId = ?', whereArgs: [local.id]);
            await txn.delete('playlists',
                where: 'id = ?', whereArgs: [local.id]);
            applied++;
          } else {
            skipped++;
          }
        } else if (category == SyncCategory.playlistTracks.name) {
          final parsed = SyncRecordKeys.parsePlaylistTrack(key);
          final playlist = parsed == null
              ? null
              : await _playlistRowBySyncId(txn, parsed.playlistSyncId);
          if (parsed == null || playlist == null) {
            skipped++;
          } else {
            final trackRow = await txn.query(
              'playlist_tracks',
              columns: ['updatedAt', 'updatedBy'],
              where: 'playlistId = ? AND sourceKey = ? AND songId = ?',
              whereArgs: [playlist.id, parsed.sourceKey, parsed.songId],
              limit: 1,
            );
            if (trackRow.isNotEmpty &&
                _isNewer(updatedAt, updatedBy, _stampOf(trackRow.first))) {
              await txn.delete(
                'playlist_tracks',
                where: 'playlistId = ? AND sourceKey = ? AND songId = ?',
                whereArgs: [playlist.id, parsed.sourceKey, parsed.songId],
              );
              applied++;
            } else {
              skipped++;
            }
          }
        } else {
          skipped++;
        }
      }

      // 2) 列表头（新列表按远端 syncId 落库；本地同名不受影响）。
      final localIds = <String, int>{};
      for (final row in playlistRows) {
        final syncId = row['syncId'] as String? ?? '';
        final name = row['name'] as String? ?? '';
        final updatedAt = (row['updatedAt'] as num?)?.toInt() ?? 0;
        final updatedBy = row['updatedBy'] as String? ?? '';
        final createdAt = (row['createdAt'] as num?)?.toInt() ?? updatedAt;
        if (syncId.isEmpty || name.isEmpty) {
          skipped++;
          continue;
        }
        final local = await _playlistRowBySyncId(txn, syncId);
        if (local == null) {
          final id = await txn.insert('playlists', {
            'name': name,
            'createdAt': createdAt,
            'syncId': syncId,
            'updatedAt': updatedAt,
            'updatedBy': updatedBy,
          });
          localIds[syncId] = id;
          applied++;
        } else {
          localIds[syncId] = local.id;
          if (_isNewer(
            updatedAt,
            updatedBy,
            (updatedAt: local.updatedAt, updatedBy: local.updatedBy),
          )) {
            await txn.update(
              'playlists',
              {
                'name': name,
                'updatedAt': updatedAt,
                'updatedBy': updatedBy,
              },
              where: 'id = ?',
              whereArgs: [local.id],
            );
            applied++;
          } else {
            skipped++;
          }
        }
      }

      // 3) 曲目（所属列表不存在则跳过；新行沿用远端时间戳）。
      for (final row in trackRows) {
        final playlistSyncId = row['playlistSyncId'] as String? ?? '';
        final sourceKey = row['sourceKey'] as String? ?? '';
        final songId = row['songId'] as String? ?? '';
        final updatedAt = (row['updatedAt'] as num?)?.toInt() ?? 0;
        final updatedBy = row['updatedBy'] as String? ?? '';
        if (playlistSyncId.isEmpty || sourceKey.isEmpty || songId.isEmpty) {
          skipped++;
          continue;
        }
        var localId = localIds[playlistSyncId];
        if (localId == null) {
          final playlist = await _playlistRowBySyncId(txn, playlistSyncId);
          if (playlist == null) {
            skipped++;
            continue;
          }
          localId = playlist.id;
        }
        final existing = await txn.query(
          'playlist_tracks',
          columns: ['updatedAt', 'updatedBy'],
          where: 'playlistId = ? AND sourceKey = ? AND songId = ?',
          whereArgs: [localId, sourceKey, songId],
          limit: 1,
        );
        if (existing.isEmpty) {
          await txn.insert('playlist_tracks', {
            'playlistId': localId,
            'sourceKey': sourceKey,
            'songId': songId,
            'title': row['title'] as String? ?? '',
            'artist': row['artist'] as String? ?? '',
            'album': row['album'] as String? ?? '',
            'coverUrl': row['coverUrl'] as String?,
            'durationMs': (row['durationMs'] as num?)?.toInt(),
            'raw': row['raw'] as String? ?? '{}',
            'addedAt': (row['addedAt'] as num?)?.toInt() ?? updatedAt,
            'sortOrder': (row['sortOrder'] as num?)?.toInt() ?? 0,
            'updatedAt': updatedAt,
            'updatedBy': updatedBy,
          });
          applied++;
        } else if (_isNewer(updatedAt, updatedBy, _stampOf(existing.first))) {
          await txn.update(
            'playlist_tracks',
            {
              'title': row['title'] as String? ?? '',
              'artist': row['artist'] as String? ?? '',
              'album': row['album'] as String? ?? '',
              'coverUrl': row['coverUrl'] as String?,
              'durationMs': (row['durationMs'] as num?)?.toInt(),
              'raw': row['raw'] as String? ?? '{}',
              'sortOrder': (row['sortOrder'] as num?)?.toInt() ?? 0,
              'updatedAt': updatedAt,
              'updatedBy': updatedBy,
            },
            where: 'playlistId = ? AND sourceKey = ? AND songId = ?',
            whereArgs: [localId, sourceKey, songId],
          );
          applied++;
        } else {
          skipped++;
        }
      }
    });
    if (applied > 0) _notifyChanged(const LibraryChange.import());
    return (applied: applied, skipped: skipped);
  }

  /// 补齐 v5 前旧行的 syncId（收藏固定值；其余随机生成，只补一次）。
  Future<void> _ensurePlaylistSyncIds(DatabaseExecutor executor) async {
    final rows = await executor.query(
      'playlists',
      columns: ['id', 'name', 'syncId'],
      where: "syncId IS NULL OR syncId = ''",
    );
    for (final row in rows) {
      await executor.update(
        'playlists',
        {'syncId': _newSyncId(row['name'] as String? ?? '')},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
  }

  Future<({int id, int updatedAt, String updatedBy})?> _playlistRowBySyncId(
    DatabaseExecutor executor,
    String syncId,
  ) async {
    final rows = await executor.query(
      'playlists',
      columns: ['id', 'updatedAt', 'updatedBy'],
      where: 'syncId = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (
      id: rows.first['id'] as int? ?? -1,
      updatedAt: (rows.first['updatedAt'] as num?)?.toInt() ?? 0,
      updatedBy: rows.first['updatedBy'] as String? ?? '',
    );
  }

  /// 远端戳是否严格新于本地戳（[updatedAt] 相同用设备 id 决平局）。
  static bool _isNewer(
    int updatedAt,
    String updatedBy,
    ({int updatedAt, String updatedBy}) local,
  ) {
    if (updatedAt != local.updatedAt) return updatedAt > local.updatedAt;
    return updatedBy.compareTo(local.updatedBy) > 0;
  }

  static ({int updatedAt, String updatedBy}) _stampOf(Map<String, Object?> row) =>
      (
        updatedAt: (row['updatedAt'] as num?)?.toInt() ?? 0,
        updatedBy: row['updatedBy'] as String? ?? '',
      );

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
        isFavorites: row['name'] == _favoritesPlaylistName,
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

  @override
  Future<void> dispose() async {
    await _changes.close();
  }
}
