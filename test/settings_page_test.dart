import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/pages/settings_page.dart';
import 'package:molia/providers/local_database_provider.dart';
import 'package:molia/providers/nav_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/providers/theme_provider.dart';
import 'package:molia/services/data_saver_service.dart';
import 'package:molia/services/language_service.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/services/play_statistics_service.dart';
import 'package:molia/services/settings_service.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:molia/theme/scheme_builder.dart';
import 'package:molia/utils/responsive.dart';

import 'support/fakes.dart';
import 'package:molia/data/settings/settings_keys.dart';

import 'support/settings_test_support.dart';

/// 设置页冒烟：首屏 5 分区、行内分段交互与弹层内部子页导航。
/// 不触碰真实 DB / 安全存储（fake SettingsService）。
class _FakeSettingsService extends SettingsService {
  bool copyLyricsAsSingleLine = false;

  @override
  Future<bool> getCopyLyricsAsSingleLine() async => copyLyricsAsSingleLine;

  @override
  Future<void> saveCopyLyricsAsSingleLine(bool value) async {
    copyLyricsAsSingleLine = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ThemeProvider themeProvider;
  late PlaybackProvider playbackProvider;
  late DataSaverService dataSaver;
  late PlayStatisticsService playStatisticsService;
  late ValueNotifier<bool> settingsSubPageOpen;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 构造共享 provider 树并挂载 [home]（与真实组合根同源装配）。
  Future<void> pumpApp(
    WidgetTester tester,
    Widget home, {
    List<SingleChildWidget> extraProviders = const [],
  }) async {
    themeProvider = ThemeProvider();
    playbackProvider = buildTestPlaybackProvider();
    // 省流模式：注入 fake 探测（Wi-Fi），不触碰 connectivity_plus 通道。
    dataSaver = DataSaverService(
      prefs: await SharedPreferences.getInstance(),
      cellularProbe: () async => false,
      cellularChanges: const Stream<bool>.empty(),
    );
    await dataSaver.init();
    await themeProvider.preferencesReady;
    await playbackProvider.preferencesReady;
    addTearDown(themeProvider.dispose);
    addTearDown(playbackProvider.dispose);
    addTearDown(dataSaver.dispose);

    // 底部导航定制：纯本地偏好，测试直接构造。
    final navProvider = NavProvider();
    await navProvider.preferencesReady;
    addTearDown(navProvider.dispose);

    // 听歌统计开关：只读 enabledNotifier，不触碰数据库。
    playStatisticsService = PlayStatisticsService(
      repository: PlayStatisticsRepository(
        databaseProvider: () async => throw StateError('测试不访问数据库'),
      ),
      settings: testSettingsRegistry(
        preferences: await SharedPreferences.getInstance(),
      ),
    );
    await playStatisticsService.init();
    addTearDown(playStatisticsService.enabledNotifier.dispose);

    final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
    final themedData = ThemeData(colorScheme: themeProvider.colorScheme);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
          ChangeNotifierProvider<PlaybackProvider>.value(
              value: playbackProvider),
          ChangeNotifierProvider<NavProvider>.value(value: navProvider),
          Provider<SettingsService>(create: (_) => _FakeSettingsService()),
          ChangeNotifierProvider<LocalDatabaseProvider>(
            create: (_) => LocalDatabaseProvider(),
          ),
          Provider<LyricsService>(create: (_) => LyricsService()),
          Provider<NotificationService>.value(
            value: NotificationService(scaffoldMessengerKey),
          ),
          ChangeNotifierProvider<DataSaverService>.value(value: dataSaver),
          Provider<PlayStatisticsService>.value(value: playStatisticsService),
          ...extraProviders,
        ],
        child: M3EMaterialApp(
          data: M3EThemeData.fromMaterial(themedData),
          theme: themedData,
          scaffoldMessengerKey: scaffoldMessengerKey,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: LanguageService.supportedLocales,
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpSettingsPage(
    WidgetTester tester, {
    List<SingleChildWidget> extraProviders = const [],
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // 弹层 guard 状态出口（app_shell 接线同款）。
    settingsSubPageOpen = ValueNotifier<bool>(false);
    addTearDown(settingsSubPageOpen.dispose);

    await pumpApp(
      tester,
      Scaffold(body: SettingsPage(subPageOpen: settingsSubPageOpen)),
      extraProviders: extraProviders,
    );
  }

  /// 行内分段按钮的 segment 命中（标签文本在行 key 之内）。
  Finder segmentOf(Key rowKey, String label) => find.descendant(
        of: find.byKey(rowKey),
        matching: find.text(label),
      );

  testWidgets('设置首屏：5 分区齐全，低频内容移出首屏', (tester) async {
    await pumpSettingsPage(tester);

    // 分区卡片标题（卡片上方结构标签）。
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Playback'), findsOneWidget);
    expect(find.text('Lyrics & display'), findsOneWidget);
    expect(find.text('Content & sources'), findsOneWidget);
    expect(find.text('General & data'), findsOneWidget);

    expect(find.text('Theme mode'), findsOneWidget);
    expect(find.text('Base colors'), findsOneWidget);
    expect(find.text('Follow album art'), findsOneWidget);
    expect(find.text('Pure black background'), findsOneWidget);
    expect(find.text('App font'), findsOneWidget);
    expect(find.text('Default play mode'), findsOneWidget);
    expect(find.text('Resume last playback'), findsOneWidget);
    expect(find.text('Now playing quality'), findsOneWidget);
    // 省流只有入口行一处（无分区标题、无子项）。
    expect(find.text('Data saver'), findsOneWidget);
    expect(find.text('Lyrics display'), findsOneWidget);
    expect(find.text('Source Management'), findsOneWidget);
    expect(find.text('AI DJ'), findsOneWidget);
    // 通用与数据：入口行同组。
    expect(find.text('General'), findsOneWidget);
    expect(find.text('Data & storage'), findsOneWidget);

    // 子页内容不在首屏。
    expect(find.text('Bottom navigation'), findsNothing);
    expect(find.text('App Language'), findsNothing);
    expect(find.text('App name'), findsNothing);
    expect(find.text('Cache management'), findsNothing);
    expect(find.text('Listening Stats'), findsNothing);
    expect(find.text('Export Recent Plays'), findsNothing);
    // 默认音质入口在播放区（需 SourcesProvider；本树未注入）。
    expect(find.text('Default quality'), findsNothing);

    expect(find.text('Setup'), findsNothing);
    expect(find.text('Tutorial'), findsNothing);
    expect(find.byIcon(Icons.email_rounded), findsNothing);
  });

  testWidgets('主题模式：行内分段选择深色后 provider 生效', (tester) async {
    await pumpSettingsPage(tester);

    await tester.tap(segmentOf(const Key('settingsThemeModeItem'), 'Dark'));
    await tester.pumpAndSettle();

    expect(themeProvider.themeMode, ThemeMode.dark);
    expect(themeProvider.colorScheme.brightness, Brightness.dark);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'dark');
  });

  testWidgets('基础配色：行内分段；无莫奈时壁纸段禁用，自定义可切换', (tester) async {
    await pumpSettingsPage(tester);

    // 默认壁纸；测试环境无莫奈注入，副标题给出平台说明。
    expect(themeProvider.baseColorSource, ColorBaseSource.wallpaper);
    expect(find.text('Not supported on this platform'), findsOneWidget);

    // 壁纸段禁用：点它不产生状态变化。
    await tester.tap(
      segmentOf(const Key('settingsBaseColorItem'), 'System wallpaper (Monet)'),
    );
    await tester.pumpAndSettle();
    expect(themeProvider.baseColorSource, ColorBaseSource.wallpaper);

    // 选自定义：自定义颜色行出现并持久化。
    await tester
        .tap(segmentOf(const Key('settingsBaseColorItem'), 'Custom color'));
    await tester.pumpAndSettle();
    expect(themeProvider.baseColorSource, ColorBaseSource.custom);
    expect(find.byKey(const Key('settingsSeedColorItem')), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('color_base'), 'custom');
  });

  testWidgets('播放时跟随封面开关：切换后 provider 状态与持久化生效', (tester) async {
    await pumpSettingsPage(tester);
    expect(themeProvider.followArtworkEnabled, isTrue);

    await tester.tap(find.byKey(const Key('settingsFollowArtworkSwitch')));
    await tester.pumpAndSettle();

    expect(themeProvider.followArtworkEnabled, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('follow_artwork_enabled'), isFalse);
  });

  testWidgets('主题色：任意取色（Hex）后 provider 生效', (tester) async {
    await pumpSettingsPage(tester);

    // 自定义色行只在基础配色=自定义时出现。
    await themeProvider.setBaseColorSource(ColorBaseSource.custom);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('settingsSeedColorItem')));
    await tester.pumpAndSettle();
    expect(find.byType(M3EDialog), findsOneWidget);

    await tester.enterText(find.byType(M3ETextField), '#00FF00');
    await tester.pump();
    await tester.tap(find.widgetWithText(M3EButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.byType(M3EDialog), findsNothing);
    expect(themeProvider.seedColor.toARGB32(), 0xFF00FF00);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('seed_color'), 0xFF00FF00);
  });

  testWidgets('取色弹层取消：只关弹层，设置首屏保留', (tester) async {
    await pumpSettingsPage(tester);

    await themeProvider.setBaseColorSource(ColorBaseSource.custom);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settingsSeedColorItem')));
    await tester.pumpAndSettle();
    expect(find.byType(M3EDialog), findsOneWidget);

    // M3EDialog 挂 root navigator；取消若用首屏 context 定向，
    // 弹掉的是设置弹层内部 Navigator 的首屏，表现为设置内容整块消失。
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(M3EDialog), findsNothing);
    expect(find.text('Theme mode'), findsOneWidget);
  });

  testWidgets('默认播放模式：副标题说明「默认」语义，行内分段选择随机后生效', (tester) async {
    await pumpSettingsPage(tester);

    // 语义说明常驻（不打断当前播放）。
    expect(find.textContaining('Initial mode'), findsOneWidget);

    await tester.tap(
      segmentOf(const Key('settingsDefaultPlayModeItem'), 'Shuffle'),
    );
    await tester.pumpAndSettle();

    expect(playbackProvider.defaultPlayMode, PlayMode.shuffle);
    // 无曲目：立即应用到播放服务（facade 快照跟随）。
    expect(playbackProvider.currentMode, PlayMode.shuffle);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('default_play_mode'), 'shuffle');
  });

  testWidgets('启动时恢复上次播放：默认开，关闭后状态与持久化生效', (tester) async {
    await pumpSettingsPage(tester);
    expect(playbackProvider.restoreSessionEnabled, isTrue);

    await tester.tap(find.byKey(const Key('settingsRestoreSessionSwitch')));
    await tester.pumpAndSettle();

    expect(playbackProvider.restoreSessionEnabled, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kRestoreSessionEnabled.name), isFalse);
  });

  testWidgets('省流模式：入口进子页，开关/音质上限/封面省流生效并持久化', (tester) async {
    await pumpSettingsPage(tester);

    // 首屏只有入口行，子项在子页。
    expect(find.byKey(const Key('settingsDataSaverItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsDataSaverSwitch')), findsNothing);

    final entry = find.byKey(const Key('settingsDataSaverItem'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    // 子页默认关闭：子项隐藏。
    expect(find.byKey(const Key('settingsDataSaverSwitch')), findsOneWidget);
    expect(find.byKey(const Key('settingsDataSaverQualityItem')), findsNothing);

    await tester.tap(find.byKey(const Key('settingsDataSaverSwitch')));
    await tester.pumpAndSettle();

    expect(dataSaver.enabled, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('data_saver_enabled'), isTrue);

    // 开启后子项可见：音质上限分段选择 192K。
    final qualityFinder = find.byKey(const Key('settingsDataSaverQualityItem'));
    expect(qualityFinder, findsOneWidget);
    await tester.ensureVisible(qualityFinder);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: qualityFinder, matching: find.text('192K')),
    );
    await tester.pumpAndSettle();
    expect(dataSaver.qualityCap, '192k');
    expect(prefs.getString('data_saver_quality'), '192k');

    // 封面省流默认开 → 关闭后持久化。
    final coversFinder = find.byKey(const Key('settingsDataSaverCoversSwitch'));
    await tester.ensureVisible(coversFinder);
    await tester.pumpAndSettle();
    await tester.tap(coversFinder);
    await tester.pumpAndSettle();
    expect(dataSaver.coversSaverEnabled, isFalse);
    expect(prefs.getBool('data_saver_covers'), isFalse);
  });

  testWidgets('默认音质：播放区行内下拉显示当前值并随 provider 变化', (tester) async {
    late final SourceManager manager;
    late final SourcesProvider sourcesProvider;
    await tester.runAsync(() async {
      manager = SourceManager(
        settings: testSettingsRegistry(
          preferences: await SharedPreferences.getInstance(),
        ),
      );
      sourcesProvider = SourcesProvider(manager);
    });
    addTearDown(sourcesProvider.dispose);
    addTearDown(manager.dispose);

    await pumpSettingsPage(
      tester,
      extraProviders: [
        ChangeNotifierProvider<SourcesProvider>.value(value: sourcesProvider),
      ],
    );

    expect(find.byKey(const Key('settingsDefaultQualityItem')), findsOneWidget);
    final qualityRow = find.byKey(const Key('settingsDefaultQualityItem'));
    expect(
      find.descendant(of: qualityRow, matching: find.text('320K')),
      findsOneWidget,
    );

    await sourcesProvider.setPreferredQuality('192k');
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: qualityRow, matching: find.text('192K')),
      findsOneWidget,
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kLxDefaultQuality.name), '192k');
  });

  testWidgets('通用子页：弹层内部导航进入，语言行内分段切换并持久化', (tester) async {
    await pumpSettingsPage(tester);
    expect(settingsSubPageOpen.value, isFalse);

    await tester.tap(find.byKey(const Key('settingsGeneralItem')));
    await tester.pumpAndSettle();

    // 子页内容：底部导航（行序第一）/ 语言 / 应用名称；首屏内容离屏。
    expect(find.text('App Language'), findsOneWidget);
    expect(find.text('App name'), findsOneWidget);
    expect(find.text('Bottom navigation'), findsOneWidget);
    expect(find.byType(ReorderableListView), findsOneWidget);
    expect(find.text('Theme mode'), findsNothing);
    // 子页栈状态同步给弹层 guard。
    expect(settingsSubPageOpen.value, isTrue);

    // 语言行内分段：切到简体中文后写入登记键。
    final prefs = await SharedPreferences.getInstance();
    LanguageService.attachSettings(
      testSettingsRegistry(preferences: prefs),
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('settingsLanguageItem')),
        matching: find.text('简体中文'),
      ),
    );
    await tester.pumpAndSettle();
    expect(prefs.getString(kSelectedLanguage.name), 'zh');

    // 系统返回：先退子页，不关闭设置本身。
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(find.text('Theme mode'), findsOneWidget);
    expect(find.text('App Language'), findsNothing);
    expect(settingsSubPageOpen.value, isFalse);
  });

  testWidgets('底部弹层 guard：子页打开时系统返回先退子页、不退弹层', (tester) async {
    // 移动端视口 → showAdaptiveModalPage 走底部弹层分支（large 宽走对话框）。
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // 复现 app_shell 接线：弹层 dismiss guard + SettingsPage(subPageOpen)。
    await pumpApp(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: M3EButton.filled(
              onPressed: () {
                final subPageOpen = ValueNotifier<bool>(false);
                ResponsiveNavigation.showAdaptiveModalPage(
                  context: context,
                  showCloseButton: false,
                  onDismissRequest: () async => !subPageOpen.value,
                  child: SettingsPage(subPageOpen: subPageOpen),
                ).whenComplete(subPageOpen.dispose);
              },
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);

    // 进入通用子页（列表底部，先滚到可见）。
    final generalItem = find.byKey(const Key('settingsGeneralItem'));
    await tester.scrollUntilVisible(
      generalItem,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(generalItem);
    await tester.pumpAndSettle();
    expect(find.text('App Language'), findsOneWidget);

    // 系统返回：guard 阻止弹层关闭，只退子页。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('App Language'), findsNothing);
    expect(find.text('Settings'), findsOneWidget);

    // 回到首屏后再系统返回：弹层正常关闭。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsNothing);
    expect(find.text('Open settings'), findsOneWidget);
  });

  testWidgets('底部弹层：列表滑到顶后继续下滑可关闭（M3E 弹层滚动控制器接线）', (tester) async {
    // 移动端视口 → showAdaptiveModalPage 走底部弹层分支。
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await pumpApp(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: M3EButton.filled(
              onPressed: () {
                final subPageOpen = ValueNotifier<bool>(false);
                ResponsiveNavigation.showAdaptiveModalPage(
                  context: context,
                  showCloseButton: false,
                  onDismissRequest: () async => !subPageOpen.value,
                  child: SettingsPage(subPageOpen: subPageOpen),
                ).whenComplete(subPageOpen.dispose);
              },
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);

    // 列表在顶部继续下滑：设置首屏的滚动视图挂的是弹层控制器，
    // 拖动应联动收缩/关闭弹层（回归：内嵌 Navigator 路由遮蔽控制器）。
    for (var i = 0; i < 3; i++) {
      await tester.fling(
        find.byType(SingleChildScrollView).first,
        const Offset(0, 400),
        1500,
      );
      await tester.pumpAndSettle();
      if (find.text('Settings').evaluate().isEmpty) break;
    }

    expect(find.text('Open settings'), findsOneWidget);
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('数据与存储子页：统计开关与入口同组，返回退回首屏', (tester) async {
    await pumpSettingsPage(tester);

    await tester.tap(find.byKey(const Key('settingsDataItem')));
    await tester.pumpAndSettle();

    expect(find.text('Cache management'), findsOneWidget);
    expect(find.text('Listening Stats'), findsOneWidget);
    expect(find.text('Export data'), findsOneWidget);
    expect(find.text('Import data'), findsOneWidget);
    expect(find.text('Import Favorites'), findsOneWidget);
    // 采集开关与统计入口同页同组。
    expect(
      find.byKey(const Key('settingsPlayStatisticsSwitch')),
      findsOneWidget,
    );

    // 关闭统计采集：状态与持久化生效。
    await tester.tap(find.byKey(const Key('settingsPlayStatisticsSwitch')));
    await tester.pumpAndSettle();
    expect(playStatisticsService.enabledNotifier.value, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kPlayStatisticsEnabled.name), isFalse);

    // 应用栏返回箭头退回首屏。
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Listening Stats'), findsNothing);
  });

  testWidgets('设置页不直接操作系统栏（避免关闭弹层返回时闪烁）', (tester) async {
    final chromeCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method.startsWith('SystemChrome.')) {
          chromeCalls.add(call.method);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await pumpSettingsPage(tester);

    // M3EMaterialApp 会管理 overlay style，但设置页自身不得切换 UI mode
    // （重复调用会造成系统栏 insets 抖动 → 返回主页面时闪烁）。
    expect(
      chromeCalls,
      isNot(contains('SystemChrome.setEnabledSystemUIMode')),
    );
  });
}
