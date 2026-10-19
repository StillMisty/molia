import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/data/stats_payload_codec.dart';
import 'package:molia/data/sync/statistics_sync_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'package:molia/domain/ports/statistics_sync_store.dart';
import 'support/sync_test_support.dart';

import 'support/memory_database.dart';

/// 听歌统计仓库测试：drift in-memory 库（schema 与生产一致）。
void main() {
  late MoliaDatabase db;
  late PlayStatisticsRepository repository;
  late SqliteStatisticsSyncStore statisticsSync;

  /// 直接插入已收尾 / 进行中事件（查询测试用，绕开采集服务）。
  Future<int> insertEvent({
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
  }) =>
      insertPlayEvent(
        db,
        sourceKey: sourceKey,
        songId: songId,
        title: title,
        artist: artist,
        album: album,
        coverUrl: coverUrl,
        durationMs: durationMs,
        raw: raw,
        startedAt: startedAt,
        listenedMs: listenedMs,
        maxPositionMs: maxPositionMs,
        endReason: endReason,
        endedAt: endedAt,
        syncKey: syncKey,
      );

  setUp(() async {
    db = openMemoryDatabase();
    statisticsSync = testStatisticsSyncStore(() => db);
    repository = PlayStatisticsRepository(
      databaseProvider: () => db,
      statisticsSync: statisticsSync,
    );
  });

  tearDown(() async {
    await repository.dispose();
    await db.close();
  });

  group('写入与收尾', () {
    test('startEvent → touchEvent → finishEvent 往返，收尾广播变更', () async {
      final changes = <void>[];
      final subscription = repository.changes.listen(changes.add);

      final id = await repository.startEvent(
        sourceKey: 'kw',
        songId: '7',
        title: '曲目',
        artist: '歌手',
        album: '专辑',
        durationMs: 180000,
        raw: const {'rid': 7},
        startedAt: 1000,
      );
      expect(id, greaterThan(0));

      await repository.touchEvent(id, listenedMs: 12000, maxPositionMs: 13000);
      var row = (await tableRows(db, 'play_events')).single;
      expect(row['endedAt'], isNull);
      expect(row['listenedMs'], 12000);
      expect(row['maxPositionMs'], 13000);
      // 载荷在内容行上（schema v5），按 gzip 存。
      expect(
        decodeStatsPayload((await tableRows(db, 'play_tracks')).single['raw']),
        '{"rid":7}',
      );
      expect(changes, isEmpty, reason: '进行中事件不广播');

      await repository.finishEvent(
        id,
        reason: PlayEventEndReason.completed,
        listenedMs: 180000,
        maxPositionMs: 180500,
        endedAt: 5000,
      );
      row = (await tableRows(db, 'play_events')).single;
      expect(row['endedAt'], 5000);
      expect(row['endReason'], 'completed');
      expect(changes, hasLength(1));

      await subscription.cancel();
    });

    test('closeStaleEvents 收尾遗留事件为 interrupted', () async {
      final id = await repository.startEvent(
        sourceKey: 'wy',
        songId: '1',
        title: 'T',
        startedAt: 1000,
      );
      await repository.touchEvent(id, listenedMs: 4000, maxPositionMs: 4000);

      expect(await repository.closeStaleEvents(), 1);
      final row = (await tableRows(db, 'play_events')).single;
      expect(row['endedAt'], 5000, reason: 'endedAt = startedAt + listenedMs');
      expect(row['endReason'], 'interrupted');
      expect(await repository.closeStaleEvents(), 0, reason: '幂等');
    });

    test('clearAll 清空全部事件并广播', () async {
      await insertEvent(startedAt: 1000, endedAt: 2000);
      await insertEvent(songId: 'song2', startedAt: 3000, endedAt: 4000);
      final changes = <void>[];
      final subscription = repository.changes.listen(changes.add);

      await repository.clearAll();

      expect(await tableRows(db, 'play_events'), isEmpty);
      expect(changes, hasLength(1));
      await subscription.cancel();
    });
  });

  group('汇总与榜单', () {
    test('summary 只统计已收尾非 error 事件，口径按有效播放', () async {
      final base = DateTime(2026, 3, 1, 12).millisecondsSinceEpoch;
      // 有效播放（150s ≥ min(30s, 50%×200s)）+ 完整播放。
      await insertEvent(
        songId: 'qualified',
        listenedMs: 150000,
        durationMs: 200000,
        endReason: 'completed',
        startedAt: base,
        endedAt: base + 150000,
      );
      // 未达有效阈值的跳过。
      await insertEvent(
        songId: 'skipped',
        listenedMs: 5000,
        durationMs: 200000,
        endReason: 'skipped',
        startedAt: base + 1000,
        endedAt: base + 6000,
      );
      // error 事件不计入任何计数与时长。
      await insertEvent(
        songId: 'errored',
        listenedMs: 4000,
        durationMs: 200000,
        endReason: 'error',
        startedAt: base + 2000,
        endedAt: base + 6000,
      );
      // 进行中事件不出现。
      await insertEvent(
        songId: 'open',
        endReason: null,
        endedAt: null,
        startedAt: base + 3000,
      );

      final summary = await repository.summary();

      expect(summary.playCount, 2);
      expect(summary.qualifiedPlayCount, 1);
      expect(summary.totalListenedMs, 155000);
      expect(summary.uniqueTrackCount, 2);
      expect(summary.completionRate, closeTo(0.5, 1e-9));
      expect(summary.skipRate, closeTo(0.5, 1e-9));
      expect(summary.firstPlayedAt, base);
    });

    test('summary 的 since 过滤与全局首播', () async {
      final base = DateTime(2026, 3, 10, 12).millisecondsSinceEpoch;
      await insertEvent(
        songId: 'old',
        startedAt: base - 100000,
        endedAt: base - 50000,
        endReason: 'completed',
      );
      await insertEvent(
        songId: 'new',
        listenedMs: 60000,
        durationMs: 100000,
        startedAt: base,
        endedAt: base + 60000,
        endReason: 'completed',
      );

      final summary = await repository.summary(since: base);

      expect(summary.playCount, 1);
      expect(summary.qualifiedPlayCount, 1);
      expect(
        summary.firstPlayedAt,
        base - 100000,
        reason: '数据起始日不受范围影响',
      );
    });

    test('topTracks 按有效播放排序、保留 raw、排除只有跳过的曲目', () async {
      final base = DateTime(2026, 3, 2, 9).millisecondsSinceEpoch;
      for (var i = 0; i < 2; i++) {
        await insertEvent(
          songId: 'a',
          title: 'Song A',
          listenedMs: 60000,
          durationMs: 200000,
          endReason: 'completed',
          startedAt: base + i * 1000,
          endedAt: base + i * 1000 + 60000,
        );
      }
      await insertEvent(
        songId: 'b',
        title: 'Song B',
        listenedMs: 35000,
        durationMs: 60000,
        endReason: 'completed',
        startedAt: base + 5000,
        endedAt: base + 40000,
      );
      // 只有跳过的曲目（未达有效阈值）不应出现。
      await insertEvent(
        songId: 'c',
        listenedMs: 3000,
        durationMs: 200000,
        endReason: 'skipped',
        startedAt: base + 6000,
        endedAt: base + 9000,
      );

      final top = await repository.topTracks();

      expect(top.map((entry) => entry.songId).toList(), ['a', 'b']);
      expect(top.first.playCount, 2);
      expect(top.first.listenedMs, 120000);
      expect(top.first.title, 'Song A');
      expect(top.first.raw, {'id': 'a'}, reason: 'raw 供统计页点播');
      expect(top.first.lastPlayedAt, base + 1000);
      expect(top[1].playCount, 1);
    });

    test('topArtists 拆分多歌手串并只计有效播放', () async {
      final base = DateTime(2026, 3, 3, 9).millisecondsSinceEpoch;
      for (var i = 0; i < 2; i++) {
        await insertEvent(
          songId: 'duet',
          artist: 'A, B',
          listenedMs: 60000,
          durationMs: 200000,
          endReason: 'completed',
          startedAt: base + i * 1000,
          endedAt: base + i * 1000 + 60000,
        );
      }
      await insertEvent(
        songId: 'solo',
        artist: 'B',
        listenedMs: 60000,
        durationMs: 200000,
        endReason: 'completed',
        startedAt: base + 5000,
        endedAt: base + 65000,
      );
      // 未达有效阈值不计。
      await insertEvent(
        songId: 'skipped',
        artist: 'C',
        listenedMs: 1000,
        durationMs: 200000,
        endReason: 'skipped',
        startedAt: base + 6000,
        endedAt: base + 7000,
      );

      final artists = await repository.topArtists();

      expect(artists.map((entry) => entry.artist).toList(), ['B', 'A']);
      expect(artists[0].playCount, 3);
      expect(artists[1].playCount, 2);
      expect(artists[1].listenedMs, 120000);
    });

    test('splitArtistNames 纯函数（含中西分隔符）', () {
      expect(
        PlayStatisticsRepository.splitArtistNames('A, B/C&D、E;F；G，H'),
        ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'],
      );
      expect(PlayStatisticsRepository.splitArtistNames('  '), isEmpty);
    });
  });

  group('时间分桶与来源', () {
    test('listenedByDay 按本地时区日分桶', () async {
      final d1 = DateTime(2026, 3, 1, 23, 30);
      final d2 = DateTime(2026, 3, 2, 0, 30);
      await insertEvent(
        songId: 'd1',
        listenedMs: 60000,
        durationMs: 200000,
        endReason: 'completed',
        startedAt: d1.millisecondsSinceEpoch,
        endedAt: d1.millisecondsSinceEpoch + 60000,
      );
      await insertEvent(
        songId: 'd2',
        listenedMs: 30000,
        durationMs: 200000,
        endReason: 'completed',
        startedAt: d2.millisecondsSinceEpoch,
        endedAt: d2.millisecondsSinceEpoch + 30000,
      );

      final days = await repository.listenedByDay();

      expect(days.map((entry) => entry.day).toList(), [
        DateTime(2026, 3, 1),
        DateTime(2026, 3, 2),
      ]);
      expect(days[0].listenedMs, 60000);
      expect(days[0].playCount, 1);
      expect(days[1].listenedMs, 30000);
    });

    test('listenedByHour 按本地时区小时分桶', () async {
      final base = DateTime(2026, 3, 1);
      await insertEvent(
        songId: 'h9',
        listenedMs: 60000,
        durationMs: 200000,
        endReason: 'completed',
        startedAt: DateTime(2026, 3, 1, 9, 15).millisecondsSinceEpoch,
        endedAt: base.millisecondsSinceEpoch + 3600000,
      );
      await insertEvent(
        songId: 'h23',
        listenedMs: 20000,
        durationMs: 200000,
        endReason: 'completed',
        startedAt: DateTime(2026, 3, 1, 23, 45).millisecondsSinceEpoch,
        endedAt: base.millisecondsSinceEpoch + 86400000,
      );

      final hours = await repository.listenedByHour();

      expect(hours.map((entry) => entry.hour).toList(), [9, 23]);
      expect(hours[0].listenedMs, 60000);
      expect(hours[1].listenedMs, 20000);
    });

    test('listenedByWeekdayHour 按本地星期×小时分桶', () async {
      // 2026-03-02 是周一，03-03 是周二。
      final monday = DateTime(2026, 3, 2, 9, 20);
      final tuesday = DateTime(2026, 3, 3, 23, 40);
      await insertEvent(
        songId: 'mon',
        listenedMs: 60000,
        durationMs: 200000,
        endReason: 'completed',
        startedAt: monday.millisecondsSinceEpoch,
        endedAt: monday.millisecondsSinceEpoch + 60000,
      );
      await insertEvent(
        songId: 'tue',
        listenedMs: 20000,
        durationMs: 200000,
        endReason: 'completed',
        startedAt: tuesday.millisecondsSinceEpoch,
        endedAt: tuesday.millisecondsSinceEpoch + 20000,
      );

      final buckets = await repository.listenedByWeekdayHour();

      expect(buckets, hasLength(2));
      expect(buckets[0].weekday, 0, reason: '周一 = 0');
      expect(buckets[0].hour, 9);
      expect(buckets[0].listenedMs, 60000);
      expect(buckets[0].playCount, 1);
      expect(buckets[1].weekday, 1);
      expect(buckets[1].hour, 23);
    });

    test('sourceDistribution 按 sourceKey 聚合按时长排序', () async {
      final base = DateTime(2026, 3, 4, 9).millisecondsSinceEpoch;
      await insertEvent(
        sourceKey: 'wy',
        songId: 'w1',
        listenedMs: 60000,
        durationMs: 200000,
        endReason: 'completed',
        startedAt: base,
        endedAt: base + 60000,
      );
      await insertEvent(
        sourceKey: 'kw',
        songId: 'k1',
        listenedMs: 90000,
        durationMs: 200000,
        endReason: 'completed',
        startedAt: base + 1000,
        endedAt: base + 91000,
      );

      final distribution = await repository.sourceDistribution();

      expect(
          distribution.map((entry) => entry.sourceKey).toList(), ['kw', 'wy']);
      expect(distribution.first.listenedMs, 90000);
      expect(distribution.first.playCount, 1);
    });
  });

  group('明细与导出', () {
    test('dayEvents 只含当天、升序、保留 raw', () async {
      final day = DateTime(2026, 3, 5);
      await insertEvent(
        songId: 'm1',
        listenedMs: 60000,
        durationMs: 200000,
        endReason: 'completed',
        startedAt: DateTime(2026, 3, 5, 8).millisecondsSinceEpoch,
        endedAt: DateTime(2026, 3, 5, 9).millisecondsSinceEpoch,
      );
      await insertEvent(
        songId: 'm2',
        listenedMs: 40000,
        durationMs: 200000,
        endReason: 'completed',
        startedAt: DateTime(2026, 3, 5, 20).millisecondsSinceEpoch,
        endedAt: DateTime(2026, 3, 5, 21).millisecondsSinceEpoch,
      );
      // 次日凌晨：不属于当天。
      await insertEvent(
        songId: 'next-day',
        startedAt: DateTime(2026, 3, 6, 0, 30).millisecondsSinceEpoch,
        endedAt: DateTime(2026, 3, 6, 4).millisecondsSinceEpoch,
      );

      final detail = await repository.dayEvents(day);

      expect(detail.day, day);
      expect(detail.events.map((event) => event.songId).toList(), ['m1', 'm2']);
      expect(detail.events.first.raw, {'id': 'm1'});
      expect(detail.listenedMs, 100000);
      expect(detail.playCount, 2);
    });

    test('listPlayedTrackNames 去重并按最近播放排序', () async {
      await insertEvent(
        songId: 'a',
        title: 'Song A',
        artist: 'Artist A',
        startedAt: 1000,
        endedAt: 2000,
      );
      await insertEvent(
        songId: 'a-live',
        title: 'Song A',
        artist: 'Artist A',
        startedAt: 5000,
        endedAt: 6000,
      );
      await insertEvent(
        songId: 'b',
        title: 'Song B',
        artist: 'Artist B',
        startedAt: 3000,
        endedAt: 4000,
      );
      // 进行中事件不出现。
      await insertEvent(
        songId: 'open',
        title: 'Open',
        artist: 'X',
        startedAt: 9000,
        endedAt: null,
      );

      final names = await repository.listPlayedTrackNames();

      expect(names.map((entry) => entry.title).toList(), ['Song A', 'Song B']);
      expect(names.first.artist, 'Artist A');
      expect(names.first.title, 'Song A');
    });

    test('listEventsForExport 按时间倒序、遵守上限、含 error 原始日志', () async {
      final base = DateTime(2026, 3, 6, 9).millisecondsSinceEpoch;
      for (var i = 0; i < 4; i++) {
        await insertEvent(
          songId: 'e$i',
          endedAt: base + i * 1000 + 100,
          endReason: i == 3 ? 'error' : 'completed',
          startedAt: base + i * 1000,
        );
      }

      final events = await repository.listEventsForExport(limit: 3);

      expect(events, hasLength(3));
      expect(events.first.songId, 'e3', reason: '倒序取最近');
      expect(events.first.endReason, PlayEventEndReason.error);
      expect(events.first.isFinished, isTrue);
    });
  });

  group('采集服务写入路径', () {
    test('touchEvent 不覆盖已收尾行', () async {
      final id = await repository.startEvent(
        sourceKey: 'wy',
        songId: 'x',
        title: 'X',
        startedAt: 1000,
      );
      await repository.finishEvent(
        id,
        reason: PlayEventEndReason.skipped,
        listenedMs: 1000,
        maxPositionMs: 1000,
        endedAt: 2000,
      );
      await repository.touchEvent(id, listenedMs: 9999, maxPositionMs: 9999);

      final row = (await tableRows(db, 'play_events')).single;
      expect(row['listenedMs'], 1000);
    });
  });

  test('导出缓存：增量维护（新收尾事件立即出现，重复导出不重读全表）', () async {
    final first = await repository.startEvent(
      sourceKey: 'wy',
      songId: '1',
      title: '曲目一',
      startedAt: 1000,
    );
    // 缓存未加载时收尾：指纹推进，导出结果包含该行。
    await repository.finishEvent(
      first,
      reason: PlayEventEndReason.completed,
      listenedMs: 6000,
      maxPositionMs: 6000,
      endedAt: 2000,
    );
    final exported = await statisticsSync.syncExportEvents();
    expect(exported, hasLength(1));
    expect(exported.single.songId, '1');
    expect(exported.single.syncKey, isNotEmpty);
    // 缓存命中复用同一列表实例。
    expect(
        identical(await statisticsSync.syncExportEvents(), exported), isTrue);

    // 增量：新事件收尾后缓存就地更新（含 syncKey / 版本）。
    final second = await repository.startEvent(
      sourceKey: 'kw',
      songId: '2',
      title: '曲目二',
      startedAt: 3000,
    );
    await repository.finishEvent(
      second,
      reason: PlayEventEndReason.skipped,
      listenedMs: 3000,
      maxPositionMs: 3000,
      endedAt: 4000,
    );
    final after = await statisticsSync.syncExportEvents();
    expect(after, hasLength(2));
    expect(after.map((row) => row.songId), containsAll(['1', '2']));

    // clearAll 后缓存失效：导出为空。
    await repository.clearAll();
    expect(await statisticsSync.syncExportEvents(), isEmpty);
  });

  test('保留策略：超出时长窗口与行数上限的已收尾事件被裁剪', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final dayMs = const Duration(days: 1).inMilliseconds;
    for (var i = 0; i < 5; i++) {
      await insertEvent(
        songId: 'old$i',
        startedAt: now - 10 * dayMs + i * 1000,
        endedAt: now - 10 * dayMs + i * 1000 + 1000,
      );
    }
    // 窗口内的新事件（保留）。
    await insertEvent(songId: 'new', startedAt: now - 1000, endedAt: now);

    // 时长窗口：只留最近 5 天收尾的事件。
    final removed = await repository.pruneOldEvents(
      maxRows: 100,
      retention: const Duration(days: 5),
    );
    expect(removed, 5);
    final exported = await statisticsSync.syncExportEvents();
    expect(exported.map((row) => row.songId), ['new']);

    // 行数上限：再插入两条并保留 1 行 → 只留最新（startedAt 最大）一条。
    await insertEvent(songId: 'a', startedAt: now + 1000, endedAt: now + 2000);
    await insertEvent(songId: 'b', startedAt: now + 3000, endedAt: now + 4000);
    await repository.pruneOldEvents(
      maxRows: 1,
      retention: const Duration(days: 3650),
    );
    final trimmed = await statisticsSync.syncExportEvents();
    expect(trimmed, hasLength(1));
    expect(trimmed.single.songId, 'b');
  });

  test('同步指纹：进行中事件不变，收尾后推进', () async {
    final id = await repository.startEvent(
      sourceKey: 'wy',
      songId: '1',
      title: '曲目',
      startedAt: 1000,
    );
    final started = await statisticsSync.syncFingerprint();

    // 进行中事件不导出：进度更新不影响指纹。
    await repository.touchEvent(id, listenedMs: 5000, maxPositionMs: 5000);
    expect(await statisticsSync.syncFingerprint(), started);

    await repository.finishEvent(
      id,
      reason: PlayEventEndReason.completed,
      listenedMs: 6000,
      maxPositionMs: 6000,
      endedAt: 2000,
    );
    expect(await statisticsSync.syncFingerprint(), isNot(started));
  });

  group('曲目内容表（play_tracks）', () {
    /// 播放同一曲三次（载荷 v1→v3，标题跟着变），返回行 id。
    Future<void> playSameTrack(List<String> values, {int base = 1000}) async {
      for (var i = 0; i < values.length; i++) {
        final id = await repository.startEvent(
          sourceKey: 'wy',
          songId: 'same',
          title: '标题${values[i]}',
          raw: {'v': values[i]},
          startedAt: base + i * 1000,
        );
        await repository.finishEvent(
          id,
          reason: PlayEventEndReason.completed,
          listenedMs: 60000,
          maxPositionMs: 60000,
          endedAt: base + i * 1000 + 500,
        );
      }
    }

    test('连续播放同一曲：内容行每曲一行，元数据 / 载荷取最近一次', () async {
      await playSameTrack(['v1', 'v2', 'v3']);

      final tracks = await tableRows(db, 'play_tracks');
      expect(tracks, hasLength(1), reason: '内容每曲一行（不再逐事件复制）');
      expect(tracks.single['title'], '标题v3');
      expect(tracks.single['updatedAt'], 3000);
      expect(decodeStatsPayload(tracks.single['raw']), '{"v":"v3"}');
      expect(await tableRows(db, 'play_events'), hasLength(3), reason: '事件全保留');

      // 读取侧：三条事件都拿到该曲载荷（明细 / 榜单 / 点播口径一致）。
      final events = await repository.listEventsForExport();
      expect(events, hasLength(3));
      expect(events.every((event) => event.raw['v'] == 'v3'), isTrue);
      final top = await repository.topTracks();
      expect(top.single.raw, {'v': 'v3'});
      expect(top.single.title, '标题v3');
      expect(top.single.playCount, 3);
    });

    test('载荷按 gzip 存 BLOB（库里不是明文 JSON）', () async {
      await playSameTrack(['v1']);

      final raw = (await tableRows(db, 'play_tracks')).single['raw'];
      expect(raw, isA<Uint8List>());
      expect(
        utf8.decode(raw! as Uint8List, allowMalformed: true),
        isNot(contains('"v":"v1"')),
        reason: 'gzip 字节不是可读 JSON',
      );
      expect(decodeStatsPayload(raw), '{"v":"v1"}');
    });

    test('事件裁剪后：被裁光事件的曲目内容行 GC，仍有事件的曲目载荷保留', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await playSameTrack(['v1', 'v2', 'v3'], base: now);
      await insertEvent(
        songId: 'other',
        startedAt: now - 10 * 1000,
        endedAt: now - 9000,
        listenedMs: 60000,
      );

      await repository.pruneOldEvents(
        maxRows: 1,
        retention: const Duration(days: 3650),
      );

      expect(await tableRows(db, 'play_events'), hasLength(1));
      final tracks = await tableRows(db, 'play_tracks');
      expect(tracks, hasLength(1), reason: '事件被裁光的曲目内容行一并清理');
      expect(tracks.single['songId'], 'same');
      final events = await repository.listEventsForExport();
      expect(events.single.raw, {'v': 'v3'}, reason: '载荷不随旧事件丢失');
    });

    test('载荷预算：超出按「最近播放」保留，越界的清空（历史 / 明细不变）', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final pad = 'x' * 600;
      for (final (index, songId) in ['a', 'b', 'c'].indexed) {
        final id = await repository.startEvent(
          sourceKey: 'wy',
          songId: songId,
          title: 'T$songId',
          raw: {'id': songId, 'pad': pad},
          startedAt: now + index * 1000,
        );
        await repository.finishEvent(
          id,
          reason: PlayEventEndReason.completed,
          listenedMs: 60000,
          maxPositionMs: 60000,
          endedAt: now + index * 1000 + 500,
        );
      }
      // 预算 = 最近两首的载荷字节（按 gzip 后的实际长度算）。
      final holders = await db
          .customSelect(
            'SELECT LENGTH(raw) AS bytes FROM play_tracks '
            'WHERE raw IS NOT NULL ORDER BY updatedAt DESC, id DESC',
          )
          .get();
      final budget = holders
          .take(2)
          .fold<int>(0, (sum, row) => sum + ((row.data['bytes'] as int?) ?? 0));
      expect(holders, hasLength(3));

      await repository.pruneOldEvents(
        maxRows: 100,
        retention: const Duration(days: 3650),
        maxPayloadBytes: budget,
      );

      final tracks = await tableRows(db, 'play_tracks');
      expect(tracks, hasLength(3), reason: '只清载荷，不删内容行 / 事件');
      final withPayload = [
        for (final track in tracks)
          if (track['raw'] != null) track['songId'],
      ];
      expect(withPayload.toSet(), {'b', 'c'}, reason: '最久未播放的载荷先清');
      expect(await repository.listEventsForExport(), hasLength(3));
      final top = await repository.topTracks();
      expect(
        top.firstWhere((entry) => entry.songId == 'a').raw,
        isEmpty,
        reason: '点播参数没了 → 回退重新解析',
      );
      expect(
        top.firstWhere((entry) => entry.songId == 'c').raw,
        <String, dynamic>{'id': 'c', 'pad': pad},
      );
    });

    test('同步导出：每条记录自包含（载荷按曲补齐）', () async {
      await playSameTrack(['v1', 'v2']);

      final exported = await statisticsSync.syncExportEvents();
      expect(exported, hasLength(2));
      for (final row in exported) {
        expect(row.raw.isNotEmpty, isTrue, reason: '远端按记录独立落地，raw 必须补齐');
        expect(jsonDecode(row.raw), {'v': 'v2'});
      }
    });

    test('远端落地：更旧的事件不改内容行，更新的事件才覆盖', () async {
      final localId = await repository.startEvent(
        sourceKey: 'wy',
        songId: 'same',
        title: '本机新标题',
        raw: {'v': 'local'},
        startedAt: 5000,
      );
      await repository.finishEvent(
        localId,
        reason: PlayEventEndReason.completed,
        listenedMs: 60000,
        maxPositionMs: 60000,
        endedAt: 5500,
      );

      await statisticsSync.syncApplyEvents([
        StatisticsSyncEvent(
          syncKey: 'remote-old',
          version: const SyncVersion(physical: 9000, deviceId: 'devB'),
          sourceKey: 'wy',
          songId: 'same',
          title: '远端旧标题',
          raw: '{"v":"old"}',
          startedAt: 3000,
          endedAt: 3500,
        ),
      ]);
      expect(await tableRows(db, 'play_events'), hasLength(2), reason: '事件仍落地');
      var track = (await tableRows(db, 'play_tracks')).single;
      expect(track['title'], '本机新标题', reason: '旧事件不覆盖新内容');
      expect(decodeStatsPayload(track['raw']), '{"v":"local"}');

      await statisticsSync.syncApplyEvents([
        StatisticsSyncEvent(
          syncKey: 'remote-new',
          version: const SyncVersion(physical: 9001, deviceId: 'devB'),
          sourceKey: 'wy',
          songId: 'same',
          title: '远端新标题',
          raw: '{"v":"new"}',
          startedAt: 9000,
          endedAt: 9500,
        ),
      ]);
      track = (await tableRows(db, 'play_tracks')).single;
      expect(track['title'], '远端新标题');
      expect(decodeStatsPayload(track['raw']), '{"v":"new"}');
    });
  });
}
