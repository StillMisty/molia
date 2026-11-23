import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/domain/models/annual_report.dart';
import 'package:molia/domain/models/annual_report_entry.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'package:molia/providers/play_statistics_provider.dart';
import 'package:molia/services/play_statistics_export.dart';

import '../support/memory_database.dart';
import '../support/provider_test_scope.dart';

import 'package:molia/providers/app_providers.dart';

import '../support/sync_test_support.dart';

/// 每次 `snapshot()` 的脚本；用于失败 / 乱序返回等无法用真库表达的时序。
typedef _SnapshotStep = Future<ListeningStatisticsSnapshot> Function();

class _ScriptedRepository extends PlayStatisticsRepository {
  _ScriptedRepository({
    required super.databaseProvider,
    required super.statisticsSync,
  });

  final List<_SnapshotStep> _steps = [];

  void enqueue(_SnapshotStep step) => _steps.add(step);

  @override
  Future<ListeningStatisticsSnapshot> snapshot({int? since}) {
    if (_steps.isEmpty) {
      return Future.error(StateError('没有排队的 snapshot'));
    }
    return _steps.removeAt(0)();
  }
}

/// 一次加载只允许读一次：第二次读直接失败，而不是靠末尾计数兜底。
class _FakeClock {
  _FakeClock(this._values);

  final List<DateTime> _values;
  int reads = 0;
  bool _armed = true;

  DateTime next() {
    if (!_armed) fail('一次加载只能读取一次时钟');
    if (reads >= _values.length) fail('时钟读取次数超出预期');
    _armed = false;
    return _values[reads++];
  }

  void armNext() => _armed = true;
}

ListeningStatisticsSnapshot _snapshot({
  int totalListenedMs = 0,
  List<DayListened> daily = const [],
  DateTime? firstPlayedAt,
}) {
  final firstPlayed = firstPlayedAt ?? DateTime(2030, 12, 31);
  return ListeningStatisticsSnapshot(
    summary: PlayStatisticsSummary(
      playCount: 1,
      qualifiedPlayCount: 1,
      totalListenedMs: totalListenedMs,
      uniqueTrackCount: 1,
      completionRate: 1,
      skipRate: 0,
      firstPlayedAt: firstPlayed.millisecondsSinceEpoch,
    ),
    topTracks: const [],
    topArtists: const [],
    daily: daily,
    byWeekdayHour: const [],
    sources: const [],
  );
}

/// provider 的加载状态：全量日历 rollup、窗口一致性与失败 / 乱序返回。

PlayStatisticsProvider _scopedProvider(
  PlayStatisticsRepository repo,
  DateTime Function() clock,
) {
  final scope = ProviderTestScope(
    overrides: [
      playStatisticsRepositoryProvider.overrideWithValue(repo),
      playStatisticsClockProvider.overrideWithValue(clock),
    ],
  );
  return scope.container.read(playStatisticsPageProvider.notifier);
}

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
    final scope = ProviderTestScope(
      overrides: [
        playStatisticsRepositoryProvider.overrideWithValue(repository),
      ],
    );
    provider = scope.container.read(playStatisticsPageProvider.notifier);
  });

  tearDown(() async {
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

  _ScriptedRepository scripted() {
    return _ScriptedRepository(
      databaseProvider: () => db,
      statisticsSync: testStatisticsSyncStore(() => db),
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
    final days = provider.view!.snapshot.daily;
    expect(days.map((day) => day.day.year), contains(old.year));
    final entry = AnnualReportEntry.fromDaily(days, now: now);
    expect(entry.isVisible, isTrue);
    expect(entry.years, contains(old.year));
  });

  test('跨午夜：一次加载只读一次时钟，窗口 / 视图 / 高亮一致', () async {
    final first = DateTime(2031, 1, 1, 23, 59, 59);
    final second = DateTime(2031, 1, 2, 0, 0, 1);
    final third = DateTime(2031, 1, 3, 12);
    final clock = _FakeClock([first, second, third]);
    final scoped = _scopedProvider(repository, clock.next);

    final startedAt = first.subtract(const Duration(days: 1));
    await insertPlayEvent(
      db,
      songId: 's1',
      title: 'Track',
      startedAt: startedAt.millisecondsSinceEpoch,
      endedAt: startedAt.millisecondsSinceEpoch + 120000,
      listenedMs: 120000,
      maxPositionMs: 120000,
      endReason: 'completed',
    );

    await scoped.setRange(PlayStatisticsRange.week);

    expect(clock.reads, 1);
    final window = scoped.window!;
    expect(window.range, PlayStatisticsRange.week);
    expect(window.now, first);
    expect(window.start, first.subtract(const Duration(days: 7)));
    expect(scoped.view!.window, same(window));
    expect(scoped.view!.today, DateTime(2031, 1, 1));
    expect(scoped.view!.window.start, window.start);
    expect(scoped.view!.firstDay, DateTime(2030, 12, 31));

    clock.armNext();
    await scoped.refresh();

    expect(clock.reads, 2);
    expect(scoped.window!.now, second);
    expect(scoped.view!.today, DateTime(2031, 1, 2));
    expect(
      scoped.view!.window.start,
      second.subtract(const Duration(days: 7)),
      reason: '高亮起点跟着同一次加载的窗口移动',
    );

    clock.armNext();
    await scoped.setRange(PlayStatisticsRange.all);

    expect(clock.reads, 3);
    expect(scoped.window!.now, third);
    expect(scoped.view!.window.start, isNull);
    expect(scoped.view!.today, DateTime(2031, 1, 3));
  });

  test('成功加载后重载失败：保留旧的窗口 / 视图对', () async {
    final first = DateTime(2031, 1, 1, 23, 59, 59);
    final second = DateTime(2031, 1, 2, 0, 0, 1);
    final clock = _FakeClock([first, second]);
    final repo = scripted()
      ..enqueue(() async => _snapshot(totalListenedMs: 100))
      ..enqueue(() async => throw StateError('boom'));
    addTearDown(repo.dispose);
    final scoped = _scopedProvider(repo, clock.next);

    await scoped.ensureLoaded();
    final accepted = scoped.view!;
    expect(accepted.window.now, first);
    expect(scoped.hasLoaded, isTrue);
    expect(scoped.hasError, isFalse);

    clock.armNext();
    await scoped.refresh();

    expect(clock.reads, 2);
    expect(scoped.hasLoaded, isTrue);
    expect(scoped.hasError, isTrue);
    expect(scoped.view, same(accepted), reason: '失败不替换已显示的视图');
    expect(scoped.window!.now, first, reason: '窗口跟着视图，不先移交给失败加载');
    expect(scoped.snapshot!.summary.totalListenedMs, 100);
  });

  test('旧快照晚到：保留新范围的窗口 / 视图', () async {
    final older = Completer<ListeningStatisticsSnapshot>();
    final newer = Completer<ListeningStatisticsSnapshot>();
    final repo = scripted()
      ..enqueue(() => older.future)
      ..enqueue(() => newer.future);
    addTearDown(repo.dispose);
    final firstNow = DateTime(2031, 1, 1, 23, 59, 59);
    final secondNow = DateTime(2031, 1, 2, 0, 0, 1);
    final clock = _FakeClock([firstNow, secondNow]);
    final scoped = _scopedProvider(repo, clock.next);

    final firstLoad = scoped.ensureLoaded();
    clock.armNext();
    final secondLoad = scoped.setRange(PlayStatisticsRange.week);

    newer.complete(_snapshot(totalListenedMs: 200));
    await secondLoad;
    final accepted = scoped.view!;
    expect(accepted.window.now, secondNow);
    expect(accepted.window.range, PlayStatisticsRange.week);
    expect(accepted.snapshot.summary.totalListenedMs, 200);

    older.complete(_snapshot(totalListenedMs: 100));
    await firstLoad;

    expect(clock.reads, 2);
    expect(scoped.view, same(accepted), reason: '过期结果不得覆盖新视图');
    expect(scoped.window!.now, secondNow);
    expect(scoped.snapshot!.summary.totalListenedMs, 200);
  });

  test('跨年窗口：入口 / 年度覆盖 / 导出时间戳共用已接受窗口', () async {
    final before = DateTime(2030, 12, 31, 23, 59, 59);
    final after = DateTime(2031, 1, 1, 0, 0, 1);
    final firstPlayedAt = DateTime(2030, 12, 31, 23, 30);
    final clock = _FakeClock([before, after]);
    final repo = scripted()
      ..enqueue(
        () async => _snapshot(
          daily: [
            DayListened(
              day: DateTime(2030, 12, 31),
              listenedMs: 120000,
              playCount: 1,
            ),
          ],
          firstPlayedAt: firstPlayedAt,
        ),
      )
      ..enqueue(() async => throw StateError('boom'));
    addTearDown(repo.dispose);
    final scoped = _scopedProvider(repo, clock.next);

    // 真实库里的事件让年度快照读到同一份首播事实。
    await insert(DateTime(2030, 12, 31, 23, 30), 's1');

    await scoped.ensureLoaded();
    final view = scoped.view!;
    expect(view.window.now, before);
    expect(view.firstPlayedAt, firstPlayedAt);
    expect(view.annualEntry.featuredYear, 2030);
    expect(view.annualEntry.prominent, isTrue);

    final annualData = await repo.annualSnapshot(
      since: DateTime(2030).millisecondsSinceEpoch,
      until: DateTime(2031).millisecondsSinceEpoch,
    );
    final report = buildAnnualReport(
      year: view.annualEntry.featuredYear,
      data: annualData,
      now: view.window.now,
      knownSourceNames: const {},
      firstPlayedAt: view.firstPlayedAt,
    );
    expect(report.coverageStart, firstPlayedAt);
    expect(report.asOfToday, isTrue);

    final export = await scoped.buildExportJson();
    expect(export.exportedAt, before);
    expect(
      playStatisticsExportFileName(export.exportedAt),
      'molia_listening_2030-12-31T23-59-59.000.json',
    );

    // 跨过年后重载失败：旧视图 / 旧时间戳保持不变。
    clock.armNext();
    await scoped.refresh();
    expect(scoped.hasError, isTrue);
    expect(scoped.view, same(view));
    expect(scoped.view!.window.now, before);
    expect((await scoped.buildExportJson()).exportedAt, before);
  });

  test('首次加载失败：没有已接受窗口时不盖导出时间戳', () async {
    final clock = _FakeClock([DateTime(2031, 1, 2, 12)]);
    final repo = scripted()..enqueue(() async => throw StateError('boom'));
    addTearDown(repo.dispose);
    final scoped = _scopedProvider(repo, clock.next);

    await scoped.ensureLoaded();

    expect(scoped.view, isNull);
    await expectLater(scoped.buildExportJson(), throwsStateError);
  });

  test('首次加载失败：窗口 / 视图保持 null', () async {
    final clock = _FakeClock([DateTime(2031, 1, 2, 12)]);
    final repo = scripted()..enqueue(() async => throw StateError('boom'));
    addTearDown(repo.dispose);
    final scoped = _scopedProvider(repo, clock.next);

    await scoped.ensureLoaded();

    expect(clock.reads, 1);
    expect(scoped.hasLoaded, isFalse);
    expect(scoped.hasError, isTrue);
    expect(scoped.view, isNull);
    expect(scoped.snapshot, isNull);
    expect(scoped.window, isNull);
    expect(scoped.isEmpty, isFalse);
  });
}
