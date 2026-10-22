/// 性能场景的应用装配：与 `test/app/desktop_shell_test.dart` 同源的 provider
/// 树，换成 1k 条确定性数据，供 `integration_test/perf_flows_test.dart` 在
/// profile 模式下驱动真实壳层。
///
/// 为什么复用假仓库而不是真实 DB：帧体检要的是可重复的列表长度与滚动路径；
/// 真实启动 / DB 开销由 `tool/agent/startup.sh` 与真实应用单独测。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/app_shell.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/discover_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/providers/nav_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/search_provider.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/providers/theme_provider.dart';
import 'package:molia/services/escape_claims.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:molia/services/shortcut_bindings.dart';
import 'package:molia/services/shortcut_settings.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_library_repository.dart';
import 'fake_music_source.dart';
import 'fakes.dart';
import 'settings_test_support.dart';

const String _favoritesName = '__favorites__';

/// 挂载一屏真实壳层 + [favoritesCount] 条收藏；返回播放后端供切歌场景使用。
Future<FakePlaybackBackend> pumpPerfApp(
  WidgetTester tester, {
  required bool desktopShell,
  int favoritesCount = 1000,
}) async {
  SharedPreferences.setMockInitialValues({
    'shell_home_destination': 'favorites',
  });
  await ShortcutSettings.instance.setInAppEnabled(true);
  await ShortcutSettings.instance.setGlobalEnabled(false);
  await ShortcutSettings.instance.resetScope(ShortcutScope.inApp);
  await ShortcutSettings.instance.resetScope(ShortcutScope.global);
  EscapeClaims.reset();

  final theme = ThemeProvider(settings: testSettingsRegistry());
  addTearDown(theme.dispose);
  await theme.preferencesReady;
  final nav = NavProvider(settings: testSettingsRegistry());
  addTearDown(nav.dispose);
  await nav.preferencesReady;

  final repository = FakeLibraryRepository();
  addTearDown(repository.dispose);
  final now = DateTime.now().millisecondsSinceEpoch;
  final favoritesId = await repository.createPlaylist(_favoritesName);
  await repository.addTracksToPlaylist(
    favoritesId,
    [
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
    ],
    favoriteChange: true,
  );

  final backend = FakePlaybackBackend();
  final playback = buildTestPlaybackProvider(
    settings: testSettingsRegistry(),
    backend: backend,
    libraryRepository: repository,
  );
  addTearDown(playback.dispose);
  final library = LibraryProvider(
    repository: repository,
    playbackProvider: playback,
  );
  addTearDown(library.dispose);

  final sourceManager = SourceManager(settings: testSettingsRegistry());
  final sources = SourcesProvider(sourceManager);
  addTearDown(() {
    sources.dispose();
    sourceManager.dispose();
  });
  final discover = DiscoverProvider(
    playbackProvider: playback,
    libraryProvider: library,
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
  backend.emit(BackendSnapshot(
    current: queue.first,
    queue: queue,
    currentIndex: 0,
    isPlaying: true,
    position: const Duration(seconds: 30),
    duration: queue.first.duration ?? Duration.zero,
    upNext: queue.sublist(1),
  ));

  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
        ChangeNotifierProvider<LibraryProvider>.value(value: library),
        ChangeNotifierProvider<SourcesProvider>.value(value: sources),
        ChangeNotifierProvider<DiscoverProvider>.value(value: discover),
        ChangeNotifierProvider<SearchProvider>.value(value: search),
        ChangeNotifierProvider<LyricsProvider>.value(value: lyrics),
        ChangeNotifierProvider<LyricsDisplaySettings>.value(
          value: lyricsDisplay,
        ),
        ChangeNotifierProvider<NavProvider>.value(value: nav),
        ChangeNotifierProvider<ThemeProvider>.value(value: theme),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        home: MyApp(desktopShell: desktopShell),
      ),
    ),
  );
  await tester.pump();
  await waitForFinder(
    tester,
    find.text('Performance Track 0'),
    reason: '收藏首屏未出现',
  );
  return backend;
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
