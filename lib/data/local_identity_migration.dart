/// 本地导入身份的一次性迁移（v2 → v3 schema 的一部分）。
///
/// 为什么在迁移里做：旧导入的身份是文件路径（`local:<绝对路径>`），路径一变，
/// 收藏 / 列表 / 历史 / 会话 / 统计 / 自定义封面会同时失联。v3 给导入记录一个
/// 与路径无关的 `file:<uuid>`（`downloads.localKey`），这里把旧引用一次性改写到
/// 新身份。规则与常量见 `local_identity.dart`。
///
/// 约束：
/// - 与结构变更同一事务（调用方包事务）：任何失败整体回滚，库仍是 v2；
/// - 批量读写（≤500 行 / 批），失败不留下「一半新一半旧」；
/// - 重跑幂等：已有 `file:` 身份直接复用，不再生成第二个；
/// - 会话 JSON 解析失败不阻断迁移：保留原 JSON、跳过该行，冷启动按既有逻辑
///   视为无会话；
/// - 只改本地导入引用；下载副本（`local:<原音源键>`）与非本地行原样保留。
library;

import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:logging/logging.dart';

import '../domain/models/device_sync.dart';
import 'local_identity.dart';
import 'stats_payload_codec.dart';

/// 迁移批大小（读写都按这个粒度推进）。
const int _batchSize = 500;

/// 本地身份改写器（内部只做 SQL，不依赖仓储 / 服务）。
abstract final class LocalIdentityMigration {
  static final Logger _logger = Logger('molia.local_identity_migration');

  /// 把旧 `local:<path>` 引用改写成 `file:<uuid>`。
  ///
  /// [db] 必须已经带上 v3 新列（`downloads.localKey` 等）；调用方负责事务。
  /// [random] 仅测试注入（默认安全随机）。
  static Future<void> rewrite(
    DatabaseConnectionUser db, {
    Random? random,
  }) async {
    final randomSource = random ?? Random();
    final mapping = <String, String>{}; // 旧曲目 id（local:<path>）→ 新 key
    final usedKeys = <String>{};

    String keyForLegacyId(String legacyId) {
      final existing = mapping[legacyId];
      if (existing != null) return existing;
      final key = _freshKey(usedKeys, randomSource);
      usedKeys.add(key);
      mapping[legacyId] = key;
      return key;
    }

    // 1) 导入记录：先把每条的 localKey / originSongId 定下来，再改引用。
    final importedRows = await db
        .customSelect(
          "SELECT id, originSongId, filePath, localKey FROM downloads "
          "WHERE originSourceKey = 'local' AND imported = 1 ORDER BY id",
        )
        .get();
    final recordUpdates = <({int id, String key})>[];
    for (final row in importedRows) {
      final id = row.read<int>('id');
      final origin = row.readNullable<String>('originSongId') ?? '';
      final filePath = row.readNullable<String>('filePath');
      final existingKey = row.readNullable<String>('localKey');
      final path = (filePath != null && filePath.isNotEmpty)
          ? filePath
          : origin;
      var key = _stableOrNull(existingKey) ?? _stableOrNull(origin);
      key ??= mapping[legacyLocalIdentityOf(path)];
      if (key == null) {
        key = _freshKey(usedKeys, randomSource);
      } else if (usedKeys.contains(key)) {
        // 极端情况：两行共享一个 key（旧版本手工改动 / 中断）。保留第一行，
        // 其余重新发号，避免后面的部分唯一索引建不起来。
        key = _freshKey(usedKeys, randomSource);
      }
      usedKeys.add(key);
      if (filePath != null && filePath.isNotEmpty) {
        mapping[legacyLocalIdentityOf(filePath)] = key;
      }
      if (legacyLocalPathOf(origin) != null) {
        mapping[legacyLocalIdentityOf(origin)] = key;
      }
      if (existingKey != key || origin != key) {
        recordUpdates.add((id: id, key: key));
      }
    }

    // 2) 孤儿引用：只有列表 / 历史 / 统计行、没有下载记录。先登记再改写，
    //    避免同一路径在不同表里拿到不同 key。
    for (final table in const [
      'playlist_tracks',
      'play_history',
      'play_tracks',
    ]) {
      final rows = await db
          .customSelect(
            "SELECT DISTINCT songId FROM $table "
            "WHERE sourceKey = 'local' ORDER BY songId",
          )
          .get();
      for (final row in rows) {
        final songId = row.read<String>('songId');
        if (!isLegacyLocalIdentity(songId)) continue;
        keyForLegacyId(songId);
      }
    }

    // 3) 播放会话：解析一次，收集旧 id；解析失败只跳过（不阻断迁移）。
    final sessionRow = await db
        .customSelect('SELECT json FROM playback_session_payloads WHERE id = 1')
        .getSingleOrNull();
    Map<String, dynamic>? sessionJson;
    if (sessionRow != null) {
      final raw = sessionRow.read<String>('json');
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          sessionJson = decoded.cast<String, dynamic>();
          final tracks = sessionJson['tracks'];
          if (tracks is List) {
            for (final track in tracks) {
              if (track is! Map) continue;
              if (track['sourceKey'] != 'local') continue;
              final id = track['id'];
              if (id is String && isLegacyLocalIdentity(id)) {
                keyForLegacyId(id);
              }
              final payload = track['payload'];
              if (payload is Map) {
                final songId = payload['songId'];
                if (songId is String && isLegacyLocalIdentity(songId)) {
                  keyForLegacyId(songId);
                }
              }
            }
          }
        }
      } on Object catch (e) {
        _logger.warning('播放会话 JSON 无法解析，跳过会话身份改写：$e');
        sessionJson = null;
      }
    }

    // 4) 写回下载记录（先写身份列，引用表随后引用同一份 key）。
    for (final update in recordUpdates) {
      await db.customUpdate(
        'UPDATE downloads SET originSongId = ?, localKey = ? WHERE id = ?',
        variables: [
          Variable<String>(update.key),
          Variable<String>(update.key),
          Variable<int>(update.id),
        ],
      );
    }

    // 5) 引用表：列表曲目 / 历史 / 统计曲目。raw 载荷可解析时同步改
    //    `payload.songId`；解析失败保留原文（本地播放信任 path）。
    await _rewritePlaylistTracks(db, mapping);
    await _rewritePlayHistory(db, mapping);
    await _rewritePlayTracks(db, mapping);

    // 6) 会话 JSON 写回：只改 id / payload.songId，index / positionMs /
    //    savedAt / 队列顺序保持原样。
    if (sessionJson != null) {
      final rewritten = _rewriteSessionJson(sessionJson, mapping);
      if (rewritten != null) {
        await db.customUpdate(
          'UPDATE playback_session_payloads SET json = ? WHERE id = 1',
          variables: [Variable<String>(jsonEncode(rewritten))],
        );
      }
    }

    // 7) 本地曲目的同步墓碑 / 已知版本没有远端对手，直接丢弃（append-only
    //    日志不在这里重写：适配器本来就过滤本地记录）。
    await _dropLocalSyncKeys(db, 'sync_tombstones');
    await _dropLocalSyncKeys(db, 'sync_known');
  }

  static String? _stableOrNull(String? value) =>
      value != null && isStableLocalKey(value) ? value : null;

  static String _freshKey(Set<String> used, Random random) {
    // 极端碰撞（注入的固定随机源）时继续发号，避免静默复用。
    var key = newLocalKey(random);
    while (used.contains(key)) {
      key = newLocalKey(random);
    }
    return key;
  }

  static Future<void> _rewritePlaylistTracks(
    DatabaseConnectionUser db,
    Map<String, String> mapping,
  ) async {
    if (mapping.isEmpty) return;
    var lastId = 0;
    while (true) {
      final rows = await db
          .customSelect(
            "SELECT id, playlistId, songId, raw FROM playlist_tracks "
            "WHERE sourceKey = 'local' AND id > ? ORDER BY id LIMIT $_batchSize",
            variables: [Variable<int>(lastId)],
          )
          .get();
      if (rows.isEmpty) return;
      for (final row in rows) {
        lastId = row.read<int>('id');
        final oldId = row.read<String>('songId');
        final newKey = mapping[oldId];
        if (newKey == null) continue;
        final playlistId = row.read<int>('playlistId');
        final collision = await db
            .customSelect(
              "SELECT id FROM playlist_tracks WHERE playlistId = ? "
              "AND sourceKey = 'local' AND songId = ? LIMIT 1",
              variables: [Variable<int>(playlistId), Variable<String>(newKey)],
            )
            .getSingleOrNull();
        if (collision != null) {
          // 重跑 / 半迁移现场：新身份行已存在，旧引用是重复条目。
          await db.customUpdate(
            'DELETE FROM playlist_tracks WHERE id = ?',
            variables: [Variable<int>(row.read<int>('id'))],
          );
          continue;
        }
        await db.customUpdate(
          'UPDATE playlist_tracks SET songId = ?, raw = ? WHERE id = ?',
          variables: [
            Variable<String>(newKey),
            Variable<String>(
              _rewritePayloadJson(
                    row.read<String>('raw'),
                    oldId: oldId,
                    newKey: newKey,
                  ) ??
                  row.read<String>('raw'),
            ),
            Variable<int>(row.read<int>('id')),
          ],
        );
      }
    }
  }

  static Future<void> _rewritePlayHistory(
    DatabaseConnectionUser db,
    Map<String, String> mapping,
  ) async {
    var lastId = 0;
    while (true) {
      final rows = await db
          .customSelect(
            "SELECT rowid AS rowId, songId, raw FROM play_history "
            "WHERE sourceKey = 'local' AND rowid > ? "
            "ORDER BY rowid LIMIT $_batchSize",
            variables: [Variable<int>(lastId)],
          )
          .get();
      if (rows.isEmpty) return;
      for (final row in rows) {
        lastId = row.read<int>('rowId');
        final oldId = row.read<String>('songId');
        final newKey = mapping[oldId];
        if (newKey == null) continue;
        final collision = await db
            .customSelect(
              "SELECT rowid FROM play_history WHERE sourceKey = 'local' "
              'AND songId = ? LIMIT 1',
              variables: [Variable<String>(newKey)],
            )
            .getSingleOrNull();
        if (collision != null) {
          await db.customUpdate(
            'DELETE FROM play_history WHERE rowid = ?',
            variables: [Variable<int>(row.read<int>('rowId'))],
          );
          continue;
        }
        await db.customUpdate(
          'UPDATE play_history SET songId = ?, raw = ? WHERE rowid = ?',
          variables: [
            Variable<String>(newKey),
            Variable<String>(
              _rewritePayloadJson(
                    row.read<String>('raw'),
                    oldId: oldId,
                    newKey: newKey,
                  ) ??
                  row.read<String>('raw'),
            ),
            Variable<int>(row.read<int>('rowId')),
          ],
        );
      }
    }
  }

  static Future<void> _rewritePlayTracks(
    DatabaseConnectionUser db,
    Map<String, String> mapping,
  ) async {
    var lastId = 0;
    while (true) {
      final rows = await db
          .customSelect(
            'SELECT id, songId, raw FROM play_tracks '
            "WHERE sourceKey = 'local' AND id > ? ORDER BY id LIMIT $_batchSize",
            variables: [Variable<int>(lastId)],
          )
          .get();
      if (rows.isEmpty) return;
      for (final row in rows) {
        lastId = row.read<int>('id');
        final oldId = row.read<String>('songId');
        final newKey = mapping[oldId];
        if (newKey == null) continue;
        final trackId = row.read<int>('id');
        final collision = await db
            .customSelect(
              "SELECT id FROM play_tracks WHERE sourceKey = 'local' "
              'AND songId = ? LIMIT 1',
              variables: [Variable<String>(newKey)],
            )
            .getSingleOrNull();
        if (collision != null) {
          // 统计事件仍要指向存活行：把事件挪过去再删旧曲目行。
          await db.customUpdate(
            'UPDATE play_events SET trackId = ? WHERE trackId = ?',
            variables: [
              Variable<int>(collision.read<int>('id')),
              Variable<int>(trackId),
            ],
          );
          await db.customUpdate(
            'DELETE FROM play_tracks WHERE id = ?',
            variables: [Variable<int>(trackId)],
          );
          continue;
        }
        final raw = row.readNullable<Uint8List>('raw');
        final rewrittenRaw = _rewriteStatsPayload(
          oldId: oldId,
          newKey: newKey,
          bytes: raw,
        );
        await db.customUpdate(
          'UPDATE play_tracks SET songId = ?, raw = ? WHERE id = ?',
          variables: [
            Variable<String>(newKey),
            rewrittenRaw == null
                ? const Variable<Uint8List>(null)
                : Variable<Uint8List>(rewrittenRaw),
            Variable<int>(trackId),
          ],
        );
      }
    }
  }

  /// 列表 / 历史 raw 是 JSON 文本：能解析且 `songId` 是旧身份时改写，否则
  /// 返回 null（调用方保留原文）。
  static String? _rewritePayloadJson(
    String raw, {
    required String oldId,
    required String newKey,
  }) {
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      if (decoded['songId'] != oldId) return null;
      final next = decoded.map((key, value) => MapEntry(key.toString(), value));
      next['songId'] = newKey;
      return jsonEncode(next);
    } on Object {
      return null;
    }
  }

  /// 统计 raw 是 gzip(JSON)：解不开就保留原字节（本地播放信任 path）。
  static Uint8List? _rewriteStatsPayload({
    required String oldId,
    required String newKey,
    required Uint8List? bytes,
  }) {
    if (bytes == null || bytes.isEmpty) return null;
    final text = decodeStatsPayload(bytes);
    if (text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map || decoded['songId'] != oldId) return null;
      final next = decoded.map((key, value) => MapEntry(key.toString(), value));
      next['songId'] = newKey;
      return encodeStatsPayload(jsonEncode(next));
    } on Object {
      return null;
    }
  }

  static Map<String, dynamic>? _rewriteSessionJson(
    Map<String, dynamic> session,
    Map<String, String> mapping,
  ) {
    final tracks = session['tracks'];
    if (tracks is! List) return null;
    var changed = false;
    final nextTracks = <Object?>[];
    for (final track in tracks) {
      if (track is! Map) {
        nextTracks.add(track);
        continue;
      }
      final next = track.map((key, value) => MapEntry(key.toString(), value));
      if (next['sourceKey'] == 'local') {
        final id = next['id'];
        var newKey = id is String ? mapping[id] : null;
        final payload = next['payload'];
        if (payload is Map) {
          final nextPayload = payload.map(
            (key, value) => MapEntry(key.toString(), value),
          );
          final payloadId = nextPayload['songId'];
          if (payloadId is String && mapping.containsKey(payloadId)) {
            newKey ??= mapping[payloadId];
            nextPayload['songId'] = newKey;
            next['payload'] = nextPayload;
            changed = true;
          }
        }
        if (newKey != null && newKey != id) {
          next['id'] = newKey;
          changed = true;
        }
      }
      nextTracks.add(next);
    }
    if (!changed) return null;
    return {...session, 'tracks': nextTracks};
  }

  static Future<void> _dropLocalSyncKeys(
    DatabaseConnectionUser db,
    String table,
  ) async {
    final rows = await db
        .customSelect('SELECT category, key FROM $table')
        .get();
    for (final row in rows) {
      final category = row.read<String>('category');
      final key = row.read<String>('key');
      if (!_isLocalSyncKey(category, key)) continue;
      await db.customUpdate(
        'DELETE FROM $table WHERE category = ? AND key = ?',
        variables: [Variable<String>(category), Variable<String>(key)],
      );
    }
  }

  static bool _isLocalSyncKey(String category, String key) {
    final history = SyncRecordKeys.parseHistory(key);
    if (history?.sourceKey == 'local') return true;
    final track = SyncRecordKeys.parsePlaylistTrack(key);
    if (track?.sourceKey == 'local') return true;
    // 封面类别：导入封面键（新 file: / 旧 local:<path>）不上云。
    if (category == 'covers') return isDeviceLocalCoverKey(key);
    return false;
  }
}
