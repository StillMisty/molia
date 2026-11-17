/// 设备本地缓存索引仓库（drift `local_cache_index` 表）。
///
/// 只做行 ↔ 领域模型映射与批量读写；排序上限 / 初始化 / 对账语义在
/// `LocalCacheIndexStore`。这张表不参与同步、不写同步日志，也不在
/// `MoliaDatabase.maxSyncVersion()` 的扫描范围内。
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../domain/models/local_cache_index.dart';
import '../domain/ports/local_cache_index.dart';
import 'molia_database.dart';

class LocalCacheIndexRepository implements LocalCacheIndexPersistence {
  /// [databaseProvider] 仅测试注入（in-memory drift 库）；生产走
  /// [MoliaDatabase.instance]。
  LocalCacheIndexRepository({MoliaDatabase Function()? databaseProvider})
    : _databaseProvider = databaseProvider ?? (() => MoliaDatabase.instance);

  final MoliaDatabase Function() _databaseProvider;

  MoliaDatabase get _db => _databaseProvider();

  @override
  Future<List<LocalCacheIndexEntry>> loadAll() async {
    final rows = await (_db.select(
      _db.localCacheIndex,
    )..orderBy([(t) => OrderingTerm.desc(t.cachedAt)])).get();
    return [for (final row in rows) _fromRow(row)];
  }

  @override
  Future<void> upsertAll(List<LocalCacheIndexEntry> entries) async {
    if (entries.isEmpty) return;
    await _db.transaction(() async {
      for (final entry in entries) {
        await _db
            .into(_db.localCacheIndex)
            .insert(
              LocalCacheIndexCompanion.insert(
                sourceKey: entry.sourceKey,
                songId: entry.songId,
                title: entry.title,
                artist: Value(entry.artist),
                album: Value(entry.album),
                coverUrl: Value(entry.coverUrl),
                durationMs: Value(entry.durationMs),
                raw: Value(jsonEncode(entry.raw)),
                cachedAt: entry.cachedAt,
              ),
              mode: InsertMode.insertOrReplace,
            );
      }
    });
  }

  @override
  Future<void> removeAll(Iterable<LocalCacheIndexKey> keys) async {
    final list = keys.toList(growable: false);
    if (list.isEmpty) return;
    await _db.transaction(() async {
      for (final key in list) {
        await (_db.delete(_db.localCacheIndex)..where(
              (t) =>
                  t.sourceKey.equals(key.sourceKey) &
                  t.songId.equals(key.songId),
            ))
            .go();
      }
    });
  }

  static LocalCacheIndexEntry _fromRow(LocalCacheIndexRow row) =>
      LocalCacheIndexEntry(
        sourceKey: row.sourceKey,
        songId: row.songId,
        title: row.title,
        artist: row.artist,
        album: row.album,
        coverUrl: row.coverUrl,
        durationMs: row.durationMs,
        raw: _decodeRaw(row.raw),
        cachedAt: row.cachedAt,
      );

  static Map<String, dynamic> _decodeRaw(String raw) {
    if (raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      // 旧行 / 手改数据解析失败不阻断列表：按无载荷处理。
    }
    return const {};
  }
}
