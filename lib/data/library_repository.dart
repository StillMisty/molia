/// 本地资料库数据仓库：播放历史 / 用户列表 / 收藏 / `.lxmc` 导入。
///
/// 数据操作走 drift（简单读写用 DSL，JOIN / 聚合 / rowid 语句保留原 SQL
/// 文本），返回 [PlayHistoryEntry] / [PlaylistInfo] / [PlaylistTrack] 等领域
/// 模型；**不持久化播放直链**（只存元数据 + raw 取链参数），播放时由上层按
/// 需重新取链（对齐 LX Music 的设计）。
///
/// 所有写操作后通过 [changes] 广播变更，provider 据此失效内存缓存。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';

import '../domain/models/device_sync.dart';
import '../domain/models/library.dart';
import '../domain/ports/library_store.dart';
import '../domain/ports/library_sync_store.dart';
import 'lxmc_decoder.dart';
import 'molia_database.dart';
import 'sync/sync_stamp.dart';

/// 默认收藏列表的保留行名：实现内部细节（UI 显示走本地化文案，调用方
/// 判定收藏用 [PlaylistInfo.isFavorites]）。
const String _favoritesPlaylistName = '__favorites__';

class LibraryRepository implements LibraryStore, LibrarySyncStore {
  /// [databaseProvider] 仅测试注入（in-memory drift 库）；生产走
  /// [MoliaDatabase.instance]。
  ///
  /// [stamps] 是版本戳唯一发号器（必填：组合根注入同一实例；漏注入会各自
  /// 建号、可能发出重复版本）；[clock] 供内容时间（`createdAt` / `addedAt` /
  /// `playedAt` / 墓碑的真实删除时间）——两者刻意分开（内容时间分离，
  /// 见 ADR-0003 v2 §2）。
  LibraryRepository({
    MoliaDatabase Function()? databaseProvider,
    int Function()? clock,
    required SyncStampIssuer stamps,
  })  : _databaseProvider = databaseProvider ?? (() => MoliaDatabase.instance),
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _stamps = stamps;

  final MoliaDatabase Function() _databaseProvider;
  final int Function() _clock;
  final SyncStampIssuer _stamps;
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

  MoliaDatabase get _db => _databaseProvider();

  int _nowMs() => _clock();

  SyncVersion _nextVersion() => _stamps.next();

  /// 全库最大同步戳：供 `SyncStampIssuer` 首次初始化（基线 ≥ 全库最大戳）。
  Future<SyncVersion> maxVersion() async {
    final max = await _db.maxSyncVersion();
    return SyncVersion(physical: max.physical, counter: max.counter);
  }

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
    DatabaseConnectionUser executor,
    String category,
    String key, {
    required SyncVersion version,
    required int deletedAt,
  }) async {
    await executor.into(_db.syncTombstones).insert(
          SyncTombstonesCompanion.insert(
            category: category,
            key: key,
            versionPhysical: version.physical,
            versionCounter: Value(version.counter),
            deviceId: Value(version.deviceId),
            deletedAt: Value(deletedAt),
          ),
          mode: InsertMode.insertOrReplace,
        );
  }

  Future<String?> _playlistSyncIdById(
    DatabaseConnectionUser executor,
    int id,
  ) async {
    final row = await (executor.select(_db.playlists)
          ..where((t) => t.id.equals(id))
          ..limit(1))
        .getSingleOrNull();
    return row?.syncId;
  }

  void _notifyChanged(LibraryChange change) {
    if (!_changes.isClosed) _changes.add(change);
  }

  /// 写入/更新时间播放记录（唯一键 `(sourceKey, songId)`），并裁剪到上限。
  ///
  /// `playedAt` 是内容时间（上层给的聆听时刻）；版本戳由发号器现取。
  @override
  Future<void> addHistoryEntry(PlayHistoryEntry entry) async {
    final db = _db;
    final version = _nextVersion();
    await db.into(db.playHistory).insert(
          PlayHistoryCompanion.insert(
            sourceKey: entry.sourceKey,
            songId: entry.songId,
            title: entry.title,
            artist: Value(entry.artist),
            album: Value(entry.album),
            coverUrl: Value(entry.coverUrl),
            durationMs: Value(entry.durationMs),
            raw: Value(jsonEncode(entry.raw)),
            playedAt: entry.playedAt,
            versionPhysical: Value(version.physical),
            versionCounter: Value(version.counter),
            deviceId: Value(version.deviceId),
          ),
          mode: InsertMode.insertOrReplace,
        );
    // 重新播放让条目复活：清除该曲目的历史删除墓碑。
    await _clearHistoryTombstone(db, entry.sourceKey, entry.songId);
    await _trimHistory(db);
    _notifyChanged(const LibraryChange.history());
  }

  /// 超出 [historyLimit] 时删除最旧记录。
  ///
  /// 走 SQL：`play_history` 没有显式主键，只能按隐式 `rowid` 淘汰。
  Future<void> _trimHistory(DatabaseConnectionUser executor) async {
    await executor.customStatement(
      'DELETE FROM play_history WHERE rowid NOT IN ('
      'SELECT rowid FROM play_history ORDER BY playedAt DESC, rowid DESC LIMIT ?)',
      [historyLimit],
    );
  }

  /// 最近播放（playedAt 倒序）。
  @override
  Future<List<PlayHistoryEntry>> listHistory({int limit = historyLimit}) async {
    final db = _db;
    final rows = await (db.select(db.playHistory)
          ..orderBy([
            (t) => OrderingTerm.desc(t.playedAt),
            (t) => OrderingTerm.desc(const CustomExpression<int>('rowid')),
          ])
          ..limit(limit))
        .get();
    return [for (final row in rows) _historyFromRow(row)];
  }

  @override
  Future<void> deleteHistoryEntry(String sourceKey, String songId) async {
    final db = _db;
    final removed = await (db.delete(db.playHistory)
          ..where((t) =>
              t.sourceKey.equals(sourceKey) & t.songId.equals(songId)))
        .go();
    if (removed > 0) {
      await _recordTombstone(
        db,
        SyncCategory.history.name,
        SyncRecordKeys.history(sourceKey, songId),
        version: _nextVersion(),
        deletedAt: _nowMs(),
      );
    }
    _notifyChanged(const LibraryChange.history());
  }

  /// 批量删除历史记录（事务；返回实际删除数，变更只广播一次）。
  @override
  Future<int> deleteHistoryEntries(List<TrackKey> keys) async {
    if (keys.isEmpty) return 0;
    final db = _db;
    var removed = 0;
    await db.transaction(() async {
      for (final key in keys) {
        final count = await (db.delete(db.playHistory)
              ..where((t) =>
                  t.sourceKey.equals(key.sourceKey) &
                  t.songId.equals(key.songId)))
            .go();
        removed += count;
        if (count > 0) {
          await _recordTombstone(
            db,
            SyncCategory.history.name,
            SyncRecordKeys.history(key.sourceKey, key.songId),
            version: _nextVersion(),
            deletedAt: _nowMs(),
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
  /// 换源是一次本地修改：版本三列经发号器取新值，改动才能同步到对端。
  @override
  Future<bool> replaceHistoryEntry(
    TrackKey oldKey,
    PlayHistoryEntry replacement,
  ) async {
    final db = _db;
    final version = _nextVersion();
    var updated = 0;
    await db.transaction(() async {
      final sameKey = replacement.sourceKey == oldKey.sourceKey &&
          replacement.songId == oldKey.songId;
      if (!sameKey) {
        await (db.delete(db.playHistory)
              ..where((t) =>
                  t.sourceKey.equals(replacement.sourceKey) &
                  t.songId.equals(replacement.songId)))
            .go();
      }
      updated = await (db.update(db.playHistory)
            ..where((t) =>
                t.sourceKey.equals(oldKey.sourceKey) &
                t.songId.equals(oldKey.songId)))
          .write(PlayHistoryCompanion(
        sourceKey: Value(replacement.sourceKey),
        songId: Value(replacement.songId),
        title: Value(replacement.title),
        artist: Value(replacement.artist),
        album: Value(replacement.album),
        coverUrl: Value(replacement.coverUrl),
        durationMs: Value(replacement.durationMs),
        raw: Value(jsonEncode(replacement.raw)),
        versionPhysical: Value(version.physical),
        versionCounter: Value(version.counter),
        deviceId: Value(version.deviceId),
      ));
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
    final db = _db;
    final rows = <PlayHistoryCompanion>[];
    for (final entry in entries) {
      final version = _nextVersion();
      rows.add(PlayHistoryCompanion.insert(
        sourceKey: entry.sourceKey,
        songId: entry.songId,
        title: entry.title,
        artist: Value(entry.artist),
        album: Value(entry.album),
        coverUrl: Value(entry.coverUrl),
        durationMs: Value(entry.durationMs),
        raw: Value(jsonEncode(entry.raw)),
        playedAt: entry.playedAt,
        versionPhysical: Value(version.physical),
        versionCounter: Value(version.counter),
        deviceId: Value(version.deviceId),
      ));
    }
    await db.batch((batch) => batch.insertAll(
          db.playHistory,
          rows,
          mode: InsertMode.insertOrReplace,
        ));
    for (final entry in entries) {
      await _clearHistoryTombstone(db, entry.sourceKey, entry.songId);
    }
    await _trimHistory(db);
    _notifyChanged(const LibraryChange.history());
    return entries.length;
  }

  @override
  Future<void> clearHistory() async {
    final db = _db;
    await db.transaction(() async {
      final rows = await db.select(db.playHistory).get();
      if (rows.isEmpty) return;
      await db.delete(db.playHistory).go();
      for (final row in rows) {
        await _recordTombstone(
          db,
          SyncCategory.history.name,
          SyncRecordKeys.history(row.sourceKey, row.songId),
          version: _nextVersion(),
          deletedAt: _nowMs(),
        );
      }
    });
    _notifyChanged(const LibraryChange.history());
  }

  Future<void> _clearHistoryTombstone(
    DatabaseConnectionUser executor,
    String sourceKey,
    String songId,
  ) async {
    await (executor.delete(_db.syncTombstones)
          ..where((t) =>
              t.category.equals(SyncCategory.history.name) &
              t.key.equals(SyncRecordKeys.history(sourceKey, songId))))
        .go();
  }

  @override
  Future<int> createPlaylist(String name) async {
    final db = _db;
    final now = _nowMs();
    final version = _nextVersion();
    final id = await db.into(db.playlists).insert(
          PlaylistsCompanion.insert(
            name: name,
            createdAt: now,
            syncId: Value(_newSyncId(name)),
            versionPhysical: Value(version.physical),
            versionCounter: Value(version.counter),
            deviceId: Value(version.deviceId),
          ),
        );
    _notifyChanged(const LibraryChange.playlists());
    return id;
  }

  @override
  Future<PlaylistInfo?> findPlaylistByName(String name) async {
    final db = _db;
    final row = await (db.select(db.playlists)
          ..where((t) => t.name.equals(name))
          ..orderBy([(t) => OrderingTerm.asc(t.id)])
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : _playlistFromRow(row);
  }

  @override
  Future<PlaylistInfo?> playlistById(int id) async {
    final db = _db;
    final row = await (db.select(db.playlists)
          ..where((t) => t.id.equals(id))
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : _playlistFromRow(row);
  }

  /// 全部列表（默认收藏置顶，其余新列表在前），带曲目数。
  @override
  Future<List<PlaylistInfo>> listPlaylists() async {
    final db = _db;
    // 列表 + 曲目数 + 收藏置顶排序是一个整体口径，保留原 SQL 文本。
    final rows = await db.customSelect('''
      SELECT p.id, p.name, p.createdAt, COUNT(t.id) AS trackCount
      FROM playlists p
      LEFT JOIN playlist_tracks t ON t.playlistId = p.id
      GROUP BY p.id
      ORDER BY CASE WHEN p.name = ? THEN 0 ELSE 1 END, p.createdAt DESC, p.id DESC
    ''', variables: [Variable.withString(_favoritesPlaylistName)]).get();
    return [for (final row in rows) _playlistFromData(row.data)];
  }

  @override
  Future<void> renamePlaylist(int id, String name) async {
    final db = _db;
    final version = _nextVersion();
    await (db.update(db.playlists)..where((t) => t.id.equals(id)))
        .write(PlaylistsCompanion(
      name: Value(name),
      versionPhysical: Value(version.physical),
      versionCounter: Value(version.counter),
      deviceId: Value(version.deviceId),
    ));
    _notifyChanged(const LibraryChange.playlists());
  }

  @override
  Future<void> deletePlaylist(int id) async {
    final db = _db;
    final syncId = await _playlistSyncIdById(db, id);
    await db.transaction(() async {
      await (db.delete(db.playlistTracks)
            ..where((t) => t.playlistId.equals(id)))
          .go();
      await (db.delete(db.playlists)..where((t) => t.id.equals(id))).go();
      if (syncId != null && syncId.isNotEmpty) {
        await _recordTombstone(
          db,
          SyncCategory.playlists.name,
          syncId,
          version: _nextVersion(),
          deletedAt: _nowMs(),
        );
      }
    });
    _notifyChanged(const LibraryChange.playlists());
  }

  /// 列表内曲目（sortOrder 升序，其次加入时间）。
  @override
  Future<List<PlaylistTrack>> listPlaylistTracks(int playlistId) async {
    final db = _db;
    final rows = await (db.select(db.playlistTracks)
          ..where((t) => t.playlistId.equals(playlistId))
          ..orderBy([
            (t) => OrderingTerm.asc(t.sortOrder),
            (t) => OrderingTerm.asc(t.addedAt),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .get();
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
    final db = _db;
    final existing = await (db.select(db.playlistTracks)
          ..where((t) =>
              t.playlistId.equals(playlistId) &
              t.sourceKey.equals(track.sourceKey) &
              t.songId.equals(track.songId))
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) return false;

    final nextOrder = await _nextSortOrder(db, playlistId);

    final version = _nextVersion();
    await db.into(db.playlistTracks).insert(
          PlaylistTracksCompanion.insert(
            playlistId: playlistId,
            sourceKey: track.sourceKey,
            songId: track.songId,
            title: track.title,
            artist: Value(track.artist),
            album: Value(track.album),
            coverUrl: Value(track.coverUrl),
            durationMs: Value(track.durationMs),
            raw: Value(jsonEncode(track.raw)),
            addedAt: track.addedAt,
            sortOrder: Value(nextOrder),
            versionPhysical: Value(version.physical),
            versionCounter: Value(version.counter),
            deviceId: Value(version.deviceId),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    _notifyChanged(favoriteChange
        ? const LibraryChange.favorites()
        : LibraryChange.playlistTracks(playlistId));
    return true;
  }

  /// 列表内下一个排序位（空列表从 0 开始）。
  Future<int> _nextSortOrder(MoliaDatabase db, int playlistId) async {
    final maxSortOrder = db.playlistTracks.sortOrder.max();
    final row = await (db.selectOnly(db.playlistTracks)
          ..addColumns([maxSortOrder])
          ..where(db.playlistTracks.playlistId.equals(playlistId)))
        .getSingle();
    return (row.read(maxSortOrder) ?? -1) + 1;
  }

  @override
  Future<int> removeTrackFromPlaylist(
    int playlistId,
    String sourceKey,
    String songId, {
    bool favoriteChange = false,
  }) async {
    final db = _db;
    final removed = await (db.delete(db.playlistTracks)
          ..where((t) =>
              t.playlistId.equals(playlistId) &
              t.sourceKey.equals(sourceKey) &
              t.songId.equals(songId)))
        .go();
    if (removed > 0) {
      final syncId = await _playlistSyncIdById(db, playlistId);
      if (syncId != null && syncId.isNotEmpty) {
        await _recordTombstone(
          db,
          SyncCategory.playlistTracks.name,
          SyncRecordKeys.playlistTrack(syncId, sourceKey, songId),
          version: _nextVersion(),
          deletedAt: _nowMs(),
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
    final db = _db;
    var removed = 0;
    await db.transaction(() async {
      final syncId = await _playlistSyncIdById(db, playlistId);
      for (final key in keys) {
        final count = await (db.delete(db.playlistTracks)
              ..where((t) =>
                  t.playlistId.equals(playlistId) &
                  t.sourceKey.equals(key.sourceKey) &
                  t.songId.equals(key.songId)))
            .go();
        removed += count;
        if (count > 0 && syncId != null && syncId.isNotEmpty) {
          await _recordTombstone(
            db,
            SyncCategory.playlistTracks.name,
            SyncRecordKeys.playlistTrack(syncId, key.sourceKey, key.songId),
            version: _nextVersion(),
            deletedAt: _nowMs(),
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
    final db = _db;
    final knownRows = await (db.selectOnly(db.playlistTracks)
          ..addColumns([db.playlistTracks.sourceKey, db.playlistTracks.songId])
          ..where(db.playlistTracks.playlistId.equals(playlistId)))
        .get();
    final known = {
      for (final row in knownRows)
        '${row.read(db.playlistTracks.sourceKey)}:'
            '${row.read(db.playlistTracks.songId)}',
    };
    var nextOrder = await _nextSortOrder(db, playlistId);
    var added = 0;
    final rows = <PlaylistTracksCompanion>[];
    for (final track in tracks) {
      final key = '${track.sourceKey}:${track.songId}';
      if (!known.add(key)) continue;
      final version = _nextVersion();
      rows.add(PlaylistTracksCompanion.insert(
        playlistId: playlistId,
        sourceKey: track.sourceKey,
        songId: track.songId,
        title: track.title,
        artist: Value(track.artist),
        album: Value(track.album),
        coverUrl: Value(track.coverUrl),
        durationMs: Value(track.durationMs),
        raw: Value(jsonEncode(track.raw)),
        addedAt: track.addedAt,
        sortOrder: Value(nextOrder++),
        versionPhysical: Value(version.physical),
        versionCounter: Value(version.counter),
        deviceId: Value(version.deviceId),
      ));
      added++;
    }
    if (added > 0) {
      await db.batch((batch) => batch.insertAll(
            db.playlistTracks,
            rows,
            mode: InsertMode.insertOrIgnore,
          ));
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
    final db = _db;
    await db.transaction(() async {
      for (var index = 0; index < ordered.length; index++) {
        final key = ordered[index];
        final version = _nextVersion();
        await (db.update(db.playlistTracks)
              ..where((t) =>
                  t.playlistId.equals(playlistId) &
                  t.sourceKey.equals(key.sourceKey) &
                  t.songId.equals(key.songId) &
                  t.sortOrder.equals(index).not()))
            .write(PlaylistTracksCompanion(
          sortOrder: Value(index),
          versionPhysical: Value(version.physical),
          versionCounter: Value(version.counter),
          deviceId: Value(version.deviceId),
        ));
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
  /// 换源是一次本地修改：版本三列经发号器取新值，改动才能同步到对端。
  @override
  Future<bool> replacePlaylistTrack(
    int playlistId,
    TrackKey oldKey,
    PlaylistTrack replacement, {
    bool favoriteChange = false,
  }) async {
    final db = _db;
    final version = _nextVersion();
    var updated = 0;
    await db.transaction(() async {
      final sameKey = replacement.sourceKey == oldKey.sourceKey &&
          replacement.songId == oldKey.songId;
      if (!sameKey) {
        await (db.delete(db.playlistTracks)
              ..where((t) =>
                  t.playlistId.equals(playlistId) &
                  t.sourceKey.equals(replacement.sourceKey) &
                  t.songId.equals(replacement.songId)))
            .go();
      }
      updated = await (db.update(db.playlistTracks)
            ..where((t) =>
                t.playlistId.equals(playlistId) &
                t.sourceKey.equals(oldKey.sourceKey) &
                t.songId.equals(oldKey.songId)))
          .write(PlaylistTracksCompanion(
        sourceKey: Value(replacement.sourceKey),
        songId: Value(replacement.songId),
        title: Value(replacement.title),
        artist: Value(replacement.artist),
        album: Value(replacement.album),
        coverUrl: Value(replacement.coverUrl),
        durationMs: Value(replacement.durationMs),
        raw: Value(jsonEncode(replacement.raw)),
        versionPhysical: Value(version.physical),
        versionCounter: Value(version.counter),
        deviceId: Value(version.deviceId),
      ));
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
    final db = _db;
    final playlist = await findPlaylistByName(_favoritesPlaylistName);
    if (playlist == null) return {};
    final rows = await (db.selectOnly(db.playlistTracks)
          ..addColumns([db.playlistTracks.sourceKey, db.playlistTracks.songId])
          ..where(db.playlistTracks.playlistId.equals(playlist.id)))
        .get();
    return {
      for (final row in rows)
        '${row.read(db.playlistTracks.sourceKey)}:'
            '${row.read(db.playlistTracks.songId)}',
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

    final db = _db;
    final existingPlaylist = await findPlaylistByName(decoded.name);
    final playlistId =
        existingPlaylist?.id ?? await createPlaylist(decoded.name);

    final knownRows = await (db.selectOnly(db.playlistTracks)
          ..addColumns([db.playlistTracks.sourceKey, db.playlistTracks.songId])
          ..where(db.playlistTracks.playlistId.equals(playlistId)))
        .get();
    final knownKeys = {
      for (final row in knownRows)
        '${row.read(db.playlistTracks.sourceKey)}:'
            '${row.read(db.playlistTracks.songId)}',
    };

    var nextOrder = await _nextSortOrder(db, playlistId);

    final addedAt = DateTime.now().millisecondsSinceEpoch;
    var imported = 0;
    final rows = <PlaylistTracksCompanion>[];
    for (final track in decoded.tracks) {
      final key = '${track.sourceKey}:${track.songId}';
      if (knownKeys.contains(key)) continue;
      knownKeys.add(key);
      final version = _nextVersion();
      rows.add(PlaylistTracksCompanion.insert(
        playlistId: playlistId,
        sourceKey: track.sourceKey,
        songId: track.songId,
        title: track.title,
        artist: Value(track.artist),
        album: Value(track.album),
        coverUrl: Value(track.coverUrl),
        durationMs: Value(track.durationMs),
        raw: Value(jsonEncode(track.raw)),
        addedAt: addedAt,
        sortOrder: Value(nextOrder++),
        versionPhysical: Value(version.physical),
        versionCounter: Value(version.counter),
        deviceId: Value(version.deviceId),
      ));
      imported++;
    }
    if (imported > 0) {
      await db.batch((batch) => batch.insertAll(
            db.playlistTracks,
            rows,
            mode: InsertMode.insertOrIgnore,
          ));
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
  // 契约：导出只读本机视图并补齐缺失的 syncId；应用端逐行按版本三元组
  // `(versionPhysical, versionCounter, deviceId)` 取新，写入沿用远端版本
  // （幂等，不制造新的本地变更），删除经墓碑表表达；历史「删除 vs 播放」用
  // 真实时间（playedAt vs 墓碑 deletedAt）判定。旧行（v6 前）版本回默认 0，
  // 在导出/应用前一次性补齐 syncId。

  /// 导出列表头（类型化记录；列名不出实现）。
  @override
  Future<List<PlaylistSyncRecord>> syncExportPlaylists() async {
    final db = _db;
    await _ensurePlaylistSyncIds(db);
    final rows = await db.select(db.playlists).get();
    return [
      for (final row in rows)
        PlaylistSyncRecord(
          syncId: row.syncId ?? '',
          name: row.name,
          createdAt: row.createdAt,
          version: row.syncVersion,
        ),
    ];
  }

  /// 导出列表曲目（携带所属列表 syncId；自增 id 不出本机）。
  @override
  Future<List<PlaylistTrackSyncRecord>> syncExportPlaylistTracks() async {
    final db = _db;
    await _ensurePlaylistSyncIds(db);
    // 两表 JOIN 的投影口径保留原 SQL 文本。
    final rows = await db.customSelect('''
      SELECT p.syncId AS playlistSyncId, t.sourceKey, t.songId, t.title,
             t.artist, t.album, t.coverUrl, t.durationMs, t.raw, t.addedAt,
             t.sortOrder, t.versionPhysical, t.versionCounter, t.deviceId
      FROM playlist_tracks t
      JOIN playlists p ON p.id = t.playlistId
      WHERE p.syncId IS NOT NULL
    ''').get();
    return [
      for (final row in rows)
        PlaylistTrackSyncRecord(
          playlistSyncId: row.data['playlistSyncId'] as String? ?? '',
          sourceKey: row.data['sourceKey'] as String? ?? '',
          songId: row.data['songId'] as String? ?? '',
          title: row.data['title'] as String? ?? '',
          artist: row.data['artist'] as String? ?? '',
          album: row.data['album'] as String? ?? '',
          coverUrl: row.data['coverUrl'] as String?,
          durationMs: (row.data['durationMs'] as num?)?.toInt(),
          raw: row.data['raw'] as String? ?? '{}',
          addedAt: (row.data['addedAt'] as num?)?.toInt() ?? 0,
          sortOrder: (row.data['sortOrder'] as num?)?.toInt() ?? 0,
          version: SyncVersion(
            physical: (row.data['versionPhysical'] as num?)?.toInt() ?? 0,
            counter: (row.data['versionCounter'] as num?)?.toInt() ?? 0,
            deviceId: row.data['deviceId'] as String? ?? '',
          ),
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
    final db = _db;
    final rows = await (db.select(db.syncTombstones)
          ..where((t) => t.category.isIn(list)))
        .get();
    return [
      for (final row in rows)
        SyncTombstoneRecord(
          category: row.category,
          key: row.key,
          version: row.syncVersion,
          deletedAt: row.deletedAt,
        ),
    ];
  }

  /// 导出播放历史（唯一键 `(sourceKey, songId)`；`playedAt` 是内容时间）。
  @override
  Future<List<PlayHistorySyncRecord>> syncExportHistory() async {
    final db = _db;
    final rows = await (db.select(db.playHistory)
          ..orderBy([(t) => OrderingTerm.asc(t.playedAt)]))
        .get();
    return [
      for (final row in rows)
        PlayHistorySyncRecord(
          sourceKey: row.sourceKey,
          songId: row.songId,
          title: row.title,
          artist: row.artist,
          album: row.album,
          coverUrl: row.coverUrl,
          durationMs: row.durationMs,
          raw: row.raw,
          playedAt: row.playedAt,
          version: row.syncVersion,
        ),
    ];
  }

  /// 应用远端播放历史：版本三元组取新；删除 vs 播放按**真实时间**判定
  /// （本机 `playedAt <= 墓碑 deletedAt` → 删除生效；晚于删除的播放复活条目）。
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
    final db = _db;
    var applied = 0;
    var skipped = 0;
    await db.transaction(() async {
      final category = SyncCategory.history.name;

      for (final tombstone in tombstones) {
        final parsed = SyncRecordKeys.parseHistory(tombstone.key);
        if (tombstone.category != category || parsed == null) {
          skipped++;
          continue;
        }
        final existing = await _tombstoneRow(db, category, tombstone.key);
        final adopted =
            existing == null || tombstone.version.isNewerThan(existing.syncVersion);
        if (adopted) {
          await _recordTombstone(
            db,
            category,
            tombstone.key,
            version: tombstone.version,
            deletedAt: tombstone.deletedAt,
          );
        }
        // 删除 vs 播放按**实际生效**（被 LWW 采用）的墓碑时间判定：
        // 入站墓碑比库内旧时不采用，也就不能用它的删除时间删行。
        final effectiveDeletedAt =
            adopted ? tombstone.deletedAt : existing.deletedAt;
        final local = await _historyRow(db, parsed.sourceKey, parsed.songId);
        if (local != null && local.playedAt <= effectiveDeletedAt) {
          // 删除晚于本地最后播放（真实时间）：删除生效。
          await _deleteHistoryRow(db, parsed.sourceKey, parsed.songId);
          applied++;
        } else if (local != null) {
          // 播放晚于删除（真实时间）：条目复活；只有被采用的墓碑才撤下，
          // 比入站更新的本地墓碑原样保留。
          if (adopted) {
            await _clearHistoryTombstone(db, parsed.sourceKey, parsed.songId);
          }
          skipped++;
        } else {
          skipped++;
        }
      }

      for (final entry in entries) {
        final sourceKey = entry.sourceKey;
        final songId = entry.songId;
        if (sourceKey.isEmpty || songId.isEmpty) {
          skipped++;
          continue;
        }
        final key = SyncRecordKeys.history(sourceKey, songId);
        final tombstone = await _tombstoneRow(db, category, key);
        if (tombstone != null) {
          if (entry.playedAt <= tombstone.deletedAt) {
            skipped++;
            continue;
          }
          // 晚于删除的播放记录复活该曲目；只有本条播放确实比墓碑新时才撤下
          // 墓碑（导入旧备份不会顶掉更新的本地删除）。
          if (entry.version.isNewerThan(tombstone.syncVersion)) {
            await _clearHistoryTombstone(db, sourceKey, songId);
          }
        }
        final local = await _historyRow(db, sourceKey, songId);
        if (local == null || entry.version.isNewerThan(local.syncVersion)) {
          await db.into(db.playHistory).insert(
                PlayHistoryCompanion.insert(
                  sourceKey: sourceKey,
                  songId: songId,
                  title: entry.title,
                  artist: Value(entry.artist),
                  album: Value(entry.album),
                  coverUrl: Value(entry.coverUrl),
                  durationMs: Value(entry.durationMs),
                  raw: Value(entry.raw),
                  playedAt: entry.playedAt,
                  versionPhysical: Value(entry.version.physical),
                  versionCounter: Value(entry.version.counter),
                  deviceId: Value(entry.version.deviceId),
                ),
                mode: InsertMode.insertOrReplace,
              );
          applied++;
        } else {
          skipped++;
        }
      }
      await _trimHistory(db);
    });
    if (applied > 0) _notifyChanged(const LibraryChange.history());
    return (applied: applied, skipped: skipped);
  }

  /// 单条播放历史行（删除 vs 播放判定用）。
  Future<PlayHistoryData?> _historyRow(
    DatabaseConnectionUser executor,
    String sourceKey,
    String songId,
  ) =>
      (executor.select(_db.playHistory)
            ..where((t) => t.sourceKey.equals(sourceKey) & t.songId.equals(songId))
            ..limit(1))
          .getSingleOrNull();

  Future<void> _deleteHistoryRow(
    DatabaseConnectionUser executor,
    String sourceKey,
    String songId,
  ) =>
      (executor.delete(_db.playHistory)
            ..where((t) => t.sourceKey.equals(sourceKey) & t.songId.equals(songId)))
          .go();

  Future<SyncTombstone?> _tombstoneRow(
    DatabaseConnectionUser executor,
    String category,
    String key,
  ) =>
      (executor.select(_db.syncTombstones)
            ..where((t) => t.category.equals(category) & t.key.equals(key))
            ..limit(1))
          .getSingleOrNull();


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
    final db = _db;
    var applied = 0;
    var skipped = 0;
    await db.transaction(() async {
      await _ensurePlaylistSyncIds(db);

      // 1) 墓碑先行：删除本地旧行并保留墓碑供后续轮次继续传播。
      for (final tombstone in tombstones) {
        final category = tombstone.category;
        final key = tombstone.key;
        if (key.isEmpty) {
          skipped++;
          continue;
        }
        final existing = await _tombstoneRow(db, category, key);
        if (existing == null ||
            tombstone.version.isNewerThan(existing.syncVersion)) {
          await _recordTombstone(
            db,
            category,
            key,
            version: tombstone.version,
            deletedAt: tombstone.deletedAt,
          );
        }

        if (category == SyncCategory.playlists.name) {
          final local = await _playlistRowBySyncId(db, key);
          if (local != null && tombstone.version.isNewerThan(local.version)) {
            await (db.delete(db.playlistTracks)
                  ..where((t) => t.playlistId.equals(local.id)))
                .go();
            await (db.delete(db.playlists)
                  ..where((t) => t.id.equals(local.id)))
                .go();
            applied++;
          } else {
            skipped++;
          }
        } else if (category == SyncCategory.playlistTracks.name) {
          final parsed = SyncRecordKeys.parsePlaylistTrack(key);
          final playlist = parsed == null
              ? null
              : await _playlistRowBySyncId(db, parsed.playlistSyncId);
          if (parsed == null || playlist == null) {
            skipped++;
          } else {
            final trackRow = await (db.select(db.playlistTracks)
                  ..where((t) =>
                      t.playlistId.equals(playlist.id) &
                      t.sourceKey.equals(parsed.sourceKey) &
                      t.songId.equals(parsed.songId))
                  ..limit(1))
                .getSingleOrNull();
            if (trackRow != null &&
                tombstone.version.isNewerThan(trackRow.syncVersion)) {
              await (db.delete(db.playlistTracks)
                    ..where((t) =>
                        t.playlistId.equals(playlist.id) &
                        t.sourceKey.equals(parsed.sourceKey) &
                        t.songId.equals(parsed.songId)))
                  .go();
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
      for (final record in playlists) {
        final syncId = record.syncId;
        final name = record.name;
        if (syncId.isEmpty || name.isEmpty) {
          skipped++;
          continue;
        }
        final local = await _playlistRowBySyncId(db, syncId);
        if (local == null) {
          final id = await db.into(db.playlists).insert(
                PlaylistsCompanion.insert(
                  name: name,
                  createdAt: record.createdAt,
                  syncId: Value(syncId),
                  versionPhysical: Value(record.version.physical),
                  versionCounter: Value(record.version.counter),
                  deviceId: Value(record.version.deviceId),
                ),
              );
          localIds[syncId] = id;
          applied++;
        } else {
          localIds[syncId] = local.id;
          if (record.version.isNewerThan(local.version)) {
            await (db.update(db.playlists)
                  ..where((t) => t.id.equals(local.id)))
                .write(PlaylistsCompanion(
              name: Value(name),
              versionPhysical: Value(record.version.physical),
              versionCounter: Value(record.version.counter),
              deviceId: Value(record.version.deviceId),
            ));
            applied++;
          } else {
            skipped++;
          }
        }
      }

      // 3) 曲目（所属列表不存在则跳过；新行沿用远端版本）。
      for (final record in tracks) {
        final playlistSyncId = record.playlistSyncId;
        final sourceKey = record.sourceKey;
        final songId = record.songId;
        if (playlistSyncId.isEmpty || sourceKey.isEmpty || songId.isEmpty) {
          skipped++;
          continue;
        }
        var localId = localIds[playlistSyncId];
        if (localId == null) {
          final playlist = await _playlistRowBySyncId(db, playlistSyncId);
          if (playlist == null) {
            skipped++;
            continue;
          }
          localId = playlist.id;
        }
        final playlistId = localId;
        final existing = await (db.select(db.playlistTracks)
              ..where((t) =>
                  t.playlistId.equals(playlistId) &
                  t.sourceKey.equals(sourceKey) &
                  t.songId.equals(songId))
              ..limit(1))
            .getSingleOrNull();
        if (existing == null) {
          await db.into(db.playlistTracks).insert(
                PlaylistTracksCompanion.insert(
                  playlistId: playlistId,
                  sourceKey: sourceKey,
                  songId: songId,
                  title: record.title,
                  artist: Value(record.artist),
                  album: Value(record.album),
                  coverUrl: Value(record.coverUrl),
                  durationMs: Value(record.durationMs),
                  raw: Value(record.raw),
                  addedAt: record.addedAt,
                  sortOrder: Value(record.sortOrder),
                  versionPhysical: Value(record.version.physical),
                  versionCounter: Value(record.version.counter),
                  deviceId: Value(record.version.deviceId),
                ),
              );
          applied++;
        } else if (record.version.isNewerThan(existing.syncVersion)) {
          await (db.update(db.playlistTracks)
                ..where((t) =>
                    t.playlistId.equals(playlistId) &
                    t.sourceKey.equals(sourceKey) &
                    t.songId.equals(songId)))
              .write(PlaylistTracksCompanion(
            title: Value(record.title),
            artist: Value(record.artist),
            album: Value(record.album),
            coverUrl: Value(record.coverUrl),
            durationMs: Value(record.durationMs),
            raw: Value(record.raw),
            sortOrder: Value(record.sortOrder),
            versionPhysical: Value(record.version.physical),
            versionCounter: Value(record.version.counter),
            deviceId: Value(record.version.deviceId),
          ));
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
  Future<void> _ensurePlaylistSyncIds(DatabaseConnectionUser executor) async {
    final rows = await (executor.select(_db.playlists)
          ..where((t) => t.syncId.isNull() | t.syncId.equals('')))
        .get();
    for (final row in rows) {
      await (executor.update(_db.playlists)
            ..where((t) => t.id.equals(row.id)))
          .write(PlaylistsCompanion(syncId: Value(_newSyncId(row.name))));
    }
  }

  Future<({int id, SyncVersion version})?> _playlistRowBySyncId(
    DatabaseConnectionUser executor,
    String syncId,
  ) async {
    final row = await (executor.select(_db.playlists)
          ..where((t) => t.syncId.equals(syncId))
          ..limit(1))
        .getSingleOrNull();
    if (row == null) return null;
    return (id: row.id, version: row.syncVersion);
  }

  PlayHistoryEntry _historyFromRow(PlayHistoryData row) => PlayHistoryEntry(
        sourceKey: row.sourceKey,
        songId: row.songId,
        title: row.title,
        artist: row.artist,
        album: row.album,
        coverUrl: row.coverUrl,
        durationMs: row.durationMs,
        raw: _decodeRaw(row.raw),
        playedAt: row.playedAt,
      );

  PlaylistInfo _playlistFromRow(Playlist row) => PlaylistInfo(
        id: row.id,
        name: row.name,
        createdAt: row.createdAt,
        trackCount: 0,
        isFavorites: row.name == _favoritesPlaylistName,
      );

  PlaylistInfo _playlistFromData(Map<String, Object?> row) => PlaylistInfo(
        id: row['id'] as int? ?? -1,
        name: row['name'] as String? ?? '',
        createdAt: row['createdAt'] as int? ?? 0,
        trackCount: row['trackCount'] as int? ?? 0,
        isFavorites: row['name'] == _favoritesPlaylistName,
      );

  PlaylistTrack _trackFromRow(PlaylistTrackRow row) => PlaylistTrack(
        playlistId: row.playlistId,
        sourceKey: row.sourceKey,
        songId: row.songId,
        title: row.title,
        artist: row.artist,
        album: row.album,
        coverUrl: row.coverUrl,
        durationMs: row.durationMs,
        raw: _decodeRaw(row.raw),
        addedAt: row.addedAt,
        sortOrder: row.sortOrder,
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
