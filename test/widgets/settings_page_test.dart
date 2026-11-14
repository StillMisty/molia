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

  testWidgets('重组后的行仍保留原子页入口 key', (tester) async {
    await pumpSettings(tester);

    // 外观：封面并进外观。
    expect(
      find.byKey(const Key('settingsFollowArtworkSwitch')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settingsDefaultCoverItem')), findsOneWidget);

    // 播放：播放细节并进播放卡。
    expect(find.byKey(const Key('settingsFadeItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSmartShuffleSwitch')), findsOneWidget);

    // 曲库与存储：加入位置 / 文件夹 / 下载 / 缓存。
    expect(
      find.byKey(const Key('settingsLibraryAddPositionItem')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settingsMusicFoldersItem')), findsOneWidget);
    expect(
      find.byKey(const Key('settingsDownloadSettingsItem')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settingsDownloadsManageItem')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settingsCacheManagementItem')),
      findsOneWidget,
    );

    // 数据与备份：统计 / 备份入口。
    expect(
      find.byKey(const Key('settingsPlayStatisticsSwitch')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settingsPlayStatisticsItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsBackupRestoreItem')), findsOneWidget);

    // 通用：启动页 / 底栏入口 / 语言 / 震动 / 应用名称。
    expect(find.byKey(const Key('settingsStartupPageItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsBottomNavItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsHapticsSwitch')), findsOneWidget);
    expect(find.byKey(const Key('settingsLanguageItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsAppTitleItem')), findsOneWidget);

    // 桌面：托盘 / 窗口 / 快捷键。
    expect(find.byKey(const Key('settingsCloseToTraySwitch')), findsOneWidget);
    expect(
      find.byKey(const Key('settingsRememberWindowBoundsSwitch')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settingsShortcutsItem')), findsOneWidget);

    // 关于与更新：问题排查（更新入口缺省 provider 时不渲染）。
    expect(find.byKey(const Key('settingsDiagnosticsItem')), findsOneWidget);
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
