/// 数据库计数（只读）：只导出数量与 schema 版本，不读曲名 / 列表名 / raw。
library;

import 'package:drift/drift.dart' show Variable;

import '../../services/diagnostics/diagnostics_bundle.dart';
import '../library_write_engine.dart' show favoritesPlaylistRowName;
import '../molia_database.dart';

/// 逐项容错：单表查询失败返回 null，整体仍可导出。
Future<DiagnosticsDatabaseCounts> gatherDiagnosticsDatabaseCounts({
  MoliaDatabase Function()? database,
}) async {
  final db = (database ?? () => MoliaDatabase.instance)();
  Future<int?> count(String sql, {List<Variable<Object>>? variables}) async {
    try {
      final row = await db
          .customSelect(sql, variables: variables ?? const [])
          .getSingle();
      return row.read<int>('c');
    } catch (_) {
      return null;
    }
  }

  final counts = <String, int?>{
    'playlists': await count('SELECT COUNT(*) AS c FROM playlists'),
    'playlist_tracks': await count('SELECT COUNT(*) AS c FROM playlist_tracks'),
    'favorites': await count(
      'SELECT COUNT(*) AS c FROM playlist_tracks '
      'WHERE playlistId IN (SELECT id FROM playlists WHERE name = ?)',
      variables: [Variable.withString(favoritesPlaylistRowName)],
    ),
    'play_history': await count('SELECT COUNT(*) AS c FROM play_history'),
    'play_tracks': await count('SELECT COUNT(*) AS c FROM play_tracks'),
    'play_events': await count('SELECT COUNT(*) AS c FROM play_events'),
    'downloads': await count('SELECT COUNT(*) AS c FROM downloads'),
  };
  int? hasSession;
  try {
    final row = await db
        .customSelect('SELECT 1 AS c FROM playback_session_payloads LIMIT 1')
        .getSingleOrNull();
    hasSession = row == null ? 0 : 1;
  } catch (_) {
    hasSession = null;
  }
  return DiagnosticsDatabaseCounts(
    schemaVersion: db.schemaVersion,
    counts: counts,
    hasSavedSession: hasSession == null ? null : hasSession == 1,
  );
}
