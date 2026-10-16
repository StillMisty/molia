import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'package:molia/providers/play_statistics_provider.dart';
import 'support/sync_test_support.dart';

import 'support/memory_database.dart';

/// 听歌统计 Provider 测试：范围过滤、日历全量、清空与维度切换。
void main() {
  late MoliaDatabase db;
  late PlayStatisticsRepository repository;
  late PlayStatisticsProvider provider;

  Future<int> insertEvent({
    required String songId,
    required int startedAt,
    int listenedMs = 60000,
    int durationMs = 200000,
    String endReason = 'completed',
    String sourceKey = 'wy',
  }) async {
    return db.into(db.playEvents).insert(PlayEventsCompanion.insert(
          sourceKey: sourceKey,
          songId: songId,
          title: Value('Song $songId'),
          artist: const Value('Artist'),
          album: const Value(''),
          durationMs: Value(durationMs),
          raw: Value(jsonEncode({'id': songId})),
          startedAt: startedAt,
          endedAt: Value(startedAt + listenedMs),
          listenedMs: Value(listenedMs),
          maxPositionMs: Value(listenedMs),
          endReason: Value(endReason),
        ));
  }

  setUp(() async {
    db = openMemoryDatabase();
    repository = PlayStatisticsRepository(
      databaseProvider: () => db,
      stamps: testStampIssuer(),
    );
    provider = PlayStatisticsProvider(repository: repository);
  });

  tearDown(() async {
    provider.dispose();
    await repository.dispose();
    await db.close();
  });

  test('默认近 30 天；日历热力图固定全量历史', () async {
    final now = DateTime.now();
    final recent = now.subtract(const Duration(days: 1));
    final old = now.subtract(const Duration(days: 100));
    await insertEvent(
      songId: 'recent',
      startedAt: recent.millisecondsSinceEpoch,
    );
    await insertEvent(songId: 'old', startedAt: old.millisecondsSinceEpoch);

    await provider.ensureLoaded();

    expect(provider.hasLoaded, isTrue);
    expect(provider.hasError, isFalse);
    expect(provider.range, PlayStatisticsRange.month);
    expect(provider.snapshot!.summary.playCount, 1, reason: '范围外的事件不计入汇总');
    expect(provider.snapshot!.daily, hasLength(2), reason: '日历数据不受范围过滤');

    await provider.setRange(PlayStatisticsRange.all);

    expect(provider.snapshot!.summary.playCount, 2);
    expect(provider.snapshot!.topTracks, hasLength(2));
  });

  test('范围切换后榜单与作息数据跟随过滤', () async {
    final now = DateTime.now();
    final old = now.subtract(const Duration(days: 100));
    await insertEvent(
      songId: 'old',
      startedAt: old.millisecondsSinceEpoch,
    );
    await insertEvent(
      songId: 'recent',
      startedAt: now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
    );

    await provider.ensureLoaded();
    expect(provider.snapshot!.byWeekdayHour, hasLength(1));
    await provider.setRange(PlayStatisticsRange.all);
    expect(provider.snapshot!.byWeekdayHour, hasLength(2));
  });

  test('valueMode 切换只通知不重查；clearAll 清空后进入空态', () async {
    final now = DateTime.now();
    await insertEvent(
      songId: 'a',
      startedAt: now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
    );
    await provider.ensureLoaded();
    expect(provider.isEmpty, isFalse);

    var notifications = 0;
    provider.addListener(() => notifications++);
    provider.setValueMode(PlayStatisticsValueMode.count);
    expect(provider.valueMode, PlayStatisticsValueMode.count);
    expect(notifications, 1);

    await provider.clearAll();

    expect(provider.snapshot!.summary.playCount, 0);
    expect(provider.isEmpty, isTrue);
    expect(provider.snapshot!.daily, isEmpty);
  });

  test('loadDay 返回当天明细（含 raw，供点播）', () async {
    final day = DateTime(2026, 3, 5);
    await insertEvent(
      songId: 'a',
      startedAt: DateTime(2026, 3, 5, 9).millisecondsSinceEpoch,
    );
    await insertEvent(
      songId: 'b',
      startedAt: DateTime(2026, 3, 6, 9).millisecondsSinceEpoch,
    );
    await provider.ensureLoaded();

    final detail = await provider.loadDay(day);

    expect(detail.day, DateTime(2026, 3, 5));
    expect(detail.events, hasLength(1));
    expect(detail.events.single.songId, 'a');
    expect(detail.events.single.raw, {'id': 'a'});
    expect(detail.listenedMs, 60000);
  });
}
