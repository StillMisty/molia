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

  testWidgets('首屏是六张语义卡，不再有通用 / 数据目录入口', (tester) async {
    await pumpSettings(tester);

    expect(find.text('外观'), findsOneWidget);
    expect(find.text('播放'), findsWidgets);
    expect(find.text('歌词'), findsOneWidget);
    expect(find.text('内容与来源'), findsOneWidget);
    expect(find.text('数据与存储'), findsOneWidget);
    expect(find.text('通用与关于'), findsOneWidget);

    expect(find.byKey(const Key('settingsGeneralItem')), findsNothing);
    expect(find.byKey(const Key('settingsDataItem')), findsNothing);
    expect(find.text('通用设置'), findsNothing);
  });

  testWidgets('合并后的行仍保留原子页入口 key', (tester) async {
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

    // 数据与存储：缓存 / 下载 / 文件夹 / 统计 / 导入导出 / 排查。
    expect(
      find.byKey(const Key('settingsCacheManagementItem')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settingsDownloadSettingsItem')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settingsDownloadsManageItem')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settingsMusicFoldersItem')), findsOneWidget);
    expect(
      find.byKey(const Key('settingsPlayStatisticsSwitch')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settingsPlayStatisticsItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsDiagnosticsItem')), findsOneWidget);

    // 通用与关于：启动页 / 底栏 / 语言 / 震动 / 快捷键。
    expect(find.byKey(const Key('settingsStartupPageItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsHapticsSwitch')), findsOneWidget);
    expect(find.byKey(const Key('settingsLanguageItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsShortcutsItem')), findsOneWidget);
  });

  testWidgets('设备本地设置在卡底有一句说明', (tester) async {
    await pumpSettings(tester);
    expect(find.text('播放细节只保存在本机，不随跨设备同步。'), findsOneWidget);
    expect(find.text('托盘、窗口与震动反馈只保存在本机，不随跨设备同步。'), findsOneWidget);
  });
}
