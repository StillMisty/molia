import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/app_shell.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/favorites.dart';
import 'package:molia/pages/library.dart';
import 'package:molia/pages/nowplaying.dart';
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
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_library_repository.dart';
import 'support/fake_music_source.dart';
import 'support/fakes.dart';
import 'support/settings_test_support.dart';

/// 壳层「有效选中项」的运行时隐藏测试（挂载真实应用壳 `MyApp`）。
///
/// 回归：chrome 用可见目的地回退，但页面栈用 raw `_selectedDestination`。
/// 同步在运行中隐藏当前目的地时，导航高亮回退到首个可见项、页面栈却继续
/// 显示被隐藏的页。这里同时钉住隐藏 / 重新可见两步的 chrome 与页面栈一致。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NavProvider nav;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 装配与组合根同源的 provider 树并挂载壳层（同 `app_shell_reselect_test`；
  /// provider 在测试体内创建：偏好加载的 Future 必须在 fake-async 区内解析）。
  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
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
    final backend = FakePlaybackBackend();
    final playback = buildTestPlaybackProvider(
      backend: backend,
      libraryRepository: repository,
      settings: testSettingsRegistry(),
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
          home: const MyApp(desktopShell: false),
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
    await tester.pump(const Duration(milliseconds: 900));
  }

  int selectedNavIndex(WidgetTester tester) => tester
      .widget<M3ENavigationBar>(find.byType(M3ENavigationBar))
      .selectedIndex;

  int navIndexOf(ShellDestination destination) =>
      nav.visibleDestinations.indexOf(destination);

  /// 记录平台通道上的震动请求（值即 `HapticFeedbackType` 字符串）。
  List<String> recordVibrations(WidgetTester tester) {
    final vibrations = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          vibrations.add(call.arguments as String? ?? '');
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    return vibrations;
  }

  testWidgets('运行时隐藏当前目的地：chrome 与页面栈一起回退到首个可见项', (tester) async {
    await pumpShell(tester);
    expect(selectedNavIndex(tester), navIndexOf(ShellDestination.nowPlaying));

    // 选中「收藏」，确认 chrome 与页面栈都在收藏页。
    await tapBottomDestination(tester, ShellDestination.favorites);
    await settleTransition(tester);
    expect(selectedNavIndex(tester), navIndexOf(ShellDestination.favorites));
    expect(find.byType(FavoritesPage), findsOneWidget);
    expect(find.byType(Library), findsNothing);

    // 模拟同步在运行中隐藏当前目的地（远端导航设置落盘后 reload）。
    expect(await nav.setVisible(ShellDestination.favorites, false), isTrue);
    await tester.pump();

    final fallback = nav.visibleDestinations.first;
    expect(fallback, ShellDestination.library, reason: '默认顺序的首个可见项');
    expect(
      selectedNavIndex(tester),
      navIndexOf(fallback),
      reason: 'chrome 必须高亮回退项',
    );
    expect(
      find.byType(Library),
      findsOneWidget,
      reason: '页面栈必须跟随同一个有效选中项',
    );
    expect(
      find.byType(FavoritesPage),
      findsNothing,
      reason: '被隐藏的页不能继续显示',
    );
    // 页面实例仍挂在树上（只是不可见），重新可见时状态不丢。
    expect(find.byType(FavoritesPage, skipOffstage: false), findsOneWidget);

    // 同步解除隐藏：raw 选中项恢复，chrome 与页面栈仍一致。
    expect(await nav.setVisible(ShellDestination.favorites, true), isTrue);
    await tester.pump();
    expect(selectedNavIndex(tester), navIndexOf(ShellDestination.favorites));
    expect(find.byType(FavoritesPage), findsOneWidget);
    expect(find.byType(Library), findsNothing);
  });

  testWidgets('raw 选中项被隐藏时点击回退项：按当前可见页处理，恰一次反馈', (tester) async {
    final vibrations = recordVibrations(tester);
    await pumpShell(tester);
    await tapBottomDestination(tester, ShellDestination.favorites);
    await settleTransition(tester);

    expect(await nav.setVisible(ShellDestination.favorites, false), isTrue);
    await tester.pump();
    vibrations.clear();

    // 点击的正是 chrome 当前高亮的回退页：应走「重复点击」语义，
    // 不切页（不闪一次淡入），也不对隐藏页触发任何响应。
    await tapBottomDestination(tester, ShellDestination.library);
    await tester.pump();

    expect(
      selectedNavIndex(tester),
      navIndexOf(ShellDestination.library),
      reason: '点击回退项后 chrome 仍高亮它',
    );
    expect(
      find.byType(Library),
      findsOneWidget,
      reason: '页面栈保持在回退页',
    );
    expect(find.byType(FavoritesPage), findsNothing);
    expect(
      vibrations,
      ['HapticFeedbackType.lightImpact'],
      reason: '重复点击恰一次轻震（不重复触发）',
    );

    await settleTransition(tester);
    expect(selectedNavIndex(tester), navIndexOf(ShellDestination.library));
    expect(find.byType(Library), findsOneWidget);
  });

  testWidgets('隐藏正在显示的播放页：页面栈与顶栏一起退出播放页形态', (tester) async {
    await pumpShell(tester);
    expect(selectedNavIndex(tester), navIndexOf(ShellDestination.nowPlaying));
    expect(find.byType(NowPlaying), findsOneWidget);

    // setVisible 拒绝隐藏启动首页：先把首页挪到收藏，模拟远端设置后
    // 同步隐藏播放页（reload 路径允许隐藏原首页）。
    await nav.setHomeDestination(ShellDestination.favorites);
    await tester.pump();
    expect(await nav.setVisible(ShellDestination.nowPlaying, false), isTrue);
    await tester.pump();

    expect(
      selectedNavIndex(tester),
      navIndexOf(ShellDestination.library),
      reason: 'chrome 回退到首个可见项',
    );
    expect(find.byType(Library), findsOneWidget);
    expect(
      find.byType(NowPlaying).hitTestable(),
      findsNothing,
      reason: '被隐藏的播放页不再可命中（上一页层仅保留过渡占位）',
    );
    expect(
      tester
          .widget<AnimatedOpacity>(
            find
                .ancestor(
                  of: find.descendant(
                    of: find.byType(AppBar),
                    matching: find.byType(M3EProgressIndicator),
                  ),
                  matching: find.byType(AnimatedOpacity),
                )
                .first,
          )
          .opacity,
      1,
      reason: '已离开播放页：顶栏曲目区/进度条恢复（morph 状态跟随有效选中项）',
    );

    // 播放页恢复可见：raw 选中项恢复，页面栈与顶栏回到播放页形态。
    expect(await nav.setVisible(ShellDestination.nowPlaying, true), isTrue);
    await tester.pump();
    expect(selectedNavIndex(tester), navIndexOf(ShellDestination.nowPlaying));
    expect(find.byType(NowPlaying), findsOneWidget);
    expect(find.byType(Library), findsNothing);
    expect(
      tester
          .widget<AnimatedOpacity>(
            find
                .ancestor(
                  of: find.descendant(
                    of: find.byType(AppBar),
                    matching: find.byType(M3EProgressIndicator),
                  ),
                  matching: find.byType(AnimatedOpacity),
                )
                .first,
          )
          .opacity,
      0,
      reason: '回到播放页：顶栏曲目区/进度条再次由页面承接',
    );
  });
}
