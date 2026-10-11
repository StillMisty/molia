/// 听歌统计数据仓库：`play_events` 的读写与查询时聚合。
///
/// 设计对齐 [LibraryRepository]：可注入 [databaseProvider]（测试 in-memory
/// FFI），写操作后通过 [changes] 广播；只持久化元数据 + raw 取链参数，
/// **不持久化直链**。
///
/// 口径（查询时计算，常量见 [PlayStatisticsLimits]）：
/// - 有效播放：`listenedMs ≥ min(30s, 50% × duration)`；
/// - 完整播放率：`endReason = completed` / 非 error 事件；
/// - 跳过率：`endReason = skipped` 且未达有效阈值 / 非 error 事件；
/// - error 事件不计入任何计数、比率与时长（原始行仍保留）；
/// - 进行中（`endedAt IS NULL`）的事件不出现在任何查询结果里；
/// - 日/小时分桶在 Dart 侧按本地时区计算（SQLite 无时区语义）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../domain/models/play_statistics.dart';
import 'database_helper.dart';

class PlayStatisticsRepository {
  /// [databaseProvider] 仅测试注入（in-memory sqflite FFI）；生产走
  /// [DatabaseHelper.instance]（版本迁移 v3 → v4）。
  PlayStatisticsRepository({Future<Database> Function()? databaseProvider})
      : _databaseProvider =
            databaseProvider ?? (() => DatabaseHelper.instance.database);

  final Future<Database> Function() _databaseProvider;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// 统计变更广播（收尾事件 / 清空 / 遗留收尾后触发）。
  Stream<void> get changes => _changes.stream;

  Future<Database> get _db => _databaseProvider();

  void _notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// 有效播放的 SQL 判定式（durationMs 未知时按 30s 兜底）。
  static const String _qualifiedPredicate =
      'listenedMs >= CASE WHEN durationMs IS NULL OR durationMs <= 0 '
      'THEN ${PlayStatisticsLimits.qualifiedMinListenedMs} '
      'ELSE MIN(${PlayStatisticsLimits.qualifiedMinListenedMs}, '
      'durationMs * ${PlayStatisticsLimits.qualifiedFraction}) END';

  /// 已收尾且非 error 事件的公共过滤（计数/比率/时长统一口径）。
  static const String _countablePredicate =
      "endedAt IS NOT NULL AND COALESCE(endReason, '') <> 'error'";

  // ---------------------------------------------------------------------------
  // 写入（采集服务调用；所有写操作由调用方保证顺序）
  // ---------------------------------------------------------------------------

  /// 开始一次播放事件，返回行 id（`endedAt` 为 null = 进行中）。
  Future<int> startEvent({
    required String sourceKey,
    required String songId,
    required String title,
    String artist = '',
    String album = '',
    String? coverUrl,
    int? durationMs,
    Map<String, dynamic> raw = const {},
    required int startedAt,
  }) async {
    final db = await _db;
    return db.insert('play_events', {
      'sourceKey': sourceKey,
      'songId': songId,
      'title': title,
      'artist': artist,
      'album': album,
      'coverUrl': coverUrl,
      'durationMs': durationMs,
      'raw': jsonEncode(raw),
      'startedAt': startedAt,
      'endedAt': null,
      'listenedMs': 0,
      'maxPositionMs': 0,
      'endReason': null,
    });
  }

  /// 落盘进行中事件的进度（节流调用；不广播变更，进行中事件不影响统计）。
  Future<void> touchEvent(
    int id, {
    required int listenedMs,
    required int maxPositionMs,
  }) async {
    final db = await _db;
    await db.update(
      'play_events',
      {'listenedMs': listenedMs, 'maxPositionMs': maxPositionMs},
      where: 'id = ? AND endedAt IS NULL',
      whereArgs: [id],
    );
  }

  /// 收尾一次播放事件（写入最终进度 + 结束原因）。
  Future<void> finishEvent(
    int id, {
    required PlayEventEndReason reason,
    required int listenedMs,
    required int maxPositionMs,
    int? endedAt,
  }) async {
    final db = await _db;
    await db.update(
      'play_events',
      {
        'endedAt': endedAt ?? DateTime.now().millisecondsSinceEpoch,
        'listenedMs': listenedMs,
        'maxPositionMs': maxPositionMs,
        'endReason': reason.storageValue,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    _notifyChanged();
  }

  /// 收尾进程被杀等外部中断遗留的进行中事件。
  ///
  /// `endedAt` 取 `startedAt + listenedMs`（最后落盘进度，确定性可测）。
  /// 返回收尾行数。
  Future<int> closeStaleEvents() async {
    final db = await _db;
    final closed = await db.rawUpdate(
      'UPDATE play_events SET endedAt = startedAt + listenedMs, endReason = ? '
      'WHERE endedAt IS NULL',
      [PlayEventEndReason.interrupted.storageValue],
    );
    if (closed > 0) _notifyChanged();
    return closed;
  }

  /// 清空全部统计事件（不可撤销）。
  Future<void> clearAll() async {
    final db = await _db;
    await db.delete('play_events');
    _notifyChanged();
  }

  // ---------------------------------------------------------------------------
  // 查询
  // ---------------------------------------------------------------------------

  /// 范围内汇总；[since]（epoch ms）为 null 表示全部历史。
  Future<PlayStatisticsSummary> summary({int? since}) async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT
        SUM(CASE WHEN $_countablePredicate THEN 1 ELSE 0 END) AS playCount,
        SUM(CASE WHEN $_countablePredicate AND ($_qualifiedPredicate)
            THEN 1 ELSE 0 END) AS qualifiedCount,
        COALESCE(SUM(CASE WHEN $_countablePredicate THEN listenedMs ELSE 0 END), 0)
            AS listenedMs,
        COUNT(DISTINCT CASE WHEN $_countablePredicate
            THEN sourceKey || ':' || songId END) AS uniqueTracks,
        SUM(CASE WHEN endReason = 'completed' THEN 1 ELSE 0 END) AS completedCount,
        SUM(CASE WHEN endReason = 'skipped' AND NOT ($_qualifiedPredicate)
            THEN 1 ELSE 0 END) AS skippedUnqualifiedCount
      FROM play_events
      WHERE endedAt IS NOT NULL${since != null ? ' AND startedAt >= ?' : ''}
    ''', [if (since != null) since]);
    final row = rows.isEmpty ? const <String, Object?>{} : rows.first;
    final playCount = _intOf(row['playCount']);
    final completed = _intOf(row['completedCount']);
    final skippedUnqualified = _intOf(row['skippedUnqualifiedCount']);
    return PlayStatisticsSummary(
      playCount: playCount,
      qualifiedPlayCount: _intOf(row['qualifiedCount']),
      totalListenedMs: _intOf(row['listenedMs']),
      uniqueTrackCount: _intOf(row['uniqueTracks']),
      completionRate: playCount == 0 ? 0 : completed / playCount,
      skipRate: playCount == 0 ? 0 : skippedUnqualified / playCount,
      firstPlayedAt: await firstPlayedAt(),
    );
  }

  /// 全局首播时间（「数据起始日」；不受范围过滤影响）。
  Future<int?> firstPlayedAt() async {
    final db = await _db;
    final rows = await db.rawQuery(
      'SELECT MIN(startedAt) AS firstAt FROM play_events '
      "WHERE endedAt IS NOT NULL AND COALESCE(endReason, '') <> 'error'",
    );
    return rows.isEmpty ? null : rows.first['firstAt'] as int?;
  }

  /// Top 曲目（有效播放次数排序；只出现至少一次有效播放的曲目）。
  Future<List<PlayStatTrackEntry>> topTracks({
    int? since,
    int limit = 10,
  }) async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT
        sourceKey,
        songId,
        MAX(title) AS title,
        MAX(artist) AS artist,
        MAX(album) AS album,
        MAX(coverUrl) AS coverUrl,
        MAX(durationMs) AS durationMs,
        MAX(raw) AS raw,
        SUM(CASE WHEN ($_qualifiedPredicate) THEN 1 ELSE 0 END) AS playCount,
        COALESCE(SUM(listenedMs), 0) AS listenedMs,
        MAX(startedAt) AS lastPlayedAt
      FROM play_events
      WHERE $_countablePredicate${since != null ? ' AND startedAt >= ?' : ''}
      GROUP BY sourceKey, songId
      HAVING playCount > 0
      ORDER BY playCount DESC, listenedMs DESC, lastPlayedAt DESC
      LIMIT ?
    ''', [if (since != null) since, limit]);
    return [
      for (final row in rows)
        PlayStatTrackEntry(
          sourceKey: row['sourceKey'] as String? ?? '',
          songId: row['songId'] as String? ?? '',
          title: row['title'] as String? ?? '',
          artist: row['artist'] as String? ?? '',
          album: row['album'] as String? ?? '',
          coverUrl: row['coverUrl'] as String?,
          durationMs: row['durationMs'] as int?,
          raw: _decodeRaw(row['raw']),
          playCount: _intOf(row['playCount']),
          listenedMs: _intOf(row['listenedMs']),
          lastPlayedAt: _intOf(row['lastPlayedAt']),
        ),
    ];
  }

  /// Top 歌手（artist 串按分隔符拆分，各计一次有效播放）。
  Future<List<PlayStatArtistEntry>> topArtists({
    int? since,
    int limit = 10,
  }) async {
    final db = await _db;
    final rows = await db.query(
      'play_events',
      columns: ['artist', 'durationMs', 'listenedMs'],
      where:
          "$_countablePredicate${since != null ? ' AND startedAt >= ?' : ''}",
      whereArgs: [if (since != null) since],
    );
    final counts = <String, int>{};
    final listened = <String, int>{};
    for (final row in rows) {
      if (!_isQualified(row['listenedMs'], row['durationMs'])) continue;
      final listenedMs = _intOf(row['listenedMs']);
      for (final name in splitArtistNames(row['artist'] as String? ?? '')) {
        counts[name] = (counts[name] ?? 0) + 1;
        listened[name] = (listened[name] ?? 0) + listenedMs;
      }
    }
    final entries = [
      for (final entry in counts.entries)
        PlayStatArtistEntry(
          artist: entry.key,
          playCount: entry.value,
          listenedMs: listened[entry.key] ?? 0,
        ),
    ]..sort((a, b) {
        final byCount = b.playCount.compareTo(a.playCount);
        if (byCount != 0) return byCount;
        return b.listenedMs.compareTo(a.listenedMs);
      });
    return entries.take(limit).toList();
  }

  /// 按日收听（本地时区，升序；只含非 error 事件）。
  Future<List<DayListened>> listenedByDay({int? since}) async {
    final rows = await _statsRows(since);
    final listened = <DateTime, int>{};
    final counts = <DateTime, int>{};
    for (final row in rows) {
      final day = _localDay(row.startedAt);
      listened[day] = (listened[day] ?? 0) + row.listenedMs;
      if (row.qualified) counts[day] = (counts[day] ?? 0) + 1;
    }
    final days = listened.keys.toList()..sort();
    return [
      for (final day in days)
        DayListened(
          day: day,
          listenedMs: listened[day] ?? 0,
          playCount: counts[day] ?? 0,
        ),
    ];
  }

  /// 按小时收听（本地时区 0-23，升序；只含非 error 事件）。
  Future<List<HourListened>> listenedByHour({int? since}) async {
    final rows = await _statsRows(since);
    final listened = <int, int>{};
    final counts = <int, int>{};
    for (final row in rows) {
      final hour = DateTime.fromMillisecondsSinceEpoch(row.startedAt).hour;
      listened[hour] = (listened[hour] ?? 0) + row.listenedMs;
      if (row.qualified) counts[hour] = (counts[hour] ?? 0) + 1;
    }
    final hours = listened.keys.toList()..sort();
    return [
      for (final hour in hours)
        HourListened(
          hour: hour,
          listenedMs: listened[hour] ?? 0,
          playCount: counts[hour] ?? 0,
        ),
    ];
  }

  /// 星期 × 时段分布（作息热力图；`weekday` 0=周一，本地时区）。
  ///
  /// 返回稀疏列表（只有有数据的小时），按 (weekday, hour) 升序。
  Future<List<WeekdayHourListened>> listenedByWeekdayHour({int? since}) async {
    final rows = await _statsRows(since);
    final listened = <(int, int), int>{};
    final counts = <(int, int), int>{};
    for (final row in rows) {
      final local = DateTime.fromMillisecondsSinceEpoch(row.startedAt);
      final key = (local.weekday - 1, local.hour);
      listened[key] = (listened[key] ?? 0) + row.listenedMs;
      if (row.qualified) counts[key] = (counts[key] ?? 0) + 1;
    }
    final keys = listened.keys.toList()
      ..sort((a, b) {
        final byDay = a.$1.compareTo(b.$1);
        return byDay != 0 ? byDay : a.$2.compareTo(b.$2);
      });
    return [
      for (final key in keys)
        WeekdayHourListened(
          weekday: key.$1,
          hour: key.$2,
          listenedMs: listened[key] ?? 0,
          playCount: counts[key] ?? 0,
        ),
    ];
  }

  /// 来源分布（`sourceKey` 维度，按时长降序）。
  Future<List<SourceListened>> sourceDistribution({int? since}) async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT
        sourceKey,
        COALESCE(SUM(listenedMs), 0) AS listenedMs,
        SUM(CASE WHEN ($_qualifiedPredicate) THEN 1 ELSE 0 END) AS playCount
      FROM play_events
      WHERE $_countablePredicate${since != null ? ' AND startedAt >= ?' : ''}
      GROUP BY sourceKey
      ORDER BY listenedMs DESC, playCount DESC
    ''', [if (since != null) since]);
    return [
      for (final row in rows)
        SourceListened(
          sourceKey: row['sourceKey'] as String? ?? '',
          listenedMs: _intOf(row['listenedMs']),
          playCount: _intOf(row['playCount']),
        ),
    ];
  }

  /// 某一天的播放明细（热力图点按弹层用；不含 error 事件）。
  Future<DayPlayEvents> dayEvents(DateTime day) async {
    final db = await _db;
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    final rows = await db.query(
      'play_events',
      where: "$_countablePredicate AND startedAt >= ? AND startedAt < ?",
      whereArgs: [
        start.millisecondsSinceEpoch,
        end.millisecondsSinceEpoch,
      ],
      orderBy: 'startedAt ASC, id ASC',
    );
    final events = [for (final row in rows) _eventFromRow(row)];
    var listenedMs = 0;
    var playCount = 0;
    for (final event in events) {
      listenedMs += event.listenedMs;
      if (_isQualified(event.listenedMs, event.durationMs)) playCount++;
    }
    return DayPlayEvents(
      day: start,
      listenedMs: listenedMs,
      playCount: playCount,
      events: events,
    );
  }

  /// 导出用明细（最近 [limit] 条已收尾事件，含 error——导出是原始日志）。
  Future<List<PlayEvent>> listEventsForExport({
    int limit = PlayStatisticsLimits.exportEventLimit,
  }) async {
    final db = await _db;
    final rows = await db.query(
      'play_events',
      where: 'endedAt IS NOT NULL',
      orderBy: 'startedAt DESC, id DESC',
      limit: limit,
    );
    return [for (final row in rows) _eventFromRow(row)];
  }

  /// 已听过的曲目名（title + artist，按最近播放排序去重）。
  ///
  /// AI 推歌的排除清单用：不按 sourceKey 去重（同一首在不同平台都一样
  /// 不该再推），由调用方做规范化去重与截断。
  Future<List<({String title, String artist})>> listPlayedTrackNames({
    int limit = 1000,
  }) async {
    final db = await _db;
    final rows = await db.rawQuery('''
      SELECT title, artist, MAX(startedAt) AS lastAt
      FROM play_events
      WHERE endedAt IS NOT NULL
      GROUP BY title, artist
      ORDER BY lastAt DESC
      LIMIT ?
    ''', [limit]);
    return [
      for (final row in rows)
        (
          title: row['title'] as String? ?? '',
          artist: row['artist'] as String? ?? '',
        ),
    ];
  }

  /// 拆分 artist 串（`A, B` / `A/B` / `A&B` 等各计一位歌手）。
  ///
  /// 不做 feat./别名归一（留给 Phase 2，原始串完整保留在事件行里）。
  static List<String> splitArtistNames(String value) {
    return [
      for (final part in value.split(RegExp(r'[,，/、&;；]')))
        if (part.trim().isNotEmpty) part.trim(),
    ];
  }

  /// 有效播放判定（与 SQL 的 [_qualifiedPredicate] 同口径：`min(30s, 50%)`）。
  static bool _isQualified(Object? listenedMsRaw, Object? durationMsRaw) {
    final listenedMs = _intOf(listenedMsRaw);
    final durationMs = durationMsRaw as int?;
    if (durationMs == null || durationMs <= 0) {
      return listenedMs >= PlayStatisticsLimits.qualifiedMinListenedMs;
    }
    final fraction = durationMs * PlayStatisticsLimits.qualifiedFraction;
    final threshold = fraction < PlayStatisticsLimits.qualifiedMinListenedMs
        ? fraction
        : PlayStatisticsLimits.qualifiedMinListenedMs.toDouble();
    return listenedMs >= threshold;
  }

  DateTime _localDay(int startedAt) {
    final local = DateTime.fromMillisecondsSinceEpoch(startedAt);
    return DateTime(local.year, local.month, local.day);
  }

  Future<List<_StatRow>> _statsRows(int? since) async {
    final db = await _db;
    final rows = await db.query(
      'play_events',
      columns: ['startedAt', 'listenedMs', 'durationMs'],
      where:
          "$_countablePredicate${since != null ? ' AND startedAt >= ?' : ''}",
      whereArgs: [if (since != null) since],
      orderBy: 'startedAt ASC',
    );
    return [
      for (final row in rows)
        _StatRow(
          startedAt: _intOf(row['startedAt']),
          listenedMs: _intOf(row['listenedMs']),
          qualified: _isQualified(row['listenedMs'], row['durationMs']),
        ),
    ];
  }

  // ---------------------------------------------------------------------------
  // 行映射
  // ---------------------------------------------------------------------------

  PlayEvent _eventFromRow(Map<String, Object?> row) => PlayEvent(
        id: _intOf(row['id']),
        sourceKey: row['sourceKey'] as String? ?? '',
        songId: row['songId'] as String? ?? '',
        title: row['title'] as String? ?? '',
        artist: row['artist'] as String? ?? '',
        album: row['album'] as String? ?? '',
        coverUrl: row['coverUrl'] as String?,
        durationMs: row['durationMs'] as int?,
        raw: _decodeRaw(row['raw']),
        startedAt: _intOf(row['startedAt']),
        endedAt: row['endedAt'] as int?,
        listenedMs: _intOf(row['listenedMs']),
        maxPositionMs: _intOf(row['maxPositionMs']),
        endReason: PlayEventEndReason.fromStorage(row['endReason']),
      );

  static int _intOf(Object? value) => (value as num?)?.toInt() ?? 0;

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

  Future<void> dispose() async {
    await _changes.close();
  }
}

/// 内部用的轻量统计行（日/小时分桶与歌手聚合）。
class _StatRow {
  const _StatRow({
    required this.startedAt,
    required this.listenedMs,
    required this.qualified,
  });

  final int startedAt;
  final int listenedMs;
  final bool qualified;
}
