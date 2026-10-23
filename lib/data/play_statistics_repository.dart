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
///
/// **曲目内容（`play_tracks`，每曲一行）**：元数据（title / artist / album /
/// coverUrl / durationMs）与取链参数（`raw`，gzip BLOB）不再逐事件复制——事件
/// 是 append-only 的，逐行复制在保留窗口（[maxRetainedEvents] 行 / 365 天）下把
/// 库顶到数十 MB（LX 脚本原样透传平台对象时单条 2–8 KB，见 ADR-0003 实测）。
/// 语义：元数据是**该曲最近一次播放时的快照**（`updatedAt` = 该次事件的内容
/// 时间，旧事件不覆盖新内容）；载荷按「最近播放」保留，超出
/// [maxRetainedPayloadBytes] 的曲目清空 `raw`（点播回退到重新解析）。
/// 读取侧统一 join 取内容；同步导出 / 日志条目在统计同步存储里按行补齐
/// （记录仍**逐条自包含**）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../domain/models/play_statistics.dart';
import 'molia_database.dart';
import 'stats_payload_codec.dart';
import 'sync/statistics_sync_store.dart';

class PlayStatisticsRepository {
  /// [databaseProvider] 仅测试注入（in-memory drift 库）；生产走
  /// [MoliaDatabase.instance]。
  ///
  /// [statisticsSync] 是同步写入点（`syncKey` / 版本戳 / 增量日志 / 导出
  /// 缓存），仓库只表达「开始 / 收尾 / 批量变更」；[clock] 提供内容时间
  /// （`endedAt`）——内容时间与版本戳刻意分开（见 ADR-0003 v2 §2）。
  PlayStatisticsRepository({
    MoliaDatabase Function()? databaseProvider,
    int Function()? clock,
    required StatisticsSyncWriter statisticsSync,
    Future<void> Function()? beforeWrite,
  })  : _databaseProvider = databaseProvider ?? (() => MoliaDatabase.instance),
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _sync = statisticsSync,
        _beforeWrite = beforeWrite {
    // 远端落地后仍需走仓库的变更流：UI 刷新与同步调度都监听这里。
    _sync.onChanged = _notifyChanged;
  }

  final MoliaDatabase Function() _databaseProvider;
  final int Function() _clock;
  final StatisticsSyncWriter _sync;

  /// 写入前的就绪门（版本戳基线种子）；null = 不需要等待（测试）。
  final Future<void> Function()? _beforeWrite;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// 统计变更广播（收尾事件 / 清空 / 遗留收尾后触发）。
  Stream<void> get changes => _changes.stream;

  MoliaDatabase get _db => _databaseProvider();

  Future<void> _ensureReady() async {
    final beforeWrite = _beforeWrite;
    if (beforeWrite != null) await beforeWrite();
  }

  void _notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// 有效播放的 SQL 判定式（durationMs 未知时按 30s 兜底）。
  ///
  /// 与 [PlayStatisticsLimits.qualifiedThresholdMs] 同口径；一致性由
  /// test/play_statistics_formula_test.dart 用同一批 fixture 行逐行对照。
  /// 用到它的查询必须 join `play_tracks`（`durationMs` 在内容表上）；SQL 里
  /// 一律以 `pt.` 限定，避免连表后列名歧义。
  static const String _qualifiedPredicate =
      'listenedMs >= CASE WHEN pt.durationMs IS NULL OR pt.durationMs <= 0 '
      'THEN ${PlayStatisticsLimits.qualifiedMinListenedMs} '
      'ELSE MIN(${PlayStatisticsLimits.qualifiedMinListenedMs}, '
      'pt.durationMs * ${PlayStatisticsLimits.qualifiedFraction}) END';

  /// 已收尾且非 error 事件的公共过滤（计数/比率/时长统一口径）。
  static const String _countablePredicate =
      "endedAt IS NOT NULL AND COALESCE(endReason, '') <> 'error'";

  // 写入（采集服务调用；所有写操作由调用方保证顺序）

  /// 开始一次播放事件，返回行 id（`endedAt` 为 null = 进行中）。
  ///
  /// 事件行（含 `syncKey` / 来源设备）与曲目内容行由同步写入点在同一事务里
  /// 创建：仓库不再自己拼同步列（见 [StatisticsSyncWriter.startEvent]）。
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
    return _sync.startEvent(
      sourceKey: sourceKey,
      songId: songId,
      title: title,
      artist: artist,
      album: album,
      coverUrl: coverUrl,
      durationMs: durationMs,
      raw: raw,
      startedAt: startedAt,
    );
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
  ///
  /// `endedAt` 是内容时间（何时结束），版本戳由同步存储在同一事务里现取：
  /// 跨设备「同键晚收尾覆盖」按版本判定，而不是拿 `endedAt` 当时间戳。
  Future<void> finishEvent(
    int id, {
    required PlayEventEndReason reason,
    required int listenedMs,
    required int maxPositionMs,
    int? endedAt,
  }) async {
    await _ensureReady();
    await _db.transaction(() async {
      await (_db.update(_db.playEvents)..where((t) => t.id.equals(id)))
          .write(PlayEventsCompanion(
        endedAt: Value(endedAt ?? _clock()),
        listenedMs: Value(listenedMs),
        maxPositionMs: Value(maxPositionMs),
        endReason: Value(reason.storageValue),
      ));
      // 版本戳 + 增量日志与内容写入同事务（崩溃不出现「数据落了、日志没落」）。
      await _sync.stampFinishedEvent(_db, id);
    });
    // 导出的已收尾集合发生变化：指纹推进（与缓存是否加载无关）。
    await _sync.noteEventExported(id);
    _notifyChanged();
  }

  /// 收尾进程被杀等外部中断遗留的进行中事件。
  ///
  /// `endedAt` 取 `startedAt + listenedMs`（最后落盘进度，确定性可测）。
  /// 返回收尾行数。版本戳整批取一个（各行键不同，LWW 只在同键间比较）。
  Future<int> closeStaleEvents() async {
    await _ensureReady();
    var closed = 0;
    await _db.transaction(() async {
      // 先取遗留行 id：收尾后要按行追加增量日志（内容变化必须可同步）。
      final staleIds = [
        for (final row in await (_db.select(_db.playEvents)
              ..where((t) => t.endedAt.isNull()))
            .get())
          row.id,
      ];
      if (staleIds.isEmpty) return;
      closed = await _db.customUpdate(
        'UPDATE play_events SET endedAt = startedAt + listenedMs, endReason = ? '
        'WHERE endedAt IS NULL',
        variables: [
          Variable.withString(PlayEventEndReason.interrupted.storageValue),
        ],
        updates: {_db.playEvents},
      );
      // 整批取一个版本戳并按行追加日志（与内容写入同事务）。
      await _sync.stampClosedEvents(_db, staleIds);
    });
    if (closed > 0) {
      // 批量把进行中行变成已收尾：导出集合整体重建（一次性）。
      _sync.noteExportInvalidated();
      _notifyChanged();
    }
    return closed;
  }

  /// 清空全部统计事件与曲目内容（不可撤销）。
  Future<void> clearAll() async {
    // 先事件后内容：`play_events.trackId` 是 ON DELETE RESTRICT。
    await _db.delete(_db.playEvents).go();
    await _db.delete(_db.playTracks).go();
    _sync.noteExportInvalidated();
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
            THEN trackId END) AS uniqueTracks,
        SUM(CASE WHEN endReason = 'completed' THEN 1 ELSE 0 END) AS completedCount,
        SUM(CASE WHEN endReason = 'skipped' AND NOT ($_qualifiedPredicate)
            THEN 1 ELSE 0 END) AS skippedUnqualifiedCount
      FROM play_events e
      JOIN play_tracks pt ON pt.id = e.trackId
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
    final (
      summaryResult,
      trackResult,
      artistResult,
      dayResult,
      weekdayHourResult,
      sourceResult
    ) = await (
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
    final row = await _db
        .customSelect(
          'SELECT MIN(startedAt) AS firstAt FROM play_events '
          "WHERE endedAt IS NOT NULL AND COALESCE(endReason, '') <> 'error'",
        )
        .getSingle();
    return row.data['firstAt'] as int?;
  }

  /// Top 曲目（有效播放次数排序；只出现至少一次有效播放的曲目）。
  Future<List<PlayStatTrackEntry>> topTracks({
    int? since,
    int limit = 10,
  }) async {
    final rows = await _db.customSelect('''
      SELECT
        pt.sourceKey AS sourceKey,
        pt.songId AS songId,
        MAX(pt.title) AS title,
        MAX(pt.artist) AS artist,
        MAX(pt.album) AS album,
        MAX(pt.coverUrl) AS coverUrl,
        MAX(pt.durationMs) AS durationMs,
        -- 载荷每曲一份（内容表一行）：MAX 取到的就是那一份；NULL = 无载荷
        -- （未提供 / 已被载荷预算清掉）→ 点播走重新解析。
        MAX(pt.raw) AS raw,
        SUM(CASE WHEN ($_qualifiedPredicate) THEN 1 ELSE 0 END) AS playCount,
        COALESCE(SUM(listenedMs), 0) AS listenedMs,
        MAX(startedAt) AS lastPlayedAt
      FROM play_events e
      JOIN play_tracks pt ON pt.id = e.trackId
      WHERE $_countablePredicate${since != null ? ' AND startedAt >= ?' : ''}
      GROUP BY e.trackId
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
  ///
  /// 逐事件的有效判定与求和下沉到 SQL（按原始 artist 串分组）：20k 事件
  /// 保留窗口下避免把整张事件表读进 Dart 再逐行聚合。Dart 只做拆分合并与
  /// 排序——同一原始串拆出的歌手各得一份该组的计数 / 时长。
  Future<List<PlayStatArtistEntry>> topArtists({
    int? since,
    int limit = 10,
  }) async {
    final rows = await _db.customSelect('''
      SELECT
        pt.artist AS artist,
        SUM(CASE WHEN ($_qualifiedPredicate) THEN 1 ELSE 0 END) AS playCount,
        COALESCE(SUM(CASE WHEN ($_qualifiedPredicate) THEN e.listenedMs ELSE 0 END), 0)
            AS listenedMs
      FROM play_events e
      JOIN play_tracks pt ON pt.id = e.trackId
      WHERE $_countablePredicate${since != null ? ' AND e.startedAt >= ?' : ''}
      GROUP BY pt.artist
      HAVING playCount > 0
    ''', variables: [if (since != null) Variable.withInt(since)]).get();
    final counts = <String, int>{};
    final listened = <String, int>{};
    for (final row in rows) {
      final playCount = _intOf(row.data['playCount']);
      final listenedMs = _intOf(row.data['listenedMs']);
      // 空串拆不出名字（自然无贡献），与逐事件过滤等价。
      for (final name
          in splitArtistNames(row.data['artist'] as String? ?? '')) {
        counts[name] = (counts[name] ?? 0) + playCount;
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
        pt.sourceKey AS sourceKey,
        COALESCE(SUM(listenedMs), 0) AS listenedMs,
        SUM(CASE WHEN ($_qualifiedPredicate) THEN 1 ELSE 0 END) AS playCount
      FROM play_events e
      JOIN play_tracks pt ON pt.id = e.trackId
      WHERE $_countablePredicate${since != null ? ' AND startedAt >= ?' : ''}
      GROUP BY pt.sourceKey
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
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    final rows = await _db.customSelect(
      '$playEventTrackSelect WHERE $_countablePredicate '
      'AND e.startedAt >= ? AND e.startedAt < ? '
      'ORDER BY e.startedAt ASC, e.id ASC',
      variables: [
        Variable.withInt(start.millisecondsSinceEpoch),
        Variable.withInt(end.millisecondsSinceEpoch),
      ],
    ).get();
    final playEvents = [
      for (final row in rows) _eventFromQueryRow(row.data),
    ];
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
    final rows = await _db.customSelect(
      '$playEventTrackSelect WHERE e.endedAt IS NOT NULL '
      'ORDER BY e.startedAt DESC, e.id DESC LIMIT ?',
      variables: [Variable.withInt(limit)],
    ).get();
    return [for (final row in rows) _eventFromQueryRow(row.data)];
  }

  /// 事件保留上限：行数上限 + 保留时长（超出即裁剪已收尾事件）。
  ///
  /// 统计口径全部「查询时计算」，裁剪只影响「全部」范围的可见历史；同步侧
  /// 的导出缓存 / 引擎指纹 / 每轮合并都是 O(已保留行数)，不设上限会随库龄
  /// 线性变慢。当前是快速演进的测试项目，不做长期数据保留承诺。
  static const int maxRetainedEvents = 20000;
  static const Duration eventRetention = Duration(days: 365);

  /// 载荷（gzip 后）总量预算：超出按「最近播放」（`updatedAt` 降序）保留，
  /// 其余曲目清空 `raw`。
  ///
  /// 兜底用途：单条载荷大小由脚本决定（原样透传平台对象 2–8 KB；病态脚本
  /// 可以更大），行数上限约束不了字节。清空只影响「点播参数」——历史 / 计数 /
  /// 明细都不变，点播回退到重新解析；下次播放该曲会带回载荷。
  static const int maxRetainedPayloadBytes = 16 * 1024 * 1024;

  /// 裁剪超出保留上限的已收尾事件；返回删除行数。
  ///
  /// 启动维护调用（与 [closeStaleEvents] 同一时机）。除事件裁剪外还做两件
  /// 收尾：内容行 GC（没有任何事件引用的曲目）与载荷字节预算裁剪。
  Future<int> pruneOldEvents({
    int? maxRows,
    Duration? retention,
    int? maxPayloadBytes,
  }) async {
    final keep = maxRows ?? maxRetainedEvents;
    final window = retention ?? eventRetention;
    final payloadBudget = maxPayloadBytes ?? maxRetainedPayloadBytes;
    final cutoff = _clock() - window.inMilliseconds;
    var deleted = 0;
    var tracksDropped = 0;
    var payloadsCleared = 0;
    await _db.transaction(() async {
      deleted += await _db.customUpdate(
        'DELETE FROM play_events WHERE endedAt IS NOT NULL AND endedAt < ?',
        variables: [Variable.withInt(cutoff)],
        updates: {_db.playEvents},
      );
      if (keep > 0) {
        deleted += await _db.customUpdate(
          'DELETE FROM play_events WHERE endedAt IS NOT NULL AND id NOT IN ('
          'SELECT id FROM play_events WHERE endedAt IS NOT NULL '
          'ORDER BY startedAt DESC LIMIT ?)',
          variables: [Variable.withInt(keep)],
          updates: {_db.playEvents},
        );
      }
      // 内容行 GC：该曲事件全被裁掉（或从未有事件）→ 删除内容行。
      tracksDropped = await _db.customUpdate(
        'DELETE FROM play_tracks WHERE id NOT IN ('
        'SELECT DISTINCT trackId FROM play_events)',
        updates: {_db.playTracks},
      );
      // 载荷字节预算：按最近播放保留，超出即清空（最坏情况兜底）。
      final holders = await _db
          .customSelect(
            'SELECT id, LENGTH(raw) AS bytes FROM play_tracks '
            'WHERE raw IS NOT NULL ORDER BY updatedAt DESC, id DESC',
          )
          .get();
      var remaining = payloadBudget;
      final drop = <int>[];
      for (final row in holders) {
        final bytes = (row.data['bytes'] as num?)?.toInt() ?? 0;
        if (bytes <= remaining) {
          remaining -= bytes;
        } else {
          drop.add((row.data['id'] as num).toInt());
        }
      }
      if (drop.isNotEmpty) {
        payloadsCleared = await _db.customUpdate(
          'UPDATE play_tracks SET raw = NULL WHERE id IN ('
          '${List.filled(drop.length, '?').join(', ')})',
          variables: [for (final id in drop) Variable.withInt(id)],
          updates: {_db.playTracks},
        );
      }
    });
    if (deleted > 0 || tracksDropped > 0 || payloadsCleared > 0) {
      _sync.noteExportInvalidated();
      _notifyChanged();
    }
    return deleted;
  }

  /// 已听过的曲目名（title + artist，按最近播放排序去重）。
  ///
  /// AI 推歌的排除清单用：不按 sourceKey 去重（同一首在不同平台都一样
  /// 不该再推），由调用方做规范化去重与截断。
  Future<List<({String title, String artist})>> listPlayedTrackNames({
    int limit = 1000,
  }) async {
    final rows = await _db.customSelect('''
      SELECT pt.title AS title, pt.artist AS artist,
             MAX(e.startedAt) AS lastAt
      FROM play_events e
      JOIN play_tracks pt ON pt.id = e.trackId
      WHERE e.endedAt IS NOT NULL
      GROUP BY pt.title, pt.artist
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
    final rows = await _db.customSelect(
      'SELECT e.startedAt AS startedAt, e.listenedMs AS listenedMs, '
      'pt.durationMs AS durationMs FROM play_events e '
      'JOIN play_tracks pt ON pt.id = e.trackId '
      'WHERE $_countablePredicate${since != null ? ' AND e.startedAt >= ?' : ''} '
      'ORDER BY e.startedAt ASC',
      variables: [if (since != null) Variable.withInt(since)],
    ).get();
    return [
      for (final row in rows)
        _StatRow(
          startedAt: _intOf(row.data['startedAt']),
          listenedMs: _intOf(row.data['listenedMs']),
          qualified: _isQualified(
            row.data['listenedMs'],
            (row.data['durationMs'] as num?)?.toInt(),
          ),
        ),
    ];
  }

  /// 明细查询行（[playEventTrackSelect]：事件 + 曲目内容）→ 领域事件。
  static PlayEvent _eventFromQueryRow(Map<String, Object?> row) => PlayEvent(
        id: (row['id'] as num?)?.toInt() ?? 0,
        sourceKey: row['sourceKey'] as String? ?? '',
        songId: row['songId'] as String? ?? '',
        title: row['title'] as String? ?? '',
        artist: row['artist'] as String? ?? '',
        album: row['album'] as String? ?? '',
        coverUrl: row['coverUrl'] as String?,
        durationMs: (row['durationMs'] as num?)?.toInt(),
        raw: _decodeRaw(row['raw']),
        startedAt: (row['startedAt'] as num?)?.toInt() ?? 0,
        endedAt: (row['endedAt'] as num?)?.toInt(),
        listenedMs: (row['listenedMs'] as num?)?.toInt() ?? 0,
        maxPositionMs: (row['maxPositionMs'] as num?)?.toInt() ?? 0,
        endReason: PlayEventEndReason.fromStorage(row['endReason'] as String?),
      );

  static int _intOf(Object? value) => (value as num?)?.toInt() ?? 0;

  /// 载荷 → JSON 映射：gzip BLOB（v5 起）或文本（迁移期 / 直接注入的占位）。
  static Map<String, dynamic> _decodeRaw(Object? raw) {
    final json = raw is String ? raw : decodeStatsPayload(raw);
    if (json.isEmpty) return const {};
    try {
      final decoded = jsonDecode(json);
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
