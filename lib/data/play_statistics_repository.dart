/// 听歌统计数据仓库：`play_events` 的读写与查询时聚合。
///
/// 设计对齐 [LibraryRepository]：可注入 [databaseProvider]（测试 in-memory
/// drift 库），写操作后通过 [changes] 广播；只持久化元数据 + raw 取链参数，
/// **不持久化直链**。
///
/// 简单读写走 drift DSL；跨行聚合（汇总 / 首播时间 / 榜单 / 来源分布 /
/// 已听曲目名）保留 `customSelect`：SQL 语义逐字保留，
/// 口径常量（[_qualifiedPredicate] / [_countablePredicate]）仍是唯一来源。
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
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../domain/models/play_statistics.dart';
import 'molia_database.dart';

class PlayStatisticsRepository {
  /// [databaseProvider] 仅测试注入（in-memory drift 库）；生产走
  /// [MoliaDatabase.instance]。
  ///
  /// [deviceIdProvider] 供跨设备统计合并标注事件来源设备（缺省为空串，
  /// 同步未启用时无影响）。
  PlayStatisticsRepository({
    MoliaDatabase Function()? databaseProvider,
    String Function()? deviceIdProvider,
  })  : _databaseProvider = databaseProvider ?? (() => MoliaDatabase.instance),
        _deviceIdProvider = deviceIdProvider ?? (() => '');

  final MoliaDatabase Function() _databaseProvider;
  final String Function() _deviceIdProvider;
  final Random _random = Random.secure();
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// 统计变更广播（收尾事件 / 清空 / 遗留收尾后触发）。
  Stream<void> get changes => _changes.stream;

  MoliaDatabase get _db => _databaseProvider();

  void _notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// 有效播放的 SQL 判定式（durationMs 未知时按 30s 兜底）。
  ///
  /// 与 [PlayStatisticsLimits.qualifiedThresholdMs] 同口径；一致性由
  /// test/play_statistics_formula_test.dart 用同一批 fixture 行逐行对照。
  static const String _qualifiedPredicate =
      'listenedMs >= CASE WHEN durationMs IS NULL OR durationMs <= 0 '
      'THEN ${PlayStatisticsLimits.qualifiedMinListenedMs} '
      'ELSE MIN(${PlayStatisticsLimits.qualifiedMinListenedMs}, '
      'durationMs * ${PlayStatisticsLimits.qualifiedFraction}) END';

  /// 已收尾且非 error 事件的公共过滤（计数/比率/时长统一口径）。
  static const String _countablePredicate =
      "endedAt IS NOT NULL AND COALESCE(endReason, '') <> 'error'";

  /// DSL 查询用的公共过滤（复用 [_countablePredicate] 的同一份 SQL 文本）。
  Expression<bool> get _countable => CustomExpression<bool>(_countablePredicate);

  /// 公共过滤 + 可选起始时间（[since] 为 null 表示全部历史）。
  Expression<bool> _countableSince(int? since) => since == null
      ? _countable
      : _countable & _db.playEvents.startedAt.isBiggerOrEqualValue(since);

  // 写入（采集服务调用；所有写操作由调用方保证顺序）

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
  }) {
    return _db.into(_db.playEvents).insert(PlayEventsCompanion.insert(
          sourceKey: sourceKey,
          songId: songId,
          title: Value(title),
          artist: Value(artist),
          album: Value(album),
          coverUrl: Value(coverUrl),
          durationMs: Value(durationMs),
          raw: Value(jsonEncode(raw)),
          startedAt: startedAt,
          endedAt: const Value(null),
          listenedMs: const Value(0),
          maxPositionMs: const Value(0),
          endReason: const Value(null),
          syncKey: Value(_newSyncKey()),
          originDeviceId: Value(_deviceIdProvider()),
        ));
  }

  /// 落盘进行中事件的进度（节流调用；不广播变更，进行中事件不影响统计）。
  Future<void> touchEvent(
    int id, {
    required int listenedMs,
    required int maxPositionMs,
  }) {
    return (_db.update(_db.playEvents)
          ..where((t) => t.id.equals(id) & t.endedAt.isNull()))
        .write(PlayEventsCompanion(
      listenedMs: Value(listenedMs),
      maxPositionMs: Value(maxPositionMs),
    ));
  }

  /// 收尾一次播放事件（写入最终进度 + 结束原因）。
  Future<void> finishEvent(
    int id, {
    required PlayEventEndReason reason,
    required int listenedMs,
    required int maxPositionMs,
    int? endedAt,
  }) async {
    await (_db.update(_db.playEvents)..where((t) => t.id.equals(id)))
        .write(PlayEventsCompanion(
      endedAt: Value(endedAt ?? DateTime.now().millisecondsSinceEpoch),
      listenedMs: Value(listenedMs),
      maxPositionMs: Value(maxPositionMs),
      endReason: Value(reason.storageValue),
    ));
    _notifyChanged();
  }

  /// 收尾进程被杀等外部中断遗留的进行中事件。
  ///
  /// `endedAt` 取 `startedAt + listenedMs`（最后落盘进度，确定性可测）。
  /// 返回收尾行数。
  Future<int> closeStaleEvents() async {
    final closed = await _db.customUpdate(
      'UPDATE play_events SET endedAt = startedAt + listenedMs, endReason = ? '
      'WHERE endedAt IS NULL',
      variables: [Variable.withString(PlayEventEndReason.interrupted.storageValue)],
      updates: {_db.playEvents},
    );
    if (closed > 0) _notifyChanged();
    return closed;
  }

  /// 清空全部统计事件（不可撤销）。
  Future<void> clearAll() async {
    await _db.delete(_db.playEvents).go();
    _notifyChanged();
  }

  /// 范围内汇总；[since]（epoch ms）为 null 表示全部历史。
  Future<PlayStatisticsSummary> summary({int? since}) async {
    final row = await _db.customSelect('''
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
    ''', variables: [if (since != null) Variable.withInt(since)]).getSingle();
    final data = row.data;
    final playCount = _intOf(data['playCount']);
    final completed = _intOf(data['completedCount']);
    final skippedUnqualified = _intOf(data['skippedUnqualifiedCount']);
    return PlayStatisticsSummary(
      playCount: playCount,
      qualifiedPlayCount: _intOf(data['qualifiedCount']),
      totalListenedMs: _intOf(data['listenedMs']),
      uniqueTrackCount: _intOf(data['uniqueTracks']),
      completionRate: playCount == 0 ? 0 : completed / playCount,
      skipRate: playCount == 0 ? 0 : skippedUnqualified / playCount,
      firstPlayedAt: await firstPlayedAt(),
    );
  }

  /// 全局首播时间（「数据起始日」；不受范围过滤影响）。
  /// 一次范围查询的全部聚合（统计页只渲染它）：并发执行、失败整体抛出。
  ///
  /// 查询集合固定：汇总 / 榜单 / 日历（固定全量历史）/ 作息热力图 / 来源分布。
  Future<ListeningStatisticsSnapshot> snapshot({int? since}) async {
    final (summaryResult, trackResult, artistResult, dayResult,
            weekdayHourResult, sourceResult) =
        await (
      summary(since: since),
      topTracks(since: since),
      topArtists(since: since),
      listenedByDay(),
      listenedByWeekdayHour(since: since),
      sourceDistribution(since: since),
    ).wait;
    return ListeningStatisticsSnapshot(
      summary: summaryResult,
      topTracks: trackResult,
      topArtists: artistResult,
      daily: dayResult,
      byWeekdayHour: weekdayHourResult,
      sources: sourceResult,
    );
  }

  Future<int?> firstPlayedAt() async {
    final row = await _db.customSelect(
      'SELECT MIN(startedAt) AS firstAt FROM play_events '
      "WHERE endedAt IS NOT NULL AND COALESCE(endReason, '') <> 'error'",
    ).getSingle();
    return row.data['firstAt'] as int?;
  }

  /// Top 曲目（有效播放次数排序；只出现至少一次有效播放的曲目）。
  Future<List<PlayStatTrackEntry>> topTracks({
    int? since,
    int limit = 10,
  }) async {
    final rows = await _db.customSelect('''
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
    ''', variables: [
      if (since != null) Variable.withInt(since),
      Variable.withInt(limit),
    ]).get();
    return [
      for (final row in rows)
        PlayStatTrackEntry(
          sourceKey: row.data['sourceKey'] as String? ?? '',
          songId: row.data['songId'] as String? ?? '',
          title: row.data['title'] as String? ?? '',
          artist: row.data['artist'] as String? ?? '',
          album: row.data['album'] as String? ?? '',
          coverUrl: row.data['coverUrl'] as String?,
          durationMs: row.data['durationMs'] as int?,
          raw: _decodeRaw(row.data['raw']),
          playCount: _intOf(row.data['playCount']),
          listenedMs: _intOf(row.data['listenedMs']),
          lastPlayedAt: _intOf(row.data['lastPlayedAt']),
        ),
    ];
  }

  /// Top 歌手（artist 串按分隔符拆分，各计一次有效播放）。
  Future<List<PlayStatArtistEntry>> topArtists({
    int? since,
    int limit = 10,
  }) async {
    final events = _db.playEvents;
    final rows = await (_db.selectOnly(events)
          ..addColumns([events.artist, events.durationMs, events.listenedMs])
          ..where(_countableSince(since)))
        .get();
    final counts = <String, int>{};
    final listened = <String, int>{};
    for (final row in rows) {
      final listenedMs = row.read(events.listenedMs) ?? 0;
      if (!_isQualified(listenedMs, row.read(events.durationMs))) continue;
      for (final name in splitArtistNames(row.read(events.artist) ?? '')) {
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
    final rows = await _db.customSelect('''
      SELECT
        sourceKey,
        COALESCE(SUM(listenedMs), 0) AS listenedMs,
        SUM(CASE WHEN ($_qualifiedPredicate) THEN 1 ELSE 0 END) AS playCount
      FROM play_events
      WHERE $_countablePredicate${since != null ? ' AND startedAt >= ?' : ''}
      GROUP BY sourceKey
      ORDER BY listenedMs DESC, playCount DESC
    ''', variables: [if (since != null) Variable.withInt(since)]).get();
    return [
      for (final row in rows)
        SourceListened(
          sourceKey: row.data['sourceKey'] as String? ?? '',
          listenedMs: _intOf(row.data['listenedMs']),
          playCount: _intOf(row.data['playCount']),
        ),
    ];
  }

  /// 某一天的播放明细（热力图点按弹层用；不含 error 事件）。
  Future<DayPlayEvents> dayEvents(DateTime day) async {
    final db = _db;
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    final events = db.playEvents;
    final rows = await (db.select(events)
          ..where((t) =>
              _countableSince(null) &
              t.startedAt
                  .isBiggerOrEqualValue(start.millisecondsSinceEpoch) &
              t.startedAt.isSmallerThanValue(end.millisecondsSinceEpoch))
          ..orderBy([
            (t) => OrderingTerm.asc(t.startedAt),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .get();
    final playEvents = [for (final row in rows) _eventFromRow(row)];
    var listenedMs = 0;
    var playCount = 0;
    for (final event in playEvents) {
      listenedMs += event.listenedMs;
      if (_isQualified(event.listenedMs, event.durationMs)) playCount++;
    }
    return DayPlayEvents(
      day: start,
      listenedMs: listenedMs,
      playCount: playCount,
      events: playEvents,
    );
  }

  /// 导出用明细（最近 [limit] 条已收尾事件，含 error——导出是原始日志）。
  Future<List<PlayEvent>> listEventsForExport({
    int limit = PlayStatisticsLimits.exportEventLimit,
  }) async {
    final events = _db.playEvents;
    final rows = await (_db.select(events)
          ..where((t) => t.endedAt.isNotNull())
          ..orderBy([
            (t) => OrderingTerm.desc(t.startedAt),
            (t) => OrderingTerm.desc(t.id),
          ])
          ..limit(limit))
        .get();
    return [for (final row in rows) _eventFromRow(row)];
  }

  /// 同步导出：全部已收尾事件。
  ///
  /// 进行中事件不导出（远端无法继续更新进度，收尾后自然进入下一轮）；
  /// v5 前的旧行无去重键，按内容哈希一次性回填并落库。
  Future<List<Map<String, Object?>>> syncExportEvents() async {
    final db = _db;
    // 导出行直接复用列名映射（远端按列名取值；不要改成类型化行）。
    final rows = await db
        .customSelect('SELECT * FROM play_events WHERE endedAt IS NOT NULL')
        .get();
    final result = <Map<String, Object?>>[];
    final backfilled = <(int, String)>[];
    for (final row in rows) {
      final data = row.data;
      var syncKey = data['syncKey'] as String?;
      if (syncKey == null || syncKey.isEmpty) {
        syncKey = _legacySyncKey(data);
        backfilled.add((data['id'] as int? ?? -1, syncKey));
      }
      result.add({...data, 'syncKey': syncKey});
    }
    if (backfilled.isNotEmpty) {
      await db.transaction(() async {
        for (final (id, key) in backfilled) {
          await (db.update(db.playEvents)
                ..where((t) =>
                    t.id.equals(id) &
                    (t.syncKey.isNull() | t.syncKey.equals(''))))
              .write(PlayEventsCompanion(syncKey: Value(key)));
        }
      });
    }
    return result;
  }

  /// 同步应用：按 `syncKey` 去重合并；同键已存在且远端 `endedAt` 更新时
  /// 覆盖进度（进程被杀后由启动收尾补完的事件会晚于首次同步）。
  Future<({int applied, int skipped})> syncApplyEvents(
    List<Map<String, Object?>> events,
  ) async {
    if (events.isEmpty) return (applied: 0, skipped: 0);
    final db = _db;
    var applied = 0;
    var skipped = 0;
    await db.transaction(() async {
      for (final event in events) {
        final syncKey = event['syncKey'] as String? ?? '';
        final endedAt = (event['endedAt'] as num?)?.toInt();
        if (syncKey.isEmpty || endedAt == null) {
          skipped++;
          continue;
        }
        final existing = await (db.select(db.playEvents)
              ..where((t) => t.syncKey.equals(syncKey))
              ..limit(1))
            .getSingleOrNull();
        if (existing == null) {
          await db.into(db.playEvents).insert(PlayEventsCompanion.insert(
                sourceKey: event['sourceKey'] as String? ?? '',
                songId: event['songId'] as String? ?? '',
                title: Value(event['title'] as String? ?? ''),
                artist: Value(event['artist'] as String? ?? ''),
                album: Value(event['album'] as String? ?? ''),
                coverUrl: Value(event['coverUrl'] as String?),
                durationMs: Value((event['durationMs'] as num?)?.toInt()),
                raw: Value(event['raw'] as String? ?? '{}'),
                startedAt: (event['startedAt'] as num?)?.toInt() ?? 0,
                endedAt: Value(endedAt),
                listenedMs: Value((event['listenedMs'] as num?)?.toInt() ?? 0),
                maxPositionMs:
                    Value((event['maxPositionMs'] as num?)?.toInt() ?? 0),
                endReason: Value(event['endReason'] as String?),
                syncKey: Value(syncKey),
                originDeviceId:
                    Value(event['originDeviceId'] as String? ?? ''),
              ));
          applied++;
        } else if (endedAt > (existing.endedAt ?? 0)) {
          await (db.update(db.playEvents)
                ..where((t) => t.id.equals(existing.id)))
              .write(PlayEventsCompanion(
            endedAt: Value(endedAt),
            listenedMs: Value((event['listenedMs'] as num?)?.toInt() ?? 0),
            maxPositionMs:
                Value((event['maxPositionMs'] as num?)?.toInt() ?? 0),
            endReason: Value(event['endReason'] as String?),
          ));
          applied++;
        } else {
          skipped++;
        }
      }
    });
    if (applied > 0) _notifyChanged();
    return (applied: applied, skipped: skipped);
  }

  String _newSyncKey() {
    const hex = '0123456789abcdef';
    final buffer = StringBuffer();
    for (var i = 0; i < 32; i++) {
      buffer.write(hex[_random.nextInt(hex.length)]);
    }
    return buffer.toString();
  }

  /// 存量事件（v5 前）的确定性去重键：同一条事件在任何设备上哈希一致。
  static String _legacySyncKey(Map<String, Object?> row) {
    final content = [
      row['sourceKey'],
      row['songId'],
      row['startedAt'],
      row['endedAt'],
      row['listenedMs'],
    ].join('|');
    return 'legacy_${sha256.convert(utf8.encode(content))}';
  }

  /// 已听过的曲目名（title + artist，按最近播放排序去重）。
  ///
  /// AI 推歌的排除清单用：不按 sourceKey 去重（同一首在不同平台都一样
  /// 不该再推），由调用方做规范化去重与截断。
  Future<List<({String title, String artist})>> listPlayedTrackNames({
    int limit = 1000,
  }) async {
    final rows = await _db.customSelect('''
      SELECT title, artist, MAX(startedAt) AS lastAt
      FROM play_events
      WHERE endedAt IS NOT NULL
      GROUP BY title, artist
      ORDER BY lastAt DESC
      LIMIT ?
    ''', variables: [Variable.withInt(limit)]).get();
    return [
      for (final row in rows)
        (
          title: row.data['title'] as String? ?? '',
          artist: row.data['artist'] as String? ?? '',
        ),
    ];
  }

  /// 拆分 artist 串（`A, B` / `A/B` / `A&B` 等各计一位歌手）。
  ///
  /// 不做 feat./别名归一（原始串完整保留在事件行里）。
  static List<String> splitArtistNames(String value) {
    return [
      for (final part in value.split(RegExp(r'[,，/、&;；]')))
        if (part.trim().isNotEmpty) part.trim(),
    ];
  }

  /// 有效播放判定：委托唯一口径（[PlayStatisticsLimits.isQualified]）。
  static bool _isQualified(Object? listenedMsRaw, int? durationMs) =>
      PlayStatisticsLimits.isQualified(
        listenedMs: _intOf(listenedMsRaw),
        durationMs: durationMs,
      );

  DateTime _localDay(int startedAt) {
    final local = DateTime.fromMillisecondsSinceEpoch(startedAt);
    return DateTime(local.year, local.month, local.day);
  }

  Future<List<_StatRow>> _statsRows(int? since) async {
    final events = _db.playEvents;
    final rows = await (_db.select(events)
          ..where((t) => _countableSince(since))
          ..orderBy([(t) => OrderingTerm.asc(t.startedAt)]))
        .get();
    return [
      for (final row in rows)
        _StatRow(
          startedAt: row.startedAt,
          listenedMs: row.listenedMs,
          qualified: _isQualified(row.listenedMs, row.durationMs),
        ),
    ];
  }

  PlayEvent _eventFromRow(PlayEventRow row) => PlayEvent(
        id: row.id,
        sourceKey: row.sourceKey,
        songId: row.songId,
        title: row.title,
        artist: row.artist,
        album: row.album,
        coverUrl: row.coverUrl,
        durationMs: row.durationMs,
        raw: _decodeRaw(row.raw),
        startedAt: row.startedAt,
        endedAt: row.endedAt,
        listenedMs: row.listenedMs,
        maxPositionMs: row.maxPositionMs,
        endReason: PlayEventEndReason.fromStorage(row.endReason),
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
