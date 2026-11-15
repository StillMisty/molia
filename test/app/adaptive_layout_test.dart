import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/desktop/now_playing_bar.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/settings_page.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/theme_provider.dart';
import 'package:molia/widgets/adaptive_layout.dart';
import 'package:molia/widgets/desktop_layout.dart';
import 'package:molia/widgets/now_playing_layout_metrics.dart';
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

    test('短横屏只看窗口高：479 / 480', () {
      expect(AdaptiveLayout.fromSize(800, 479).isShortViewport, isTrue);
      expect(AdaptiveLayout.fromSize(800, 480).isShortViewport, isFalse);
      expect(AdaptiveLayout.fromSize(915, 412).isShortViewport, isTrue);
      expect(AdaptiveLayout.fromSize(915, 900).isShortViewport, isFalse);
    });

    test('表格列只看内容宽，不看桌面平台标记', () {
      DesktopLayout layout({required bool desktop, required double width}) =>
          DesktopLayout(
            isDesktopPlatform: desktop,
            windowWidth: width,
            railWidth: 96,
            child: const SizedBox.shrink(),
          );
      expect(layout(desktop: false, width: 840).tableColumns, isTrue);
      expect(layout(desktop: true, width: 840).tableColumns, isTrue);
      expect(layout(desktop: true, width: 720).tableColumns, isFalse);
      expect(layout(desktop: false, width: 720).tableColumns, isFalse);
    });

    test('结构判据只由宽度档位决定', () {
      expect(libraryBrowseUsesSplitLayout(WindowSizeClass.medium), isFalse);
      expect(libraryBrowseUsesSplitLayout(WindowSizeClass.expanded), isTrue);
    });

    test('播放页宽版式：expanded，或 medium 短横屏', () {
      // 竖屏照旧只看宽度档位。
      expect(
        usesWideNowPlayingLayout(AdaptiveLayout.fromSize(839, 900)),
        isFalse,
      );
      expect(
        usesWideNowPlayingLayout(AdaptiveLayout.fromSize(840, 900)),
        isTrue,
      );
      // 手机横屏：medium 也走两栏，compact 仍单栏。
      expect(
        usesWideNowPlayingLayout(AdaptiveLayout.fromSize(915, 412)),
        isTrue,
      );
      expect(
        usesWideNowPlayingLayout(AdaptiveLayout.fromSize(800, 360)),
        isTrue,
      );
      expect(
        usesWideNowPlayingLayout(AdaptiveLayout.fromSize(640, 360)),
        isTrue,
      );
      expect(
        usesWideNowPlayingLayout(AdaptiveLayout.fromSize(480, 400)),
        isFalse,
      );
    });

    test('桌面播放页左栏：内容宽充足保持 480，不足优先保右栏 420', () {
      // 900 窗口 − 96 导航轨 = 804 → 左 384 / 右 420。
      expect(desktopNowPlayingPlayerWidth(804), 384);
      expect(desktopNowPlayingPlayerWidth(840), 420);
      expect(desktopNowPlayingPlayerWidth(900), 480);
      expect(desktopNowPlayingPlayerWidth(904), 480);
      expect(desktopNowPlayingPlayerWidth(1184), 480);
      // 极窄值不返回大于内容宽的宽度。
      expect(desktopNowPlayingPlayerWidth(300), 300);
      expect(desktopNowPlayingPlayerWidth(0), 0);
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

  group('收藏页合集入口', () {
    testWidgets('840 宽也只用标题弹层，不再出合集左栏', (tester) async {
      await pumpPerfApp(
        tester,
        desktopShell: false,
        favoritesCount: 3,
        size: const Size(840, 900),
      );
      expect(find.byKey(const Key('collectionSplitView')), findsNothing);
      expect(find.byKey(const Key('favoritesHeaderOverflow')), findsOneWidget);
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

  group('短横屏', () {
    for (final size in const [Size(915, 412), Size(800, 360), Size(640, 360)]) {
      testWidgets('${size.width.toInt()}×${size.height.toInt()} 播放页走两栏', (
        tester,
      ) async {
        await pumpPerfApp(
          tester,
          desktopShell: false,
          favoritesCount: 3,
          size: size,
        );
        await tester.tap(find.text('播放').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byKey(const Key('wideNowPlayingLayout')), findsOneWidget);
        expect(find.byKey(const Key('singlePaneNowPlaying')), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('640×360 + 200% 字号：发现页空态不溢出', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpPerfApp(
        tester,
        desktopShell: false,
        favoritesCount: 3,
        size: const Size(640, 360),
      );
      await tester.tap(find.text('发现').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
    });

    testWidgets('800×360 + 键盘 + 200% 字号：资料库搜索不溢出', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpPerfApp(
        tester,
        desktopShell: false,
        favoritesCount: 3,
        size: const Size(800, 360),
      );
      await tester.tap(find.text('发现').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
    });

    testWidgets('左右安全区：导航轨与顶栏内容都让开', (tester) async {
      tester.view.padding = const FakeViewPadding(left: 64, right: 64);
      addTearDown(tester.view.resetPadding);
      await pumpPerfApp(
        tester,
        desktopShell: false,
        favoritesCount: 3,
        size: const Size(915, 412),
      );

      expect(tester.getRect(find.byType(M3ENavigationRail)).left, 64);
      // 品牌文字原本贴着顶栏左缘（16 + 标志宽 + 间距 = 68）；安全区补在
      // 内容层后整体右移 64。
      expect(tester.getRect(find.text('Molia').first).left, 132);
      expect(tester.takeException(), isNull);
    });

    testWidgets('竖屏旋转到横屏：播放页切两栏且无异常', (tester) async {
      await pumpPerfApp(
        tester,
        desktopShell: false,
        favoritesCount: 3,
        size: const Size(412, 915),
      );
      await tester.tap(find.text('播放').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('singlePaneNowPlaying')), findsOneWidget);

      tester.view.physicalSize = const Size(915, 412);
      // 播放页有常驻波浪进度等持续动画，不能 pumpAndSettle；按固定帧推进。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('wideNowPlayingLayout')), findsOneWidget);
      expect(find.byKey(const Key('singlePaneNowPlaying')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('桌面壳层窄窗口', () {
    testWidgets('480 宽：紧凑底栏 + 单栏播放页，无溢出', (tester) async {
      await pumpPerfApp(
        tester,
        desktopShell: true,
        favoritesCount: 3,
        size: const Size(480, 800),
      );
      expect(find.byKey(DesktopNowPlayingBar.compactKey), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('播放').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('singlePaneNowPlaying')), findsOneWidget);
      expect(find.byKey(const Key('desktopNowPlayingLayout')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('480×400 最小窗口：首屏与播放页无溢出', (tester) async {
      await pumpPerfApp(
        tester,
        desktopShell: true,
        favoritesCount: 3,
        size: const Size(480, 400),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('播放').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('singlePaneNowPlaying')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('900 宽：完整底栏 + 桌面两栏播放页', (tester) async {
      await pumpPerfApp(
        tester,
        desktopShell: true,
        favoritesCount: 3,
        size: const Size(900, 800),
      );
      expect(find.byKey(DesktopNowPlayingBar.compactKey), findsNothing);

      await tester.tap(find.text('播放').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('desktopNowPlayingLayout')), findsOneWidget);
      expect(find.byKey(const Key('singlePaneNowPlaying')), findsNothing);
      expect(
        tester.getSize(find.byKey(const Key('desktopPlayerColumn'))).width,
        384,
        reason: '900 − 96 内容宽 804：左栏给右栏让到 384',
      );
      expect(
        tester.getSize(find.byKey(const Key('desktopSidePane'))).width,
        420,
        reason: '右栏（队列/歌词/信息）保底 420',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('1280 宽：左栏保持 480，右栏吃余量', (tester) async {
      await pumpPerfApp(
        tester,
        desktopShell: true,
        favoritesCount: 3,
        size: const Size(1280, 800),
      );
      await tester.tap(find.text('播放').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        tester.getSize(find.byKey(const Key('desktopPlayerColumn'))).width,
        480,
      );
      expect(
        tester.getSize(find.byKey(const Key('desktopSidePane'))).width,
        greaterThanOrEqualTo(420),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('900×600 + 200% 字号：桌面两栏不溢出', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpPerfApp(
        tester,
        desktopShell: true,
        favoritesCount: 3,
        size: const Size(900, 600),
      );
      await tester.tap(find.text('播放').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('desktopNowPlayingLayout')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('480 宽 200% 字号无溢出', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpPerfApp(
        tester,
        desktopShell: true,
        favoritesCount: 3,
        size: const Size(480, 800),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('播放').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
    });
  });

  group('200% 字号', () {
    testWidgets('收藏页与播放页在 2.0 倍字号下不溢出', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpPerfApp(
        tester,
        desktopShell: false,
        favoritesCount: 3,
        size: const Size(900, 900),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('播放').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('wideNowPlayingLayout')), findsOneWidget);
      expect(
        find.textContaining('Queue Artist 0'),
        findsWidgets,
        reason: '200% 字号下作者行重排而不是隐藏',
      );
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

    Future<void> pumpSettings(
      WidgetTester tester,
      double width, {
      double? localWidth,
    }) async {
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
            home: Scaffold(
              body: localWidth == null
                  ? const SettingsPage()
                  : Center(
                      child: SizedBox(
                        width: localWidth,
                        height: 900,
                        child: AdaptiveLayoutScope.local(
                          child: const SettingsPage(),
                        ),
                      ),
                    ),
            ),
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

    testWidgets('弹层按自身宽度决定两列，不读整窗宽度', (tester) async {
      await pumpSettings(tester, 1200, localWidth: 500);
      var grid = tester.widget<SettingsSectionGrid>(
        find.byType(SettingsSectionGrid),
      );
      expect(grid.twoColumn, isFalse);

      await pumpSettings(tester, 1200, localWidth: 900);
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
