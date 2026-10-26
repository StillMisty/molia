import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/pages/settings_page.dart';
import 'package:molia/providers/lyrics_display_provider.dart';
import 'package:molia/providers/nav_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/providers/theme_provider.dart';
import 'package:molia/services/audio_focus_settings.dart';
import 'package:molia/services/covers/custom_cover_store.dart';
import 'package:molia/services/data_saver_service.dart';
import 'package:molia/services/haptics.dart';
import 'package:molia/services/library/library_add_settings.dart';
import 'package:molia/services/language_service.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/services/lyrics_display/lyrics_output.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/services/play_statistics_service.dart';
import 'package:molia/services/shortcut_bindings.dart';
import 'package:molia/services/shortcut_settings.dart';
import 'package:molia/services/shortcuts.dart';
import 'package:molia/services/window/app_tray.dart';
import 'package:molia/services/window/tray_settings.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:molia/theme/scheme_builder.dart';
import 'package:molia/widgets/molia_mark.dart';
import 'package:molia/widgets/settings/settings_subpage.dart';
import 'package:molia/widgets/settings/settings_tiles.dart';

import 'support/fakes.dart';

import 'package:molia/data/settings/settings_keys.dart';

import 'support/notification_recorder.dart';
import 'support/sync_test_support.dart';

import 'support/settings_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ThemeProvider themeProvider;
  late PlaybackProvider playbackProvider;
  late DataSaverService dataSaver;
  late AudioFocusSettings audioFocusSettings;
  late PlayStatisticsService playStatisticsService;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 构造共享 provider 树并挂载 [home]（与真实组合根同源装配）。
  Future<void> pumpApp(
    WidgetTester tester,
    Widget home, {
    List<SingleChildWidget> extraProviders = const [],
  }) async {
    themeProvider = ThemeProvider(settings: testSettingsRegistry());
    playbackProvider = buildTestPlaybackProvider();
    // 省流模式：注入 fake 探测（Wi-Fi），不触碰 connectivity_plus 通道。
    dataSaver = DataSaverService(
      prefs: await SharedPreferences.getInstance(),
      cellularProbe: () async => false,
      cellularChanges: const Stream<bool>.empty(),
    );
    await dataSaver.init();
    audioFocusSettings = AudioFocusSettings(settings: testSettingsRegistry());
    await audioFocusSettings.init();
    await themeProvider.preferencesReady;
    await playbackProvider.preferencesReady;
    addTearDown(themeProvider.dispose);
    addTearDown(playbackProvider.dispose);
    addTearDown(dataSaver.dispose);
    addTearDown(audioFocusSettings.dispose);

    // 底部导航定制：纯本地偏好，测试直接构造。
    final navProvider = NavProvider(settings: testSettingsRegistry());
    await navProvider.preferencesReady;
    addTearDown(navProvider.dispose);

    // 听歌统计开关：只读 enabledNotifier，不触碰数据库。
    playStatisticsService = PlayStatisticsService(
      repository: PlayStatisticsRepository(
        databaseProvider: () => throw StateError('测试不访问数据库'),
        statisticsSync: testStatisticsSyncStore(
          () => throw StateError('测试不访问数据库'),
        ),
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
            value: playbackProvider,
          ),
          ChangeNotifierProvider<NavProvider>.value(value: navProvider),
          Provider<LyricsService>(create: (_) => LyricsService()),
          Provider<NotificationService>.value(value: NotificationService()),
          ChangeNotifierProvider<DataSaverService>.value(value: dataSaver),
          ChangeNotifierProvider<AudioFocusSettings>.value(
            value: audioFocusSettings,
          ),
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

  /// 设置子页 chrome 的独立挂载：不需要整棵 provider 树。
  Future<void> pumpSubPage(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(
      M3EMaterialApp(
        data: M3EThemeData.fromMaterial(ThemeData()),
        theme: ThemeData(),
        home: page,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('设置子页 chrome：标题 / 动作 / 正文与统一内边距', (tester) async {
    await pumpSubPage(
      tester,
      SettingsSubPage(
        title: 'Settings title',
        actions: [
          M3EIconButton(
            key: const Key('subpageAction'),
            variant: M3EIconButtonVariant.standard,
            icon: const Icon(Icons.refresh_rounded),
            semanticLabel: 'Refresh',
            onPressed: () {},
          ),
        ],
        children: const [Text('Body child')],
      ),
    );

    expect(find.text('Settings title'), findsOneWidget);
    expect(find.byKey(const Key('subpageAction')), findsOneWidget);
    expect(find.text('Body child'), findsOneWidget);
    expect(
      tester.widget<ListView>(find.byType(ListView)).padding,
      const EdgeInsets.all(kSettingsPadding),
    );
  });

  testWidgets('设置子页 chrome：自定义正文不再自动套 ListView', (tester) async {
    await pumpSubPage(
      tester,
      const SettingsSubPage.body(
        title: 'Custom title',
        body: Center(child: Text('Custom body')),
      ),
    );

    expect(find.text('Custom title'), findsOneWidget);
    expect(find.text('Custom body'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('设置子页 chrome：safeArea 在标准正文外层补系统 inset', (tester) async {
    await pumpSubPage(
      tester,
      const SettingsSubPage(
        title: 'Cache',
        safeArea: true,
        children: [Text('Cache body')],
      ),
    );

    expect(
      find.ancestor(of: find.byType(ListView), matching: find.byType(SafeArea)),
      findsOneWidget,
    );
  });

  Future<void> pumpSettingsPage(
    WidgetTester tester, {
    List<SingleChildWidget> extraProviders = const [],
    Size size = const Size(1200, 2400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // 直接挂载设置页（弹层宿主由各用例按需提供）。
    await pumpApp(
      tester,
      const Scaffold(body: SettingsPage()),
      extraProviders: extraProviders,
    );
  }

  /// 设置首屏在场的标记：顶部「设置」标题行已移除（弹层 chrome 只剩内容），
  /// 用第一个分区标题判断首屏在不在。
  Finder settingsHome() => find.text('Appearance');

  /// 行内选项的命中：分段/预览圆的标签文本都在行 key 之内。
  Finder optionOf(Key rowKey, String label) =>
      find.descendant(of: find.byKey(rowKey), matching: find.text(label));

  Map<String, dynamic> backArgs(double progress) => <String, dynamic>{
    'touchOffset': <double>[5, 600],
    'progress': progress,
    'swipeEdge': 0,
  };

  /// 模拟 Android 预测返回手势通道事件（start / update / commit / cancel）。
  Future<void> sendBack(
    WidgetTester tester,
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    final data = const StandardMethodCodec().encodeMethodCall(
      MethodCall(method, args),
    );
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.backGesture.name,
      data,
      (ByteData? _) {},
    );
  }

  testWidgets('震动反馈：行在通用子页，默认开，关闭后即时生效并持久化', (tester) async {
    await pumpSettingsPage(tester);
    addTearDown(() => HapticsService.setEnabled(HapticsService.defaultEnabled));

    // 入口在「通用与数据」，开关本体在通用子页。
    await tester.tap(find.byKey(const Key('settingsGeneralItem')));
    await tester.pumpAndSettle();

    expect(find.text('Vibration feedback'), findsOneWidget);
    expect(HapticsService.enabled, isTrue);

    await tester.tap(find.byKey(const Key('settingsHapticsSwitch')));
    await tester.pumpAndSettle();

    expect(HapticsService.enabled, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(HapticsService.keyEnabled), isFalse);

    // 再点开：即时恢复（不需要重启应用）。
    await tester.tap(find.byKey(const Key('settingsHapticsSwitch')));
    await tester.pumpAndSettle();
    expect(HapticsService.enabled, isTrue);
  });

  testWidgets('主题模式：行内分段选择深色后 provider 生效', (tester) async {
    await pumpSettingsPage(tester);

    await tester.tap(optionOf(const Key('settingsThemeModeItem'), 'Dark'));
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
      optionOf(const Key('settingsBaseColorItem'), 'System wallpaper'),
    );
    await tester.pumpAndSettle();
    expect(themeProvider.baseColorSource, ColorBaseSource.wallpaper);

    // 选自定义：自定义颜色行出现并持久化。
    await tester.tap(
      optionOf(const Key('settingsBaseColorItem'), 'Custom color'),
    );
    await tester.pumpAndSettle();
    expect(themeProvider.baseColorSource, ColorBaseSource.custom);
    expect(find.byKey(const Key('settingsSeedColorItem')), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('color_base'), 'custom');
  });

  testWidgets('基础配色副标题三态：壁纸 / 强调色 / 都不可用；仅壁纸 seed 时壁纸段可点', (tester) async {
    await pumpSettingsPage(tester);

    // 都不可用：说明文案 + 壁纸段禁用（既有行为）。
    expect(find.text('Not supported on this platform'), findsOneWidget);

    // 仅壁纸 seed（无强调色）：副标题显示真实来源，壁纸段可点。
    themeProvider.updateSystemWallpaperSeed(Colors.green, Colors.teal);
    await tester.pumpAndSettle();
    expect(find.text('Source: system wallpaper'), findsOneWidget);

    await themeProvider.setBaseColorSource(ColorBaseSource.custom);
    await tester.pumpAndSettle();
    await tester.tap(
      optionOf(const Key('settingsBaseColorItem'), 'System wallpaper'),
    );
    await tester.pumpAndSettle();
    expect(themeProvider.baseColorSource, ColorBaseSource.wallpaper);

    // 只有强调色（壁纸 seed 清空）：副标题回到强调色口径，壁纸段仍可点。
    themeProvider.updateSystemWallpaperSeed(null, null);
    themeProvider.updateMonetSchemes(
      buildColorScheme(Colors.pink, Brightness.light),
      buildColorScheme(Colors.pink, Brightness.dark),
    );
    await tester.pumpAndSettle();
    expect(find.text('Source: system theme color'), findsOneWidget);

    await themeProvider.setBaseColorSource(ColorBaseSource.custom);
    await tester.pumpAndSettle();
    await tester.tap(
      optionOf(const Key('settingsBaseColorItem'), 'System wallpaper'),
    );
    await tester.pumpAndSettle();
    expect(themeProvider.baseColorSource, ColorBaseSource.wallpaper);

    // 强调色也清空：回到「都不可用」。
    themeProvider.updateMonetSchemes(null, null);
    await tester.pumpAndSettle();
    expect(find.text('Not supported on this platform'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

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
    expect(
      find.textContaining('Used the next time playback starts'),
      findsOneWidget,
    );

    await tester.tap(
      optionOf(const Key('settingsDefaultPlayModeItem'), 'Shuffle'),
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

  testWidgets('与其他应用同时播放：默认开，关闭后状态与持久化生效', (tester) async {
    await pumpSettingsPage(tester);
    expect(audioFocusSettings.playWithOtherApps, isTrue);

    await tester.tap(find.byKey(const Key('settingsPlayWithOtherAppsSwitch')));
    await tester.pumpAndSettle();

    expect(audioFocusSettings.playWithOtherApps, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kPlayWithOtherApps.name), isFalse);
  });

  testWidgets('与其他应用同时播放：桌面没有音频焦点实现，不显示', (tester) async {
    await pumpSettingsPage(tester);
    expect(
      find.byKey(const Key('settingsPlayWithOtherAppsSwitch')),
      findsNothing,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('省流模式：开关/音质上限/封面省流在播放分区内生效并持久化', (tester) async {
    await pumpSettingsPage(tester);

    // 默认关闭：只有开关行，子项不出现。
    expect(find.byKey(const Key('settingsDataSaverSwitch')), findsOneWidget);
    expect(find.byKey(const Key('settingsDataSaverQualityItem')), findsNothing);
    expect(
      find.byKey(const Key('settingsDataSaverCoversSwitch')),
      findsNothing,
    );

    final switchFinder = find.byKey(const Key('settingsDataSaverSwitch'));
    await tester.ensureVisible(switchFinder);
    await tester.pumpAndSettle();
    await tester.tap(switchFinder);
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

  testWidgets('加入位置：分段行默认选中顶部，切换后持久化', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final libraryAddSettings = LibraryAddSettings(
      settings: testSettingsRegistry(preferences: prefs),
    );
    addTearDown(libraryAddSettings.dispose);
    await libraryAddSettings.init();

    await pumpSettingsPage(
      tester,
      extraProviders: [
        ChangeNotifierProvider<LibraryAddSettings>.value(
          value: libraryAddSettings,
        ),
      ],
    );

    final row = find.byKey(const Key('settingsLibraryAddPositionItem'));
    expect(row, findsOneWidget);
    expect(libraryAddSettings.addToTop, isTrue, reason: '默认放列表开头');
    expect(
      optionOf(const Key('settingsLibraryAddPositionItem'), 'Top'),
      findsOneWidget,
    );

    await tester.tap(
      optionOf(const Key('settingsLibraryAddPositionItem'), 'Bottom'),
    );
    await tester.pumpAndSettle();

    expect(libraryAddSettings.position, LibraryAddPosition.bottom);
    expect(prefs.getString(kLibraryAddPosition.name), 'bottom');
  });

  testWidgets('通用子页：弹层内部导航进入，语言行内分段切换并持久化', (tester) async {
    await pumpSettingsPage(tester);

    await tester.tap(find.byKey(const Key('settingsGeneralItem')));
    await tester.pumpAndSettle();

    // 子页内容：底部导航（行序第一）/ 语言 / 应用名称；首屏内容离屏。
    expect(find.text('App Language'), findsOneWidget);
    expect(find.text('App name'), findsOneWidget);
    expect(find.text('Bottom navigation'), findsOneWidget);
    expect(find.byType(ReorderableListView), findsOneWidget);
    expect(find.text('Theme mode'), findsNothing);

    // 语言行内分段：切到简体中文后写入登记键。
    final prefs = await SharedPreferences.getInstance();
    LanguageService.attachSettings(testSettingsRegistry(preferences: prefs));
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
  });

  // 快捷键入口只在桌面平台显示（`flutter test` 的 defaultTargetPlatform 是
  // android，需要 variant 钉住 linux，与其它桌面门控用例同口径）。
  testWidgets('设置首屏：快捷键入口打开绑定设置子页', (tester) async {
    await pumpSettingsPage(tester);

    final entry = find.byKey(const Key('settingsShortcutsItem'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    // 子页：两组总开关 + 两组绑定行（软件内 / 全局默认表各取一条代表）。
    expect(find.byKey(const Key('shortcutsEnabledSwitch')), findsOneWidget);
    expect(
      find.byKey(const Key('shortcutsGlobalEnabledSwitch')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('shortcutRow_inApp_togglePlayPause')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('shortcutRow_global_showMainWindow')),
      findsOneWidget,
    );
    // 组级恢复默认行两组都有（全默认时置灰，仍占位）。
    expect(find.byKey(const Key('shortcutResetAll_inApp')), findsOneWidget);
    expect(find.byKey(const Key('shortcutResetAll_global')), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('通用子页：快捷键冲突弹确认层，替换后互换两者绑定', (tester) async {
    // 快捷键状态是单例：接线登记表并保证从全默认开始，结束恢复默认。
    final prefs = await SharedPreferences.getInstance();
    ShortcutSettings.attachSettings(testSettingsRegistry(preferences: prefs));
    await ShortcutSettings.load();
    // 提示出口换成记录型（默认构造缺 hostContextKey，展示是空操作）。
    final notifications = RecordingNotificationService();
    addTearDown(() async {
      await ShortcutSettings.instance.resetScope(ShortcutScope.inApp);
      await ShortcutSettings.instance.resetScope(ShortcutScope.global);
    });

    await pumpSettingsPage(
      tester,
      extraProviders: [
        Provider<NotificationService>.value(value: notifications),
        // 页面经 `context.watch<ShortcutSettings?>` 订阅；不接 provider 会走
        // 单例回退（不订阅），互换后行内文案不会刷新。
        ChangeNotifierProvider<ShortcutSettings>.value(
          value: ShortcutSettings.instance,
        ),
      ],
    );
    // 快捷键入口在设置首屏「通用」卡（不再藏在通用子页里）。
    final entry = find.byKey(const Key('settingsShortcutsItem'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    // 给「音量 +」录 Space（已被「播放 / 暂停」占用）→ 弹替换确认层。
    final row = find.byKey(const Key('shortcutRow_inApp_volumeUp'));
    Future<void> recordSpace() async {
      await tester.tap(row);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
    }

    await recordSpace();
    expect(find.text('Replace shortcut?'), findsOneWidget);
    expect(
      find.text(
        '“Play / pause” already uses this combination. '
        'Replacing will swap the two shortcuts.',
      ),
      findsOneWidget,
    );

    // 取消：绑定不动。
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      ShortcutSettings.instance.inAppBindings.comboFor(
        ShortcutCommand.volumeUp,
      ),
      const ShortcutCombo(key: LogicalKeyboardKey.arrowUp),
    );

    // 再录一次并确认替换：「音量 +」← Space，「播放 / 暂停」← ↑。
    await recordSpace();
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();

    final bindings = ShortcutSettings.instance.inAppBindings;
    expect(
      bindings.comboFor(ShortcutCommand.volumeUp),
      const ShortcutCombo(key: LogicalKeyboardKey.space),
    );
    expect(
      bindings.comboFor(ShortcutCommand.togglePlayPause),
      const ShortcutCombo(key: LogicalKeyboardKey.arrowUp),
    );
    // 页面订阅生效：互换后两行文案与「回默认」亮态随通知更新。
    expect(
      find.descendant(of: row, matching: find.text('Space')),
      findsOneWidget,
    );
    final playRow = find.byKey(const Key('shortcutRow_inApp_togglePlayPause'));
    expect(
      find.descendant(of: playRow, matching: find.text('↑')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('shortcutReset_inApp_volumeUp')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('shortcutReset_inApp_togglePlayPause')),
      findsOneWidget,
    );
    // 落盘：存储读回互换后的绑定。
    expect(
      ShortcutBindings.decode(
        ShortcutScope.inApp,
        prefs.getString(kShortcutBindings.name),
      ).comboFor(ShortcutCommand.togglePlayPause),
      const ShortcutCombo(key: LogicalKeyboardKey.arrowUp),
    );
    // 成功反馈经提示出口给出（记录型服务断言文案）。
    expect(
      notifications.messages,
      contains('Swapped shortcuts with “Play / pause”'),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('通用子页：单行回默认撞车弹确认层，替换后互换且无重复', (tester) async {
    // 快捷键状态是单例：接线登记表并保证从全默认开始，结束恢复默认。
    final prefs = await SharedPreferences.getInstance();
    ShortcutSettings.attachSettings(testSettingsRegistry(preferences: prefs));
    await ShortcutSettings.load();
    final notifications = RecordingNotificationService();
    addTearDown(() async {
      await ShortcutSettings.instance.resetScope(ShortcutScope.inApp);
      await ShortcutSettings.instance.resetScope(ShortcutScope.global);
    });

    await pumpSettingsPage(
      tester,
      extraProviders: [
        Provider<NotificationService>.value(value: notifications),
        // 页面经 `context.watch<ShortcutSettings?>` 订阅；本用例兼验订阅——
        // 互换后行内文案与「回默认」亮态必须随通知刷新。
        ChangeNotifierProvider<ShortcutSettings>.value(
          value: ShortcutSettings.instance,
        ),
      ],
    );
    // 快捷键入口在设置首屏「通用」卡（不再藏在通用子页里）。
    final entry = find.byKey(const Key('settingsShortcutsItem'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    // 复现审查路径：全默认 → 「音量 +」录 Space → 确认替换（两行互换）。
    final volumeRow = find.byKey(const Key('shortcutRow_inApp_volumeUp'));
    await tester.tap(volumeRow);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();

    // 互换后两行都被覆盖：「回默认」按钮亮起。
    final volumeReset = find.byKey(const Key('shortcutReset_inApp_volumeUp'));
    final playReset = find.byKey(
      const Key('shortcutReset_inApp_togglePlayPause'),
    );
    expect(volumeReset, findsOneWidget);
    expect(playReset, findsOneWidget);

    // 点「音量 +」回默认（目标 = 默认 ↑，已被「播放 / 暂停」占着）：
    // 弹互换确认层，而不是直接清覆盖造出两行同键。
    await tester.tap(volumeReset);
    await tester.pumpAndSettle();
    expect(find.text('Replace shortcut?'), findsOneWidget);
    expect(
      find.text(
        '“Play / pause” already uses this combination. '
        'Replacing will swap the two shortcuts.',
      ),
      findsOneWidget,
    );

    // 取消：绑定不动。
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      ShortcutSettings.instance.inAppBindings.comboFor(
        ShortcutCommand.volumeUp,
      ),
      const ShortcutCombo(key: LogicalKeyboardKey.space),
    );

    // 再点并确认：两行互换回默认（覆盖清空），组内无重复。
    await tester.tap(volumeReset);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();

    final bindings = ShortcutSettings.instance.inAppBindings;
    expect(
      bindings.comboFor(ShortcutCommand.volumeUp),
      const ShortcutCombo(key: LogicalKeyboardKey.arrowUp),
    );
    expect(
      bindings.comboFor(ShortcutCommand.togglePlayPause),
      const ShortcutCombo(key: LogicalKeyboardKey.space),
    );
    final combos = bindings.effective.values.toList();
    expect(combos.toSet().length, combos.length);
    expect(bindings.encode(), '');
    expect(prefs.getString(kShortcutBindings.name), '');

    // 页面同步刷新：文案回默认、「回默认」按钮消失。
    final playRow = find.byKey(const Key('shortcutRow_inApp_togglePlayPause'));
    expect(
      find.descendant(of: volumeRow, matching: find.text('↑')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: playRow, matching: find.text('Space')),
      findsOneWidget,
    );
    expect(volumeReset, findsNothing);
    expect(playReset, findsNothing);
    // 回默认这一次也给出互换成功反馈。
    expect(
      notifications.messages,
      contains('Swapped shortcuts with “Play / pause”'),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('通用子页：互换确认后复核冲突，前提失效则不写入', (tester) async {
    // 快捷键状态是单例：接线登记表并保证从全默认开始，结束恢复默认。
    final prefs = await SharedPreferences.getInstance();
    ShortcutSettings.attachSettings(testSettingsRegistry(preferences: prefs));
    await ShortcutSettings.load();
    final notifications = RecordingNotificationService();
    addTearDown(() async {
      await ShortcutSettings.instance.resetScope(ShortcutScope.inApp);
      await ShortcutSettings.instance.resetScope(ShortcutScope.global);
    });

    await pumpSettingsPage(
      tester,
      extraProviders: [
        Provider<NotificationService>.value(value: notifications),
        ChangeNotifierProvider<ShortcutSettings>.value(
          value: ShortcutSettings.instance,
        ),
      ],
    );
    // 快捷键入口在设置首屏「通用」卡（不再藏在通用子页里）。
    final entry = find.byKey(const Key('settingsShortcutsItem'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    // 交叉状态：「音量 +」= Space、「播放 / 暂停」= ↑。
    await ShortcutSettings.instance.swapBindings(
      ShortcutScope.inApp,
      ShortcutCommand.togglePlayPause,
      ShortcutCommand.volumeUp,
    );
    await tester.pumpAndSettle();

    // 打开「音量 +」回默认的互换确认层。
    final volumeReset = find.byKey(const Key('shortcutReset_inApp_volumeUp'));
    await tester.tap(volumeReset);
    await tester.pumpAndSettle();
    expect(find.text('Replace shortcut?'), findsOneWidget);

    // 对话框存续期间模拟应用远端设置：reload 同步回写绑定键，冲突前提消失。
    await prefs.setString(kShortcutBindings.name, '');
    await ShortcutSettings.reload();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();

    // 复核不成立：不写入，按冲突兜底文案提示；绑定保持 reload 后的全默认。
    final bindings = ShortcutSettings.instance.inAppBindings;
    expect(bindings.encode(), '');
    expect(
      bindings.comboFor(ShortcutCommand.volumeUp),
      const ShortcutCombo(key: LogicalKeyboardKey.arrowUp),
    );
    expect(
      bindings.comboFor(ShortcutCommand.togglePlayPause),
      const ShortcutCombo(key: LogicalKeyboardKey.space),
    );
    expect(notifications.messages, contains('Already used by “Play / pause”'));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('通用子页：桌面托盘开关切换并持久化（仅桌面端）', (tester) async {
    // Linux/Windows/macOS 才有托盘实现：测试跑在桌面 VM 上 isSupported 为 true
    // （与 WindowChrome 的既有约束一致，见 docs/pitfalls.md #30）；
    // 其余平台直接通过。
    if (!AppTray.isSupported) return;

    final prefs = await SharedPreferences.getInstance();
    final traySettings = TraySettings(prefs: prefs);
    await traySettings.init();
    addTearDown(traySettings.dispose);

    await pumpSettingsPage(
      tester,
      extraProviders: [
        ChangeNotifierProvider<TraySettings>.value(value: traySettings),
      ],
    );
    await tester.tap(find.byKey(const Key('settingsGeneralItem')));
    await tester.pumpAndSettle();

    // 桌面分组：默认「关闭时最小化到托盘」为开。
    expect(find.text('Desktop'), findsOneWidget);
    final closeToTray = find.byKey(const Key('settingsCloseToTraySwitch'));
    await tester.ensureVisible(closeToTray);
    await tester.pumpAndSettle();
    expect(traySettings.closeToTray, isTrue);

    await tester.tap(closeToTray);
    await tester.pumpAndSettle();
    expect(traySettings.closeToTray, isFalse);
    expect(prefs.getBool(TraySettings.keyCloseToTray), isFalse);
  });

  testWidgets('底部弹层 guard：子页打开时系统返回先退子页、不退弹层', (tester) async {
    // 移动端视口 → showPageModal 走底部弹层分支（宽屏走 M3E 页面弹窗）。
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // 复用 app_shell 接线：从入口打开设置弹层（guard 退子页后弹层才关闭）。
    await pumpApp(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: M3EButton.filled(
              onPressed: () => showSettingsSheet(context),
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(settingsHome(), findsOneWidget);

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
    expect(settingsHome(), findsOneWidget);

    // 回到首屏后再系统返回：弹层正常关闭。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(settingsHome(), findsNothing);
    expect(find.text('Open settings'), findsOneWidget);
  });

  testWidgets('底部弹层：预测返回提交先退子页、再关弹层（guard 接管手势）', (tester) async {
    // 移动端视口 → showPageModal 走底部弹层分支。
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
              onPressed: () => showSettingsSheet(context),
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    // 进入通用子页。
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

    // 预测返回提交：弹层宿主接管手势 → 提交后走 guard → 退子页
    // （guard 返回 false → 弹层保持打开、预览回弹）。
    await sendBack(tester, 'startBackGesture', backArgs(0));
    await sendBack(tester, 'updateBackGestureProgress', backArgs(1));
    await tester.pump();
    await sendBack(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('App Language'), findsNothing);
    expect(settingsHome(), findsOneWidget);

    // 回到首屏后再次提交：允许关闭弹层。
    await sendBack(tester, 'startBackGesture', backArgs(0));
    await sendBack(tester, 'updateBackGestureProgress', backArgs(1));
    await tester.pump();
    await sendBack(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(settingsHome(), findsNothing);
    expect(find.text('Open settings'), findsOneWidget);
  });

  /// 弹层预测返回预览的横向缩放：M3E 弹层宿主把 backProgress 映射进包裹弹层的
  /// 内层 `Transform`（`m3e_bottom_sheet_frame_build.dart`）。
  ///
  /// 没有预览层时按静止值 1 处理：宿主放弃手势（1.1.6 及以下 guard 非空）时它
  /// 根本不插这层 Transform，这样失败点就落在「有没有跟进手势」而不是 finder 空手。
  double sheetBackScaleX(WidgetTester tester) {
    final preview = find
        .ancestor(
          of: find.byType(SettingsPage),
          matching: find.byType(Transform),
        )
        .evaluate();
    if (preview.isEmpty) {
      return 1.0;
    }
    return (preview.first.widget as Transform).transform.storage[0];
  }

  testWidgets('底部弹层：子页预测返回由页面接管（弹层不缩放，提交只退子页）', (tester) async {
    // 移动端视口 → showPageModal 走底部弹层分支。
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
              onPressed: () => showSettingsSheet(context),
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    // 子页打开 → 内部 Navigator 可弹栈。
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
    expect(sheetBackScaleX(tester), 1.0, reason: '静止时预览缩放为 1');

    // 子页手势：弹层宿主仍收到事件，但缩放归零；内层路由按 FadeForwards 退场。
    await sendBack(tester, 'startBackGesture', backArgs(0));
    await sendBack(tester, 'updateBackGestureProgress', backArgs(0.6));
    await tester.pump();
    expect(
      sheetBackScaleX(tester),
      1.0,
      reason: '子页手势必须由页面过渡接管，不能再显示 sheet 收缩',
    );
    final subPageRoute = ModalRoute.of(
      tester.element(find.text('App Language')),
    )!;
    expect(
      subPageRoute.animation!.value,
      closeTo(0.4, 0.001),
      reason: '内层路由应跟手回退（1 - 手势进度）',
    );

    // 提交：只退子页，弹层保持打开。
    await sendBack(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('App Language'), findsNothing);
    expect(settingsHome(), findsOneWidget);
    expect(sheetBackScaleX(tester), 1.0, reason: '子页退栈不得把弹层一起缩走');
  });

  testWidgets('底部弹层：首屏预测返回仍是 sheet 收缩，提交关闭设置', (tester) async {
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
              onPressed: () => showSettingsSheet(context),
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    final sheetWidth = tester.getSize(find.byType(SettingsPage)).width;
    final shrinkX = M3ETheme.of(tester.element(find.byType(SettingsPage)))
        .bottomSheetTheme
        .predictiveBackShrinkX;

    await sendBack(tester, 'startBackGesture', backArgs(0));
    await sendBack(tester, 'updateBackGestureProgress', backArgs(0.6));
    await tester.pump();
    expect(
      sheetBackScaleX(tester),
      closeTo(1 - shrinkX * 0.6 / sheetWidth, 0.001),
      reason: '首屏手势保持 M3E 宿主的 sheet 收缩预览',
    );

    await sendBack(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(settingsHome(), findsNothing);
    expect(find.text('Open settings'), findsOneWidget);
  });

  testWidgets('底部弹层：根导航器上方 dialog 打开时，返回手势不得退内层子页', (tester) async {
    // 移动端视口 → showPageModal 走底部弹层分支。
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
              onPressed: () => showSettingsSheet(context),
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    // 进入通用子页：内层 Navigator 的栈深为 1，其路由是内层导航器的 current。
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

    // 根导航器上方再开一个 dialog（与 M3EDialog.show 同一条路径）。
    unawaited(
      M3EDialog.show<void>(
        tester.element(find.text('App Language')),
        dialog: M3EDialog(
          title: 'Root dialog',
          content: const Text('dialog body'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Root dialog'), findsOneWidget);

    // 返回手势应只作用于最上层 dialog：内层子页虽然在内层导航器里是 current，
    // 但已被排除在预测返回之外（框架会把手势派发给每个返回 true 的观察者，
    // 不排除的话内层子页会自己退一级，dialog 反而留着）。
    await sendBack(tester, 'startBackGesture', backArgs(0));
    await sendBack(tester, 'updateBackGestureProgress', backArgs(1));
    await tester.pump();
    await sendBack(tester, 'commitBackGesture');
    await tester.pumpAndSettle();

    expect(find.text('Root dialog'), findsNothing);
    expect(find.text('App Language'), findsOneWidget);
  });

  testWidgets('外观：默认封面行带缩略图，设置后立即刷新', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'molia_settings_cover_',
    );
    final store = CustomCoverStore(
      supportDirectory: () async => tempDir,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
    );
    await tester.runAsync(store.load);
    CustomCoverStore.overrideInstance(store);
    addTearDown(() {
      CustomCoverStore.overrideInstance(null);
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    await pumpSettingsPage(tester);
    final row = find.byKey(const Key('settingsDefaultCoverItem'));
    expect(row, findsOneWidget);
    expect(find.text('Default cover'), findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.byType(MoliaMark)),
      findsOneWidget,
      reason: '未设置默认封面时缩略图是 Molia 标志',
    );

    final source = image.Image(width: 2, height: 2);
    await tester.runAsync(
      () => store.setDefaultCover(Uint8List.fromList(image.encodePng(source))),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: row, matching: find.byType(MoliaMark)),
      findsNothing,
    );

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('coverPickerChooseButton')), findsOneWidget);
    expect(find.byKey(const Key('coverPickerResetButton')), findsOneWidget);
  });

  testWidgets('首屏：封面独立成卡，同步封面开关不再进外观', (tester) async {
    await pumpSettingsPage(tester);

    final coversSection = find.ancestor(
      of: find.byKey(const Key('settingsFollowArtworkSwitch')),
      matching: find.byType(SettingsSectionCard),
    );
    expect(coversSection, findsOneWidget);
    expect(
      find.descendant(
        of: coversSection,
        matching: find.byKey(const Key('settingsDefaultCoverItem')),
      ),
      findsOneWidget,
      reason: '跟随封面与默认封面应在同一张封面卡里',
    );
    expect(find.text('Covers'), findsOneWidget);
    expect(
      find.byKey(const Key('settingsSyncCustomCoversSwitch')),
      findsNothing,
      reason: '同步类别只保留「跨设备同步 › 同步内容」一处入口',
    );
  });

  testWidgets('首屏：宽屏两列瀑布式，短卡回填较矮的左列', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await pumpSettingsPage(tester);

      final appearance = tester.getTopLeft(find.text('Appearance'));
      final covers = tester.getTopLeft(find.text('Covers'));
      final playback = tester.getTopLeft(find.text('Playback'));

      expect(covers.dx, appearance.dx, reason: '封面卡应跟在较矮的左列');
      expect(covers.dy, greaterThan(appearance.dy));
      expect(playback.dx, greaterThan(appearance.dx));
      expect(playback.dy, appearance.dy, reason: '播放卡与外观卡顶对齐');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('首屏：歌词分区三条直达入口（能力就绪时全显示并进入子页）', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final lyricsSettings = LyricsDisplaySettings(
      settings: testSettingsRegistry(preferences: prefs),
    );
    await lyricsSettings.init();
    addTearDown(lyricsSettings.dispose);
    final display = LyricsDisplayProvider(
      settings: lyricsSettings,
      outputs: [_FakeDesktopOutput(), _FakeMediaOutput()],
    );
    addTearDown(display.dispose);

    await pumpSettingsPage(
      tester,
      extraProviders: [
        ChangeNotifierProvider<LyricsDisplaySettings>.value(
          value: lyricsSettings,
        ),
        ChangeNotifierProvider<LyricsDisplayProvider>.value(value: display),
      ],
    );

    // 三条叶子入口都在首屏「歌词与展示」分区，不再经过任何 hub。
    expect(find.byKey(const Key('settingsDesktopLyricsItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsLyricsContentItem')), findsOneWidget);
    expect(
      find.byKey(const Key('settingsSystemMediaLyricsItem')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('settingsDesktopLyricsItem')));
    await tester.pumpAndSettle();

    // 桌面歌词子页聚合：启用开关与共享展示项（翻译/偏移）同页。
    expect(find.text('Enable floating lyrics'), findsOneWidget);
    expect(find.text('Lyric display'), findsOneWidget);
    expect(find.text('Unsynced lyrics'), findsOneWidget);
  });

  testWidgets('首屏：无输出能力时只留「歌词与输出」入口并给出平台提示', (tester) async {
    await pumpSettingsPage(tester);

    expect(find.byKey(const Key('settingsLyricsContentItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsDesktopLyricsItem')), findsNothing);
    expect(
      find.byKey(const Key('settingsSystemMediaLyricsItem')),
      findsNothing,
    );
    expect(
      find.text('Lyric outputs are not available on this platform'),
      findsOneWidget,
    );
  });

  testWidgets('首屏：媒体会话初始化失败给出可见提示', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final lyricsSettings = LyricsDisplaySettings(
      settings: testSettingsRegistry(preferences: prefs),
    );
    await lyricsSettings.init();
    addTearDown(lyricsSettings.dispose);
    final display = LyricsDisplayProvider(
      settings: lyricsSettings,
      outputs: [_FakeDesktopOutput(), _FakeMediaOutput()],
      mediaSessionInitFailed: true,
    );
    addTearDown(display.dispose);

    await pumpSettingsPage(
      tester,
      extraProviders: [
        ChangeNotifierProvider<LyricsDisplaySettings>.value(
          value: lyricsSettings,
        ),
        ChangeNotifierProvider<LyricsDisplayProvider>.value(value: display),
      ],
    );

    expect(
      find.textContaining('System media controls failed to start'),
      findsOneWidget,
    );
  });

  testWidgets('底部弹层：列表滑到顶后继续下滑可关闭（M3E 弹层滚动控制器接线）', (tester) async {
    // 移动端视口 → showPageModal 走底部弹层分支。
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
              onPressed: () => showSettingsSheet(context),
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(settingsHome(), findsOneWidget);

    // 列表在顶部继续下滑：设置首屏的滚动视图挂的是弹层控制器，
    // 拖动应联动收缩/关闭弹层（回归：内嵌 Navigator 路由遮蔽控制器）。
    for (var i = 0; i < 3; i++) {
      await tester.fling(
        find.byType(SingleChildScrollView).first,
        const Offset(0, 400),
        1500,
      );
      await tester.pumpAndSettle();
      if (settingsHome().evaluate().isEmpty) break;
    }

    expect(find.text('Open settings'), findsOneWidget);
    expect(settingsHome(), findsNothing);
  });

  testWidgets('数据与存储子页：统计开关在场（统计入口在首屏），返回退回首屏', (tester) async {
    await pumpSettingsPage(tester);

    // 统计入口在设置首屏「数据」卡（不再藏在数据子页里）。
    expect(find.text('Listening Stats'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settingsDataItem')));
    await tester.pumpAndSettle();

    expect(find.text('Cache management'), findsOneWidget);
    expect(find.text('Export data'), findsOneWidget);
    expect(find.text('Import data'), findsOneWidget);
    expect(find.text('Import Favorites'), findsOneWidget);
    // 采集开关留在数据子页（与缓存 / 导入导出同一处）。
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
    expect(find.text('Listening Stats'), findsOneWidget, reason: '统计入口在首屏');
  });
}

/// 最小桌面歌词输出：能力就绪，不触碰平台通道。
class _FakeDesktopOutput implements LyricsOutput {
  @override
  String get id => LyricsOutputIds.desktop;

  @override
  LyricsOutputCapability get capability => LyricsOutputCapability.ready;

  @override
  Future<void> start(LyricsDisplaySettings settings) async {}

  @override
  Future<void> apply(LyricsPresentation presentation) async {}

  @override
  Future<void> clear() async {}

  @override
  Future<void> stop() async {}
}

/// 最小媒体（通知 / 蓝牙）歌词输出：能力就绪，不触碰平台通道。
class _FakeMediaOutput implements LyricsOutput {
  @override
  String get id => LyricsOutputIds.media;

  @override
  LyricsOutputCapability get capability => LyricsOutputCapability.ready;

  @override
  Future<void> start(LyricsDisplaySettings settings) async {}

  @override
  Future<void> apply(LyricsPresentation presentation) async {}

  @override
  Future<void> clear() async {}

  @override
  Future<void> stop() async {}
}
