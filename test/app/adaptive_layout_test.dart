import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/settings_page.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/theme_provider.dart';
import 'package:molia/widgets/adaptive_layout.dart';
import 'package:molia/widgets/settings/settings_section_grid.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cover_test_support.dart';
import '../support/fakes.dart';
import '../support/perf_app_harness.dart';
import '../support/settings_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WindowSizeClassResolver', () {
    test('边界 599 / 600 / 839 / 840', () {
      expect(WindowSizeClassResolver.resolve(599), WindowSizeClass.compact);
      expect(WindowSizeClassResolver.resolve(599.9), WindowSizeClass.compact);
      expect(WindowSizeClassResolver.resolve(600), WindowSizeClass.medium);
      expect(WindowSizeClassResolver.resolve(839), WindowSizeClass.medium);
      expect(WindowSizeClassResolver.resolve(839.9), WindowSizeClass.medium);
      expect(WindowSizeClassResolver.resolve(840), WindowSizeClass.expanded);
    });

    test('结构判据只由宽度档位决定', () {
      expect(collectionsUseSplitLayout(WindowSizeClass.medium), isFalse);
      expect(collectionsUseSplitLayout(WindowSizeClass.expanded), isTrue);
      expect(usesWideNowPlayingLayout(WindowSizeClass.medium), isFalse);
      expect(usesWideNowPlayingLayout(WindowSizeClass.expanded), isTrue);
    });
  });

  group('移动壳层导航档位', () {
    testWidgets('500 底栏、720 导航轨、900 导航轨且无底栏', (tester) async {
      await pumpPerfApp(
        tester,
        desktopShell: false,
        favoritesCount: 3,
        size: const Size(500, 900),
      );
      expect(find.byType(M3ENavigationBar), findsOneWidget);
      expect(find.byType(M3ENavigationRail), findsNothing);
    });

    testWidgets('720 宽用导航轨', (tester) async {
      await pumpPerfApp(
        tester,
        desktopShell: false,
        favoritesCount: 3,
        size: const Size(720, 900),
      );
      expect(find.byType(M3ENavigationRail), findsOneWidget);
      expect(find.byType(M3ENavigationBar), findsNothing);
    });

    testWidgets('900 宽保持导航轨', (tester) async {
      await pumpPerfApp(
        tester,
        desktopShell: false,
        favoritesCount: 3,
        size: const Size(900, 900),
      );
      expect(find.byType(M3ENavigationRail), findsOneWidget);
      expect(find.byType(M3ENavigationBar), findsNothing);
    });
  });

  group('合集分栏', () {
    testWidgets('840 宽收藏页出合集左栏', (tester) async {
      await pumpPerfApp(
        tester,
        desktopShell: false,
        favoritesCount: 3,
        size: const Size(840, 900),
      );
      expect(find.byKey(const Key('collectionSplitView')), findsOneWidget);
    });

    testWidgets('839 宽保持单栏', (tester) async {
      await pumpPerfApp(
        tester,
        desktopShell: false,
        favoritesCount: 3,
        size: const Size(839, 900),
      );
      expect(find.byKey(const Key('collectionSplitView')), findsNothing);
    });
  });

  group('播放页宽版式', () {
    testWidgets('840 宽用宽版式', (tester) async {
      await pumpPerfApp(
        tester,
        desktopShell: false,
        favoritesCount: 3,
        size: const Size(840, 900),
      );
      await tester.tap(find.text('播放').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('wideNowPlayingLayout')), findsOneWidget);
      expect(find.byKey(const Key('singlePaneNowPlaying')), findsNothing);
    });

    testWidgets('839 宽保持单栏播放页', (tester) async {
      await pumpPerfApp(
        tester,
        desktopShell: false,
        favoritesCount: 3,
        size: const Size(839, 900),
      );
      await tester.tap(find.text('播放').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('singlePaneNowPlaying')), findsOneWidget);
      expect(find.byKey(const Key('wideNowPlayingLayout')), findsNothing);
    });
  });

  group('设置两列', () {
    late ThemeProvider theme;
    late PlaybackProvider playback;

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
    });

    tearDown(() {
      theme.dispose();
      playback.dispose();
    });

    Future<void> pumpSettings(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            coverStoreProvider(),
            ChangeNotifierProvider<ThemeProvider>.value(value: theme),
            ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
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
    }

    testWidgets('839 单列、840 两列', (tester) async {
      await pumpSettings(tester, 839);
      var grid = tester.widget<SettingsSectionGrid>(
        find.byType(SettingsSectionGrid),
      );
      expect(grid.twoColumn, isFalse);

      await pumpSettings(tester, 840);
      grid = tester.widget<SettingsSectionGrid>(
        find.byType(SettingsSectionGrid),
      );
      expect(grid.twoColumn, isTrue);
    });

    testWidgets('2.0 倍字号无溢出', (tester) async {
      await pumpSettings(tester, 840);
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
