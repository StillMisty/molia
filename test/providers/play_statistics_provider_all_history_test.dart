import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/domain/models/annual_report_entry.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'package:molia/providers/play_statistics_provider.dart';

import '../support/memory_database.dart';
import '../support/sync_test_support.dart';

/// 年度入口必须读全量日历 rollup：30 天范围只影响汇总 / 榜单，不缩年份。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MoliaDatabase db;
  late PlayStatisticsRepository repository;
  late PlayStatisticsProvider provider;

  setUp(() async {
    db = openMemoryDatabase();
    repository = PlayStatisticsRepository(
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

  Future<void> insert(DateTime at, String songId) async {
    await insertPlayEvent(
      db,
      songId: songId,
      title: 'Track $songId',
      startedAt: at.millisecondsSinceEpoch,
      endedAt: at.millisecondsSinceEpoch + 120000,
      listenedMs: 120000,
      maxPositionMs: 120000,
      endReason: 'completed',
    );
  }

  test('近 30 天范围下仍保留往年 rollup，年度入口可打开更早年份', () async {
    final now = DateTime.now();
    final old = now.subtract(const Duration(days: 400));
    final recent = now.subtract(const Duration(days: 1));
    await insert(old, 'old');
    await insert(recent, 'recent');

    await provider.setRange(PlayStatisticsRange.month);
    await provider.ensureLoaded();

    // 汇总 / 榜单按 30 天范围过滤。
    expect(provider.snapshot?.topTracks.map((entry) => entry.songId), [
      'recent',
    ]);
    // 全量日历仍含往年，入口不会只剩当前年。
    final days = provider.allHistoryDaily;
    expect(days.map((day) => day.day.year), contains(old.year));
    final entry = AnnualReportEntry.fromDaily(days, now: now);
    expect(entry.isVisible, isTrue);
    expect(entry.years, contains(old.year));
  });
}
