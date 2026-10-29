/// 播放会话的 SQLite 仓库：主库两张单行表（payload / cursor），不建独立库。
///
/// 为什么拆两表：payload 是整份队列 JSON（含每首曲目的音源 payload，大队列
/// MB 级），游标只是下标 / 进度 / 时间。动作只改游标时绝不能重写 payload 行
/// ——那等于把 SharedPreferences 整文件重写放大搬进数据库。
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:logging/logging.dart';

import '../domain/ports/playback_session_sync.dart';
import 'molia_database.dart';

/// 会话单行表固定主键。
const int playbackSessionRowId = 1;

/// 播放会话原始读写（`PlaybackSessionStore` 的唯一持久化后端）。
///
/// 注入 [MoliaDatabase Function()]：生产用 `MoliaDatabase.instance`，测试用
/// 内存库；数据库在首次查询时才真正打开。
class PlaybackSessionRepository {
  PlaybackSessionRepository({MoliaDatabase Function()? database})
    : _database = database ?? (() => MoliaDatabase.instance);

  final MoliaDatabase Function() _database;
  final Logger _logger = Logger('molia.playback_session_repository');

  MoliaDatabase get _db => _database();

  /// 读取 payload + cursor 合并后的原始 JSON；没有 payload 返回 null。
  ///
  /// 游标 `savedAt` 不早于 payload 内容时间才覆盖下标 / 进度 / savedAt：
  /// 远端或数据注入整份改写 payload 后，旧游标不属于这份队列，必须忽略。
  Future<Map<String, dynamic>?> loadRaw() {
    // payload / cursor 必须读同一快照：写者可能正好在两次 select 之间提交
    // 「新 payload + 新 cursor」，分开读会把旧游标套到新队列上。
    return _db.transaction(() async {
      final payloadRow = await (_db.select(
        _db.playbackSessionPayloads,
      )..where((row) => row.id.equals(playbackSessionRowId))).getSingleOrNull();
      if (payloadRow == null || payloadRow.json.isEmpty) return null;

      final Object? decoded;
      try {
        decoded = jsonDecode(payloadRow.json);
      } catch (e) {
        _logger.warning('播放会话 payload 损坏，按无会话处理：$e');
        return null;
      }
      if (decoded is! Map) return null;
      final map = decoded.cast<String, dynamic>();

      final cursor = await (_db.select(
        _db.playbackSessionCursors,
      )..where((row) => row.id.equals(playbackSessionRowId))).getSingleOrNull();
      if (cursor == null) return map;
      final contentSavedAt =
          (map[kPlaybackSessionSavedAtKey] as num?)?.toInt() ??
          payloadRow.updatedAt;
      if (cursor.savedAt < contentSavedAt) return map;
      map['index'] = cursor.cursorIndex;
      map['positionMs'] = cursor.positionMs;
      map[kPlaybackSessionSavedAtKey] = cursor.savedAt;
      return map;
    });
  }

  /// 写整份 payload（单行 upsert）；队列 / 模式 / 上下文变化时才调用。
  Future<void> savePayload(
    Map<String, dynamic> payload, {
    required int savedAt,
  }) async {
    await _db
        .into(_db.playbackSessionPayloads)
        .insert(
          PlaybackSessionPayloadsCompanion.insert(
            id: const Value(playbackSessionRowId),
            json: jsonEncode(payload),
            updatedAt: savedAt,
          ),
          mode: InsertMode.insertOrReplace,
        );
  }

  /// 只写游标：不触碰 payload 行（动作路径的低成本写）。
  Future<void> saveCursor({
    required int index,
    required int positionMs,
    required int savedAt,
  }) async {
    await _db
        .into(_db.playbackSessionCursors)
        .insert(
          PlaybackSessionCursorsCompanion.insert(
            id: const Value(playbackSessionRowId),
            cursorIndex: index,
            positionMs: positionMs,
            savedAt: savedAt,
          ),
          mode: InsertMode.insertOrReplace,
        );
  }

  /// payload + cursor 同一事务（队列变化 / 远端整份应用）。
  Future<void> saveAll({
    required Map<String, dynamic> payload,
    required int savedAt,
    required int index,
    required int positionMs,
  }) async {
    await _db.transaction(() async {
      await savePayload(payload, savedAt: savedAt);
      await saveCursor(index: index, positionMs: positionMs, savedAt: savedAt);
    });
  }

  /// 只更新已有游标的进度；没有游标时为空操作（不凭空造一条无下标记录）。
  Future<void> updatePosition(int positionMs) async {
    await (_db.update(_db.playbackSessionCursors)
          ..where((row) => row.id.equals(playbackSessionRowId)))
        .write(PlaybackSessionCursorsCompanion(positionMs: Value(positionMs)));
  }

  /// 删除两行（幂等）。
  Future<void> clear() async {
    await _db.transaction(() async {
      await _db.delete(_db.playbackSessionPayloads).go();
      await _db.delete(_db.playbackSessionCursors).go();
    });
  }
}
