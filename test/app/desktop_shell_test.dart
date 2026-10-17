import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/app_shell.dart';
import 'package:molia/app/desktop/desktop_shell.dart';
import 'package:molia/app/desktop/now_playing_bar.dart';
import 'package:molia/app/desktop/queue_panel.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/catalog.dart';
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
import 'package:molia/widgets/cover_appearance.dart';
import 'package:molia/widgets/global_search.dart';
import 'package:molia/widgets/player.dart';
import 'package:molia/widgets/queue.dart';
import 'package:molia/widgets/track_row.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_library_repository.dart';
import '../support/fake_music_source.dart';
import '../support/fakes.dart';

/// 桌面骨架（`MyApp(desktopShell: true)`）的挂载测试。
///
/// 覆盖骨架结构与两条不变量：桌面底栏 / 侧栏存在且顶栏瘦身（无播放控制、
/// 无进度线）；队列面板开关；底栏左区进播放页；移动骨架不受影响；
/// 窄窗口分级折叠（阈值只影响渲染、记忆值保留）；顶栏全局搜索（宽窗 pill /
/// 窄窗图标、docked 结果面板、查看全部结果切资料库）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = lookupAppLocalizations(const Locale('zh'));

  late NavProvider nav;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 装配与组合根同源的 provider 树并挂载壳层（骨架同 `app_shell_reselect_test`；
  /// provider 在测试体内创建：偏好加载的 Future 必须在 fake-async 区内解析）。
  ///
  /// [searchSource] 非空时给搜索 provider 接上假音源（顶栏搜索用例预置结果），
  /// [configureSearch] 在挂载前配置搜索状态（如先提交一次搜索）。
  Future<void> pumpShell(
    WidgetTester tester, {
    required bool desktopShell,
    Size size = const Size(1440, 900),
    FakeMusicSource? searchSource,
    void Function(SearchProvider search)? configureSearch,
  }) async {
    tester.view.physicalSize = size;
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
    final discover = DiscoverProvider(
      playbackProvider: playback,
      libraryProvider: library,
      sources: const {},
    );
    addTearDown(discover.dispose);
    final registry = FakeSourceRegistry(
      searchSource == null ? const {} : {'kw': searchSource},
    );
    final search = SearchProvider(
      playback,
      catalogService:
          searchSource == null ? null : CatalogService(registry: registry),
      sourceRegistry: registry,
    );
    addTearDown(search.dispose);
    configureSearch?.call(search);
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
          home: MyApp(desktopShell: desktopShell),
        ),
      ),
    );
    await tester.pump();
    // 首帧切歌入场动画（封面堆叠 460ms）+ 桌面布局偏好异步恢复。
    await tester.pump(const Duration(milliseconds: 600));
  }

  /// 走完一次切页过渡（含顶栏 ⇄ 播放页共享元素飞行约 0.4s）。
  Future<void> settleTransition(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
  }

  int selectedRailIndex(WidgetTester tester) => tester
      .widget<M3ENavigationRail>(find.byType(M3ENavigationRail))
      .selectedIndex;

  int navIndexOf(ShellDestination destination) =>
      nav.visibleDestinations.indexOf(destination);

  /// 顶栏搜索用例的假曲目（不带封面：避免测试触发网络预取 / 取色）。
  Track searchTrack(String id) => Track(
        id: TrackId('kw', id),
        title: 'Title $id',
        artists: [Artist(name: 'Artist $id')],
        album: 'Album',
        duration: const Duration(minutes: 3, seconds: 5),
        origin: TrackOrigin.builtin,
        payload: {'songmid': id},
      );

  /// 装配「已有结果」的顶栏搜索用例：假音源返回两条结果并先提交一次搜索。
  Future<void> pumpSearchShell(WidgetTester tester) async {
    final source = FakeMusicSource('kw');
    source.onSearch = (query) => Future.value(
          SearchResult(
            items: [searchTrack('a'), searchTrack('b')],
            total: 2,
          ),
        );
    await pumpShell(
      tester,
      desktopShell: true,
      searchSource: source,
      configureSearch: (search) => search.submitSearch('hello'),
    );
  }

  testWidgets('桌面骨架：底栏 / 侧栏存在，顶栏无播放控制与进度线', (tester) async {
    await pumpShell(tester, desktopShell: true);

    expect(find.byKey(DesktopNowPlayingBar.shellKey), findsOneWidget);
    expect(find.byType(M3ENavigationRail), findsOneWidget);
    expect(find.byType(M3ENavigationBar), findsNothing);

    // 顶栏瘦身：播放 / 下一首按钮与进度线只在移动骨架的顶栏里出现。
    final appBar = find.byType(AppBar);
    expect(
      find.descendant(
        of: appBar,
        matching: find.byIcon(Icons.skip_next_rounded),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: appBar, matching: find.byType(M3EProgressIndicator)),
      findsNothing,
    );
    // 顶栏标题 = 当前目的地。
    expect(
      find.descendant(of: appBar, matching: find.text(l10n.nowPlayingLabel)),
      findsOneWidget,
    );
  });

  testWidgets('队列面板：底栏开关打开 / 关闭', (tester) async {
    await pumpShell(tester, desktopShell: true);
    expect(find.byType(QueueDisplay), findsNothing);

    await tester.tap(find.byKey(DesktopNowPlayingBar.queueToggleKey));
    await settleTransition(tester);
    expect(find.byType(DesktopQueuePanel), findsOneWidget);
    expect(find.byType(QueueDisplay), findsOneWidget);

    await tester.tap(find.byKey(DesktopNowPlayingBar.queueToggleKey));
    await settleTransition(tester);
    expect(find.byType(QueueDisplay), findsNothing);
  });

  testWidgets('底栏左区点击：切回播放页', (tester) async {
    await pumpShell(tester, desktopShell: true);

    // 先离开播放页（点侧栏「收藏」）：播放页层保持挂载但不可命中。
    await tester.tap(
      find.descendant(
        of: find.byType(M3ENavigationRail),
        matching: find.text(l10n.favoritesLabel),
      ),
    );
    await settleTransition(tester);
    expect(selectedRailIndex(tester), navIndexOf(ShellDestination.favorites));
    expect(
      find.byType(Player).hitTestable(),
      findsNothing,
      reason: '播放页已被盖住（不可命中）',
    );

    // 点底栏封面（左区手势的一部分）→ 选中目的地回到播放页。
    await tester.tap(
      find.descendant(
        of: find.byKey(DesktopNowPlayingBar.shellKey),
        matching: find.byType(CoverCard),
      ),
    );
    await settleTransition(tester);
    expect(selectedRailIndex(tester), navIndexOf(ShellDestination.nowPlaying));
    expect(find.byType(Player).hitTestable(), findsOneWidget);
  });

  testWidgets('移动骨架不回归：无底栏 Key、底部导航栏仍在', (tester) async {
    await pumpShell(
      tester,
      desktopShell: false,
      size: const Size(420, 900),
    );

    expect(find.byKey(DesktopNowPlayingBar.shellKey), findsNothing);
    expect(find.byType(M3ENavigationBar), findsOneWidget);
    expect(find.byType(M3ENavigationRail), findsNothing);
  });

  testWidgets('窄窗口分级折叠：阈值只影响渲染，变宽后恢复', (tester) async {
    // 1100 < 1200：队列入口置灰（点了也看不到面板，不留死控件）。
    await pumpShell(
      tester,
      desktopShell: true,
      size: const Size(1100, 900),
    );
    expect(
      tester
          .widget<M3EIconButton>(
            find.byKey(DesktopNowPlayingBar.queueToggleKey),
          )
          .onPressed,
      isNull,
      reason: '窄窗口下队列入口置灰',
    );
    expect(find.byType(QueueDisplay), findsNothing);

    // 变宽后入口可用：打开面板（阈值不改写记忆值，只是渲染被抑制）。
    tester.view.physicalSize = const Size(1440, 900);
    await settleTransition(tester);
    await tester.tap(find.byKey(DesktopNowPlayingBar.queueToggleKey));
    await settleTransition(tester);
    expect(find.byType(QueueDisplay), findsOneWidget);

    // 再变窄：面板重新被抑制；回到宽窗后按记忆值自动恢复。
    tester.view.physicalSize = const Size(1100, 900);
    await settleTransition(tester);
    expect(find.byType(QueueDisplay), findsNothing);
    tester.view.physicalSize = const Size(1440, 900);
    await settleTransition(tester);
    expect(find.byType(QueueDisplay), findsOneWidget);

    // 侧栏：900 宽强制折叠（无展开入口），1440 宽恢复用户设定（展开）。
    tester.view.physicalSize = const Size(900, 900);
    await settleTransition(tester);
    expect(
      tester.widget<M3ENavigationRail>(find.byType(M3ENavigationRail)).type,
      M3ENavigationRailType.alwaysCollapse,
    );
    tester.view.physicalSize = const Size(1440, 900);
    await settleTransition(tester);
    expect(
      tester.widget<M3ENavigationRail>(find.byType(M3ENavigationRail)).type,
      M3ENavigationRailType.expanded,
    );
  });

  testWidgets('顶栏搜索入口：宽窗是搜索 pill，窄窗退化为图标按钮', (tester) async {
    await pumpShell(tester, desktopShell: true);

    expect(find.byKey(DesktopShell.searchEntryKey), findsOneWidget);
    expect(
      find.byType(GlobalSearch),
      findsOneWidget,
      reason: '宽窗搜索入口是顶栏全局搜索组件',
    );
    expect(
      find.byType(M3ESearchAnchor),
      findsOneWidget,
      reason: '宽窗搜索入口是 M3E 搜索 pill',
    );

    // < 900：入口退化为图标按钮（不再挂搜索锚点，顶栏不会被挤坏）。
    tester.view.physicalSize = const Size(800, 900);
    await settleTransition(tester);
    expect(find.byKey(DesktopShell.searchEntryKey), findsOneWidget);
    expect(find.byType(M3ESearchAnchor), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.search_rounded),
      ),
      findsOneWidget,
    );
  });

  testWidgets('顶栏搜索：点击入口弹出 docked 结果面板（曲目行 + 查看全部结果）', (tester) async {
    await pumpSearchShell(tester);
    expect(find.byType(TrackRow), findsNothing, reason: '面板未打开时不渲染结果');

    await tester.tap(find.byKey(DesktopShell.searchEntryKey));
    await tester.pumpAndSettle();

    // 面板与资料库页共用同一个 SearchProvider：预置结果直接就地渲染。
    expect(find.byType(TrackRow), findsNWidgets(2));
    expect(
      // 底栏当前曲目也叫 Title a：定位到面板行内。
      find.descendant(
        of: find.byType(TrackRow),
        matching: find.text('Title a'),
      ),
      findsOneWidget,
    );
    expect(find.text(l10n.viewAllResults), findsOneWidget);
  });

  testWidgets('顶栏搜索：「查看全部结果」收起面板并切到资料库目的地', (tester) async {
    await pumpSearchShell(tester);
    await tester.tap(find.byKey(DesktopShell.searchEntryKey));
    await tester.pumpAndSettle();

    await tester.tap(find.text(l10n.viewAllResults));
    await settleTransition(tester);

    expect(selectedRailIndex(tester), navIndexOf(ShellDestination.library));
    expect(
      find.text(l10n.viewAllResults),
      findsNothing,
      reason: '面板应已收起（跳转前先关搜索视图）',
    );
  });
}
