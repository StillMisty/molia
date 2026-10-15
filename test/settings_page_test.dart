import 'dart:async';

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
import 'package:molia/providers/lyrics_display_provider.dart';
import 'package:molia/providers/nav_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/providers/theme_provider.dart';
import 'package:molia/services/data_saver_service.dart';
import 'package:molia/services/language_service.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/services/lyrics_display/lyrics_output.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/services/play_statistics_service.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:molia/theme/scheme_builder.dart';
import 'package:molia/widgets/card_list_surface.dart';

import 'support/fakes.dart';
import 'package:molia/data/settings/settings_keys.dart';

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
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
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
    final data = const StandardMethodCodec()
        .encodeMethodCall(MethodCall(method, args));
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.backGesture.name,
      data,
      (ByteData? _) {},
    );
  }

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
    // 省流并回播放分区：默认关闭时只有开关行（无子项）。
    expect(find.text('Data saver'), findsOneWidget);
    expect(find.text('Lyrics & outputs'), findsOneWidget);
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
      return tester.getSize(
        find
            .descendant(of: target, matching: find.byType(CardListSurface))
            .first,
      ).height;
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
    expect(find.byKey(const Key('settingsDataSaverCoversSwitch')), findsNothing);

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

    // 预测返回提交：无人接管手势 → 走普通返回 → guard 退子页
    // （弹层保持打开；弹层本身没有跟手预览，见 SettingsPage 注释）。
    await sendBack(tester, 'startBackGesture', backArgs(0));
    await sendBack(tester, 'updateBackGestureProgress', backArgs(1));
    await tester.pump();
    await sendBack(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('App Language'), findsNothing);
    expect(find.text('Settings'), findsOneWidget);

    // 回到首屏后再次提交：允许关闭弹层。
    await sendBack(tester, 'startBackGesture', backArgs(0));
    await sendBack(tester, 'updateBackGestureProgress', backArgs(1));
    await tester.pump();
    await sendBack(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsNothing);
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
    // 但已被排除在预测返回之外（否则一次手势退两级）。
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
