/// 本地下载数据仓库（drift `downloads` 表）。
///
/// 只做行 ↔ 领域模型映射与简单读写；「下载中的文件状态 / 进度 / 取消」由
/// `DownloadService` 承担。写操作后经 [changes] 广播变更（UI 失效缓存）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/models/download.dart';
import '../molia_database.dart';

class DownloadsRepository {
  /// [databaseProvider] 仅测试注入（in-memory drift 库）；生产走
  /// [MoliaDatabase.instance]。
  DownloadsRepository({MoliaDatabase Function()? databaseProvider})
      : _databaseProvider = databaseProvider ?? (() => MoliaDatabase.instance);

  final MoliaDatabase Function() _databaseProvider;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  MoliaDatabase get _db => _databaseProvider();

  /// 下载集合变更广播（插入 / 删除后触发）。
  Stream<void> get changes => _changes.stream;

  /// 全部下载（下载时间倒序）。
  Future<List<DownloadedTrack>> listAll() async {
    final rows = await (_db.select(_db.downloads)
          ..orderBy([
            (t) => OrderingTerm.desc(t.downloadedAt),
            (t) => OrderingTerm.desc(t.id),
          ]))
        .get();
    return [for (final row in rows) _fromRow(row)];
  }

  /// 按原音源曲目键查询（一首原曲最多一条下载）。
  Future<DownloadedTrack?> findByOrigin(String sourceKey, String songId) async {
    final row = await (_db.select(_db.downloads)
          ..where((t) =>
              t.originSourceKey.equals(sourceKey) &
              t.originSongId.equals(songId))
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  /// 插入下载记录（同原曲唯一键冲突时整体替换）。
  Future<void> insert(DownloadedTrack track) async {
    await _db.into(_db.downloads).insert(
          DownloadsCompanion.insert(
            originSourceKey: track.originSourceKey,
            originSongId: track.originSongId,
            title: track.title,
            artist: Value(track.artist),
            album: Value(track.album),
            coverUrl: Value(track.coverUrl),
            durationMs: Value(track.durationMs),
            raw: Value(jsonEncode(track.raw)),
            quality: Value(track.quality),
          filePath: Value(track.filePath),
            sizeBytes: Value(track.sizeBytes),
            lyricPath: Value(track.lyricPath),
            coverPath: Value(track.coverPath),
            publicUri: Value(track.publicUri),
            downloadedAt: track.downloadedAt,
          ),
          mode: InsertMode.insertOrReplace,
        );
    _notifyChanged();
  }

  /// 删除下载记录（文件删除由服务负责）。
  Future<void> delete(String sourceKey, String songId) async {
    final removed = await (_db.delete(_db.downloads)
          ..where((t) =>
              t.originSourceKey.equals(sourceKey) &
              t.originSongId.equals(songId)))
        .go();
    if (removed > 0) _notifyChanged();
  }

  void _notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  DownloadedTrack _fromRow(DownloadRow row) => DownloadedTrack(
        originSourceKey: row.originSourceKey,
        originSongId: row.originSongId,
        title: row.title,
        artist: row.artist,
        album: row.album,
        coverUrl: row.coverUrl,
        durationMs: row.durationMs,
        raw: _decodeRaw(row.raw),
        quality: row.quality,
        filePath: row.filePath,
        sizeBytes: row.sizeBytes,
        lyricPath: row.lyricPath,
        coverPath: row.coverPath,
        publicUri: row.publicUri,
        downloadedAt: row.downloadedAt,
      );

  static Map<String, dynamic> _decodeRaw(String raw) {
    if (raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      // 损坏数据降级为空 raw（本地播放只依赖 payload 里的路径字段）。
    }
    return const {};
  }

  Future<void> dispose() async {
    await _changes.close();
  }
}
