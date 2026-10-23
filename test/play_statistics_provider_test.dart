import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'package:molia/providers/play_statistics_provider.dart';
import 'support/sync_test_support.dart';

import 'support/memory_database.dart';

/// 计数仓库：验证防抖窗口内没有查询、窗口结束后只查一次。
class _CountingPlayStatisticsRepository extends PlayStatisticsRepository {
  _CountingPlayStatisticsRepository({
    required super.databaseProvider,
    required super.statisticsSync,
  });

  int snapshotCalls = 0;

  @override
  Future<ListeningStatisticsSnapshot> snapshot({int? since}) {
    snapshotCalls++;
    return super.snapshot(since: since);
  }
}

/// 听歌统计 Provider 测试：范围过滤、日历全量、清空与维度切换。
void main() {
  late MoliaDatabase db;
  late _CountingPlayStatisticsRepository repository;
  late PlayStatisticsProvider provider;

  /// 直接插入已收尾事件（查询测试用，绕开采集服务）。
  Future<int> insertEvent({
    String sourceKey = 'wy',
    String songId = 'Song 1',
    String title = 'Song 1',
    String artist = 'Artist',
    String album = '',
    String? coverUrl,
    int? durationMs = 200000,
    Map<String, dynamic>? raw,
    required int startedAt,
    int listenedMs = 60000,
    int maxPositionMs = 60000,
    String? endReason = 'completed',
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
        // 未显式给 endedAt 的行按「收尾于 startedAt + listenedMs」造（查询只看
        // 已收尾事件）。
        endedAt: endedAt ?? startedAt + listenedMs,
        syncKey: syncKey,
      );

  setUp(() async {
    db = openMemoryDatabase();
    repository = _CountingPlayStatisticsRepository(
      databaseProvider: () => db,
      statisticsSync: testStatisticsSyncStore(() => db),
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

  test('仓库变更防抖：连续变更只重载一次；手动刷新立即加载', () async {
    await provider.ensureLoaded();
    expect(repository.snapshotCalls, 1);

    provider.startWatching();
    await repository.clearAll();
    await repository.clearAll();
    await repository.clearAll();

    // 防抖窗口内不查库。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(repository.snapshotCalls, 1);

    await Future<void>.delayed(
      PlayStatisticsProvider.watchDebounce + const Duration(milliseconds: 200),
    );
    expect(repository.snapshotCalls, 2, reason: '一串变更只收敛成一次静默重载');

    await provider.refresh();
    expect(repository.snapshotCalls, 3, reason: '手动刷新不走防抖');
  });

  test('停止监听 / dispose 取消尚未触发的防抖重载', () async {
    await provider.ensureLoaded();
    provider.startWatching();
    await repository.clearAll();
    provider.stopWatching();

    await Future<void>.delayed(
      PlayStatisticsProvider.watchDebounce + const Duration(milliseconds: 200),
    );
    expect(repository.snapshotCalls, 1);
  });
}
