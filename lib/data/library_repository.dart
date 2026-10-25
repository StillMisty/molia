/// 本地资料库数据仓库：播放历史 / 用户列表 / 收藏 / `.lxmc` 导入。
///
/// 数据操作走 drift（简单读写用 DSL，JOIN / 聚合 / rowid 语句保留原 SQL
/// 文本），返回 [PlayHistoryEntry] / [PlaylistInfo] / [PlaylistTrack] 等领域
/// 模型；**不持久化播放直链**（只存元数据 + raw 取链参数），播放时由上层按
/// 需重新取链（对齐 LX Music 的设计）。
///
/// 写路径全部委托 [LibraryWriteEngine]（发号 → 写行 → journal → 墓碑 → 变更
/// 事件，五步仪式只有一个实现）；本类保留读路径与同步面（应用远端记录），
/// 以及两类 seam 的端口实现。
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../domain/models/device_sync.dart';
import '../domain/models/library.dart';
import '../domain/ports/library_store.dart';
import '../domain/ports/library_sync_store.dart';
import 'library_write_engine.dart';
import 'lxmc_decoder.dart';
import 'molia_database.dart';
import 'sync/sync_journal.dart';
import 'sync/sync_stamp.dart';

class LibraryRepository implements LibraryStore, LibrarySyncStore {
  /// [databaseProvider] 仅测试注入（in-memory drift 库）；生产走
  /// [MoliaDatabase.instance]。
  ///
  /// [stamps] 是版本戳唯一发号器（必填：组合根注入同一实例；漏注入会各自
  /// 建号、可能发出重复版本）；[clock] 供内容时间（`createdAt` / `addedAt` /
  /// `playedAt` / 墓碑的真实删除时间）——两者刻意分开（内容时间分离，
  /// 见 ADR-0003 v2 §2）。两者都转发给写入网关：内容时间只由写路径消费。
  ///
  /// [journal] 是增量日志（可选）：本机写入在**同一个 drift 事务**里追加
  /// 日志条目，对端按游标只拉变更；应用远端记录（`syncApply*`）不追加
  /// （远端变更由来源设备广播，本机不做二次转发）。
  ///
  /// [addToTop] 是「加入列表」的位置偏好（设置页注入，缺省追加到末尾）：
  /// 只影响手动加入 / 收藏，表内导入（平台歌单 / 收藏夹、`.lxmc`）固定按原顺序追加。
  LibraryRepository({
    MoliaDatabase Function()? databaseProvider,
    int Function()? clock,
    required SyncStampIssuer stamps,
    SyncJournalRepository? journal,
    bool Function()? addToTop,
    Future<void> Function()? beforeWrite,
  }) : _databaseProvider = databaseProvider ?? (() => MoliaDatabase.instance) {
    _writeEngine = LibraryWriteEngine(
      databaseProvider: _databaseProvider,
      clock: clock,
      stamps: stamps,
      journal: journal,
      addToTop: addToTop,
      beforeWrite: beforeWrite,
    );
  }

  final MoliaDatabase Function() _databaseProvider;

  /// 写入网关：全部写意图（含五步仪式）的唯一实现；本类只做委托。
  late final LibraryWriteEngine _writeEngine;

  /// 播放历史上限（超出删最旧，避免无限增长）。
  static const int historyLimit = kHistoryLimit;

  /// 资料库变更广播（history / playlists / favorites 任一写操作后触发）。
  ///
  /// 事件类型即失效范围（见 [LibraryChange]）；写入调用栈内同步派发。
  @override
  Stream<LibraryChange> get changes => _writeEngine.changes;

  MoliaDatabase get _db => _databaseProvider();

  /// 全库最大同步戳：供 `SyncStampIssuer` 首次初始化（基线 ≥ 全库最大戳）。
  Future<SyncVersion> maxVersion() async {
    final max = await _db.maxSyncVersion();
    return SyncVersion(physical: max.physical, counter: max.counter);
  }

  @override
  Future<void> addHistoryEntry(PlayHistoryEntry entry) =>
      _writeEngine.addHistoryEntry(entry);

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
  Future<void> deleteHistoryEntry(String sourceKey, String songId) =>
      _writeEngine.deleteHistoryEntry(sourceKey, songId);

  @override
  Future<int> deleteHistoryEntries(List<TrackKey> keys) =>
      _writeEngine.deleteHistoryEntries(keys);

  @override
  Future<bool> replaceHistoryEntry(
    TrackKey oldKey,
    PlayHistoryEntry replacement,
  ) =>
      _writeEngine.replaceHistoryEntry(oldKey, replacement);

  @override
  Future<int> addHistoryEntries(List<PlayHistoryEntry> entries) =>
      _writeEngine.addHistoryEntries(entries);

  @override
  Future<void> clearHistory() => _writeEngine.clearHistory();

  @override
  Future<int> createPlaylist(String name) => _writeEngine.createPlaylist(name);

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
    ''', variables: [Variable.withString(favoritesPlaylistRowName)]).get();
    return [for (final row in rows) _playlistFromData(row.data)];
  }

  @override
  Future<void> renamePlaylist(int id, String name) =>
      _writeEngine.renamePlaylist(id, name);

  @override
  Future<void> deletePlaylist(int id) => _writeEngine.deletePlaylist(id);

  /// 列表内曲目（sortOrder 升序，其次加入时间）。
  ///
  /// [limit] 非空时下推到 SQL（`LIMIT`），排序不变；null = 全部。
  @override
  Future<List<PlaylistTrack>> listPlaylistTracks(
    int playlistId, {
    int? limit,
  }) async {
    final db = _db;
    final query = db.select(db.playlistTracks)
      ..where((t) => t.playlistId.equals(playlistId))
      ..orderBy([
        (t) => OrderingTerm.asc(t.sortOrder),
        (t) => OrderingTerm.asc(t.addedAt),
        (t) => OrderingTerm.asc(t.id),
      ]);
    if (limit != null) query.limit(limit);
    final rows = await query.get();
    return [for (final row in rows) _trackFromRow(row)];
  }

  @override
  Future<bool> addTrackToPlaylist(
    int playlistId,
    PlaylistTrack track, {
    bool favoriteChange = false,
  }) =>
      _writeEngine.addTrackToPlaylist(
        playlistId,
        track,
        favoriteChange: favoriteChange,
      );

  @override
  Future<int> removeTrackFromPlaylist(
    int playlistId,
    String sourceKey,
    String songId, {
    bool favoriteChange = false,
  }) =>
      _writeEngine.removeTrackFromPlaylist(
        playlistId,
        sourceKey,
        songId,
        favoriteChange: favoriteChange,
      );

  @override
  Future<int> removeTracksFromPlaylist(
    int playlistId,
    List<TrackKey> keys, {
    bool favoriteChange = false,
  }) =>
      _writeEngine.removeTracksFromPlaylist(
        playlistId,
        keys,
        favoriteChange: favoriteChange,
      );

  @override
  Future<int> addTracksToPlaylist(
    int playlistId,
    List<PlaylistTrack> tracks, {
    bool favoriteChange = false,
  }) =>
      _writeEngine.addTracksToPlaylist(
        playlistId,
        tracks,
        favoriteChange: favoriteChange,
      );

  @override
  Future<void> reorderPlaylistTracks(
    int playlistId,
    List<TrackKey> ordered,
  ) =>
      _writeEngine.reorderPlaylistTracks(playlistId, ordered);

  @override
  Future<bool> replacePlaylistTrack(
    int playlistId,
    TrackKey oldKey,
    PlaylistTrack replacement, {
    bool favoriteChange = false,
  }) =>
      _writeEngine.replacePlaylistTrack(
        playlistId,
        oldKey,
        replacement,
        favoriteChange: favoriteChange,
      );

  /// 收藏键集合（`sourceKey:songId`），供 provider 一次性缓存。
  @override
  Future<Set<String>> favoriteKeys() async {
    final db = _db;
    final playlist = await findPlaylistByName(favoritesPlaylistRowName);
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
  }) =>
      _writeEngine.toggleFavorite(
        sourceKey: sourceKey,
        songId: songId,
        title: title,
        artist: artist,
        album: album,
        coverUrl: coverUrl,
        durationMs: durationMs,
        raw: raw,
      );

  @override
  Future<int> addFavorites(List<PlaylistTrack> tracks) =>
      _writeEngine.addFavorites(tracks);

  @override
  Future<int> removeFavorites(List<TrackKey> keys) =>
      _writeEngine.removeFavorites(keys);

  /// 导入 `.lxmc` 收藏夹：同名列表复用（重复导入幂等），逐曲 INSERT OR IGNORE。
  @override
  Future<LxmcImportResult> importLxmcBytes(
    Uint8List bytes, {
    String? fileName,
  }) async {
    final decoded = await decodeLxmcBytesOffThread(bytes, fileName: fileName);
    if (decoded.tracks.isEmpty) {
      throw const LxmcDecodeException('no_tracks');
    }

    final existingPlaylist = await findPlaylistByName(decoded.name);
    final playlistId =
        existingPlaylist?.id ?? await createPlaylist(decoded.name);

    // 导入的 `addedAt` 是内容时间，既有口径由调用侧取（导入不是一个播放/
    // 收藏动作，时间口径随 .lxmc 这条路径，见网关内说明）。
    final addedAt = DateTime.now().millisecondsSinceEpoch;
    final imported = await _writeEngine.importPlaylistTracks(playlistId, [
      for (final track in decoded.tracks)
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
          addedAt: addedAt,
          sortOrder: 0,
        ),
    ]);
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
  /// 返回 `(playlistId, 本次新增数, 曲目总数, created)`；供平台链接导入与
  /// 发现页歌单导入使用（总数用于区分空歌单与全部重复，[created] 让调用方
  /// 知道「本次导入的曲目就是新列表全量」，可直接建立缓存）。
  ///
  /// 导入保持文件 / 歌单原顺序**追加**到末尾，不受「加入列表位置」偏好影响
  /// （偏好只作用于手动加入与收藏）。
  @override
  Future<({int playlistId, int added, int total, bool created})> importTracks(
    String name,
    List<PlaylistTrack> tracks,
  ) async {
    if (tracks.isEmpty) {
      return (playlistId: -1, added: 0, total: 0, created: false);
    }
    final existing = await findPlaylistByName(name);
    final playlistId = existing?.id ?? await createPlaylist(name);
    final added = await _writeEngine.addTracksToPlaylist(
      playlistId,
      tracks,
      addToTop: false,
    );
    return (
      playlistId: playlistId,
      added: added,
      total: tracks.length,
      created: existing == null,
    );
  }

  // 跨设备同步（data/sync 适配器消费）
  //
  // 契约：导出只读本机视图并补齐缺失的 syncId；应用端逐行按版本三元组
  // `(versionPhysical, versionCounter, deviceId)` 取新，写入沿用远端版本
  // （幂等，不制造新的本地变更），删除经墓碑表表达；历史「删除 vs 播放」用
  // 真实时间（playedAt vs 墓碑 deletedAt）判定。缺 syncId 的行版本为默认 0，
  // 在导出/应用前一次性补齐 syncId。

  /// 导出列表头（类型化记录；列名不出实现）。
  @override
  Future<List<PlaylistSyncRecord>> syncExportPlaylists() async {
    final db = _db;
    await _writeEngine.ensurePlaylistSyncIds(db);
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
    await _writeEngine.ensurePlaylistSyncIds(db);
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

  /// 类别级廉价指纹：`COUNT(*)` + 最大版本（物理分量与计数合并比较，含该
  /// 类别墓碑）。
  ///
  /// 版本用 `MAX(versionPhysical * 1000000 + versionCounter)` 表达：同一毫秒
  /// 内的多次写入只有 `versionCounter` 变化（时钟回拨 / 吸收超前戳时物理
  /// 分量也会持平），单看 `MAX(versionPhysical)` 会漏掉这类变更。计数器
  /// 每毫秒远小于 100 万，乘法不会溢出 64 位。
  ///
  /// 列表头另计入「syncId 为空（NULL 或空串）」的行数：导出会就地补齐缺失的
  /// syncId（判据同此），补齐后指纹变化会触发一次重读（之后稳定），跳过导出
  /// 也不会让待补 syncId 的列表永远读不到。
  @override
  Future<Map<SyncCategory, String>> syncFingerprints(
    Iterable<SyncCategory> categories,
  ) async {
    final db = _db;
    const versionExpr = 'versionPhysical * 1000000 + versionCounter';
    Future<String> tableFingerprint(String table) async {
      final row = await db
          .customSelect(
              'SELECT COUNT(*) AS n, MAX($versionExpr) AS m FROM $table')
          .getSingle();
      return '${row.data['n']}:${row.data['m'] ?? 0}';
    }

    Future<String> playlistFingerprint() async {
      final row = await db.customSelect(
        'SELECT COUNT(*) AS n, MAX($versionExpr) AS m, '
        "SUM(CASE WHEN syncId IS NULL OR syncId = '' THEN 1 ELSE 0 END) AS x "
        'FROM playlists',
      ).getSingle();
      return '${row.data['n']}:${row.data['m'] ?? 0}:${row.data['x'] ?? 0}';
    }

    Future<String> tombstoneFingerprint(String category) async {
      final row = await db.customSelect(
        'SELECT COUNT(*) AS n, MAX($versionExpr) AS m '
        'FROM sync_tombstones WHERE category = ?',
        variables: [Variable<String>(category)],
      ).getSingle();
      return '${row.data['n']}:${row.data['m'] ?? 0}';
    }

    final result = <SyncCategory, String>{};
    for (final category in categories) {
      switch (category) {
        case SyncCategory.playlists:
          result[category] = 'p${await playlistFingerprint()}'
              '|t${await tombstoneFingerprint(category.name)}';
        case SyncCategory.playlistTracks:
          result[category] =
              'p${await tableFingerprint('playlist_tracks')}'
                  '|t${await tombstoneFingerprint(category.name)}';
        case SyncCategory.history:
          result[category] = 'p${await tableFingerprint('play_history')}'
              '|t${await tombstoneFingerprint(category.name)}';
        default:
          break;
      }
    }
    return result;
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
          await _writeEngine.recordTombstone(
            db,
            category,
            tombstone.key,
            version: tombstone.version,
            deletedAt: tombstone.deletedAt,
            // 应用远端记录不追加日志：变更由来源设备广播（本机不二次转发）。
            journal: false,
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
            await _writeEngine.clearHistoryTombstone(
              db,
              parsed.sourceKey,
              parsed.songId,
            );
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
            await _writeEngine.clearHistoryTombstone(db, sourceKey, songId);
          }
        }
        final local = await _historyRow(db, sourceKey, songId);
        // 同版本也应用：全量快照是权威视图，可能修掉被直接改写的本地行；
        // 内容一致则跳过（重复交付幂等，不产生写入）。
        if (local == null ||
            entry.version.isNewerThan(local.syncVersion) ||
            (!entry.version.isOlderThan(local.syncVersion) &&
                !_historyMatches(local, entry))) {
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
      await _writeEngine.trimHistory(db);
    });
    if (applied > 0) _writeEngine.notifyChanged(const LibraryChange.history());
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
      await _writeEngine.ensurePlaylistSyncIds(db);

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
          await _writeEngine.recordTombstone(
            db,
            category,
            key,
            version: tombstone.version,
            deletedAt: tombstone.deletedAt,
            // 应用远端记录不追加日志（变更由来源设备广播）。
            journal: false,
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
          // 同版本也应用（修复被直接改写的本地行）；内容一致则跳过。
          final localRow = await _playlistRowById(db, local.id);
          if (record.version.isNewerThan(local.version) ||
              (!record.version.isOlderThan(local.version) &&
                  (localRow == null ||
                      !_playlistMatches(localRow, syncId, record)))) {
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
        } else if (record.version.isNewerThan(existing.syncVersion) ||
            (!record.version.isOlderThan(existing.syncVersion) &&
                !_trackMatches(existing, record))) {
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
    if (applied > 0) _writeEngine.notifyChanged(const LibraryChange.import());
    return (applied: applied, skipped: skipped);
  }

  // 同版本内容比较：全量快照是权威视图，同版本但内容不同（被直接改写 /
  // 直接改库）要修回去；内容一致则跳过，保证重复交付幂等。

  static bool _historyMatches(PlayHistoryData row, PlayHistorySyncRecord entry) =>
      row.title == entry.title &&
      row.artist == entry.artist &&
      row.album == entry.album &&
      row.coverUrl == entry.coverUrl &&
      row.durationMs == entry.durationMs &&
      row.raw == entry.raw &&
      row.playedAt == entry.playedAt;

  static bool _playlistMatches(
    Playlist row,
    String syncId,
    PlaylistSyncRecord record,
  ) =>
      row.name == record.name &&
      row.createdAt == record.createdAt &&
      (row.syncId ?? '') == syncId;

  static bool _trackMatches(
    PlaylistTrackRow row,
    PlaylistTrackSyncRecord record,
  ) =>
      row.title == record.title &&
      row.artist == record.artist &&
      row.album == record.album &&
      row.coverUrl == record.coverUrl &&
      row.durationMs == record.durationMs &&
      row.raw == record.raw &&
      row.addedAt == record.addedAt &&
      row.sortOrder == record.sortOrder;

  Future<Playlist?> _playlistRowById(
    DatabaseConnectionUser executor,
    int id,
  ) =>
      (executor.select(_db.playlists)
            ..where((t) => t.id.equals(id))
            ..limit(1))
          .getSingleOrNull();

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
        isFavorites: row.name == favoritesPlaylistRowName,
      );

  PlaylistInfo _playlistFromData(Map<String, Object?> row) => PlaylistInfo(
        id: row['id'] as int? ?? -1,
        name: row['name'] as String? ?? '',
        createdAt: row['createdAt'] as int? ?? 0,
        trackCount: row['trackCount'] as int? ?? 0,
        isFavorites: row['name'] == favoritesPlaylistRowName,
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
    await _writeEngine.dispose();
  }
}
