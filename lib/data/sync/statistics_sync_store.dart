/// 听歌统计的同步存储：`play_events` 已收尾事件的类型化导出、
/// 本地曲目过滤与按 `syncKey` 合并。
///
/// 为什么单独成模块：统计仓库只该关心「事件怎么采集、怎么查询」，而
/// `syncKey` / 版本列 / 增量日志 / 导出缓存是同步协议的形状。把它们收在
/// 这里，适配器只映射类型化记录，仓库不再 import 同步模型。
///
/// 写入点约定：
/// - 本机收尾在**数据写入的同一事务**里调 [stampFinishedEvent] /
///   [stampClosedEvents]（版本戳 + 增量日志）；
/// - 事务提交后再调 [noteEventExported] 维护导出缓存；批量改动（清空 /
///   裁剪 / 应用远端）用 [noteExportInvalidated]。
library;

import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';

import '../../domain/models/device_sync.dart';
import '../../domain/ports/statistics_sync_store.dart';
import '../molia_database.dart';
import '../stats_payload_codec.dart';
import 'sync_journal.dart';
import 'sync_stamp.dart';

/// 事件 + 曲目内容的连表查询列集合（同步导出 / 明细查询共用）。
///
/// 键名与线上记录一致——线上格式不变；`trackId` 留在查询里供导出
/// 缓存按曲补齐载荷，写记录前会剥掉。
const String playEventTrackSelect = 'SELECT '
    'e.id, e.trackId, e.startedAt, e.endedAt, e.listenedMs, e.maxPositionMs, '
    'e.endReason, e.syncKey, e.originDeviceId, e.versionPhysical, '
    'e.versionCounter, '
    'pt.sourceKey, pt.songId, pt.title, pt.artist, pt.album, pt.coverUrl, '
    'pt.durationMs, pt.raw '
    'FROM play_events e LEFT JOIN play_tracks pt ON pt.id = e.trackId';

/// 取（或建）曲目内容行，返回 `trackId`。
///
/// 统计采集与同步落地的内容语义必须一致（内容每曲一行、取最近一次播放），
/// 因此放在同步存储旁边由两边共用，避免各写一份后分叉。
///
/// [payload] 为 null 表示**不覆盖载荷**（远端记录没带 raw 时，别把本机已有
/// 的取链参数抹掉）。[updatedAt] 是内容时间：远端补发的旧事件不该把新内容
/// 顶掉（门在 `updatedAt >= existing.updatedAt`）。
Future<int> upsertPlayTrackContent(
  MoliaDatabase db, {
  required String sourceKey,
  required String songId,
  required String title,
  required String artist,
  required String album,
  required String? coverUrl,
  required int? durationMs,
  required String? payload,
  required int updatedAt,
}) async {
  final existing = await (db.select(db.playTracks)
        ..where(
          (t) => t.sourceKey.equals(sourceKey) & t.songId.equals(songId),
        )
        ..limit(1))
      .getSingleOrNull();
  if (existing == null) {
    return db.into(db.playTracks).insert(
          PlayTracksCompanion.insert(
            sourceKey: sourceKey,
            songId: songId,
            title: Value(title),
            artist: Value(artist),
            album: Value(album),
            coverUrl: Value(coverUrl),
            durationMs: Value(durationMs),
            raw: Value(payload == null ? null : encodeStatsPayload(payload)),
            updatedAt: updatedAt,
          ),
        );
  }
  if (updatedAt >= existing.updatedAt) {
    await (db.update(
      db.playTracks,
    )..where((t) => t.id.equals(existing.id)))
        .write(
      PlayTracksCompanion(
        title: Value(title),
        artist: Value(artist),
        album: Value(album),
        coverUrl: Value(coverUrl),
        durationMs: Value(durationMs),
        // payload == null：不覆盖载荷（远端记录没带 raw 时不抹掉已有取链参数）。
        raw: payload == null
            ? const Value.absent()
            : Value(encodeStatsPayload(payload)),
        updatedAt: Value(updatedAt),
      ),
    );
  }
  return existing.id;
}

/// 听歌统计的同步写入点：仓库只通过它落同步列与版本戳 / 增量日志。
///
/// 为什么单独成 seam：仓库不该知道 `syncKey` / 版本列 / 日志的形状，也不该
/// 直接写这些列；`stamp*` 又必须在仓库的 drift 事务里执行（版本戳与增量
/// 日志要和内容写入同事务），所以接口放在数据层、签名带 drift 执行器。
/// 读取面（导出 / 应用）由 [StatisticsSyncStore] 提供给适配器。
abstract interface class StatisticsSyncWriter {
  /// 应用远端记录后通知仓库广播（UI 刷新 / 同步调度标记）。
  set onChanged(void Function()? callback);

  /// 创建一条进行中事件（含内容行 upsert、`syncKey` 与来源设备），返回行 id。
  ///
  /// 事务由实现负责：仓库只表达「开始一次播放」，不再自己拼同步列。
  Future<int> startEvent({
    required String sourceKey,
    required String songId,
    required String title,
    required String artist,
    required String album,
    required String? coverUrl,
    required int? durationMs,
    required Map<String, dynamic> raw,
    required int startedAt,
  });

  /// 收尾事件：在数据写入的同一事务里补版本戳并追加增量日志。
  Future<void> stampFinishedEvent(DatabaseConnectionUser executor, int eventId);

  /// 启动收尾遗留事件：整批取一个版本戳，并在同一事务里为每行追加日志。
  Future<void> stampClosedEvents(
    DatabaseConnectionUser executor,
    List<int> eventIds,
  );

  /// 单条事件收尾后的导出缓存增量维护（事务提交后调用）。
  Future<void> noteEventExported(int eventId);

  /// 批量 / 整体改动（清空、裁剪、收尾遗留）后推进指纹并让缓存整体失效。
  void noteExportInvalidated();
}

/// 统计同步面的 drift 实现（生产库 / 测试 in-memory 库同一套 SQL）。
///
/// 同时实现读取面（适配器）与写入面（仓库）：两个 seam 的调用方各自只
/// 依赖需要的那个接口，具体类只在组合根相遇。
class SqliteStatisticsSyncStore
    implements StatisticsSyncStore, StatisticsSyncWriter {
  SqliteStatisticsSyncStore({
    MoliaDatabase Function()? databaseProvider,
    required this._stamps,
    this._journal,
  })  : _databaseProvider = databaseProvider ?? (() => MoliaDatabase.instance);

  final MoliaDatabase Function() _databaseProvider;

  /// 版本戳唯一发号器（与写入点共用同一实例）。
  final SyncStampIssuer _stamps;

  /// 增量日志（可选）：本机收尾事件在同一事务里追加。
  final SyncJournalRepository? _journal;

  final Random _random = Random.secure();

  /// 应用远端记录后通知仓库广播（UI 刷新 / 同步调度标记）。
  ///
  /// 由 [PlayStatisticsRepository] 在构造时接入；store 不反向依赖仓库。
  @override
  void Function()? onChanged;

  /// 同步导出缓存：`null` = 未加载（下次导出全量读一次）。
  ///
  /// 写入点按 id 增量维护，避免每首歌收尾都全表重读；载荷按曲另存
  /// （[_exportPayloads]），缓存行里不留大字段。
  Map<int, _CachedEvent>? _exportRows;
  List<StatisticsSyncEvent>? _exportList;
  Map<int, String>? _exportPayloads;

  /// 导出变更计数（[syncFingerprint] 的廉价指纹来源）。
  int _syncRevision = 0;

  MoliaDatabase get _db => _databaseProvider();

  /// 本机设备 id（与发号器同一来源，保证事件来源与版本一致）。
  String get _deviceId => _stamps.deviceId;

  /// 新事件去重键（32 位十六进制随机串）。
  String _newEventSyncKey() {
    const hex = '0123456789abcdef';
    final buffer = StringBuffer();
    for (var i = 0; i < 32; i++) {
      buffer.write(hex[_random.nextInt(hex.length)]);
    }
    return buffer.toString();
  }

  /// 创建一条进行中事件：同事务 upsert 内容行 + 写入事件行（含同步列）。
  @override
  Future<int> startEvent({
    required String sourceKey,
    required String songId,
    required String title,
    required String artist,
    required String album,
    required String? coverUrl,
    required int? durationMs,
    required Map<String, dynamic> raw,
    required int startedAt,
  }) {
    final db = _db;
    return db.transaction(() async {
      final trackId = await upsertPlayTrackContent(
        db,
        sourceKey: sourceKey,
        songId: songId,
        title: title,
        artist: artist,
        album: album,
        coverUrl: coverUrl,
        durationMs: durationMs,
        payload: jsonEncode(raw),
        updatedAt: startedAt,
      );
      return db.into(db.playEvents).insert(
            PlayEventsCompanion.insert(
              trackId: trackId,
              startedAt: startedAt,
              endedAt: const Value(null),
              listenedMs: const Value(0),
              maxPositionMs: const Value(0),
              endReason: const Value(null),
              syncKey: _newEventSyncKey(),
              originDeviceId: Value(_deviceId),
            ),
          );
    });
  }

  /// 收尾事件：在数据写入的同一事务里补版本戳并追加增量日志。
  ///
  /// 调用前事件内容（`endedAt` / 进度 / 原因）已写好；这里只碰同步列，
  /// 让统计仓库不再 import 发号器与日志模型。
  @override
  Future<void> stampFinishedEvent(
    DatabaseConnectionUser executor,
    int eventId,
  ) async {
    final version = _stamps.next();
    await (executor.update(
      _db.playEvents,
    )..where((t) => t.id.equals(eventId)))
        .write(
      PlayEventsCompanion(
        versionPhysical: Value(version.physical),
        versionCounter: Value(version.counter),
      ),
    );
    await _appendEventJournal(executor, eventId);
  }

  /// 启动收尾遗留事件：整批取一个版本戳（各行键不同，LWW 只在同键间比较），
  /// 并在同一事务里为每行追加日志。
  @override
  Future<void> stampClosedEvents(
    DatabaseConnectionUser executor,
    List<int> eventIds,
  ) async {
    if (eventIds.isEmpty) return;
    final version = _stamps.next();
    final db = _db;
    await (executor.update(
      db.playEvents,
    )..where((t) => t.id.isIn(eventIds)))
        .write(
      PlayEventsCompanion(
        versionPhysical: Value(version.physical),
        versionCounter: Value(version.counter),
      ),
    );
    final journal = _journal;
    if (journal == null) return;
    final changes = <SyncJournalChange>[];
    for (final id in eventIds) {
      final change = await _eventJournalChange(executor, id);
      if (change != null) changes.add(change);
    }
    if (changes.isNotEmpty) await journal.append(executor, changes);
  }

  /// 单条事件收尾后的导出缓存增量维护（事务提交后调用）。
  @override
  Future<void> noteEventExported(int eventId) async {
    _syncRevision++;
    await _exportUpsert(eventId);
  }

  /// 批量 / 整体改动（清空、裁剪、收尾遗留）后推进指纹并让缓存整体失效。
  @override
  void noteExportInvalidated() {
    _syncRevision++;
    _exportInvalidate();
  }

  /// 同步导出的廉价指纹（本进程内的导出变更计数）。
  ///
  /// 跨进程一致本就无需要求：适配器的缓存不跨进程，重启后首次 collect
  /// 全量重读。每轮对已收尾事件做全表聚合会随库龄线性增长，故用计数。
  @override
  Future<String> syncFingerprint() async => 'r$_syncRevision';

  @override
  Future<List<StatisticsSyncEvent>> syncExportEvents() async {
    final cached = _exportList;
    if (cached != null) return cached;
    final rows = await _loadExportRows();
    _exportRows = rows;
    final payloads = _exportPayloads ?? const <int, String>{};
    // 按曲补齐载荷：同一份字符串按引用共享（只复制记录对象）；本地下载
    // 曲目的事件在导出侧过滤（文件是设备本机副本，对端无法复现）。
    _exportList = List.unmodifiable([
      for (final entry in rows.values)
        if (!entry.event.isLocal)
          entry.event.withRaw(payloads[entry.trackId] ?? ''),
    ]);
    return _exportList!;
  }

  /// 全量加载导出缓存；只在首次导出 / 缓存失效后执行。
  Future<Map<int, _CachedEvent>> _loadExportRows() async {
    final db = _db;
    final rows = await db
        .customSelect('$playEventTrackSelect WHERE e.endedAt IS NOT NULL')
        .get();
    final payloads = <int, String>{};
    final result = <int, _CachedEvent>{};
    for (final row in rows) {
      final data = row.data;
      final id = (data['id'] as num?)?.toInt() ?? -1;
      final trackId = (data['trackId'] as num?)?.toInt() ?? -1;
      final payload = decodeStatsPayload(data['raw']);
      if (payload.isNotEmpty) payloads[trackId] = payload;
      result[id] = _CachedEvent(
        trackId: trackId,
        event: _eventFromRow(
          data,
          syncKey: data['syncKey'] as String? ?? '',
          raw: '',
        ),
      );
    }
    _exportPayloads = payloads;
    return result;
  }

  /// 导出缓存按 id 增量更新（缓存未加载时空操作：下次导出全量读一次）。
  Future<void> _exportUpsert(int id) async {
    if (_exportRows == null) return;
    final row = await _db.customSelect(
      '$playEventTrackSelect WHERE e.id = ?',
      variables: [Variable.withInt(id)],
    ).getSingleOrNull();
    if (row == null || row.data['endedAt'] == null) {
      _exportRemove(id);
      return;
    }
    final data = row.data;
    final syncKey = data['syncKey'] as String? ?? '';
    final trackId = (data['trackId'] as num?)?.toInt() ?? -1;
    final payload = decodeStatsPayload(data['raw']);
    if (payload.isNotEmpty) {
      // 本曲当前载荷（内容行是唯一来源）：刷新按曲表，导出时共享这一份。
      _exportPayloads?[trackId] = payload;
    }
    _exportRows![id] = _CachedEvent(
      trackId: trackId,
      event: _eventFromRow(data, syncKey: syncKey, raw: ''),
    );
    _exportList = null;
  }

  void _exportRemove(int id) {
    if (_exportRows?.remove(id) != null) {
      _exportList = null;
    }
  }

  void _exportInvalidate() {
    _exportRows = null;
    _exportList = null;
    _exportPayloads = null;
  }

  /// 同步应用：按 `syncKey` 去重合并；同键已存在且远端**版本更新**时覆盖
  /// 进度（进程被杀后由启动收尾补完的事件会晚于首次同步）。
  ///
  /// `endedAt` 是内容时间，不参与胜负判定：版本 = `versionPhysical +
  /// versionCounter + originDeviceId`（见 ADR-0003 v2 §2）。
  @override
  Future<({int applied, int skipped})> syncApplyEvents(
    List<StatisticsSyncEvent> events,
  ) async {
    if (events.isEmpty) return (applied: 0, skipped: 0);
    final db = _db;
    var applied = 0;
    var skipped = 0;
    final appliedIds = <int>[];
    await db.transaction(() async {
      for (final event in events) {
        final endedAt = event.endedAt;
        // 本地下载曲目的事件不落地（对端文件在本机不存在）；损坏记录
        // （缺键 / 缺结束时间）同样跳过。
        if (event.syncKey.isEmpty || endedAt == null || event.isLocal) {
          skipped++;
          continue;
        }
        // 内容行按内容时间取新（远端记录自包含：元数据 + 载荷；没带载荷时
        // 不覆盖本机已有的取链参数）。
        final trackId = await upsertPlayTrackContent(
          db,
          sourceKey: event.sourceKey,
          songId: event.songId,
          title: event.title,
          artist: event.artist,
          album: event.album,
          coverUrl: event.coverUrl,
          durationMs: event.durationMs,
          payload: event.raw.isEmpty ? null : event.raw,
          updatedAt: event.startedAt,
        );
        final existing = await (db.select(db.playEvents)
              ..where((t) => t.syncKey.equals(event.syncKey))
              ..limit(1))
            .getSingleOrNull();
        if (existing == null) {
          final id = await db.into(db.playEvents).insert(
                PlayEventsCompanion.insert(
                  trackId: trackId,
                  startedAt: event.startedAt,
                  endedAt: Value(endedAt),
                  listenedMs: Value(event.listenedMs),
                  maxPositionMs: Value(event.maxPositionMs),
                  endReason: Value(event.endReason),
                  syncKey: event.syncKey,
                  originDeviceId: Value(event.version.deviceId),
                  versionPhysical: Value(event.version.physical),
                  versionCounter: Value(event.version.counter),
                ),
              );
          appliedIds.add(id);
          applied++;
        } else if (event.version.isNewerThan(existing.syncVersion) ||
            (!event.version.isOlderThan(existing.syncVersion) &&
                !_eventMatches(existing, event))) {
          // 同版本也应用（修复被直接改写的本地事件行）；内容一致则跳过。
          await (db.update(
            db.playEvents,
          )..where((t) => t.id.equals(existing.id)))
              .write(
            PlayEventsCompanion(
              endedAt: Value(endedAt),
              listenedMs: Value(event.listenedMs),
              maxPositionMs: Value(event.maxPositionMs),
              endReason: Value(event.endReason),
              versionPhysical: Value(event.version.physical),
              versionCounter: Value(event.version.counter),
            ),
          );
          appliedIds.add(existing.id);
          applied++;
        } else {
          skipped++;
        }
      }
    });
    if (applied > 0) {
      _syncRevision++;
      // 导出缓存增量维护：落地行数少时逐行刷新，批量落地（备份恢复）整体失效。
      if (appliedIds.length <= 64) {
        for (final id in appliedIds) {
          await _exportUpsert(id);
        }
      } else {
        _exportInvalidate();
      }
      onChanged?.call();
    }
    return (applied: applied, skipped: skipped);
  }

  /// 已收尾事件 → 增量日志条目（形状与导出记录一致、记录自包含）。
  ///
  /// 返回 null = 事件不存在 / 未收尾 / 缺去重键（不该被同步的行）。
  Future<SyncJournalChange?> _eventJournalChange(
    DatabaseConnectionUser executor,
    int id,
  ) async {
    final row = await executor.customSelect(
      '$playEventTrackSelect WHERE e.id = ?',
      variables: [Variable.withInt(id)],
    ).getSingleOrNull();
    if (row == null || row.data['endedAt'] == null) return null;
    final syncKey = row.data['syncKey'] as String? ?? '';
    if (syncKey.isEmpty) return null;
    final event = _eventFromRow(row.data, syncKey: syncKey);
    return (
      category: SyncCategory.statistics,
      record: SyncRecord(
        key: syncKey,
        version: event.version,
        data: event.toData(),
      ),
    );
  }

  Future<void> _appendEventJournal(
    DatabaseConnectionUser executor,
    int id,
  ) async {
    final journal = _journal;
    if (journal == null) return;
    final change = await _eventJournalChange(executor, id);
    if (change == null) return;
    await journal.append(executor, [change]);
  }

  /// 查询行 → 类型化事件（载荷默认解码为 JSON 文本；导出缓存传空串占位）。
  static StatisticsSyncEvent _eventFromRow(
    Map<String, Object?> row, {
    required String syncKey,
    String? raw,
  }) =>
      StatisticsSyncEvent(
        syncKey: syncKey,
        version: SyncVersion(
          physical: (row['versionPhysical'] as num?)?.toInt() ?? 0,
          counter: (row['versionCounter'] as num?)?.toInt() ?? 0,
          deviceId: row['originDeviceId'] as String? ?? '',
        ),
        sourceKey: row['sourceKey'] as String? ?? '',
        songId: row['songId'] as String? ?? '',
        title: row['title'] as String? ?? '',
        artist: row['artist'] as String? ?? '',
        album: row['album'] as String? ?? '',
        coverUrl: row['coverUrl'] as String?,
        durationMs: (row['durationMs'] as num?)?.toInt(),
        raw: raw ?? decodeStatsPayload(row['raw']),
        startedAt: (row['startedAt'] as num?)?.toInt() ?? 0,
        endedAt: (row['endedAt'] as num?)?.toInt(),
        listenedMs: (row['listenedMs'] as num?)?.toInt() ?? 0,
        maxPositionMs: (row['maxPositionMs'] as num?)?.toInt() ?? 0,
        endReason: row['endReason'] as String?,
      );

  /// 同版本内容比较（全量快照修复被直接改写的行；内容一致则跳过）。
  static bool _eventMatches(PlayEventRow row, StatisticsSyncEvent event) =>
      row.endedAt == event.endedAt &&
      row.listenedMs == event.listenedMs &&
      row.maxPositionMs == event.maxPositionMs &&
      row.endReason == event.endReason;
}

/// 导出缓存的一项：记录 + 本机曲目行 id（仅用于按曲补齐载荷，不进线上记录）。
class _CachedEvent {
  const _CachedEvent({required this.trackId, required this.event});

  final int trackId;
  final StatisticsSyncEvent event;
}
