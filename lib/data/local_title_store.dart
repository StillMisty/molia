/// 本地曲目标题写入的唯一数据库入口（一个事务更新所有引用面）。
///
/// 统计 `play_tracks` 是**历史快照**，按产品语义不更新；封面 / raw / 歌手 /
/// 专辑 / 歌词也不动。会话 JSON 只改匹配曲目的 `title`，队列顺序、下标、
/// 进度、模式与 `savedAt` 保持不变。
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:logging/logging.dart';

import '../../domain/models/download.dart' show kLocalSourceKey;
import 'molia_database.dart';

class LocalTitleStore {
  LocalTitleStore({MoliaDatabase Function()? database})
    : _database = database ?? (() => MoliaDatabase.instance);

  final MoliaDatabase Function() _database;
  final Logger _logger = Logger('molia.local_title_store');

  /// 在**一个事务**里更新下载记录 / 列表曲目 / 历史 / 会话；[songId] 是
  /// 本地领域 id（导入 `localKey`，下载副本原音源键）。
  Future<void> applyLocalTitle({
    required String songId,
    required String downloadSourceKey,
    required String downloadSongId,
    required String title,
  }) async {
    final db = _database();
    await db.transaction(() async {
      await db.customUpdate(
        'UPDATE downloads SET title = ? '
        'WHERE originSourceKey = ? AND originSongId = ?',
        variables: [
          Variable<String>(title),
          Variable<String>(downloadSourceKey),
          Variable<String>(downloadSongId),
        ],
      );
      await db.customUpdate(
        'UPDATE playlist_tracks SET title = ? '
        'WHERE sourceKey = ? AND songId = ?',
        variables: [
          Variable<String>(title),
          Variable<String>(kLocalSourceKey),
          Variable<String>(songId),
        ],
      );
      await db.customUpdate(
        'UPDATE play_history SET title = ? WHERE sourceKey = ? AND songId = ?',
        variables: [
          Variable<String>(title),
          Variable<String>(kLocalSourceKey),
          Variable<String>(songId),
        ],
      );
      await _updateSessionTitle(db, songId: songId, title: title);
    });
  }

  Future<void> _updateSessionTitle(
    MoliaDatabase db, {
    required String songId,
    required String title,
  }) async {
    final row =
        await (db.select(db.playbackSessionPayloads)
              ..where((t) => t.id.equals(1))
              ..limit(1))
            .getSingleOrNull();
    if (row == null || row.json.isEmpty) return;
    Map<String, dynamic> session;
    try {
      final decoded = jsonDecode(row.json);
      if (decoded is! Map) return;
      session = decoded.cast<String, dynamic>();
    } catch (e) {
      // 损坏会话保持原样（冷启动按无会话处理），不能阻断标题更新。
      _logger.warning('播放会话 JSON 无法解析，跳过标题更新：$e');
      return;
    }
    final tracks = session['tracks'];
    if (tracks is! List) return;
    var changed = false;
    final next = <Object?>[];
    for (final track in tracks) {
      if (track is! Map) {
        next.add(track);
        continue;
      }
      final map = track.map((key, value) => MapEntry(key.toString(), value));
      if (map['sourceKey'] == kLocalSourceKey && map['id'] == songId) {
        map['title'] = title;
        changed = true;
      }
      next.add(map);
    }
    if (!changed) return;
    session['tracks'] = next;
    await (db.update(
      db.playbackSessionPayloads,
    )..where((t) => t.id.equals(1))).write(
      PlaybackSessionPayloadsCompanion(json: Value(jsonEncode(session))),
    );
  }
}
