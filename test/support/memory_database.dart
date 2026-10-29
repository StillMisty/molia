import 'dart:convert';

import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/playback_session_repository.dart';
import 'package:molia/data/stats_payload_codec.dart';
import 'package:molia/services/playback_session_store.dart';

/// 测试用内存数据库：schema 与生产一致（首个查询才建表建连接）。
///
/// 生产库的执行器只走 drift_flutter（见 lib/data/molia_database.dart）；
/// `NativeDatabase.memory()` 仅测试使用。关闭由调用方负责（`await db.close()`）。
MoliaDatabase openMemoryDatabase() => MoliaDatabase(NativeDatabase.memory());

MoliaDatabase? _sharedSessionDatabase;

/// 当前用例共享的播放会话内存库（`flutter_test_config.dart` 每个用例重置）。
///
/// 参数默认的 `PlaybackSessionStore()` 与测试装配的协调者因此读写同一份库，
/// 模拟「写入 → 冷启动读取」而不触碰真实文件 / path_provider。
MoliaDatabase get sharedSessionDatabase =>
    _sharedSessionDatabase ??= openMemoryDatabase();

/// 每个用例开始前换一份空库（上一份异步关闭，不阻塞用例）。
void resetSharedSessionDatabase() {
  final previous = _sharedSessionDatabase;
  _sharedSessionDatabase = null;
  if (previous != null) unawaited(previous.close());
}

/// 用当前共享内存库建一个会话 store（需要显式 store 时用）。
PlaybackSessionStore testSessionStore({
  MoliaDatabase? database,
  DateTime Function()? clock,
}) {
  final db = database ?? sharedSessionDatabase;
  return PlaybackSessionStore(
    repository: PlaybackSessionRepository(database: () => db),
    clock: clock,
  );
}

/// 按原列名读出一张表的全部行（断言沿用列名取值，不关心 drift 行类型）。
Future<List<Map<String, Object?>>> tableRows(
  MoliaDatabase db,
  String table,
) async {
  final rows = await db.customSelect('SELECT * FROM $table').get();
  return [for (final row in rows) row.data];
}

/// 插入统计曲目内容行（`play_tracks` 每曲一行，载荷按 gzip 存）。
///
/// 已存在时按「最近一次播放」语义覆盖（`updatedAt` 不早于已有时才写），与
/// 仓库的写入口径一致。
Future<int> insertPlayTrack(
  MoliaDatabase db, {
  String sourceKey = 'wy',
  String songId = 'song1',
  String title = 'Song 1',
  String artist = 'Artist A',
  String album = '',
  String? coverUrl,
  int? durationMs = 200000,
  Map<String, dynamic>? raw,
  int updatedAt = 0,
}) async {
  final payload = encodeStatsPayload(
    jsonEncode(raw ?? <String, dynamic>{'id': songId}),
  );
  final existing =
      await (db.select(db.playTracks)
            ..where(
              (t) => t.sourceKey.equals(sourceKey) & t.songId.equals(songId),
            )
            ..limit(1))
          .getSingleOrNull();
  if (existing == null) {
    return db
        .into(db.playTracks)
        .insert(
          PlayTracksCompanion.insert(
            sourceKey: sourceKey,
            songId: songId,
            title: Value(title),
            artist: Value(artist),
            album: Value(album),
            coverUrl: Value(coverUrl),
            durationMs: Value(durationMs),
            raw: Value(payload),
            updatedAt: updatedAt,
          ),
        );
  }
  if (updatedAt >= existing.updatedAt) {
    await (db.update(
      db.playTracks,
    )..where((t) => t.id.equals(existing.id))).write(
      PlayTracksCompanion(
        title: Value(title),
        artist: Value(artist),
        album: Value(album),
        coverUrl: Value(coverUrl),
        durationMs: Value(durationMs),
        raw: Value(payload),
        updatedAt: Value(updatedAt),
      ),
    );
  }
  return existing.id;
}

/// 插入一条统计事件（含曲目内容行；两表结构）。
///
/// `syncKey` 非空且唯一：未显式给值时生成一个测试内的唯一键（生产写入点
/// 由 `SqliteStatisticsSyncStore.startEvent` 生成）。
Future<int> insertPlayEvent(
  MoliaDatabase db, {
  String sourceKey = 'wy',
  String songId = 'song1',
  String title = 'Song 1',
  String artist = 'Artist A',
  String album = '',
  String? coverUrl,
  int? durationMs = 200000,
  Map<String, dynamic>? raw,
  required int startedAt,
  int listenedMs = 100000,
  int maxPositionMs = 100000,
  String? endReason = 'skipped',
  int? endedAt,
  String? syncKey,
}) async {
  final trackId = await insertPlayTrack(
    db,
    sourceKey: sourceKey,
    songId: songId,
    title: title,
    artist: artist,
    album: album,
    coverUrl: coverUrl,
    durationMs: durationMs,
    raw: raw,
    updatedAt: startedAt,
  );
  return db
      .into(db.playEvents)
      .insert(
        PlayEventsCompanion.insert(
          trackId: trackId,
          startedAt: startedAt,
          endedAt: Value(endedAt),
          listenedMs: Value(listenedMs),
          maxPositionMs: Value(maxPositionMs),
          endReason: Value(endReason),
          syncKey: syncKey ?? 'test-sync-${_syncKeySeed++}',
        ),
      );
}

/// 测试内 `syncKey` 序号（未显式给值时保证跨行唯一）。
var _syncKeySeed = 0;

/// 事件行 + 曲目内容行（列名与同步记录的行结构一致）。
///
/// 断言用：事件表瘦身后（元数据 / `raw` 在 [insertPlayTrack] 那张表里），
/// 直接读 `play_events` 拿不到曲目字段。
Future<List<Map<String, Object?>>> playEventRows(MoliaDatabase db) async {
  final rows = await db
      .customSelect(
        'SELECT e.*, pt.sourceKey AS sourceKey, pt.songId AS songId, '
        'pt.title AS title, pt.artist AS artist, pt.album AS album, '
        'pt.coverUrl AS coverUrl, pt.durationMs AS durationMs, pt.raw AS raw '
        'FROM play_events e LEFT JOIN play_tracks pt ON pt.id = e.trackId '
        'ORDER BY e.id ASC',
      )
      .get();
  return [for (final row in rows) row.data];
}
