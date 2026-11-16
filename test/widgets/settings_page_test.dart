import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/settings_page.dart';
import 'package:molia/providers/nav_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/theme_provider.dart';
import 'package:molia/services/library/library_add_settings.dart';
import 'package:molia/services/play_statistics_service.dart';
import 'package:molia/services/window/tray_settings.dart';

import '../support/cover_test_support.dart';
import '../support/fakes.dart';
import '../support/memory_database.dart';
import '../support/settings_test_support.dart';
import '../support/sync_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ThemeProvider theme;
  late PlaybackProvider playback;
  late NavProvider nav;
  late TraySettings tray;
  late PlayStatisticsService statistics;
  late LibraryAddSettings libraryAdd;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final registry = testSettingsRegistry();
    theme = ThemeProvider(settings: registry);
    await theme.preferencesReady;
    playback = buildTestPlaybackProvider(
      settings: registry,
      facade: FakePlaybackFacade(),
    );
    await playback.preferencesReady;
    nav = NavProvider(settings: registry);
    await nav.preferencesReady;
    tray = TraySettings();
    await tray.init();
    libraryAdd = LibraryAddSettings(settings: registry);
    await libraryAdd.init();
    final db = openMemoryDatabase();
    addTearDown(db.close);
    statistics = PlayStatisticsService(
      settings: registry,
      repository: PlayStatisticsRepository(
        databaseProvider: () => db,
        statisticsSync: testStatisticsSyncStore(() => db),
      ),
    );
  });

  tearDown(() {
    nav.dispose();
    tray.dispose();
    libraryAdd.dispose();
    playback.dispose();
    theme.dispose();
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          coverStoreProvider(),
          ChangeNotifierProvider<ThemeProvider>.value(value: theme),
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          ChangeNotifierProvider<NavProvider>.value(value: nav),
          ChangeNotifierProvider<TraySettings>.value(value: tray),
          ChangeNotifierProvider<LibraryAddSettings>.value(value: libraryAdd),
          Provider<PlayStatisticsService>.value(value: statistics),
        ],
        child: M3EMaterialApp(
          data: M3EThemeData.fromMaterial(ThemeData.light()),
          theme: ThemeData.light(),
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets('首屏是九张语义卡，旧的目录入口与合并卡名消失', (tester) async {
    await pumpSettings(tester);

    for (final title in const [
      '外观',
      '歌词',
      '音源与在线服务',
      '曲库与存储',
      '数据与备份',
      '通用',
      '桌面',
      '关于与更新',
    ]) {
      expect(find.text(title), findsOneWidget, reason: '缺少卡片：$title');
    }
    // 「播放」同时是启动页分段选项的文案，只断言存在。
    expect(find.text('播放'), findsWidgets);

    // 旧的分区名与目录入口不再出现。
    expect(find.text('内容与来源'), findsNothing);
    expect(find.text('数据与存储'), findsNothing);
    expect(find.text('通用与关于'), findsNothing);
    expect(find.byKey(const Key('settingsGeneralItem')), findsNothing);
    expect(find.byKey(const Key('settingsDataItem')), findsNothing);
  });

  testWidgets('首屏只留日常项，低频项收进高级设置', (tester) async {
    await pumpSettings(tester);

    // 外观：保留跟随封面；字体与默认封面下沉。
    expect(
      find.byKey(const Key('settingsFollowArtworkSwitch')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settingsAppFontItem')), findsNothing);
    expect(find.byKey(const Key('settingsDefaultCoverItem')), findsNothing);

    // 播放：淡入淡出与智能随机下沉。
    expect(find.byKey(const Key('settingsFadeItem')), findsNothing);
    expect(find.byKey(const Key('settingsSmartShuffleSwitch')), findsNothing);

    // 曲库与存储：加入位置下沉，下载三入口并为一行。
    expect(
      find.byKey(const Key('settingsLibraryAddPositionItem')),
      findsNothing,
    );
    expect(find.byKey(const Key('settingsMusicFoldersItem')), findsOneWidget);
    expect(
      find.byKey(const Key('settingsDownloadsAndCacheItem')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settingsDownloadSettingsItem')), findsNothing);
    expect(find.byKey(const Key('settingsDownloadsManageItem')), findsNothing);
    expect(find.byKey(const Key('settingsCacheManagementItem')), findsNothing);

    // 数据与备份：采集开关移进统计页，首屏只留入口。
    expect(find.byKey(const Key('settingsPlayStatisticsSwitch')), findsNothing);
    expect(find.byKey(const Key('settingsPlayStatisticsItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsBackupRestoreItem')), findsOneWidget);

    // 通用：震动与应用名称下沉。
    expect(find.byKey(const Key('settingsStartupPageItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsBottomNavItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsLanguageItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsHapticsSwitch')), findsNothing);
    expect(find.byKey(const Key('settingsAppTitleItem')), findsNothing);

    // 桌面：窗口记忆下沉。
    expect(find.byKey(const Key('settingsCloseToTraySwitch')), findsOneWidget);
    expect(
      find.byKey(const Key('settingsRememberWindowBoundsSwitch')),
      findsNothing,
    );
    expect(find.byKey(const Key('settingsShortcutsItem')), findsOneWidget);

    // 关于与更新：问题排查 + 高级设置出口。
    expect(find.byKey(const Key('settingsDiagnosticsItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsAdvancedItem')), findsOneWidget);
  });

  testWidgets('高级设置页保留字体、震动与播放细节的自定义能力', (tester) async {
    await pumpSettings(tester);

    // 子页在 pump 之后才构建：桌面平台标记要保留到导航完成。
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final entry = find.byKey(const Key('settingsAdvancedItem'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.text('高级设置'), findsWidgets);
    // 外观 / 通用：字体、默认封面、震动、应用名称。
    expect(find.byKey(const Key('settingsAppFontItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsDefaultCoverItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsHapticsSwitch')), findsOneWidget);
    expect(find.byKey(const Key('settingsAppTitleItem')), findsOneWidget);
    // 播放 / 曲库 / 桌面：淡入淡出、智能随机、加入位置、窗口记忆。
    expect(find.byKey(const Key('settingsFadeItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSmartShuffleSwitch')), findsOneWidget);
    expect(
      find.byKey(const Key('settingsLibraryAddPositionItem')),
      findsOneWidget,
    );
    // 桌面窗口记忆在长页靠后：滚动到可见再断言。
    await tester.drag(find.byType(ListView).last, const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('settingsRememberWindowBoundsSwitch')),
      findsOneWidget,
    );
  });

  testWidgets('360 宽首屏与高级设置不溢出', (tester) async {
    await pumpSettings(tester);
    tester.view.physicalSize = const Size(360, 1200);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final entry = find.byKey(const Key('settingsAdvancedItem'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('底部导航入口打开独立子页，拖拽列表不再占首屏', (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.byKey(const Key('settingsBottomNavItem')));
    await tester.pumpAndSettle();

    expect(find.text('底部导航'), findsOneWidget);
    expect(
      find.byIcon(Icons.drag_handle_rounded),
      findsNWidgets(nav.order.length),
    );
    expect(find.text('拖拽排序；开关控制显示，至少保留 1 个标签'), findsOneWidget);
  });

  testWidgets('备份与恢复入口打开独立子页', (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.byKey(const Key('settingsBackupRestoreItem')));
    await tester.pumpAndSettle();

    expect(find.text('备份与恢复'), findsOneWidget);
    expect(find.byKey(const Key('settingsExportItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsImportItem')), findsOneWidget);
    expect(
      find.byKey(const Key('settingsImportFavoritesItem')),
      findsOneWidget,
    );
  });
}
