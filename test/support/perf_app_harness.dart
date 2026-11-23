/// 性能场景的应用装配：与 `test/app/desktop_shell_test.dart` 同源的 provider
/// 树，换成 1k 条确定性数据，供 `integration_test/perf_flows_test.dart` 在
/// profile 模式下驱动真实壳层。
///
/// 为什么复用假仓库而不是真实 DB：帧体检要的是可重复的列表长度与滚动路径；
/// 真实启动 / DB 开销由 `tool/agent/startup.sh` 与真实应用单独测。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/app_shell.dart';
import 'package:molia/app/bootstrap/runtime_providers.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/library_write_engine.dart'
    show favoritesPlaylistRowName;
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/library_browse.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/channel_selection.dart';
import 'package:molia/providers/discover_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/local_library_provider.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/providers/nav_provider.dart';
import 'package:molia/providers/play_statistics_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/search_provider.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/providers/theme_provider.dart';
import 'package:molia/services/back_claims.dart';
import 'package:molia/services/download/download_records.dart';
import 'package:molia/services/escape_claims.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:molia/services/shortcut_bindings.dart';
import 'package:molia/services/shortcut_settings.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_library_repository.dart';
import 'fake_music_source.dart';
import 'fakes.dart';
import 'cover_test_support.dart';
import 'memory_database.dart';
import 'settings_test_support.dart';
import 'sync_test_support.dart';

const String _favoritesName = '__favorites__';

/// 可选的真实内存库注入句柄：不传时 `pumpPerfApp` 保持 fake-async 口径。
///
/// 为什么需要两条装配路径：widget 测试依赖 [FakeLibraryRepository] 的
/// fake-async 时序；但 10k 曲库的 provider 重建 / 页面 notify 帧成本只有
/// 真实 drift 读路径（`LibraryRepository` + `LocalLibraryProvider`）能量出来
/// ——`LocalLibraryProvider` 的类型要求是具体仓库，fake 仓库替换不了。
class PerfRealLibrary {
  PerfRealLibrary({required this.favorites, this.statisticsDays = 0});

  /// 真实收藏列表的行数（0 = 只建空库，不加收藏）。
  final int favorites;

  /// 统计事件覆盖的天数（0 = 不塞统计；每天 1–3 条）。
  final int statisticsDays;

  MoliaDatabase? _database;
  LibraryRepository? _repository;
  LocalLibraryProvider? _localLibrary;
  PlayStatisticsRepository? _statisticsRepository;
  PlayStatisticsProvider? _statisticsProvider;

  MoliaDatabase get database => _database!;
  LibraryRepository get repository => _repository!;
  LocalLibraryProvider get localLibrary => _localLibrary!;
  PlayStatisticsRepository get statisticsRepository => _statisticsRepository!;
  PlayStatisticsProvider get statisticsProvider => _statisticsProvider!;

  /// 最近一次发布的浏览索引（provider 首轮 / 增量重建后非空）。
  LibraryBrowseIndex? get browseIndex => _localLibrary?.snapshot?.index;
}

/// 挂载一屏真实壳层 + [favoritesCount] 条收藏；返回播放后端供切歌场景使用。
///
/// [size] 是测试视口的逻辑尺寸（DPR 固定 1）。默认桌面宽度；小屏展开场景
/// 需要从首帧就用手机宽度装配——播放页会在 1440 宽走大屏两栏版式（没有
/// 迷你态），且运行中跨断点切换会让隐藏页的两套歌词视图短暂共用一个
/// ScrollController。
///
/// [realLibrary] 非空时额外注入一套真实内存资料库（10k 收藏 / 统计事件），
/// 页面仍在用 fake 仓库；详见 [PerfRealLibrary]。
Future<FakePlaybackFacade> pumpPerfApp(
  WidgetTester tester, {
  required bool desktopShell,
  int favoritesCount = 1000,
  Size size = const Size(1440, 900),
  bool showOnboarding = false,
  bool resetPreferences = true,
  bool waitForHome = true,
  PerfRealLibrary? realLibrary,
  bool disableAnimations = false,
  List<SingleChildWidget> extraProviders = const [],

  /// 在 MaterialApp 外再包一层（UI 预览用 RepaintBoundary 截图）；null = 原样。
  Widget Function(Widget child)? wrap,
}) async {
  if (resetPreferences) {
    SharedPreferences.setMockInitialValues({
      'shell_home_destination': 'favorites',
    });
  }
  // 全静态设置服务必须接线后才能读写（生产由组合根 attach；测试用内存注册表）。
  // 设置页 / 海报渲染 / 语言行都会在首帧后访问它们，缺一个就抛 StateError。
  final staticSettings = testSettingsRegistry();
  attachStaticSettingsForTest(staticSettings);
  await ShortcutSettings.load();
  await ShortcutSettings.instance.setInAppEnabled(true);
  await ShortcutSettings.instance.setGlobalEnabled(false);
  await ShortcutSettings.instance.resetScope(ShortcutScope.inApp);
  await ShortcutSettings.instance.resetScope(ShortcutScope.global);
  EscapeClaims.reset();
  BackClaims.reset();

  final themeContainer = ProviderContainer(
    overrides: [
      settingsRegistryProvider.overrideWithValue(testSettingsRegistry()),
    ],
  );
  addTearDown(themeContainer.dispose);
  final theme = themeContainer.read(themeProvider.notifier);
  await theme.preferencesReady;
  final nav = NavProvider(settings: testSettingsRegistry());
  addTearDown(nav.dispose);
  await nav.preferencesReady;

  final repository = FakeLibraryRepository();
  addTearDown(repository.dispose);
  final now = DateTime.now().millisecondsSinceEpoch;
  final favoritesId = await repository.createPlaylist(_favoritesName);
  await repository.addTracksToPlaylist(favoritesId, [
    for (var i = 0; i < favoritesCount; i++)
      PlaylistTrack(
        playlistId: favoritesId,
        sourceKey: 'perf',
        songId: 'song-$i',
        title: 'Performance Track $i',
        artist: 'Perf Artist ${i % 100}',
        album: 'Perf Album ${i % 40}',
        durationMs: 180000 + i * 1000,
        addedAt: now + i,
        sortOrder: i,
      ),
  ], favoriteChange: true);

  final backend = FakePlaybackFacade();
  final playback = buildTestPlaybackProvider(
    settings: testSettingsRegistry(),
    facade: backend,
    libraryRepository: repository,
  );
  addTearDown(playback.dispose);
  final library = LibraryProvider(
    repository: repository,
    playbackProvider: playback,
  );
  addTearDown(library.dispose);

  // 真实内存库只在显式请求时装配：默认装配仍是 fake 仓库，时序不受影响。
  final realLibraryProviders = <SingleChildWidget>[];
  if (realLibrary != null) {
    realLibraryProviders.addAll(
      await _installRealLibrary(realLibrary, playback),
    );
  }

  final sourceManager = SourceManager(settings: testSettingsRegistry());
  final sources = SourcesProvider(sourceManager);
  addTearDown(() {
    sources.dispose();
    sourceManager.dispose();
  });
  const searchChannels = ['kw'];
  final selection = ChannelSelection(
    validKeys: () => searchChannels,
    defaultKey: () => searchChannels.first,
  );
  addTearDown(selection.dispose);
  final discover = DiscoverProvider(
    playbackProvider: playback,
    libraryProvider: library,
    selection: selection,
    sources: const {},
  );
  addTearDown(discover.dispose);

  final searchSource = FakeMusicSource(
    'kw',
    items: [
      for (var i = 0; i < 80; i++)
        Track(
          id: TrackId('kw', 'search-$i'),
          title: 'Search Result $i',
          artists: [Artist(name: 'Search Artist ${i % 20}')],
          album: 'Search Album',
          duration: const Duration(minutes: 3),
          origin: TrackOrigin.builtin,
        ),
    ],
  );
  final registry = FakeSourceRegistry({'kw': searchSource});
  final search = SearchProvider(
    playback,
    selection: selection,
    catalogService: CatalogService(registry: registry),
    sourceRegistry: registry,
  );
  addTearDown(search.dispose);
  final lyrics = LyricsProvider(service: LyricsService(providers: const []));
  addTearDown(lyrics.dispose);
  final lyricsDisplay = LyricsDisplaySettings(settings: testSettingsRegistry());
  addTearDown(lyricsDisplay.dispose);

  final queue = [
    for (var i = 0; i < 30; i++)
      Track(
        id: TrackId('perf', 'queue-$i'),
        title: 'Queue Track $i',
        artists: [Artist(name: 'Queue Artist ${i % 10}')],
        album: 'Queue Album',
        duration: const Duration(minutes: 4),
        origin: TrackOrigin.lx,
        payload: {'id': i},
      ),
  ];
  backend.emit(
    PlaybackSnapshot(
      current: queue.first,
      queue: queue,
      currentIndex: 0,
      isPlaying: true,
      duration: queue.first.duration ?? Duration.zero,
      upNext: queue.sublist(1),
    ),
    position: const Duration(seconds: 30),
  );

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: themeContainer,
      child: MultiProvider(
        providers: [
          coverStoreProvider(),
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          ChangeNotifierProvider<LibraryProvider>.value(value: library),
          ChangeNotifierProvider<SourcesProvider>.value(value: sources),
          ChangeNotifierProvider<ChannelSelection>.value(value: selection),
          ChangeNotifierProvider<DiscoverProvider>.value(value: discover),
          ChangeNotifierProvider<SearchProvider>.value(value: search),
          ChangeNotifierProvider<LyricsProvider>.value(value: lyrics),
          ChangeNotifierProvider<LyricsDisplaySettings>.value(
            value: lyricsDisplay,
          ),
          ChangeNotifierProvider<NavProvider>.value(value: nav),
          ...realLibraryProviders,
          ...extraProviders,
        ],
        child: (wrap ?? (child) => child)(
          MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            supportedLocales: const [Locale('zh')],
            // 系统「减弱动效」：部分用例验证 spatial 导航动效的直达终态。
            builder: disableAnimations
                ? (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(disableAnimations: true),
                    child: child!,
                  )
                : null,
            home: MyApp(
              desktopShell: desktopShell,
              showOnboarding: showOnboarding,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  if (waitForHome) {
    await waitForFinder(
      tester,
      find.text('Performance Track 0'),
      reason: '收藏首屏未出现',
    );
  }
  return backend;
}

/// 装配真实内存库：收藏行 / 统计事件 / provider 三件套一次建好。
///
/// provider 只通过 [SingleChildWidget] 列表挂进树；页面正在用的
/// FakeLibraryRepository 与 LibraryProvider 不受影响——本场景测的是「真实库
/// 触发 → LocalLibraryProvider 重建 / 发布 → 页面 notify」的帧成本。
Future<List<SingleChildWidget>> _installRealLibrary(
  PerfRealLibrary handle,
  PlaybackProvider playback,
) async {
  final db = openMemoryDatabase();
  // tearDown 逆序执行：db 最后关，仓库与 provider 先释放。
  addTearDown(db.close);

  final repository = LibraryRepository(
    databaseProvider: () => db,
    stamps: testStampIssuer(),
  );
  addTearDown(repository.dispose);

  if (handle.favorites > 0) {
    final favoritesId = await repository.createPlaylist(
      favoritesPlaylistRowName,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    await repository.addTracksToPlaylist(favoritesId, [
      for (var i = 0; i < handle.favorites; i++)
        PlaylistTrack(
          playlistId: favoritesId,
          sourceKey: 'perf',
          songId: 'song-$i',
          title: 'Performance Track $i',
          artist: 'Perf Artist ${i % 100}',
          album: 'Perf Album ${i % 40}',
          durationMs: 180000 + i * 1000,
          addedAt: now + i,
          sortOrder: i,
        ),
    ], favoriteChange: true);
  }

  final statisticsRepository = PlayStatisticsRepository(
    databaseProvider: () => db,
    statisticsSync: testStatisticsSyncStore(() => db),
  );
  addTearDown(statisticsRepository.dispose);

  if (handle.statisticsDays > 0) {
    await _seedStatistics(db, handle.statisticsDays);
  }

  final downloads = DownloadRecords(initialized: true, supported: false);
  addTearDown(downloads.dispose);

  // 只给 LocalLibraryProvider 绑定用：页面仍读树里那个 fake LibraryProvider。
  final realLibrary = LibraryProvider(
    repository: repository,
    playbackProvider: playback,
  );
  addTearDown(realLibrary.dispose);

  final localLibrary = LocalLibraryProvider(
    repository: repository,
    downloads: downloads,
    library: realLibrary,
    statistics: statisticsRepository,
  );
  addTearDown(localLibrary.dispose);

  PlayStatisticsProvider? statisticsProvider;
  if (handle.statisticsDays > 0) {
    statisticsProvider = PlayStatisticsProvider(
      repository: statisticsRepository,
    );
    addTearDown(statisticsProvider.dispose);
  }

  handle
    .._database = db
    .._repository = repository
    .._localLibrary = localLibrary
    .._statisticsRepository = statisticsRepository
    .._statisticsProvider = statisticsProvider;

  return [
    ChangeNotifierProvider<LocalLibraryProvider>.value(value: localLibrary),
    if (statisticsProvider != null)
      ChangeNotifierProvider<PlayStatisticsProvider>.value(
        value: statisticsProvider,
      ),
  ];
}

/// 造统计事件覆盖日历热力图与时段热力图：每天 1–3 条、小时按天错开。
///
/// 一次事务里写入（`insertPlayEvent` 每行都要查 `play_tracks`）：逐条 await
/// 不事务在 10k 级 fixture 上会明显拖慢 drive 启动。
Future<void> _seedStatistics(MoliaDatabase db, int days) async {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  const songCount = 24;
  await db.transaction(() async {
    for (var day = 0; day < days; day++) {
      final date = today.subtract(Duration(days: day));
      final events = 1 + day % 3;
      for (var i = 0; i < events; i++) {
        final song = (day + i) % songCount;
        final started = date.add(
          Duration(
            hours: (day * 7 + i * 5) % 24,
            minutes: (day * 11 + i * 17) % 60,
          ),
        );
        final listenedMs = 60000 + (day * 37 + i * 53) % 180000;
        await insertPlayEvent(
          db,
          sourceKey: 'perf',
          songId: 'stat-$song',
          title: 'Stat Track $song',
          artist: 'Perf Artist ${song % 8}',
          album: 'Perf Album ${song % 5}',
          durationMs: 220000,
          startedAt: started.millisecondsSinceEpoch,
          endedAt: started.millisecondsSinceEpoch + listenedMs,
          listenedMs: listenedMs,
          maxPositionMs: listenedMs,
          endReason: i == 0 ? 'completed' : 'skipped',
        );
      }
    }
  });
}

/// 有上限的等待：profile 下首帧与异步加载比 widget test 慢，不能用
/// 无上限的 `pumpAndSettle`。
Future<void> waitForFinder(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
  String reason = '',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail('等待超时${reason.isEmpty ? '' : '：$reason'}');
}

/// 让连续动画 / 异步加载推进若干帧（不做 settle，避免无限动画挂住）。
Future<void> pumpFrames(
  WidgetTester tester, {
  int frames = 8,
  Duration interval = const Duration(milliseconds: 16),
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(interval);
  }
}

/// 泵帧直到条件成立（真实异步：防抖 / isolate / DB 读）。
///
/// 帧间隔保持 16ms（不是 [waitForFinder] 的 100ms），场景帧统计才采得到
/// 中间的重建帧；超时仍显式失败，避免空场景静默通过。
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
  Duration interval = const Duration(milliseconds: 16),
  String reason = '',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await tester.pump(interval);
  }
  if (condition()) return;
  fail('等待条件超时${reason.isEmpty ? '' : '：$reason'}');
}
