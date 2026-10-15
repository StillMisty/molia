import 'package:flutter_test/flutter_test.dart';
import 'package:molia/app/app_shell.dart';
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
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:molia/widgets/player.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_library_repository.dart';
import 'support/fake_music_source.dart';
import 'support/fakes.dart';

/// 壳层底栏重复点击的路由测试：挂载真实应用壳（`MyApp`）。
///
/// 覆盖：播放页已选中时重复点击 = 迷你 ⇄ 完整；其他目的地重复点击 = 走页面
/// 自己的响应（不动播放器）；进入播放页的飞行期间重复点击被忽略。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NavProvider nav;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 装配与组合根同源的 provider 树并挂载壳层（provider 在测试体内创建：
  /// 偏好加载的 Future 必须在 fake-async 区内解析，否则会晚于 dispose 落地）。
  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final theme = ThemeProvider();
    addTearDown(theme.dispose);
    await theme.preferencesReady;
    nav = NavProvider();
    addTearDown(nav.dispose);
    await nav.preferencesReady;

    final repository = FakeLibraryRepository();
    addTearDown(repository.dispose);
    final backend = FakePlaybackBackend();
    final playback = buildTestPlaybackProvider(
      backend: backend,
      libraryRepository: repository,
    );
    addTearDown(playback.dispose);
    final library = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
    addTearDown(library.dispose);
    final sourceManager = SourceManager();
    final sources = SourcesProvider(sourceManager);
    addTearDown(() {
      sources.dispose();
      sourceManager.dispose();
    });
    // 空发现源：资料页走「无可选渠道」空态，不触发真实网络。
    final discover = DiscoverProvider(
      playbackProvider: playback,
      libraryProvider: library,
      sources: const {},
    );
    addTearDown(discover.dispose);
    final search = SearchProvider(
      playback,
      sourceRegistry: FakeSourceRegistry(const {}),
    );
    addTearDown(search.dispose);
    final lyrics = LyricsProvider();
    addTearDown(lyrics.dispose);
    final lyricsDisplay = LyricsDisplaySettings();
    addTearDown(lyricsDisplay.dispose);

    backend.emit(BackendSnapshot(
      current: Track(
        id: const TrackId('fake', 'a'),
        title: 'Title a',
        artists: const [Artist(name: 'Artist a')],
        album: 'Album',
        duration: const Duration(seconds: 30),
        // 不带封面：避免测试触发网络预取/取色。
        origin: TrackOrigin.lx,
        payload: const {'id': 'a'},
      ),
      queue: const [],
      currentIndex: 0,
      isPlaying: false,
      position: Duration.zero,
      duration: const Duration(seconds: 30),
    ));

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
          home: const MyApp(),
        ),
      ),
    );
    await tester.pump();
    // 首帧切歌入场动画（封面堆叠 460ms）。
    await tester.pump(const Duration(milliseconds: 600));
  }

  /// 点在底栏某个目的地的正中（底栏目的地等宽均分）。
  Future<void> tapBottomDestination(
    WidgetTester tester,
    ShellDestination destination,
  ) async {
    final visible = nav.visibleDestinations;
    final index = visible.indexOf(destination);
    expect(index, isNonNegative, reason: '目的地应可见：$destination');
    final rect = tester.getRect(find.byType(M3ENavigationBar));
    await tester.tapAt(
      Offset(
        rect.left + rect.width * (index + 0.5) / visible.length,
        rect.center.dy,
      ),
    );
  }

  /// 走完一次切页过渡（含顶栏 ⇄ 播放页共享元素飞行约 0.4s）。
  Future<void> settleTransition(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
  }

  double playerHeight(WidgetTester tester) =>
      tester.getSize(find.byType(Player)).height;

  int selectedNavIndex(WidgetTester tester) =>
      tester.widget<M3ENavigationBar>(find.byType(M3ENavigationBar))
          .selectedIndex;

  int navIndexOf(ShellDestination destination) =>
      nav.visibleDestinations.indexOf(destination);

  testWidgets('底栏重复点击「播放」：迷你 ⇄ 完整切换', (tester) async {
    await pumpShell(tester);
    expect(selectedNavIndex(tester), navIndexOf(ShellDestination.nowPlaying));
    expect(playerHeight(tester), greaterThan(300), reason: '默认完整态');

    // 播放页已选中：重复点击 → 收起为迷你条。
    await tapBottomDestination(tester, ShellDestination.nowPlaying);
    await settleTransition(tester);
    expect(playerHeight(tester), lessThan(100), reason: '重复点击应收起为迷你条');
    expect(selectedNavIndex(tester), navIndexOf(ShellDestination.nowPlaying));

    // 再点 → 展开。
    await tapBottomDestination(tester, ShellDestination.nowPlaying);
    await settleTransition(tester);
    expect(playerHeight(tester), greaterThan(300), reason: '再点应展开');
  });

  testWidgets('底栏重复点击其他目的地：仍正常切页，不动播放器', (tester) async {
    await pumpShell(tester);

    await tapBottomDestination(tester, ShellDestination.favorites);
    await settleTransition(tester);
    expect(selectedNavIndex(tester), navIndexOf(ShellDestination.favorites));
    expect(playerHeight(tester), greaterThan(300), reason: '切页不改展开态');

    // 收藏页已选中：重复点击走页面自己的响应（回到列表顶部），播放器不动。
    await tapBottomDestination(tester, ShellDestination.favorites);
    await settleTransition(tester);
    expect(selectedNavIndex(tester), navIndexOf(ShellDestination.favorites));
    expect(playerHeight(tester), greaterThan(300));
  });

  testWidgets('进入播放页的飞行期间重复点击：忽略', (tester) async {
    await pumpShell(tester);

    // 先离开播放页。
    await tapBottomDestination(tester, ShellDestination.favorites);
    await settleTransition(tester);

    // 进入播放页（开始顶栏 ⇄ 播放页飞行），飞行中再点一次。
    await tapBottomDestination(tester, ShellDestination.nowPlaying);
    await tester.pump(const Duration(milliseconds: 60));
    await tapBottomDestination(tester, ShellDestination.nowPlaying);
    await settleTransition(tester);

    expect(
      playerHeight(tester),
      greaterThan(300),
      reason: '飞行期间应忽略重复点击（否则与飞行副本抢封面）',
    );
    expect(selectedNavIndex(tester), navIndexOf(ShellDestination.nowPlaying));
  });
}
