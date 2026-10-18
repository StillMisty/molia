import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
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
import 'package:molia/pages/general_settings_page.dart';
import 'package:molia/pages/settings_page.dart';
import 'package:molia/providers/local_database_provider.dart';
import 'package:molia/providers/lyrics_display_provider.dart';
import 'package:molia/providers/nav_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/providers/theme_provider.dart';
import 'package:molia/services/data_saver_service.dart';
import 'package:molia/services/haptics.dart';
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
import 'package:molia/widgets/card_list_surface.dart';
import 'package:molia/widgets/settings/settings_section_grid.dart';
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
        databaseProvider: () => throw StateError('测试不访问数据库'),
        stamps: testStampIssuer(),
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

  /// 首屏 5 个分区卡片的矩形（按展示顺序）：两列 / 单列断言共用。
  List<Rect> sectionRects(WidgetTester tester) => [
        for (var i = 0; i < 5; i++)
          tester.getRect(find.byType(SettingsSectionCard).at(i)),
      ];

  /// 设置首屏在场的标记：顶部「设置」标题行已移除（弹层 chrome 只剩内容），
  /// 用第一个分区标题判断首屏在不在。
  Finder settingsHome() => find.text('Appearance');

  /// 桌面宽屏打开真实设置弹层（顶栏入口路径：`showAdaptiveModalPage` 的
  /// 居中对话框分支，屏宽 0.9 夹取不触发）。
  Future<void> openWideSettingsSheet(
    WidgetTester tester, {
    Size size = const Size(1200, 900),
  }) async {
    tester.view.physicalSize = size;
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
  }

  /// 行内选项的命中：分段/预览圆的标签文本都在行 key 之内。
  Finder optionOf(Key rowKey, String label) => find.descendant(
        of: find.byKey(rowKey),
        matching: find.text(label),
      );

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
    final data =
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args));
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.backGesture.name,
      data,
      (ByteData? _) {},
    );
  }

  testWidgets('设置首屏：6 分区齐全，低频内容移出首屏', (tester) async {
    await pumpSettingsPage(tester);

    // 分区卡片标题（卡片上方结构标签）。
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Playback'), findsOneWidget);
    expect(find.text('Lyrics & display'), findsOneWidget);
    expect(find.text('Content & sources'), findsOneWidget);
    expect(find.text('General'), findsOneWidget);
    expect(find.text('Data'), findsOneWidget);

    expect(find.text('Theme mode'), findsOneWidget);
    expect(find.text('Base colors'), findsOneWidget);
    expect(find.text('Follow album art'), findsOneWidget);
    expect(find.text('Pure black background'), findsOneWidget);
    expect(find.text('App font'), findsOneWidget);
    expect(find.text('Default play mode'), findsOneWidget);
    expect(find.text('Resume last playback'), findsOneWidget);
    // 省流并回播放分区：默认关闭时只有开关行（无子项）。
    expect(find.text('Data saver'), findsOneWidget);
    expect(find.text('Lyrics & outputs'), findsOneWidget);
    expect(find.text('Source Management'), findsOneWidget);
    expect(find.text('AI DJ'), findsOneWidget);
    // 通用与数据拆成两张卡：入口行与新增的一级入口同组。
    expect(find.text('General settings'), findsOneWidget);
    expect(find.text('Data & storage'), findsOneWidget);
    expect(
      find.byKey(const Key('settingsPlayStatisticsItem')),
      findsOneWidget,
      reason: '听歌统计入口提到首屏「数据」卡',
    );
    // 震动反馈已移入通用子页：首屏不再直接显示。
    expect(find.text('Vibration feedback'), findsNothing);

    // 子页内容不在首屏。
    expect(find.text('Bottom navigation'), findsNothing);
    expect(find.text('App Language'), findsNothing);
    expect(find.text('App name'), findsNothing);
    expect(find.text('Cache management'), findsNothing);
    expect(find.text('Export Recent Plays'), findsNothing);
    // 默认音质入口在播放区（需 SourcesProvider；本树未注入）。
    expect(find.text('Default quality'), findsNothing);

    expect(find.text('Setup'), findsNothing);
    expect(find.text('Tutorial'), findsNothing);
    expect(find.byIcon(Icons.email_rounded), findsNothing);
  });

  testWidgets('设置首屏：无「设置」标题行与关闭按钮（弹层 chrome 去除）', (tester) async {
    await openWideSettingsSheet(tester);
    expect(settingsHome(), findsOneWidget);

    // 标题行整行移除（含关闭按钮）后，弹层顶部只剩内容：关闭走遮罩 /
    // Esc / 下滑 / 系统返回。
    expect(find.text('Settings'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(SettingsPage),
        matching: find.byIcon(Icons.close_rounded),
      ),
      findsNothing,
    );
  });

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
    expect(find.text('Source: system accent color'), findsOneWidget);

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
    expect(find.textContaining('Initial mode'), findsOneWidget);

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

  testWidgets('外观分区行高统一：副标题 2 行封顶，行高不随文案漂移', (tester) async {
    await pumpSettingsPage(tester);

    final item = M3ETheme.of(
      tester.element(find.byKey(const Key('settingsFollowArtworkSwitch'))),
    ).listTheme.item;
    // 行的 CardListSurface：switchKey 挂在开关上（祖先方向），行 key 挂在
    // tile 上（后代方向）；两种都取到行表面。
    double rowHeight(Key key) {
      final target = find.byKey(key);
      final ancestor =
          find.ancestor(of: target, matching: find.byType(CardListSurface));
      if (ancestor.evaluate().isNotEmpty) {
        return tester.getSize(ancestor.first).height;
      }
      return tester
          .getSize(
            find
                .descendant(of: target, matching: find.byType(CardListSurface))
                .first,
          )
          .height;
    }

    // 修复前三种高度混杂（96 / 118 / 158dp）：带长副标题的标签行现在等高，
    // 且不超出 M3E 双行 token（测试字体的行高比真机略高，留 4dp 容差）。
    final followArtwork = rowHeight(const Key('settingsFollowArtworkSwitch'));
    expect(followArtwork, lessThanOrEqualTo(item.twoLineHeight + 4));
    expect(rowHeight(const Key('settingsPureBlackSwitch')), followArtwork);
    expect(rowHeight(const Key('settingsRestoreSessionSwitch')), followArtwork);
    expect(rowHeight(const Key('settingsDataSaverSwitch')), followArtwork);
    expect(rowHeight(const Key('settingsLyricsContentItem')), followArtwork);

    // 全页标签行（排除分段 / 滑杆 / 下拉等复合行）都不超过双行 token。
    for (final element in find.byType(CardListSurface).evaluate()) {
      final row = find.byWidget(element.widget);
      final composite = find
          .descendant(
            of: row,
            matching: find.byWidgetPredicate((widget) {
              final type = widget.runtimeType.toString();
              return type.startsWith('M3ESegmentedButton') ||
                  type.startsWith('M3ESlider') ||
                  type.startsWith('M3EDropdownMenu');
            }),
          )
          .evaluate()
          .isNotEmpty;
      if (composite) continue;
      expect(
        tester.getSize(row).height,
        lessThanOrEqualTo(item.twoLineHeight + 4),
        reason: '标签行高度超出双行 token',
      );
    }
  });

  testWidgets('分段行：长标签不显示选中勾（图标 + 文案会截断）', (tester) async {
    await pumpSettingsPage(tester);

    // 播放模式标签长（Sequential / Single repeat）：纯文字分段、无勾
    // （勾会挤占标签宽度；图标形态的回归见 settings_choice_row_test）。
    final segmented = tester.widget<M3ESegmentedButton<PlayMode>>(
      find.descendant(
        of: find.byKey(const Key('settingsDefaultPlayModeItem')),
        matching: find.byType(M3ESegmentedButton<PlayMode>),
      ),
    );
    expect(segmented.showSelectedIcon, isFalse);
  });

  testWidgets('省流模式：开关/音质上限/封面省流在播放分区内生效并持久化', (tester) async {
    await pumpSettingsPage(tester);

    // 默认关闭：只有开关行，子项不出现。
    expect(find.byKey(const Key('settingsDataSaverSwitch')), findsOneWidget);
    expect(find.byKey(const Key('settingsDataSaverQualityItem')), findsNothing);
    expect(
        find.byKey(const Key('settingsDataSaverCoversSwitch')), findsNothing);

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
        '“Play / pause” already uses this combo. '
        'Replacing will swap the two bindings.',
      ),
      findsOneWidget,
    );

    // 取消：绑定不动。
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      ShortcutSettings.instance.inAppBindings
          .comboFor(ShortcutCommand.volumeUp),
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
        find.byKey(const Key('shortcutReset_inApp_volumeUp')), findsOneWidget);
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
      contains('Swapped bindings with “Play / pause”'),
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
    final playReset =
        find.byKey(const Key('shortcutReset_inApp_togglePlayPause'));
    expect(volumeReset, findsOneWidget);
    expect(playReset, findsOneWidget);

    // 点「音量 +」回默认（目标 = 默认 ↑，已被「播放 / 暂停」占着）：
    // 弹互换确认层，而不是直接清覆盖造出两行同键。
    await tester.tap(volumeReset);
    await tester.pumpAndSettle();
    expect(find.text('Replace shortcut?'), findsOneWidget);
    expect(
      find.text(
        '“Play / pause” already uses this combo. '
        'Replacing will swap the two bindings.',
      ),
      findsOneWidget,
    );

    // 取消：绑定不动。
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      ShortcutSettings.instance.inAppBindings
          .comboFor(ShortcutCommand.volumeUp),
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
      contains('Swapped bindings with “Play / pause”'),
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
    expect(
      notifications.messages,
      contains('Already used by “Play / pause”'),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('通用子页：桌面托盘开关切换并持久化（仅桌面端）', (tester) async {
    // Linux/Windows 才有托盘实现：测试跑在 Linux VM 上 isSupported 为 true
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
    // 移动端视口 → showAdaptiveModalPage 走底部弹层分支（large 宽走对话框）。
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
    final subPageRoute =
        ModalRoute.of(tester.element(find.text('App Language')))!;
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
    expect(
      sheetBackScaleX(tester),
      1.0,
      reason: '子页退栈不得把弹层一起缩走',
    );
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
      find.textContaining('System media session unavailable'),
      findsOneWidget,
    );
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

  testWidgets('宽屏桌面：设置弹层加宽，首屏分区两列流式（奇偶左右交替）', (tester) async {
    await openWideSettingsSheet(tester);

    // 桌面档弹层按 modal spec 加宽（1200 屏宽下 0.9 夹取为 1080，不生效）。
    expect(tester.getSize(find.byType(SettingsPage)).width, closeTo(880, 1));

    final gridWidth = tester.getSize(find.byType(SettingsSectionGrid)).width;
    final columnWidth = (gridWidth - kSettingsSectionSpacing) / 2;
    final rects = sectionRects(tester);

    // 1/2 成对：同排、左右分列、等分列宽。
    expect(rects[0].top, rects[1].top, reason: '分区 1/2 应同排');
    expect(rects[0].left, lessThan(rects[1].left));
    expect(rects[1].left - rects[0].right, kSettingsSectionSpacing);
    expect(rects[0].width, closeTo(columnWidth, 0.5));
    expect(rects[1].width, closeTo(columnWidth, 0.5));

    // 3/4 继续交替；5（奇数）回左列，右列留空。
    expect(rects[2].top, rects[3].top, reason: '分区 3/4 应同排');
    expect(rects[2].left, lessThan(rects[3].left));
    expect(rects[4].left, rects[0].left);
    expect(rects[4].top, greaterThan(rects[2].bottom));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('窄屏或移动平台：首屏分区回落单列', (tester) async {
    // 桌面平台但窗口 < 900：单列整宽。
    await pumpSettingsPage(tester, size: const Size(899, 1200));
    var gridWidth = tester.getSize(find.byType(SettingsSectionGrid)).width;
    var rects = sectionRects(tester);
    expect(rects[1].top, greaterThan(rects[0].bottom));
    expect(rects[1].left, rects[0].left);
    expect(rects[0].width, closeTo(gridWidth, 0.5));

    // 非桌面平台 + 宽窗口：同样单列（平台覆盖由 variant 复位）。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpSettingsPage(tester, size: const Size(1200, 1200));
    gridWidth = tester.getSize(find.byType(SettingsSectionGrid)).width;
    rects = sectionRects(tester);
    expect(rects[1].top, greaterThan(rects[0].bottom));
    expect(rects[1].left, rects[0].left);
    expect(rects[0].width, closeTo(gridWidth, 0.5));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('宽屏桌面：子页保持单列，底部导航拖拽卡片整宽', (tester) async {
    await openWideSettingsSheet(tester);

    // 进入通用子页（底部导航拖拽排序所在页）。
    final generalItem = find.byKey(const Key('settingsGeneralItem'));
    await tester.ensureVisible(generalItem);
    await tester.pumpAndSettle();
    await tester.tap(generalItem);
    await tester.pumpAndSettle();
    expect(find.byType(ReorderableListView), findsOneWidget);

    // 子页不进两列：拖拽卡片与弹层内容等宽（页内左右各 kSettingsPadding），
    // 拖拽命中区不会被列宽切分。
    final pageWidth = tester.getSize(find.byType(GeneralSettingsPage)).width;
    expect(
      tester.getSize(find.byType(ReorderableListView)).width,
      pageWidth - kSettingsPadding * 2,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
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

