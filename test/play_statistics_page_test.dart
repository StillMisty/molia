import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/play_statistics_page.dart';
import 'package:molia/providers/play_statistics_provider.dart';

/// 听歌统计页冒烟测试：有数据渲染、空态与窄屏无溢出。
///
/// 用数据替身（不触库）：widget 测试的 fake async 与 sqflite FFI 的真实
/// 异步不兼容；统计仓库的 SQL 行为已由 repository 单测覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  _FakeStatisticsRepository buildFakeRepository() {
    final now = DateTime.now();
    return _FakeStatisticsRepository(
      summaryData: PlayStatisticsSummary(
        playCount: 3,
        qualifiedPlayCount: 2,
        totalListenedMs: 600000,
        uniqueTrackCount: 2,
        completionRate: 2 / 3,
        skipRate: 1 / 3,
        firstPlayedAt:
            now.subtract(const Duration(days: 40)).millisecondsSinceEpoch,
      ),
      topTracksData: [
        PlayStatTrackEntry(
          sourceKey: 'wy',
          songId: 'a',
          title: 'Hello Song',
          artist: 'Artist A',
          durationMs: 200000,
          raw: const {'id': 'a'},
          playCount: 2,
          listenedMs: 400000,
          lastPlayedAt: now.millisecondsSinceEpoch,
        ),
      ],
      topArtistsData: const [
        PlayStatArtistEntry(
          artist: 'Artist A',
          playCount: 2,
          listenedMs: 400000,
        ),
      ],
      dailyData: [
        DayListened(
          day: DateUtils.dateOnly(now),
          listenedMs: 400000,
          playCount: 2,
        ),
      ],
      byWeekdayHourData: [
        WeekdayHourListened(
          weekday: 0,
          hour: 9,
          listenedMs: 600000,
          playCount: 2,
        ),
      ],
      sourcesData: const [
        SourceListened(sourceKey: 'wy', listenedMs: 600000, playCount: 2),
      ],
    );
  }

  Future<void> pumpPage(
    WidgetTester tester,
    PlayStatisticsRepository repository,
    PlayStatisticsProvider provider, {
    Size size = const Size(900, 2000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<PlayStatisticsRepository>.value(value: repository),
          ChangeNotifierProvider<PlayStatisticsProvider>.value(value: provider),
        ],
        child: M3EMaterialApp(
          data: M3EThemeData.fromMaterial(ThemeData()),
          theme: ThemeData(),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('en'), Locale('zh')],
          home: const PlayStatisticsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('有数据：渲染汇总数字块、热力图与榜单', (tester) async {
    final repository = buildFakeRepository();
    final provider = PlayStatisticsProvider(repository: repository);
    addTearDown(provider.dispose);
    await provider.ensureLoaded();

    await pumpPage(tester, repository, provider);

    expect(find.text('Valid plays'), findsOneWidget);
    expect(find.text('Listening time'), findsOneWidget);
    expect(find.text('Most played'), findsOneWidget);
    expect(find.text('Hello Song'), findsWidgets);
    expect(find.text('Top artists'), findsOneWidget);
    expect(find.text('Completion rate'), findsOneWidget);
    expect(find.text('Skip rate'), findsOneWidget);
    expect(find.byKey(const Key('statsAiDjButton')), findsOneWidget);
  });

  testWidgets('窄屏（320dp）：布局无溢出', (tester) async {
    final repository = buildFakeRepository();
    final provider = PlayStatisticsProvider(repository: repository);
    addTearDown(provider.dispose);
    await provider.ensureLoaded();

    await pumpPage(tester, repository, provider, size: const Size(320, 1600));

    expect(find.text('Valid plays'), findsOneWidget);
    expect(find.text('Most played'), findsOneWidget);
  });

  testWidgets('无数据：展示空态', (tester) async {
    final repository = _FakeStatisticsRepository(
      summaryData: PlayStatisticsSummary.empty,
    );
    final provider = PlayStatisticsProvider(repository: repository);
    addTearDown(provider.dispose);
    await provider.ensureLoaded();

    await pumpPage(tester, repository, provider);

    expect(find.text('No listening history yet'), findsOneWidget);
    expect(find.text('Most played'), findsNothing);
  });
}

/// 数据替身：只覆写查询方法，不触数据库。
class _FakeStatisticsRepository extends PlayStatisticsRepository {
  _FakeStatisticsRepository({
    required this.summaryData,
    this.topTracksData = const [],
    this.topArtistsData = const [],
    this.dailyData = const [],
    this.byWeekdayHourData = const [],
    this.sourcesData = const [],
  }) : super(databaseProvider: _unusedDatabase);

  static Future<Database> _unusedDatabase() async =>
      throw StateError('测试不访问数据库');

  final PlayStatisticsSummary summaryData;
  final List<PlayStatTrackEntry> topTracksData;
  final List<PlayStatArtistEntry> topArtistsData;
  final List<DayListened> dailyData;
  final List<WeekdayHourListened> byWeekdayHourData;
  final List<SourceListened> sourcesData;

  @override
  Future<PlayStatisticsSummary> summary({int? since}) async => summaryData;

  @override
  Future<List<PlayStatTrackEntry>> topTracks(
          {int? since, int limit = 10}) async =>
      topTracksData;

  @override
  Future<List<PlayStatArtistEntry>> topArtists(
          {int? since, int limit = 10}) async =>
      topArtistsData;

  @override
  Future<List<DayListened>> listenedByDay({int? since}) async => dailyData;

  @override
  Future<List<WeekdayHourListened>> listenedByWeekdayHour({int? since}) async =>
      byWeekdayHourData;

  @override
  Future<List<SourceListened>> sourceDistribution({int? since}) async =>
      sourcesData;
}
