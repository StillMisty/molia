/// 资料库写入网关：本地变更五步仪式（发号 → 写行 → journal 记录 → 墓碑 →
/// 变更事件）的唯一实现。
///
/// 为什么独立成模块：资料库每条本地写路径都要走同一套仪式，散在各写方法里
/// 会漏步——已经出现过「补 syncId 不发号、靠指纹条款补偿」与「收藏切换绕开
/// 注入时钟」。仪式与「写行」收进这里的意图方法
/// （[addHistoryEntry] / [replacePlaylistTrack] / [deletePlaylist]…），
/// `LibraryRepository` 的公开写方法只做委托：漏步在结构上不再可能，
/// 新写路径 = 一个意图方法。
///
/// 边界：本类型是 data 层内部实现，只为 `LibraryRepository` 与测试所用；
/// 对外端口（`LibraryStore` / `LibrarySyncStore`）与变更事件形状不变。
/// 仓库的同步面（应用远端记录）**不走**五步仪式（不发号、不追 journal、
/// 版本由远端给），只复用 [recordTombstone] / [clearHistoryTombstone] /
/// [ensurePlaylistSyncIds] 三个原语，避免墓碑行形状与 syncId 补齐口径各写一份。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';

import '../domain/models/device_sync.dart';
import '../domain/models/library.dart';
import 'molia_database.dart';
import 'sync/sync_journal.dart';
import 'sync/sync_stamp.dart';

/// 默认收藏列表的保留行名：存储实现细节（UI 显示走本地化文案，调用方判定
/// 收藏用 `PlaylistInfo.isFavorites`）。
///
/// 读写两侧共用同一字面量：写入侧（本文件，syncId 固定值）在此定义，
/// 读取侧（`LibraryRepository`）导入使用。
const String favoritesPlaylistRowName = '__favorites__';

class LibraryWriteEngine {
  /// [databaseProvider] 与仓库共用同一库（测试注入 in-memory drift 库）；
  /// [stamps] 是版本戳唯一发号器（本地写入每步取一个号）；[clock] 供内容
  /// 时间（`createdAt` / `addedAt` / `playedAt` / 墓碑的真实删除时间）——
  /// 两者刻意分开（内容时间分离，见 ADR-0003 v2 §2）。
  ///
  /// [journal] 是增量日志（可选）：本地写入在**同一个 drift 事务**里追加
  /// 日志条目，对端按游标只拉变更。
  ///
  /// [addToTop] 是「加入列表」的位置偏好（设置页，默认放开头）：true 时新曲目
  /// 排到列表开头。缺省 = 追加到末尾——测试与未接线场景保持旧口径，生产由
  /// 组合根注入 `LibraryAddSettings.addToTop`。
  LibraryWriteEngine({
    required MoliaDatabase Function() databaseProvider,
    required SyncStampIssuer stamps,
    int Function()? clock,
    SyncJournalRepository? journal,
    bool Function()? addToTop,
    Future<void> Function()? beforeWrite,
  })  : _databaseProvider = databaseProvider,
        _stamps = stamps,
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _journal = journal,
        _addToTop = addToTop,
        _beforeWrite = beforeWrite;

  final MoliaDatabase Function() _databaseProvider;
  final SyncStampIssuer _stamps;
  final int Function() _clock;
  final SyncJournalRepository? _journal;
  final bool Function()? _addToTop;

  /// 写入前的就绪门（发号器基线种子）：首帧后 DB 最大戳查询完成前，
  /// 本机写入不得取号。null = 不需要等待（测试 / 旧调用点）。
  final Future<void> Function()? _beforeWrite;

  Future<void> _ensureReady() async {
    final beforeWrite = _beforeWrite;
    if (beforeWrite != null) await beforeWrite();
  }

  final Random _random = Random.secure();
  final StreamController<LibraryChange> _changes =
      StreamController<LibraryChange>.broadcast();

  MoliaDatabase get _db => _databaseProvider();

  int _nowMs() => _clock();

  SyncVersion _nextVersion() => _stamps.next();

  // ── 变更事件（五步的最后一步）────────────────────────────

  /// 资料库变更广播（事件类型即失效范围，见 [LibraryChange]）。
  Stream<LibraryChange> get changes => _changes.stream;

  /// 广播一次变更；写入调用栈内同步派发。同步面应用远端记录后也经这里通知。
  void notifyChanged(LibraryChange change) {
    if (!_changes.isClosed) _changes.add(change);
  }

  /// 释放资源（关闭变更广播）。
  Future<void> dispose() => _changes.close();

  // ── 播放历史 ─────────────────────────────────────────────

  /// 写入/更新时间播放记录（唯一键 `(sourceKey, songId)`），并裁剪到上限。
  ///
  /// `playedAt` 是内容时间（上层给的聆听时刻）；版本戳由发号器现取。
  Future<void> addHistoryEntry(PlayHistoryEntry entry) async {
    await _ensureReady();
    final db = _db;
    final version = _nextVersion();
    final raw = jsonEncode(entry.raw);
    await db.transaction(() async {
      await db.into(db.playHistory).insert(
            PlayHistoryCompanion.insert(
              sourceKey: entry.sourceKey,
              songId: entry.songId,
              title: entry.title,
              artist: Value(entry.artist),
              album: Value(entry.album),
              coverUrl: Value(entry.coverUrl),
              durationMs: Value(entry.durationMs),
              raw: Value(raw),
              playedAt: entry.playedAt,
              versionPhysical: Value(version.physical),
              versionCounter: Value(version.counter),
              deviceId: Value(version.deviceId),
            ),
            mode: InsertMode.insertOrReplace,
          );
      // 重新播放让条目复活：清除该曲目的历史删除墓碑。
      await _clearHistoryTombstone(db, entry.sourceKey, entry.songId);
      await _appendJournal(
        db,
        SyncCategory.history.name,
        _historySyncRecord(
          sourceKey: entry.sourceKey,
          songId: entry.songId,
          title: entry.title,
          artist: entry.artist,
          album: entry.album,
          coverUrl: entry.coverUrl,
          durationMs: entry.durationMs,
          raw: raw,
          playedAt: entry.playedAt,
          version: version,
        ),
      );
      await trimHistory(db);
    });
    notifyChanged(const LibraryChange.history());
  }

  /// 批量写入播放历史（唯一键 upsert + 裁剪上限；单次广播）。
  ///
  /// 供「加入列表 → 播放历史」使用：把曲目记为最近播放。
  Future<int> addHistoryEntries(List<PlayHistoryEntry> entries) async {
    if (entries.isEmpty) return 0;
    await _ensureReady();
    final db = _db;
    final rows = <PlayHistoryCompanion>[];
    final journalChanges = <SyncJournalChange>[];
    for (final entry in entries) {
      final version = _nextVersion();
      final raw = jsonEncode(entry.raw);
      rows.add(PlayHistoryCompanion.insert(
        sourceKey: entry.sourceKey,
        songId: entry.songId,
        title: entry.title,
        artist: Value(entry.artist),
        album: Value(entry.album),
        coverUrl: Value(entry.coverUrl),
        durationMs: Value(entry.durationMs),
        raw: Value(raw),
        playedAt: entry.playedAt,
        versionPhysical: Value(version.physical),
        versionCounter: Value(version.counter),
        deviceId: Value(version.deviceId),
      ));
      journalChanges.add((
        category: SyncCategory.history,
        record: _historySyncRecord(
          sourceKey: entry.sourceKey,
          songId: entry.songId,
          title: entry.title,
          artist: entry.artist,
          album: entry.album,
          coverUrl: entry.coverUrl,
          durationMs: entry.durationMs,
          raw: raw,
          playedAt: entry.playedAt,
          version: version,
        ),
      ));
    }
    await db.transaction(() async {
      await db.batch((batch) => batch.insertAll(
            db.playHistory,
            rows,
            mode: InsertMode.insertOrReplace,
          ));
      for (final entry in entries) {
        await _clearHistoryTombstone(db, entry.sourceKey, entry.songId);
      }
      if (_journal != null) await _journal.append(db, journalChanges);
      await trimHistory(db);
    });
    notifyChanged(const LibraryChange.history());
    return entries.length;
  }

  Future<void> deleteHistoryEntry(String sourceKey, String songId) async {
    await _ensureReady();
    final db = _db;
    await db.transaction(() async {
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
    });
    notifyChanged(const LibraryChange.history());
  }

  /// 批量删除历史记录（事务；返回实际删除数，变更只广播一次）。
  Future<int> deleteHistoryEntries(List<TrackKey> keys) async {
    if (keys.isEmpty) return 0;
    await _ensureReady();
    final db = _db;
    var removed = 0;
    await db.transaction(() async {
      final tombstones = <({String key, SyncVersion version})>[];
      for (final key in keys) {
        final count = await (db.delete(db.playHistory)
              ..where((t) =>
                  t.sourceKey.equals(key.sourceKey) &
                  t.songId.equals(key.songId)))
            .go();
        removed += count;
        if (count > 0) {
          tombstones.add((
            key: SyncRecordKeys.history(key.sourceKey, key.songId),
            version: _nextVersion(),
          ));
        }
      }
      await _recordTombstones(
        db,
        SyncCategory.history.name,
        tombstones,
        deletedAt: _nowMs(),
      );
    });
    if (removed > 0) notifyChanged(const LibraryChange.history());
    return removed;
  }

  /// 换源：播放历史**原位替换**条目（保留 `playedAt` 与时间排序）。
  ///
  /// 旧键不存在返回 false；目标键行已存在时先删（历史唯一键语义），
  /// 保留旧行的 `playedAt`——换源不改变「何时听的」。
  /// 换源是一次本地修改：版本三列经发号器取新值，改动才能同步到对端。
  Future<bool> replaceHistoryEntry(
    TrackKey oldKey,
    PlayHistoryEntry replacement,
  ) async {
    await _ensureReady();
    final db = _db;
    final version = _nextVersion();
    final raw = jsonEncode(replacement.raw);
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
        raw: Value(raw),
        versionPhysical: Value(version.physical),
        versionCounter: Value(version.counter),
        deviceId: Value(version.deviceId),
      ));
      if (updated > 0) {
        await _appendJournal(
          db,
          SyncCategory.history.name,
          _historySyncRecord(
            sourceKey: replacement.sourceKey,
            songId: replacement.songId,
            title: replacement.title,
            artist: replacement.artist,
            album: replacement.album,
            coverUrl: replacement.coverUrl,
            durationMs: replacement.durationMs,
            raw: raw,
            playedAt: replacement.playedAt,
            version: version,
          ),
        );
      }
    });
    if (updated > 0) notifyChanged(const LibraryChange.history());
    return updated > 0;
  }

  Future<void> clearHistory() async {
    await _ensureReady();
    final db = _db;
    await db.transaction(() async {
      final rows = await db.select(db.playHistory).get();
      if (rows.isEmpty) return;
      await db.delete(db.playHistory).go();
      final deletedAt = _nowMs();
      await _recordTombstones(
        db,
        SyncCategory.history.name,
        [
          for (final row in rows)
            (
              key: SyncRecordKeys.history(row.sourceKey, row.songId),
              version: _nextVersion(),
            ),
        ],
        deletedAt: deletedAt,
      );
    });
    notifyChanged(const LibraryChange.history());
  }

  // ── 列表集合 ─────────────────────────────────────────────

  Future<int> createPlaylist(String name) async {
    await _ensureReady();
    final db = _db;
    final now = _nowMs();
    final version = _nextVersion();
    final syncId = _newSyncId(name);
    late final int id;
    await db.transaction(() async {
      id = await db.into(db.playlists).insert(
            PlaylistsCompanion.insert(
              name: name,
              createdAt: now,
              syncId: Value(syncId),
              versionPhysical: Value(version.physical),
              versionCounter: Value(version.counter),
              deviceId: Value(version.deviceId),
            ),
          );
      await _appendJournal(
        db,
        SyncCategory.playlists.name,
        _playlistSyncRecord(
          syncId: syncId,
          name: name,
          createdAt: now,
          version: version,
        ),
      );
    });
    notifyChanged(const LibraryChange.playlists());
    return id;
  }

  Future<void> renamePlaylist(int id, String name) async {
    await _ensureReady();
    final db = _db;
    await db.transaction(() async {
      // 版本在补 syncId **之后**取：补 syncId 本身会为同一个键写一条日志，
      // 若重命名用更早的版本号，对端按 LWW 会一直保留旧名（同键两条日志
      // 必须版本递增）。
      final syncId = await _ensurePlaylistSyncId(db, id);
      final version = _nextVersion();
      final updated = await (db.update(db.playlists)..where((t) => t.id.equals(id)))
          .write(PlaylistsCompanion(
        name: Value(name),
        versionPhysical: Value(version.physical),
        versionCounter: Value(version.counter),
        deviceId: Value(version.deviceId),
      ));
      if (updated > 0 && syncId.isNotEmpty) {
        final row = await (db.select(db.playlists)
              ..where((t) => t.id.equals(id))
              ..limit(1))
            .getSingle();
        await _appendJournal(
          db,
          SyncCategory.playlists.name,
          _playlistSyncRecord(
            syncId: syncId,
            name: row.name,
            createdAt: row.createdAt,
            version: version,
          ),
        );
      }
    });
    notifyChanged(const LibraryChange.playlists());
  }

  Future<void> deletePlaylist(int id) async {
    await _ensureReady();
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
    notifyChanged(const LibraryChange.playlists());
  }

  // ── 列表曲目 ─────────────────────────────────────────────

  /// 加入列表（`(playlistId, sourceKey, songId)` 唯一，重复加入返回 false）。
  ///
  /// [favoriteChange] 为 true 时（收藏切换内部调用）变更类型标记为
  /// [LibraryFavoritesChange]，provider 只做局部刷新。
  ///
  /// [addToTop] 覆盖位置偏好（null = 用注入偏好）；表内导入等固定追加的
  /// 路径显式传 false。
  Future<bool> addTrackToPlaylist(
    int playlistId,
    PlaylistTrack track, {
    bool favoriteChange = false,
    bool? addToTop,
  }) async {
    await _ensureReady();
    final db = _db;
    final existing = await (db.select(db.playlistTracks)
          ..where((t) =>
              t.playlistId.equals(playlistId) &
              t.sourceKey.equals(track.sourceKey) &
              t.songId.equals(track.songId))
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) return false;

    final nextOrder = await _insertionStart(
      db,
      playlistId,
      count: 1,
      addToTop: addToTop ?? _insertAtTop,
    );

    final version = _nextVersion();
    var inserted = 0;
    await db.transaction(() async {
      inserted = await db.into(db.playlistTracks).insert(
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
      if (inserted > 0) {
        final syncId = await _ensurePlaylistSyncId(db, playlistId);
        if (syncId.isNotEmpty) {
          final row = await (db.select(db.playlistTracks)
                ..where((t) =>
                    t.playlistId.equals(playlistId) &
                    t.sourceKey.equals(track.sourceKey) &
                    t.songId.equals(track.songId))
                ..limit(1))
              .getSingle();
          await _appendJournal(
            db,
            SyncCategory.playlistTracks.name,
            _trackSyncRecord(playlistSyncId: syncId, row: row),
          );
        }
      }
    });
    if (inserted == 0) return false;
    notifyChanged(favoriteChange
        ? const LibraryChange.favorites()
        : LibraryChange.playlistTracks(playlistId));
    return true;
  }

  /// 批量加入列表（跳过重复并按位置偏好插入；返回实际新增数）。
  ///
  /// [tracks] 来自任意合集（收藏/历史/其他列表）的复制：曲目级字段原样写入，
  /// `playlistId` 以本方法参数为准，批内顺序保持传入顺序。[favoriteChange]
  /// 语义同 [removeTracksFromPlaylist]；[addToTop] 语义同 [addTrackToPlaylist]。
  Future<int> addTracksToPlaylist(
    int playlistId,
    List<PlaylistTrack> tracks, {
    bool favoriteChange = false,
    bool? addToTop,
  }) async {
    if (tracks.isEmpty) return 0;
    await _ensureReady();
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
    // 先去重再定排序位：顶部插入要按实际新增数取连续序号。
    final fresh = <PlaylistTrack>[];
    for (final track in tracks) {
      if (known.add('${track.sourceKey}:${track.songId}')) fresh.add(track);
    }
    if (fresh.isEmpty) return 0;
    var nextOrder = await _insertionStart(
      db,
      playlistId,
      count: fresh.length,
      addToTop: addToTop ?? _insertAtTop,
    );
    var added = 0;
    final rows = <PlaylistTracksCompanion>[];
    final pending = <({PlaylistTrack track, SyncVersion version, int sortOrder})>[];
    for (final track in fresh) {
      final version = _nextVersion();
      final order = nextOrder++;
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
        sortOrder: Value(order),
        versionPhysical: Value(version.physical),
        versionCounter: Value(version.counter),
        deviceId: Value(version.deviceId),
      ));
      pending.add((track: track, version: version, sortOrder: order));
      added++;
    }
    if (added > 0) {
      await db.transaction(() async {
        await db.batch((batch) => batch.insertAll(
              db.playlistTracks,
              rows,
              mode: InsertMode.insertOrIgnore,
            ));
        final syncId = await _ensurePlaylistSyncId(db, playlistId);
        if (syncId.isNotEmpty && _journal != null) {
          await _journal.append(db, [
            for (final item in pending)
              (
                category: SyncCategory.playlistTracks,
                record: _trackRecord(
                  playlistSyncId: syncId,
                  sourceKey: item.track.sourceKey,
                  songId: item.track.songId,
                  title: item.track.title,
                  artist: item.track.artist,
                  album: item.track.album,
                  coverUrl: item.track.coverUrl,
                  durationMs: item.track.durationMs,
                  raw: jsonEncode(item.track.raw),
                  addedAt: item.track.addedAt,
                  sortOrder: item.sortOrder,
                  version: item.version,
                ),
              ),
          ]);
        }
      });
      notifyChanged(favoriteChange
          ? const LibraryChange.favorites()
          : LibraryChange.playlistTracks(playlistId));
    }
    return added;
  }

  Future<int> removeTrackFromPlaylist(
    int playlistId,
    String sourceKey,
    String songId, {
    bool favoriteChange = false,
  }) async {
    await _ensureReady();
    final db = _db;
    var removed = 0;
    await db.transaction(() async {
      removed = await (db.delete(db.playlistTracks)
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
      }
    });
    if (removed > 0) {
      notifyChanged(favoriteChange
          ? const LibraryChange.favorites()
          : LibraryChange.playlistTracks(playlistId));
    }
    return removed;
  }

  /// 批量移除列表曲目（事务；返回实际移除数，变更只广播一次）。
  ///
  /// [favoriteChange] 为 true 时（默认收藏批量操作）变更类型标记为
  /// [LibraryFavoritesChange]，provider 只做局部刷新。
  Future<int> removeTracksFromPlaylist(
    int playlistId,
    List<TrackKey> keys, {
    bool favoriteChange = false,
  }) async {
    if (keys.isEmpty) return 0;
    await _ensureReady();
    final db = _db;
    var removed = 0;
    await db.transaction(() async {
      final syncId = await _playlistSyncIdById(db, playlistId);
      final tombstones = <({String key, SyncVersion version})>[];
      for (final key in keys) {
        final count = await (db.delete(db.playlistTracks)
              ..where((t) =>
                  t.playlistId.equals(playlistId) &
                  t.sourceKey.equals(key.sourceKey) &
                  t.songId.equals(key.songId)))
            .go();
        removed += count;
        if (count > 0 && syncId != null && syncId.isNotEmpty) {
          tombstones.add((
            key: SyncRecordKeys.playlistTrack(syncId, key.sourceKey, key.songId),
            version: _nextVersion(),
          ));
        }
      }
      await _recordTombstones(
        db,
        SyncCategory.playlistTracks.name,
        tombstones,
        deletedAt: _nowMs(),
      );
    });
    if (removed > 0) {
      notifyChanged(favoriteChange
          ? const LibraryChange.favorites()
          : LibraryChange.playlistTracks(playlistId));
    }
    return removed;
  }

  /// 按给定顺序重写 `sortOrder`（事务；仅更新仍存在于列表中的键）。
  ///
  /// 先整列表读一次、用 batch 提交 UPDATE：重排只改 `sortOrder` 与版本三列，
  /// 读到的行 + 新值即可构造增量日志记录，无需逐行「UPDATE + SELECT 回读」
  /// （1000 首拖动一次 = 2000+ 语句）。
  Future<void> reorderPlaylistTracks(
    int playlistId,
    List<TrackKey> ordered,
  ) async {
    if (ordered.isEmpty) return;
    await _ensureReady();
    final db = _db;
    await db.transaction(() async {
      final syncId = await _ensurePlaylistSyncId(db, playlistId);
      final rows = await (db.select(db.playlistTracks)
            ..where((t) => t.playlistId.equals(playlistId)))
          .get();
      final byKey = {
        for (final row in rows) '${row.sourceKey}\u0001${row.songId}': row,
      };
      final changes = <SyncJournalChange>[];
      final updates = <({TrackKey key, int index, SyncVersion version})>[];
      for (var index = 0; index < ordered.length; index++) {
        final key = ordered[index];
        final row = byKey['${key.sourceKey}\u0001${key.songId}'];
        if (row == null || row.sortOrder == index) continue;
        final version = _nextVersion();
        updates.add((key: key, index: index, version: version));
        if (syncId.isNotEmpty) {
          changes.add((
            category: SyncCategory.playlistTracks,
            record: _trackRecord(
              playlistSyncId: syncId,
              sourceKey: row.sourceKey,
              songId: row.songId,
              title: row.title,
              artist: row.artist,
              album: row.album,
              coverUrl: row.coverUrl,
              durationMs: row.durationMs,
              raw: row.raw,
              addedAt: row.addedAt,
              sortOrder: index,
              version: version,
            ),
          ));
        }
      }
      if (updates.isNotEmpty) {
        await db.batch((batch) {
          for (final update in updates) {
            batch.update(
              db.playlistTracks,
              PlaylistTracksCompanion(
                sortOrder: Value(update.index),
                versionPhysical: Value(update.version.physical),
                versionCounter: Value(update.version.counter),
                deviceId: Value(update.version.deviceId),
              ),
              where: (t) =>
                  t.playlistId.equals(playlistId) &
                  t.sourceKey.equals(update.key.sourceKey) &
                  t.songId.equals(update.key.songId),
            );
          }
        });
      }
      if (changes.isNotEmpty && _journal != null) {
        await _journal.append(db, changes);
      }
    });
    notifyChanged(LibraryChange.playlistTracks(playlistId));
  }

  /// 换源：列表内**原位替换**曲目（保留 `id/sortOrder/addedAt` 与列表位置）。
  ///
  /// 旧键不存在返回 false；目标键行已存在时先在事务内删除（去重），
  /// 再把旧行更新为新曲目数据（`playlistId` 以参数为准，忽略
  /// [replacement] 内的值）。[favoriteChange] 语义同
  /// [removeTracksFromPlaylist]：收藏列表内换源只做局部刷新。
  /// 换源是一次本地修改：版本三列经发号器取新值，改动才能同步到对端。
  Future<bool> replacePlaylistTrack(
    int playlistId,
    TrackKey oldKey,
    PlaylistTrack replacement, {
    bool favoriteChange = false,
  }) async {
    await _ensureReady();
    final db = _db;
    final version = _nextVersion();
    final raw = jsonEncode(replacement.raw);
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
        raw: Value(raw),
        versionPhysical: Value(version.physical),
        versionCounter: Value(version.counter),
        deviceId: Value(version.deviceId),
      ));
      if (updated > 0) {
        final syncId = await _ensurePlaylistSyncId(db, playlistId);
        if (syncId.isNotEmpty) {
          final row = await (db.select(db.playlistTracks)
                ..where((t) =>
                    t.playlistId.equals(playlistId) &
                    t.sourceKey.equals(replacement.sourceKey) &
                    t.songId.equals(replacement.songId))
                ..limit(1))
              .getSingle();
          await _appendJournal(
            db,
            SyncCategory.playlistTracks.name,
            _trackSyncRecord(playlistSyncId: syncId, row: row),
          );
        }
      }
    });
    if (updated > 0) {
      notifyChanged(favoriteChange
          ? const LibraryChange.favorites()
          : LibraryChange.playlistTracks(playlistId));
    }
    return updated > 0;
  }

  // ── 收藏 ─────────────────────────────────────────────────

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
    await _ensureReady();
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
        // 加入时间是内容时间，走注入时钟（与其余写入一致）。
        addedAt: _nowMs(),
      ),
      favoriteChange: true,
    );
    return true;
  }

  /// 批量加入默认收藏（跳过已收藏；返回新增数）。
  Future<int> addFavorites(List<PlaylistTrack> tracks) async {
    if (tracks.isEmpty) return 0;
    await _ensureReady();
    final playlistId = await _ensureFavoritesPlaylist();
    return addTracksToPlaylist(playlistId, tracks, favoriteChange: true);
  }

  /// 批量取消收藏（返回移除数；无收藏列表时为 0）。
  Future<int> removeFavorites(List<TrackKey> keys) async {
    if (keys.isEmpty) return 0;
    await _ensureReady();
    final playlistId = await _favoritesPlaylistId();
    if (playlistId == null) return 0;
    return removeTracksFromPlaylist(playlistId, keys, favoriteChange: true);
  }

  // ── 导入 ─────────────────────────────────────────────────

  /// 批量导入列表曲目（跳过重复、追加到末尾；返回实际新增数）。
  ///
  /// 导入路径的既有口径与本模块其余写入不同，逐条保留（本候选只搬仪式、
  /// 不动语义）：
  /// - `addedAt` 由调用方给（一次导入一个时刻，`.lxmc` 导入在调用侧取）；
  /// - **不追 journal**：导入是「整批落库」，增量日志的覆盖范围属同步协议
  ///   议题（见 ADR-0003 v2 §5），改动待独立评审；
  /// - 无条件广播 [LibraryChange.import]（复用的列表即使 0 新增也要刷新）。
  Future<int> importPlaylistTracks(
    int playlistId,
    List<PlaylistTrack> tracks,
  ) async {
    await _ensureReady();
    final db = _db;
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

    var imported = 0;
    final rows = <PlaylistTracksCompanion>[];
    for (final track in tracks) {
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
        addedAt: track.addedAt,
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

    notifyChanged(const LibraryChange.import());
    return imported;
  }

  // ── 同步面复用的写入原语 ─────────────────────────────────
  //
  // 仓库的同步面（应用远端记录）不走五步仪式：版本由远端给（不取号）、
  // 变更由来源设备广播（不追 journal）。墓碑行形状与 syncId 补齐口径
  // 在两侧只有这一份实现。

  /// 记录一条删除墓碑（可关日志：应用远端墓碑不追加）。
  Future<void> recordTombstone(
    DatabaseConnectionUser executor,
    String category,
    String key, {
    required SyncVersion version,
    required int deletedAt,
    bool journal = true,
  }) =>
      _recordTombstone(
        executor,
        category,
        key,
        version: version,
        deletedAt: deletedAt,
        journal: journal,
      );

  /// 清除某条历史的删除墓碑（本地重播复活 / 应用远端更新后的复活）。
  Future<void> clearHistoryTombstone(
    DatabaseConnectionUser executor,
    String sourceKey,
    String songId,
  ) =>
      _clearHistoryTombstone(executor, sourceKey, songId);

  /// 补齐缺失 syncId 的行（收藏固定值；其余随机生成，只补一次）。
  ///
  /// **不发版本戳**（既有口径：导出前的就地补齐靠 syncId 计数条款补偿，
  /// 见 `syncFingerprints`；改动属同步协议议题）。
  Future<void> ensurePlaylistSyncIds(DatabaseConnectionUser executor) async {
    final rows = await (executor.select(_db.playlists)
          ..where((t) => t.syncId.isNull() | t.syncId.equals('')))
        .get();
    for (final row in rows) {
      await (executor.update(_db.playlists)
            ..where((t) => t.id.equals(row.id)))
          .write(PlaylistsCompanion(syncId: Value(_newSyncId(row.name))));
    }
  }

  // ── 仪式零件（五步的内部实现）────────────────────────────

  /// 记录一条删除墓碑（单条；批量删除走 [_recordTombstones]）。
  Future<void> _recordTombstone(
    DatabaseConnectionUser executor,
    String category,
    String key, {
    required SyncVersion version,
    required int deletedAt,
    bool journal = true,
  }) async {
    await _recordTombstones(
      executor,
      category,
      [(key: key, version: version)],
      deletedAt: deletedAt,
      journal: journal,
    );
  }

  /// 批量墓碑 + 一次日志追加（批量删除的写入路径）。
  ///
  /// 墓碑走 drift batch（一条消息），日志按批一次追加（headSeq 只查一次）：
  /// 逐行走 `_recordTombstone` 是每行 1 次 INSERT + 1 次 journal.append
  /// （后者又各自查一次 headSeq）——清 500 条历史 ≈ 2500 条语句。
  Future<void> _recordTombstones(
    DatabaseConnectionUser executor,
    String category,
    List<({String key, SyncVersion version})> entries, {
    required int deletedAt,
    bool journal = true,
  }) async {
    if (entries.isEmpty) return;
    await executor.batch((batch) {
      for (final entry in entries) {
        batch.insert(
          _db.syncTombstones,
          SyncTombstonesCompanion.insert(
            category: category,
            key: entry.key,
            versionPhysical: entry.version.physical,
            versionCounter: Value(entry.version.counter),
            deviceId: Value(entry.version.deviceId),
            deletedAt: Value(deletedAt),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
    if (!journal) return;
    final journalRepo = _journal;
    if (journalRepo == null) return;
    final parsed = SyncCategory.tryParse(category);
    if (parsed == null) return;
    await journalRepo.append(executor, [
      for (final entry in entries)
        (
          category: parsed,
          record: SyncRecord.tombstone(
            key: entry.key,
            version: entry.version,
            deletedAt: deletedAt,
          ),
        ),
    ]);
  }

  // 增量日志：本机写入在同一事务内追加（对端只拉变更；见 ADR-0003 v2 §5）。
  // 记录形状与 `syncExport*` 完全一致——同一版本在日志与全量快照里的载荷
  // 必须相同，否则对端按 LWW 应用后会得到不同的内容。

  /// 追加一条本机变更（未注入日志时为空操作；executor 必须是数据写入的事务）。
  Future<void> _appendJournal(
    DatabaseConnectionUser executor,
    String category,
    SyncRecord record,
  ) async {
    final journal = _journal;
    if (journal == null) return;
    final parsed = SyncCategory.tryParse(category);
    if (parsed == null) return;
    await journal.append(executor, [(category: parsed, record: record)]);
  }

  SyncRecord _historySyncRecord({
    required String sourceKey,
    required String songId,
    required String title,
    required String artist,
    required String album,
    required String? coverUrl,
    required int? durationMs,
    required String raw,
    required int playedAt,
    required SyncVersion version,
  }) =>
      SyncRecord(
        key: SyncRecordKeys.history(sourceKey, songId),
        version: version,
        data: PlayHistorySyncRecord(
          sourceKey: sourceKey,
          songId: songId,
          title: title,
          artist: artist,
          album: album,
          coverUrl: coverUrl,
          durationMs: durationMs,
          raw: raw,
          playedAt: playedAt,
          version: version,
        ).toJson(),
      );

  SyncRecord _playlistSyncRecord({
    required String syncId,
    required String name,
    required int createdAt,
    required SyncVersion version,
  }) =>
      SyncRecord(
        key: syncId,
        version: version,
        data: PlaylistSyncRecord(
          syncId: syncId,
          name: name,
          createdAt: createdAt,
          version: version,
        ).toJson(),
      );

  SyncRecord _trackSyncRecord({
    required String playlistSyncId,
    required PlaylistTrackRow row,
  }) =>
      _trackRecord(
        playlistSyncId: playlistSyncId,
        sourceKey: row.sourceKey,
        songId: row.songId,
        title: row.title,
        artist: row.artist,
        album: row.album,
        coverUrl: row.coverUrl,
        durationMs: row.durationMs,
        raw: row.raw,
        addedAt: row.addedAt,
        sortOrder: row.sortOrder,
        version: row.syncVersion,
      );

  SyncRecord _trackRecord({
    required String playlistSyncId,
    required String sourceKey,
    required String songId,
    required String title,
    required String artist,
    required String album,
    required String? coverUrl,
    required int? durationMs,
    required String raw,
    required int addedAt,
    required int sortOrder,
    required SyncVersion version,
  }) =>
      SyncRecord(
        key: SyncRecordKeys.playlistTrack(playlistSyncId, sourceKey, songId),
        version: version,
        data: PlaylistTrackSyncRecord(
          playlistSyncId: playlistSyncId,
          sourceKey: sourceKey,
          songId: songId,
          title: title,
          artist: artist,
          album: album,
          coverUrl: coverUrl,
          durationMs: durationMs,
          raw: raw,
          addedAt: addedAt,
          sortOrder: sortOrder,
          version: version,
        ).toJson(),
      );

  /// 列表的 syncId（缺失时就地补齐并**追加日志**：对端才知道这个列表）。
  ///
  /// 返回空串 = 列表不存在（调用方跳过）。补齐是本地写入，与数据写入同事务。
  Future<String> _ensurePlaylistSyncId(
    DatabaseConnectionUser executor,
    int playlistId,
  ) async {
    final row = await (executor.select(_db.playlists)
          ..where((t) => t.id.equals(playlistId))
          ..limit(1))
        .getSingleOrNull();
    if (row == null) return '';
    final existing = row.syncId;
    if (existing != null && existing.isNotEmpty) return existing;
    final syncId = _newSyncId(row.name);
    final version = _nextVersion();
    await (executor.update(_db.playlists)..where((t) => t.id.equals(playlistId)))
        .write(PlaylistsCompanion(
      syncId: Value(syncId),
      versionPhysical: Value(version.physical),
      versionCounter: Value(version.counter),
      deviceId: Value(version.deviceId),
    ));
    await _appendJournal(
      executor,
      SyncCategory.playlists.name,
      _playlistSyncRecord(
        syncId: syncId,
        name: row.name,
        createdAt: row.createdAt,
        version: version,
      ),
    );
    return syncId;
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

  /// 收藏列表 id（缺失时创建）。
  ///
  /// 同名取最旧一条（与 `findPlaylistByName` 的查询顺序一致：收藏键集合、
  /// 列表页展示、写入侧落到同一个列表）。
  Future<int> _ensureFavoritesPlaylist() async {
    final existing = await _favoritesPlaylistId();
    if (existing != null) return existing;
    return createPlaylist(favoritesPlaylistRowName);
  }

  Future<int?> _favoritesPlaylistId() async {
    final db = _db;
    final row = await (db.select(db.playlists)
          ..where((t) => t.name.equals(favoritesPlaylistRowName))
          ..orderBy([(t) => OrderingTerm.asc(t.id)])
          ..limit(1))
        .getSingleOrNull();
    return row?.id;
  }

  /// 超出 [kHistoryLimit] 时删除最旧记录（同步面应用远端历史后也裁剪）。
  ///
  /// 走 SQL：`play_history` 没有显式主键，只能按隐式 `rowid` 淘汰。
  Future<void> trimHistory(DatabaseConnectionUser executor) async {
    await executor.customStatement(
      'DELETE FROM play_history WHERE rowid NOT IN ('
      'SELECT rowid FROM play_history ORDER BY playedAt DESC, rowid DESC LIMIT ?)',
      [kHistoryLimit],
    );
  }

  /// 位置偏好（设置页；未接线按追加到末尾）。
  bool get _insertAtTop => _addToTop?.call() ?? false;

  /// 新曲目的排序位起点：追加接在 `max(sortOrder)` 之后；放开头从
  /// `min(sortOrder) - count` 起（连续区间、批内保持传入顺序）。
  ///
  /// 为什么用负值而不是重写既有行：顶部插入只写新行——不碰旧行的版本戳与
  /// 同步日志；顺序由 `sortOrder` 升序表达，`reorderPlaylistTracks` 会把位置
  /// 归一化回 0..n-1。
  Future<int> _insertionStart(
    MoliaDatabase db,
    int playlistId, {
    required int count,
    required bool addToTop,
  }) async {
    if (!addToTop) return _nextSortOrder(db, playlistId);
    final minSortOrder = db.playlistTracks.sortOrder.min();
    final row = await (db.selectOnly(db.playlistTracks)
          ..addColumns([minSortOrder])
          ..where(db.playlistTracks.playlistId.equals(playlistId)))
        .getSingle();
    // 空列表（min 为空）从 0 开始，保持「首行 sortOrder = 0」的旧口径。
    return (row.read(minSortOrder) ?? count) - count;
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

  /// 收藏列表用固定 syncId；其余列表按随机 128bit 生成（跨设备稳定，
  /// 自增 id 只在本机有效）。
  String _newSyncId(String name) {
    if (name == favoritesPlaylistRowName) {
      return SyncRecordKeys.favoritesPlaylistSyncId;
    }
    final buffer = StringBuffer();
    for (var i = 0; i < 32; i++) {
      buffer.write('0123456789abcdef'[_random.nextInt(16)]);
    }
    return buffer.toString();
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
}
