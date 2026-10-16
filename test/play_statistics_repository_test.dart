import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'support/sync_test_support.dart';

import 'support/memory_database.dart';

/// 听歌统计仓库测试：drift in-memory 库（schema 与生产一致）。
void main() {
  late MoliaDatabase db;
  late PlayStatisticsRepository repository;

  /// 直接插入已收尾/进行中事件（查询测试用，绕开采集服务）。
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
  }) async {
    return db.into(db.playEvents).insert(PlayEventsCompanion.insert(
          sourceKey: sourceKey,
          songId: songId,
          title: Value(title),
          artist: Value(artist),
          album: Value(album),
          coverUrl: Value(coverUrl),
          durationMs: Value(durationMs),
          raw: Value(jsonEncode(raw ?? {'id': songId})),
          startedAt: startedAt,
          endedAt: Value(endedAt),
          listenedMs: Value(listenedMs),
          maxPositionMs: Value(maxPositionMs),
          endReason: Value(endReason),
        ));
  }

  setUp(() async {
    db = openMemoryDatabase();
    repository = PlayStatisticsRepository(
      databaseProvider: () => db,
      stamps: testStampIssuer(),
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
      expect(row['raw'], '{"rid":7}');
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
}
