import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/domain/models/annual_report.dart';
import 'package:molia/providers/annual_report_provider.dart';

import '../support/memory_database.dart';
import '../support/sync_test_support.dart';

void main() {
  late MoliaDatabase db;
  late PlayStatisticsRepository repository;
  late AnnualReportProvider provider;
  late ValueNotifier<bool> enabled;

  setUp(() async {
    db = openMemoryDatabase();
    repository = PlayStatisticsRepository(
      databaseProvider: () => db,
      statisticsSync: testStatisticsSyncStore(() => db),
    );
    enabled = ValueNotifier<bool>(true);
    provider = AnnualReportProvider(
      repository: repository,
      clock: () => DateTime(2026, 11, 14),
      recordingEnabled: enabled,
    );
  });

  tearDown(() async {
    provider.dispose();
    enabled.dispose();
    await repository.dispose();
    await db.close();
  });

  Future<void> insert(int year, int month, String songId) async {
    final start = DateTime(year, month, 10, 12);
    await insertPlayEvent(
      db,
      songId: songId,
      title: 'Track $songId',
      startedAt: start.millisecondsSinceEpoch,
      endedAt: start.millisecondsSinceEpoch + 120000,
      listenedMs: 120000,
      maxPositionMs: 120000,
      endReason: 'completed',
    );
  }

  test('默认年份取入口推荐；切换年份加载对应窗口', () async {
    await insert(2025, 6, 'old');
    await insert(2026, 3, 'new');
    provider.configure(
      years: [2026, 2025],
      featuredYear: 2025,
      sourceNames: const {'wy': '网易云'},
    );
    await provider.ensureLoaded();
    expect(provider.report?.year, 2025);
    expect(provider.report?.topTracks.single.songId, 'old');

    await provider.selectYear(2026);
    expect(provider.report?.year, 2026);
    expect(provider.report?.asOfToday, isTrue);
    expect(provider.report?.topTracks.single.songId, 'new');
  });

  test('空年份返回无数据报告，不伪造图表', () async {
    provider.configure(
      years: [2020],
      featuredYear: 2020,
      sourceNames: const {},
    );
    await provider.ensureLoaded();
    expect(provider.report?.hasData, isFalse);
    expect(provider.report?.monthlyListenedMs, everyElement(0));
  });

  test('关闭记录后提示 recordingOff，但报告仍可读', () async {
    await insert(2026, 3, 'new');
    enabled.value = false;
    provider.configure(
      years: [2026],
      featuredYear: 2026,
      sourceNames: const {},
    );
    await provider.ensureLoaded();
    expect(provider.report?.hasData, isTrue);
    expect(provider.report?.notice, AnnualReportNotice.recordingOff);
  });

  test('重复打开同一入口时回到推荐年份', () async {
    await insert(2025, 6, 'old');
    await insert(2026, 3, 'new');
    provider.configure(
      years: [2026, 2025],
      featuredYear: 2025,
      sourceNames: const {},
    );
    await provider.ensureLoaded();
    await provider.selectYear(2026);
    provider.configure(
      years: [2026, 2025],
      featuredYear: 2025,
      sourceNames: const {},
    );
    expect(provider.selectedYear, 2025);
  });
}
