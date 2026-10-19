import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/app_shell.dart';
import 'package:molia/app/desktop/desktop_shell.dart';
import 'package:molia/app/desktop/now_playing_bar.dart';
import 'package:molia/app/shell_chrome.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/favorites.dart';
import 'package:molia/providers/discover_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/providers/nav_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/search_provider.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/providers/theme_provider.dart';
import 'package:molia/services/app_branding_service.dart';
import 'package:molia/services/escape_claims.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/services/shortcut_bindings.dart';
import 'package:molia/services/shortcut_settings.dart';
import 'package:molia/services/shortcuts.dart';
import 'package:molia/services/window/window_chrome.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:molia/widgets/cover_appearance.dart';
import 'package:molia/widgets/global_search_overlay.dart';
import 'package:molia/widgets/molia_mark.dart';
import 'package:molia/widgets/now_playing_controller.dart';
import 'package:molia/widgets/player.dart';
import 'package:molia/widgets/player_cover_deck.dart';
import 'package:molia/widgets/player_morph.dart';
import 'package:molia/widgets/track_row.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_library_repository.dart';
import '../support/fake_music_source.dart';
import '../support/fakes.dart';
import '../support/settings_test_support.dart';

/// 桌面骨架（`MyApp(desktopShell: true)`）的挂载测试。
///
/// 覆盖骨架结构与三条不变量：顶栏是纯工具条（无标题 / 无播放控制 / 无进度线，
/// 最左是「标志 + 应用名」品牌区（贴窗口左缘、无 tooltip）、右侧空白拖动区）；
/// 侧栏恒折叠（无展开按钮）；底栏只在非播放页出现（播放页沉浸）且封面飞行两端
/// 都成立。另有队列入口（跳播放页 + 切队列 tab）、搜索遮罩（品牌区点击 /
/// Ctrl+F 打开、docked 结果面板、查看全部结果切资料库）、全局快捷键（Space 切
/// 播放态、Esc 收起队列视图、输入框聚焦时让位）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = lookupAppLocalizations(const Locale('zh'));

  late NavProvider nav;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // 快捷键单例跨用例共享：每个用例前回到默认（内存态即可，本文件不测
    // 持久化；组合覆盖与开关都可能被上一个用例改过）。
    await ShortcutSettings.instance.setInAppEnabled(true);
    await ShortcutSettings.instance.setGlobalEnabled(false);
    await ShortcutSettings.instance.resetScope(ShortcutScope.inApp);
    await ShortcutSettings.instance.resetScope(ShortcutScope.global);
    // Esc 占用登记同为跨用例共享的静态状态：清掉上一用例可能残留的登记
    // （正常路径由页面 dispose 注销，这里兜底）。
    EscapeClaims.reset();
  });

  /// 装配与组合根同源的 provider 树并挂载壳层（骨架同 `app_shell_reselect_test`；
  /// provider 在测试体内创建：偏好加载的 Future 必须在 fake-async 区内解析）。
  ///
  /// [searchSource] 非空时给搜索 provider 接上假音源（顶栏搜索用例预置结果），
  /// [configureSearch] 在挂载前配置搜索状态（如先提交一次搜索），
  /// [seedLibrary] 在挂载前向假资料库写入数据（如预置收藏）。
  /// 返回假后端与 provider：快捷键用例据此断言后端收到的播放命令。
  Future<({FakePlaybackBackend backend, PlaybackProvider playback})> pumpShell(
    WidgetTester tester, {
    required bool desktopShell,
    Size size = const Size(1440, 900),
    FakeMusicSource? searchSource,
    void Function(SearchProvider search)? configureSearch,
    Future<void> Function(FakeLibraryRepository repository)? seedLibrary,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final theme = ThemeProvider(settings: testSettingsRegistry());
    addTearDown(theme.dispose);
    await theme.preferencesReady;
    nav = NavProvider(settings: testSettingsRegistry());
    addTearDown(nav.dispose);
    await nav.preferencesReady;

    final repository = FakeLibraryRepository();
    addTearDown(repository.dispose);
    // 挂载前预置资料库数据（收藏等）：页面首帧即读，无需等变更流回载。
    await seedLibrary?.call(repository);
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
    final lyricsDisplay =
        LyricsDisplaySettings(settings: testSettingsRegistry());
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
    // 首帧切歌入场动画（封面堆叠 460ms）。
    await tester.pump(const Duration(milliseconds: 600));

    return (backend: backend, playback: playback);
  }

  /// 走完一次切页过渡（含顶栏 ⇄ 播放页共享元素飞行约 0.4s）。
  ///
  /// 进入播放页的飞行延后一帧起跑（终点锚点要等落定布局，见
  /// `app_shell.dart::_startMorphToPage`），再下一帧才是弹簧的第一个 tick，
  /// 因此这里给两次长帧。
  Future<void> settleTransition(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 900));
  }

  /// 打开搜索遮罩（Ctrl+F：与品牌区点击同一条壳层回调）。
  Future<void> openSearchOverlay(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  /// 侧栏条目：标签恒隐藏（`alwaysHide`），只能按图标定位。
  Finder railItem(IconData outlinedIcon) => find.descendant(
        of: find.byType(M3ENavigationRail),
        matching: find.byIcon(outlinedIcon),
      );

  /// 侧栏「正在播放」条目：图标是 [MoliaMark]（描边 / 实心是一对）。
  Finder railPlayerItem() => find.descendant(
        of: find.byType(M3ENavigationRail),
        matching: find.byType(MoliaMark),
      );

  /// 点侧栏条目并走完过渡。
  Future<void> tapRailItem(WidgetTester tester, Finder item) async {
    await tester.tap(item);
    await settleTransition(tester);
  }

  /// 播放页右栏的 tab 行（icon-only 三 tab：队列 / 歌词 / 信息）。
  Finder playerTabs() => find.byType(M3ETabs);

  int playerTabIndex(WidgetTester tester) =>
      tester.widget<M3ETabs>(playerTabs()).selectedIndex;

  Future<void> tapPlayerTab(WidgetTester tester, IconData icon) async {
    await tester
        .tap(find.descendant(of: playerTabs(), matching: find.byIcon(icon)));
    await settleTransition(tester);
  }

  /// 底栏当前是否在场。
  Finder playingBar() => find.byKey(DesktopNowPlayingBar.shellKey);

  /// 搜索遮罩背景模糊层的当前不透明度（0 = 未绘制，1 = 全模糊）。
  double backdropBlurOpacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find.descendant(
          of: find.byKey(DesktopShell.searchBackdropBlurKey),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  /// 焦点当前是否在音量弹层子树内。
  bool focusInsideVolumePanel(WidgetTester tester, Key panelKey) {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;
    final panel = tester.element(find.byKey(panelKey));
    if (identical(focusContext, panel)) return true;
    var inside = false;
    (focusContext as Element).visitAncestorElements((ancestor) {
      if (identical(ancestor, panel)) {
        inside = true;
        return false;
      }
      return true;
    });
    return inside;
  }

  /// Tab 直到焦点离开音量弹层子树（面板仍可见但不再持有焦点）。
  ///
  /// 遍历顺序（面板根 → 滑杆 → 静音按钮 → 弹层外）随控件增删变化，按「离开
  /// 为止」而不是固定次数，前提失效时由断言兜底。
  Future<void> tabOutOfVolumePanel(WidgetTester tester, Key panelKey) async {
    for (var i = 0; i < 8 && focusInsideVolumePanel(tester, panelKey); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(
      focusInsideVolumePanel(tester, panelKey),
      isFalse,
      reason: '前提：焦点已移出弹层',
    );
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

  testWidgets('顶栏：纯工具条（无标题 / 无播放控制 / 无进度线）', (tester) async {
    await pumpShell(tester, desktopShell: true);

    final appBar = find.byType(AppBar);
    // 顶栏不含当前页标题（导航语义只在侧栏 / 底栏）。
    expect(
      find.descendant(of: appBar, matching: find.text(l10n.nowPlayingLabel)),
      findsNothing,
    );
    // 播放 / 下一首按钮与进度线只在移动骨架的顶栏里出现。
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
  });

  testWidgets('侧栏：恒折叠、标签隐藏、无展开入口', (tester) async {
    await pumpShell(tester, desktopShell: true);

    final rail =
        tester.widget<M3ENavigationRail>(find.byType(M3ENavigationRail));
    expect(rail.type, M3ENavigationRailType.alwaysCollapse);
    expect(rail.labelBehavior, M3ENavigationRailLabelBehavior.alwaysHide);
    // 窗口宽变化不影响侧栏形态。
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
      M3ENavigationRailType.alwaysCollapse,
    );
    expect(find.byType(M3ENavigationBar), findsNothing);
  });

  testWidgets('播放页沉浸：进播放页整条底栏让位，离开恢复', (tester) async {
    await pumpShell(tester, desktopShell: true);
    // 启动首页默认是播放页：整条底栏不在场。
    expect(playingBar(), findsNothing, reason: '播放页里底栏让位');

    await tapRailItem(tester, railItem(Icons.favorite_border_rounded));
    expect(playingBar(), findsOneWidget, reason: '离开播放页底栏恢复');

    await tapRailItem(tester, railPlayerItem());
    expect(playingBar(), findsNothing, reason: '回到播放页再次让位');
  });

  testWidgets('底栏让位：开着的音量弹层随底栏一起收起（不留悬空浮层）', (tester) async {
    await pumpShell(tester, desktopShell: true);
    await tapRailItem(tester, railItem(Icons.favorite_border_rounded));
    await tester.tap(find.byKey(DesktopNowPlayingBar.volumeButtonKey));
    await tester.pumpAndSettle();
    expect(find.byKey(DesktopNowPlayingBar.volumePanelKey), findsOneWidget);

    // 进播放页：整条底栏让位，弹层（OverlayPortal 的子级）必须一起消失，
    // 且不留 Esc 占用登记（否则按键会被一个不存在的面板吃掉）。
    await tapRailItem(tester, railPlayerItem());
    expect(find.byKey(DesktopNowPlayingBar.volumePanelKey), findsNothing);
    expect(EscapeClaims.any, isFalse, reason: '弹层登记随宿主卸载注销');
  });

  /// 元素的真实屏上矩形（含祖先变换）：与共享元素锚点同一口径。
  ///
  /// 不能直接用 `tester.getRect`：它取布局盒宽高、忽略祖先 `Transform.scale`
  /// （暂停态封面有持续 0.98 缩放），与飞行锚点（角点映射）不是同一把尺。
  Rect renderedRect(WidgetTester tester, Finder finder) {
    final box = tester.renderObject<RenderBox>(finder);
    return Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    );
  }

  testWidgets('封面飞行：进入方向副本末帧落点 == 落定后真身矩形（≤1dp）', (tester) async {
    await pumpShell(tester, desktopShell: true);
    // 先离开播放页：底栏在场，封面是进入方向的起点；也让页内封面先按
    // 「有底栏」的布局量过一次（底栏让位后页面高 +80，真身封面会下移）。
    await tapRailItem(tester, railItem(Icons.favorite_border_rounded));

    await tester.tap(railPlayerItem());
    // 逐帧跑到副本消失（落定帧交接）：记下最后一张副本的矩形与飞行锚点。
    Rect? lastCopy;
    Rect? flightTarget;
    var seen = false;
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 8));
      final flight = find.byType(PlayerMorphFlight);
      final copy = find.descendant(
        of: flight,
        matching: find.byType(CoverCard),
      );
      if (copy.evaluate().isEmpty) {
        if (seen) break;
        continue;
      }
      seen = true;
      lastCopy = renderedRect(tester, copy);
      flightTarget =
          tester.widget<PlayerMorphFlight>(flight).geometry.pageCover;
    }
    expect(lastCopy, isNotNull, reason: '前提：进入方向出现了飞行副本');
    await settleTransition(tester);
    expect(find.byType(PlayerMorphFlight), findsNothing, reason: '落定后副本已移除');

    // 落定后真身封面（页内中心封面卡）的实际绘制矩形：与锚点同一口径——
    // 卡片在播放态缩放的 `Transform.scale` 之内（暂停态 0.98），必须量到
    // 变换之后，才能和飞行锚点 / 副本的矩形比。
    final landedCard = find.descendant(
      of: find.byKey(PlayerCoverDeck.centerCoverCardKey),
      matching: find.byType(CoverCard),
    );
    expect(landedCard, findsOneWidget);
    final landed = renderedRect(tester, landedCard);
    // 飞行抓的终点锚点就是落定矩形（抓锚点这一环的根因断言）。
    expect(
      (flightTarget!.topLeft - landed.topLeft).distance,
      lessThanOrEqualTo(1.0),
      reason: '飞行终点锚点 $flightTarget 与落定真身 $landed 的左上角偏移',
    );
    // 副本末帧落在同一矩形上，交接瞬间零位移（用户可见的这一环）。
    expect(
      (lastCopy!.topLeft - landed.topLeft).distance,
      lessThanOrEqualTo(1.0),
      reason: '副本末帧 $lastCopy 与落定真身 $landed 的左上角偏移',
    );
    expect(
      (lastCopy.size.width - landed.size.width).abs(),
      lessThanOrEqualTo(1.0),
      reason: '副本末帧 $lastCopy 与落定真身 $landed 的宽度差',
    );
    expect(
      (lastCopy.size.height - landed.size.height).abs(),
      lessThanOrEqualTo(1.0),
      reason: '副本末帧 $lastCopy 与落定真身 $landed 的高度差',
    );
  });

  testWidgets('封面飞行：进入 / 离开播放页两端锚点都成立', (tester) async {
    await pumpShell(tester, desktopShell: true);
    // 先离开播放页：此时底栏在场，封面是进入方向的起点。
    await tapRailItem(tester, railItem(Icons.favorite_border_rounded));
    expect(playingBar(), findsOneWidget);

    // 进入播放页：底栏本帧让位，帧末抓到落点锚点后副本再接管（延后一帧）。
    await tester.tap(railPlayerItem());
    await tester.pump(); // 帧 1：底栏让位 + 页面按新布局落定
    await tester.pump(); // 帧 2：副本挂载
    expect(find.byType(PlayerMorphFlight), findsOneWidget, reason: '进入方向有飞行副本');
    expect(playingBar(), findsNothing, reason: '底栏同时让位');
    await settleTransition(tester);
    expect(find.byType(PlayerMorphFlight), findsNothing, reason: '落定后副本移除');

    // 离开播放页：底栏复位（封面先收进飞行态），下一帧抓到终点锚点后起飞。
    await tester.tap(railItem(Icons.favorite_border_rounded));
    await tester.pump(); // 帧 1：底栏复位
    await tester.pump(); // 帧 2：副本挂载
    expect(find.byType(PlayerMorphFlight), findsOneWidget, reason: '离开方向有飞行副本');
    await settleTransition(tester);
    expect(find.byType(PlayerMorphFlight), findsNothing, reason: '落定后副本清理干净');
    expect(
      find.descendant(of: playingBar(), matching: find.byType(CoverCard)),
      findsOneWidget,
      reason: '底栏封面真身回位（占位不跳）',
    );
  });

  testWidgets('底栏进度条：拖动提交 seek', (tester) async {
    final harness = await pumpShell(tester, desktopShell: true);
    // 底栏只在非播放页出现：先切到收藏页再操作（启动首页是播放页）。
    await tapRailItem(tester, railItem(Icons.favorite_border_rounded));

    final slider = find.descendant(
      of: playingBar(),
      matching: find.byType(M3ESlider),
    );
    final rect = tester.getRect(slider);
    // 从滑杆约 17% 拖到约 80% 位置（时长 30s ≈ 落点 24s）。
    await tester.dragFrom(
      Offset(rect.left + rect.width * 0.17, rect.center.dy),
      Offset(rect.width * 0.6, 0),
    );
    await tester.pump();
    expect(harness.backend.calls, contains('seek'));

    // 松手后的保留窗口（1500ms 兜底）跑完，避免用例结束报 pending timer。
    await tester.pump(const Duration(milliseconds: 1600));
  });

  testWidgets('底栏队列入口：跳播放页 + 切到队列 tab', (tester) async {
    await pumpShell(tester, desktopShell: true);
    await tapRailItem(tester, railItem(Icons.favorite_border_rounded));
    expect(playerTabIndex(tester), nowPlayingLyricsTabIndex, reason: '默认歌词页');
    expect(selectedRailIndex(tester), navIndexOf(ShellDestination.favorites));

    await tester.tap(find.byKey(DesktopNowPlayingBar.openQueueKey));
    await settleTransition(tester);

    expect(selectedRailIndex(tester), navIndexOf(ShellDestination.nowPlaying));
    expect(playerTabIndex(tester), nowPlayingQueueTabIndex, reason: '落在队列 tab');
    expect(playingBar(), findsNothing, reason: '已进播放页（底栏让位）');

    // 在播放页把 tab 切走，再回收藏点一次：重复请求同样生效（控制器每次都通知）。
    await tapPlayerTab(tester, M3EIcons.lyrics_rounded);
    await tapRailItem(tester, railItem(Icons.favorite_border_rounded));
    await tester.tap(find.byKey(DesktopNowPlayingBar.openQueueKey));
    await settleTransition(tester);
    expect(playerTabIndex(tester), nowPlayingQueueTabIndex);
  });

  testWidgets('底栏队列入口：窄窗口也始终可用（不再置灰）', (tester) async {
    await pumpShell(
      tester,
      desktopShell: true,
      size: const Size(900, 900),
    );
    await tapRailItem(tester, railItem(Icons.favorite_border_rounded));
    expect(
      tester
          .widget<M3EIconButton>(find.byKey(DesktopNowPlayingBar.openQueueKey))
          .onPressed,
      isNotNull,
      reason: '队列入口在任何窗口宽下都可点',
    );
  });

  testWidgets('底栏左区点击：切回播放页', (tester) async {
    await pumpShell(tester, desktopShell: true);

    // 先离开播放页（点侧栏「收藏」）：播放页层保持挂载但不可命中。
    await tapRailItem(tester, railItem(Icons.favorite_border_rounded));
    expect(selectedRailIndex(tester), navIndexOf(ShellDestination.favorites));
    expect(
      find.byType(Player).hitTestable(),
      findsNothing,
      reason: '播放页已被盖住（不可命中）',
    );

    // 点底栏封面（左区手势的一部分）→ 选中目的地回到播放页。
    await tester.tap(
      find.descendant(of: playingBar(), matching: find.byType(CoverCard)),
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

    expect(playingBar(), findsNothing);
    expect(find.byType(M3ENavigationBar), findsOneWidget);
    expect(find.byType(M3ENavigationRail), findsNothing);
  });

  testWidgets('顶栏品牌区：左上角是标志 + 应用名，点击打开搜索遮罩', (tester) async {
    await pumpShell(tester, desktopShell: true);

    final brand = find.byKey(DesktopShell.searchEntryKey);
    expect(brand, findsOneWidget);
    expect(
      find.descendant(of: brand, matching: find.byType(MoliaMark)),
      findsOneWidget,
      reason: '品牌标志在应用名左侧',
    );
    // 品牌块贴窗口左缘（AppBar `titleSpacing` 处），不再与内容左缘对齐：
    // 应用左上角就是标志本身。
    expect(
      tester.getRect(brand).left,
      ShellChrome.appBarTitleSpacing,
      reason: '品牌区左缘 = 顶栏 titleSpacing，与侧栏 / 页面留白解耦',
    );
    expect(
      find.descendant(of: brand, matching: find.byType(Tooltip)),
      findsNothing,
      reason: '顶栏工具条不做悬浮提示（键位提示只留在设置 › 快捷键）',
    );
    expect(
      find.descendant(
        of: brand,
        matching: find.text(AppBrandingService.fallbackTitle),
      ),
      findsOneWidget,
      reason: '未自定义名称时显示品牌名（测试未走组合根本地化注入，取兜底名）',
    );
    // 顶栏不再挂搜索条：整条工具行只有品牌区（+ 右侧空白拖动区）；
    // 搜索遮罩宿主挂在页面栈上（隐形锚点，Ctrl+F / 品牌区打开）。
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(M3ESearchBar),
      ),
      findsNothing,
      reason: '搜索框已从顶栏移除',
    );
    expect(find.byType(GlobalSearchOverlay), findsOneWidget);
    expect(find.text(l10n.searchHint), findsNothing, reason: '遮罩未打开');
    expect(backdropBlurOpacity(tester), 0, reason: '遮罩未打开时背景模糊不参与绘制');

    await tester.tap(brand);
    await tester.pumpAndSettle();
    expect(find.text(l10n.searchHint), findsOneWidget, reason: '点击品牌区打开遮罩');
    expect(backdropBlurOpacity(tester), 1, reason: '遮罩打开时背景模糊淡入');
    expect(
      find.descendant(
        of: find.byKey(DesktopShell.searchBackdropBlurKey),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
      reason: '背景模糊层是整窗 BackdropFilter',
    );
    expect(
      find.text(l10n.searchIdleHint),
      findsNothing,
      reason: '无关键词时结果面留空（不显示输入引导）',
    );
  });

  testWidgets('顶栏拖动区：在品牌区右侧，且不包住品牌入口', (tester) async {
    await pumpShell(tester, desktopShell: true);

    final dragArea = find.byKey(DesktopShell.titleDragAreaKey);
    expect(dragArea, findsOneWidget);
    expect(
      tester.widget<WindowDoubleTapMaximize>(dragArea).onDoubleTap,
      isNull,
      reason: '缺省即窗口最大化 / 还原',
    );
    expect(
      tester.getRect(dragArea).left,
      greaterThanOrEqualTo(
        tester.getRect(find.byKey(DesktopShell.searchEntryKey)).right,
      ),
      reason: '拖动区在品牌区右侧',
    );
    expect(
      find.ancestor(
        of: find.byKey(DesktopShell.searchEntryKey),
        matching: dragArea,
      ),
      findsNothing,
      reason: '双击按钮不最大化：品牌入口不在拖动区里',
    );
  });

  testWidgets('Ctrl+F：打开搜索遮罩（docked 面板），Esc 收起', (tester) async {
    await pumpSearchShell(tester);
    expect(find.byType(TrackRow), findsNothing, reason: '遮罩未打开时不渲染结果');

    await openSearchOverlay(tester);

    // 遮罩与资料库页共用同一个 SearchProvider：预置结果直接就地渲染。
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

    // Esc 关闭：焦点在输入框内时按键放行给视图的关闭绑定（见 DesktopShortcuts
    // 的让位规则），一次按键只关遮罩、不触发壳层「关闭队列」命令。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TrackRow), findsNothing, reason: 'Esc 收起遮罩');
    expect(find.text(l10n.searchHint), findsNothing);
    expect(backdropBlurOpacity(tester), 0, reason: '遮罩收起后背景模糊淡出');
  });

  // 旧实现（M3E docked 搜索视图）的容器变换终点矩形完全由锚点推导，锚点就在
  // 静止位置时位移为 0：遮罩是「闪现」的。这里钉住开合真的走了过渡。
  testWidgets('Ctrl+F：遮罩开合走淡入 + 缩放过渡（不是瞬间出现）', (tester) async {
    await pumpShell(tester, desktopShell: true);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    // 过渡中（半程以内）：透明度与缩放都没到终点。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final fade = tester.widget<FadeTransition>(
      find.byKey(GlobalSearchOverlay.transitionKey),
    );
    expect(fade.opacity.value, greaterThan(0), reason: '淡入已开始');
    expect(fade.opacity.value, lessThan(1), reason: '尚未落定');
    final scale = tester.widget<ScaleTransition>(
      find.descendant(
        of: find.byKey(GlobalSearchOverlay.transitionKey),
        matching: find.byType(ScaleTransition),
      ),
    );
    expect(scale.scale.value, lessThan(1), reason: '轻微缩放同步进行');

    // 落定：透明度到 1（过程里不会卡在中途）。
    await tester.pumpAndSettle();
    expect(fade.opacity.value, 1);
  });

  testWidgets('Ctrl+F：打开后首帧即可输入（不等动画落定）', (tester) async {
    await pumpSearchShell(tester);
    await openSearchOverlay(tester);

    // 输入框在遮罩打开后就持有焦点：立刻输入不会丢字。
    expect(
      tester
          .widget<EditableText>(find.byType(EditableText).first)
          .focusNode
          .hasFocus,
      isTrue,
      reason: '搜索框打开即聚焦（旧实现要等容器弹簧落定才聚焦，会吞按键）',
    );
  });

  testWidgets('顶栏品牌区：tooltip 已移除（不做悬浮提示）', (tester) async {
    await pumpShell(tester, desktopShell: true);

    // 键位提示只留在设置 › 快捷键；品牌块（贴窗口左上角、带应用名文案）
    // 不再挂 Tooltip。
    expect(
      find.descendant(
        of: find.byKey(DesktopShell.searchEntryKey),
        matching: find.byType(Tooltip),
      ),
      findsNothing,
    );
    // 软件内快捷键开关状态变化也不该再影响顶栏（没有提示可跟）。
    await ShortcutSettings.instance.setInAppEnabled(false);
    await tester.pump();
    expect(
      find.byKey(DesktopShell.searchEntryKey),
      findsOneWidget,
      reason: '开关只影响按键是否生效，不影响品牌区存在',
    );
    await ShortcutSettings.instance.setInAppEnabled(true);
  });

  testWidgets('Ctrl+F：窄窗同样打开遮罩（不再分流到资料库搜索页）', (tester) async {
    await pumpShell(
      tester,
      desktopShell: true,
      size: const Size(800, 900),
      searchSource: FakeMusicSource('kw'),
    );

    await openSearchOverlay(tester);
    expect(find.text(l10n.searchHint), findsOneWidget, reason: '窄窗也走遮罩');
    expect(
      selectedRailIndex(tester),
      navIndexOf(ShellDestination.nowPlaying),
      reason: '不切目的地（旧窄窗路径会跳资料库搜索页）',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('搜索遮罩：清除键清空关键词，结果面留空', (tester) async {
    await pumpSearchShell(tester);
    await openSearchOverlay(tester);
    expect(find.byType(TrackRow), findsNWidgets(2));

    // 清除键自绘（tooltip 走 l10n）：清空必须同步给 provider，面板不能停留
    // 在上一轮结果上。图标 X 与左侧的关闭箭头区分开；窗口控件里也有一个 X
    // （窗口关闭键），定位收在搜索条内。
    final clearButton = find.descendant(
      of: find.byType(M3ESearchBar),
      matching: find.byIcon(Icons.close_rounded),
    );
    expect(clearButton, findsOneWidget);
    await tester.tap(clearButton);
    await tester.pumpAndSettle();

    expect(find.byType(TrackRow), findsNothing);
    expect(
      find.text(l10n.searchIdleHint),
      findsNothing,
      reason: '空词时结果面留空，不显示输入引导',
    );

    // 收起遮罩，避免用例结束时路由仍挂在导航栈上。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('搜索遮罩：「查看全部结果」收起遮罩并切到资料库目的地', (tester) async {
    await pumpSearchShell(tester);
    await openSearchOverlay(tester);

    await tester.tap(find.text(l10n.viewAllResults));
    await settleTransition(tester);

    expect(selectedRailIndex(tester), navIndexOf(ShellDestination.library));
    expect(
      find.text(l10n.viewAllResults),
      findsNothing,
      reason: '遮罩应已收起（跳转前先关搜索视图）',
    );
  });

  testWidgets('全局快捷键：Space 切播放态、Esc 收起队列视图', (tester) async {
    final harness = await pumpShell(tester, desktopShell: true);

    // 先按 Space：此刻没有其它焦点，顶层 Focus 持有焦点 → 播放
    //（假快照 isPlaying=false，toggle 走 play）。放在点按之前：点按会让
    // M3E 按钮取得焦点，Space 会被按钮自己的 ActivateIntent 消费。
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(harness.backend.calls, contains('play'));

    // 播放中再按 → 暂停。
    harness.backend.emit(BackendSnapshot(
      current: harness.playback.snapshot.current,
      queue: const [],
      currentIndex: 0,
      isPlaying: true,
      duration: const Duration(seconds: 30),
    ));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(harness.backend.calls.last, 'pause');

    // Esc（可配置的「关闭队列」）：落点 = 在播放页里把队列视图收成默认页
    //（先手动切到队列 tab 才有可收的视图）。
    await tapPlayerTab(tester, M3EIcons.queue_music_rounded);
    expect(playerTabIndex(tester), nowPlayingQueueTabIndex);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleTransition(tester);
    expect(playerTabIndex(tester), nowPlayingLyricsTabIndex);
  });

  testWidgets('Esc 关队列：按目的地生效（播放页收成默认页，其它页 no-op）', (tester) async {
    await pumpShell(tester, desktopShell: true);

    // 播放页停在信息 tab：命令是「把队列视图收成默认页」，壳层看不到页内
    // tab，因此在播放页里一律回默认页。
    await tapPlayerTab(tester, M3EIcons.info_rounded);
    expect(playerTabIndex(tester), nowPlayingInfoTabIndex);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleTransition(tester);
    expect(playerTabIndex(tester), nowPlayingLyricsTabIndex);

    // 非播放页：no-op（不切目的地、不动页内 tab）。
    await tapPlayerTab(tester, M3EIcons.queue_music_rounded);
    await tapRailItem(tester, railItem(Icons.favorite_border_rounded));
    expect(playerTabIndex(tester), nowPlayingQueueTabIndex);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleTransition(tester);
    expect(selectedRailIndex(tester), navIndexOf(ShellDestination.favorites));
    expect(
      playerTabIndex(tester),
      nowPlayingQueueTabIndex,
      reason: '非播放页按 Esc 不动页内队列视图',
    );
  });

  testWidgets('Esc 裁决：音量弹层与队列视图同时在场时，一次 Esc 只关弹层', (tester) async {
    await pumpShell(tester, desktopShell: true);
    // 前提一：播放页停在队列 tab（Esc 的壳层命令是收起队列视图）。
    await tapPlayerTab(tester, M3EIcons.queue_music_rounded);
    expect(playerTabIndex(tester), nowPlayingQueueTabIndex);

    // 前提二：播放页的音量弹层打开（占用登记的 Esc 消费方）。
    await tester.tap(find.byKey(Player.volumeButtonKey));
    await tester.pumpAndSettle();
    expect(find.byKey(Player.volumePanelKey), findsOneWidget);

    // 第一次 Esc：弹层优先——队列视图保持不动。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(Player.volumePanelKey), findsNothing);
    expect(
      playerTabIndex(tester),
      nowPlayingQueueTabIndex,
      reason: '第一次 Esc 不应同时触发壳层的收队列命令',
    );

    // 第二次 Esc：弹层已关，壳层命令收起队列视图。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleTransition(tester);
    expect(playerTabIndex(tester), nowPlayingLyricsTabIndex);
  });

  testWidgets('Esc 裁决：焦点移出音量弹层后 Esc 仍关闭弹层，不落入按键黑洞', (tester) async {
    await pumpShell(tester, desktopShell: true);

    await tester.tap(find.byKey(Player.volumeButtonKey));
    await tester.pumpAndSettle();
    expect(find.byKey(Player.volumePanelKey), findsOneWidget);
    expect(
      focusInsideVolumePanel(tester, Player.volumePanelKey),
      isTrue,
      reason: '前提：autofocus 落在弹层内',
    );

    // 面板可见但焦点被 Tab 移出弹层：Esc 必须仍由弹层消费——登记让壳层
    // 让位后，若弹层不接按键就成了黑洞。
    await tabOutOfVolumePanel(tester, Player.volumePanelKey);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(Player.volumePanelKey),
      findsNothing,
      reason: '焦点不在弹层内也要关闭（不是黑洞）',
    );
  });

  testWidgets('Esc 裁决：焦点移出音量弹层后，一次 Esc 只关弹层、队列视图仍在', (tester) async {
    await pumpShell(tester, desktopShell: true);

    // 前提一：播放页停在队列 tab（Esc 的壳层命令是收起队列视图）。
    await tapPlayerTab(tester, M3EIcons.queue_music_rounded);
    expect(playerTabIndex(tester), nowPlayingQueueTabIndex);

    // 前提二：音量弹层打开，再把焦点 Tab 出弹层子树。
    await tester.tap(find.byKey(Player.volumeButtonKey));
    await tester.pumpAndSettle();
    expect(find.byKey(Player.volumePanelKey), findsOneWidget);
    await tabOutOfVolumePanel(tester, Player.volumePanelKey);

    // 第一次 Esc：弹层（占用登记）优先关闭，队列视图保持不动。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(Player.volumePanelKey), findsNothing);
    expect(
      playerTabIndex(tester),
      nowPlayingQueueTabIndex,
      reason: '弹层已消费 Esc，壳层命令不应同时生效',
    );

    // 第二次 Esc：弹层已关，壳层命令收起队列视图。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleTransition(tester);
    expect(playerTabIndex(tester), nowPlayingLyricsTabIndex);
  });

  testWidgets('全局快捷键：输入框聚焦时 Space 不触发播放', (tester) async {
    final harness = await pumpShell(tester, desktopShell: true);

    // 切到收藏页并打开搜索行：收藏页的搜索框是壳层内真实的 EditableText
    //（Space 不是它的键位，事件会冒泡到顶层 Focus），聚焦由 _openSearch
    // 的帧末 requestFocus 完成。
    await tapRailItem(tester, railItem(Icons.favorite_border_rounded));
    await tester.tap(
      find.descendant(
        of: find.byType(FavoritesPage),
        matching: find.byIcon(Icons.search_rounded),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<EditableText>() !=
          null,
      isTrue,
      reason: '前提：焦点确实落在输入框内',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(harness.backend.calls, isNot(contains('play')));
    expect(harness.backend.calls, isNot(contains('pause')));
  });

  testWidgets('全局快捷键：焦点不在壳内（失焦到 route 作用域）仍生效', (tester) async {
    // 回归：早期用顶层 Focus.onKeyEvent 时，焦点一旦落到壳层 Focus 的祖先
    // （搜索回车后 unfocus / 点列表空白），Space 等按键就整体失效；现在走
    // HardwareKeyboard 处理器，与焦点位置无关。
    final harness = await pumpShell(tester, desktopShell: true);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(
      harness.backend.calls.where((call) => call == 'play' || call == 'pause'),
      isNotEmpty,
      reason: '失焦状态下 Space 仍应切播放态',
    );
  });

  testWidgets('软件内快捷键：总开关关闭后 Space 不再切播放态', (tester) async {
    final harness = await pumpShell(tester, desktopShell: true);

    // 默认开：Space 走播放命令（与既有用例同口径）。
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(harness.backend.calls, contains('play'));

    // 关闭总开关：处理器摘除，所有按键放行。
    await ShortcutSettings.instance.setInAppEnabled(false);
    await tester.pump();

    final before = List<String>.of(harness.backend.calls);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(harness.backend.calls, before, reason: '关闭后按键完全放行');
  });

  testWidgets('软件内快捷键：改绑后新键生效、旧键失效', (tester) async {
    final harness = await pumpShell(tester, desktopShell: true);

    // 把「播放 / 暂停」从 Space 改绑到 Ctrl+P。
    final result = await ShortcutSettings.instance.setBinding(
      ShortcutScope.inApp,
      ShortcutCommand.togglePlayPause,
      const ShortcutCombo(key: LogicalKeyboardKey.keyP, ctrl: true),
    );
    expect(result, isA<ShortcutBindingAccepted>());
    await tester.pump();

    // 新键生效：Ctrl+P 切播放态（假快照 isPlaying=false → play）。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(harness.backend.calls, contains('play'));

    // 旧键失效：Space 已不在绑定表里，不再触发播放命令。
    final before = List<String>.of(harness.backend.calls);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(harness.backend.calls, before);
  });
}
