import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/lyrics_display/desktop_lyrics_settings_page.dart';
import 'package:molia/pages/lyrics_display/lyrics_output_settings_page.dart';
import 'package:molia/pages/lyrics_display/notification_lyrics_settings_page.dart';
import 'package:molia/pages/lyrics_display_page.dart';
import 'package:molia/providers/lyrics_display_provider.dart';
import 'package:molia/providers/theme_provider.dart';
import 'package:molia/services/language_service.dart';
import 'package:molia/services/lyrics_display/lyric_color_resolver.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/theme/scheme_builder.dart';
import 'package:molia/utils/color_hex.dart';

import 'support/settings_test_support.dart';

/// 歌词显示二级设置页：hub 入口导航、输出共享项、桌面歌词颜色面板、
/// 通知格式分段。不触碰真实 DB / 安全存储（内存注册表 + mock prefs）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ThemeProvider themeProvider;
  late LyricsDisplaySettings settings;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 构造共享 provider 树并挂载 [home]（与真实组合根同源装配）。
  Future<void> pumpApp(WidgetTester tester, Widget home) async {
    themeProvider = ThemeProvider();
    await themeProvider.preferencesReady;
    addTearDown(themeProvider.dispose);

    final prefs = await SharedPreferences.getInstance();
    settings = LyricsDisplaySettings(
      settings: testSettingsRegistry(preferences: prefs),
    );
    await settings.init();
    addTearDown(settings.dispose);

    // outputs 为空：能力全部 unsupported（hub 隐藏输出入口，子页仍可独立挂载）。
    final display =
        LyricsDisplayProvider(settings: settings, outputs: const []);
    addTearDown(display.dispose);

    final themedData = ThemeData(colorScheme: themeProvider.colorScheme);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
          ChangeNotifierProvider<LyricsDisplaySettings>.value(value: settings),
          ChangeNotifierProvider<LyricsDisplayProvider>.value(value: display),
        ],
        child: M3EMaterialApp(
          data: M3EThemeData.fromMaterial(themedData),
          theme: themedData,
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

  void useLargeViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  testWidgets('歌词显示 hub：入口行齐全，点击进入歌词输出子页', (tester) async {
    useLargeViewport(tester);
    await pumpApp(tester, const LyricsDisplayPage());

    expect(find.byKey(const Key('lyricsPageEntry')), findsOneWidget);
    expect(find.byKey(const Key('lyricsOutputsEntry')), findsOneWidget);
    // 无输出能力（outputs 为空）：输出入口隐藏，只留平台不支持说明。
    expect(find.byKey(const Key('lyricsDesktopEntry')), findsNothing);
    expect(find.byKey(const Key('lyricsNotificationEntry')), findsNothing);
    expect(find.byKey(const Key('lyricsBluetoothEntry')), findsNothing);
    expect(
      find.text('Lyric outputs are not available on this platform'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('lyricsOutputsEntry')));
    await tester.pumpAndSettle();

    // 子页标题 + 共享输出项（无时间轴分段行）。
    expect(find.text('Lyric outputs'), findsOneWidget);
    expect(find.text('Unsynced lyrics'), findsOneWidget);
    expect(find.byKey(const Key('lyricsPageEntry')), findsNothing);
  });

  testWidgets('歌词输出页：无时间轴分段选择「隐藏」并持久化', (tester) async {
    await pumpApp(tester, const LyricsOutputSettingsPage());
    expect(settings.unsyncedBehavior, UnsyncedBehavior.title);

    await tester.tap(find.text('Hide'));
    await tester.pumpAndSettle();

    expect(settings.unsyncedBehavior, UnsyncedBehavior.hide);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kLyricsDisplaySettings.name);
    expect(raw, isNotNull);
    expect(raw, contains('"unsyncedBehavior":"hide"'));
  });

  testWidgets('桌面歌词页：颜色行显示解析色，面板选「主色」即生效', (tester) async {
    useLargeViewport(tester);
    await pumpApp(tester, const DesktopLyricsSettingsPage());

    final scheme = resolveSurfaceScheme(
      settings.desktopSchemeSource,
      appScheme: themeProvider.colorScheme,
      artworkScheme: themeProvider.artworkColorScheme,
    );
    final playedArgb = resolveLyricColor(
      settings.desktopPlayedColorSource,
      settings.desktopPlayedColor,
      scheme,
    );
    String hexOf(int argb) =>
        colorHexLabel(argb, withAlpha: (argb >> 24) & 0xFF != 0xFF);

    // 默认自定义白（不透明）→ 行内 hex 与 resolveLyricColor 结果一致。
    expect(playedArgb, 0xFFFFFFFF);
    expect(find.text(hexOf(playedArgb)), findsOneWidget);

    final playedRow = find.text('Current line color');
    await tester.scrollUntilVisible(
      playedRow,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(playedRow);
    await tester.pumpAndSettle();

    // 颜色面板：6 个来源候选项，主色候选 hex 与方案一致。
    expect(find.byType(M3EDialog), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);
    final primaryArgb = scheme.primary.toARGB32();
    expect(
      find.descendant(
        of: find.byType(M3EDialog),
        matching: find.text(hexOf(primaryArgb)),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.descendant(
        of: find.byType(M3EDialog),
        matching: find.text('Primary'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(M3EDialog), findsNothing);
    expect(settings.desktopPlayedColorSource, LyricColorSource.primary);
    // 行内色值跟随来源刷新（与 resolveLyricColor 同源）。
    expect(
      find.text(hexOf(resolveLyricColor(
        settings.desktopPlayedColorSource,
        settings.desktopPlayedColor,
        scheme,
      ))),
      findsOneWidget,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(kLyricsDisplaySettings.name),
      contains('"desktop.playedColorSource":"primary"'),
    );
  });

  testWidgets('通知·锁屏页：格式分段切回「仅歌词」', (tester) async {
    await pumpApp(tester, const NotificationLyricsSettingsPage());
    await settings.setNotificationFormat(LyricsMetadataFormat.titleLyric);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Lyrics only'));
    await tester.pumpAndSettle();

    expect(settings.notificationFormat, LyricsMetadataFormat.lyric);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(kLyricsDisplaySettings.name),
      contains('"notification.format":"lyric"'),
    );
  });
}
