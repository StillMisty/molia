import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/pages/settings_page.dart';
import 'package:molia/providers/local_database_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/theme_provider.dart';
import 'package:molia/services/data_saver_service.dart';
import 'package:molia/services/language_service.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/services/settings_service.dart';

import 'support/fakes.dart';

/// 设置页冒烟：新设置项存在、切换后 provider 状态与持久化生效；
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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpSettingsPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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

    final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
    final themedData = ThemeData(colorScheme: themeProvider.colorScheme);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
          ChangeNotifierProvider<PlaybackProvider>.value(
              value: playbackProvider),
          Provider<SettingsService>(create: (_) => _FakeSettingsService()),
          ChangeNotifierProvider<LocalDatabaseProvider>(
            create: (_) => LocalDatabaseProvider(),
          ),
          Provider<LyricsService>(create: (_) => LyricsService()),
          Provider<NotificationService>.value(
            value: NotificationService(scaffoldMessengerKey),
          ),
          ChangeNotifierProvider<DataSaverService>.value(value: dataSaver),
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
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('设置页存在新设置项，且教程/邮箱入口已移除', (tester) async {
    await pumpSettingsPage(tester);

    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Theme mode'), findsOneWidget);
    expect(find.text('Dynamic color'), findsOneWidget);
    expect(find.text('Theme color'), findsOneWidget);
    expect(find.text('Playback'), findsOneWidget);
    expect(find.text('Default play mode'), findsOneWidget);
    // 区块标题 + 开关项标题各一处。
    expect(find.text('Data saver'), findsNWidgets(2));

    expect(find.text('Setup'), findsNothing);
    expect(find.text('Tutorial'), findsNothing);
    expect(find.byIcon(Icons.email_rounded), findsNothing);
  });

  testWidgets('主题模式弹层：选择深色后 provider 生效', (tester) async {
    await pumpSettingsPage(tester);

    await tester.tap(find.byKey(const Key('settingsThemeModeItem')));
    await tester.pumpAndSettle();
    expect(find.byType(M3EDialog), findsOneWidget);

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    expect(find.byType(M3EDialog), findsNothing);
    expect(themeProvider.themeMode, ThemeMode.dark);
    expect(themeProvider.colorScheme.brightness, Brightness.dark);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'dark');
  });

  testWidgets('动态取色开关：切换后 provider 状态与持久化生效', (tester) async {
    await pumpSettingsPage(tester);
    expect(themeProvider.dynamicColorEnabled, isTrue);

    await tester.tap(find.byKey(const Key('settingsDynamicColorSwitch')));
    await tester.pumpAndSettle();

    expect(themeProvider.dynamicColorEnabled, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('dynamic_color_enabled'), isFalse);
  });

  testWidgets('主题色弹层：选择绿色后 provider 生效', (tester) async {
    await pumpSettingsPage(tester);

    await tester.tap(find.byKey(const Key('settingsSeedColorItem')));
    await tester.pumpAndSettle();
    expect(find.byType(M3EDialog), findsOneWidget);

    await tester.tap(find.text('Green'));
    await tester.pumpAndSettle();

    expect(find.byType(M3EDialog), findsNothing);
    expect(themeProvider.seedColor.toARGB32(), Colors.green.toARGB32());

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('seed_color'), Colors.green.toARGB32());
  });

  testWidgets('默认播放模式弹层：选择随机后 provider 生效', (tester) async {
    await pumpSettingsPage(tester);

    await tester.tap(find.byKey(const Key('settingsDefaultPlayModeItem')));
    await tester.pumpAndSettle();
    expect(find.byType(M3EDialog), findsOneWidget);

    await tester.tap(find.text('Shuffle'));
    await tester.pumpAndSettle();

    expect(find.byType(M3EDialog), findsNothing);
    expect(playbackProvider.defaultPlayMode, PlayMode.shuffle);
    // 无曲目：立即应用到播放服务（facade 快照跟随）。
    expect(playbackProvider.currentMode, PlayMode.shuffle);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('default_play_mode'), 'shuffle');
  });

  testWidgets('省流模式：开关/音质上限/封面省流生效并持久化', (tester) async {
    await pumpSettingsPage(tester);

    // 默认关闭：子项隐藏。
    expect(find.text('Data saver'), findsNWidgets(2));
    expect(find.byKey(const Key('settingsDataSaverQualityItem')), findsNothing);

    final switchFinder = find.byKey(const Key('settingsDataSaverSwitch'));
    await tester.ensureVisible(switchFinder);
    await tester.pumpAndSettle();
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();

    expect(dataSaver.enabled, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('data_saver_enabled'), isTrue);

    // 开启后子项可见：音质上限弹层选择 192K。
    final qualityFinder = find.byKey(const Key('settingsDataSaverQualityItem'));
    expect(qualityFinder, findsOneWidget);
    await tester.ensureVisible(qualityFinder);
    await tester.pumpAndSettle();
    await tester.tap(qualityFinder);
    await tester.pumpAndSettle();
    expect(find.byType(M3EDialog), findsOneWidget);

    await tester.tap(find.text('192K'));
    await tester.pumpAndSettle();
    expect(find.byType(M3EDialog), findsNothing);
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
