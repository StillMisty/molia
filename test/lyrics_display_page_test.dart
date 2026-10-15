import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/lyrics_display/desktop_lyrics_settings_page.dart';
import 'package:molia/pages/lyrics_display/lyrics_content_settings_page.dart';
import 'package:molia/pages/lyrics_display/system_media_lyrics_settings_page.dart';
import 'package:molia/providers/lyrics_display_provider.dart';
import 'package:molia/providers/theme_provider.dart';
import 'package:molia/services/language_service.dart';
import 'package:molia/services/lyrics_display/lyric_color_resolver.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/theme/scheme_builder.dart';
import 'package:molia/utils/color_hex.dart';
import 'package:molia/widgets/settings/settings_tiles.dart';

import 'support/settings_test_support.dart';

/// 歌词显示设置页：歌词与输出（页内分组）、系统媒体歌词（通知 + 蓝牙）、
/// 桌面歌词颜色面板。不触碰真实 DB / 安全存储（内存注册表 + mock prefs）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ThemeProvider themeProvider;
  late LyricsDisplaySettings settings;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 构造共享 provider 树并挂载 [home]（与真实组合根同源装配）。
  Future<void> pumpApp(
    WidgetTester tester,
    Widget home, {
    bool mediaSessionInitFailed = false,
  }) async {
    themeProvider = ThemeProvider();
    await themeProvider.preferencesReady;
    addTearDown(themeProvider.dispose);

    final prefs = await SharedPreferences.getInstance();
    settings = LyricsDisplaySettings(
      settings: testSettingsRegistry(preferences: prefs),
    );
    await settings.init();
    addTearDown(settings.dispose);

    // outputs 为空：输出能力全部 unsupported（页面本身仍可独立挂载）。
    final display = LyricsDisplayProvider(
      settings: settings,
      outputs: const [],
      mediaSessionInitFailed: mediaSessionInitFailed,
    );
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

  testWidgets('歌词与输出页：页内分组齐全（应用内歌词页 + 输出共享）', (tester) async {
    useLargeViewport(tester);
    await pumpApp(tester, const LyricsContentSettingsPage());

    // 两个分组标题 + 两组开关（同名的「翻译」用副标题区分生效范围）。
    expect(find.text('Lyrics page'), findsOneWidget);
    expect(find.text('Lyric outputs'), findsOneWidget);
    expect(
      find.text('Show translation under each line in the lyrics page'),
      findsOneWidget,
    );
    expect(
      find.text('Show translation in floating, notification and Bluetooth lyrics'),
      findsOneWidget,
    );
    expect(find.text('Unsynced lyrics'), findsOneWidget);
  });

  testWidgets('歌词与输出页：无时间轴分段选择「隐藏」并持久化', (tester) async {
    useLargeViewport(tester);
    await pumpApp(tester, const LyricsContentSettingsPage());
    expect(settings.unsyncedBehavior, UnsyncedBehavior.title);

    final hide = find.text('Hide');
    await tester.scrollUntilVisible(
      hide,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(hide);
    await tester.pumpAndSettle();

    expect(settings.unsyncedBehavior, UnsyncedBehavior.hide);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kLyricsDisplaySettings.name);
    expect(raw, isNotNull);
    expect(raw, contains('"unsyncedBehavior":"hide"'));
  });

  testWidgets('桌面歌词页：颜色默认跟随主题，面板选「表面色」即生效', (tester) async {
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

    final playedRow = find.byKey(const Key('desktopColorPlayedRow'));

    // 默认开箱即用：当前行颜色直接跟随应用主题主色。
    expect(settings.desktopPlayedColorSource, LyricColorSource.primary);
    expect(playedArgb, scheme.primary.toARGB32());
    expect(
      find.descendant(of: playedRow, matching: find.text(hexOf(playedArgb))),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(
      playedRow,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(playedRow);
    await tester.pumpAndSettle();

    // 颜色面板：7 个来源候选项（含表面色），主色候选 hex 与方案一致。
    expect(find.byType(M3EDialog), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);
    expect(find.text('Surface'), findsOneWidget);
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
        matching: find.text('Surface'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(M3EDialog), findsNothing);
    expect(settings.desktopPlayedColorSource, LyricColorSource.surface);
    // 行内色值跟随来源刷新（与 resolveLyricColor 同源）。
    expect(
      find.descendant(
        of: playedRow,
        matching: find.text(hexOf(resolveLyricColor(
          settings.desktopPlayedColorSource,
          settings.desktopPlayedColor,
          scheme,
        ))),
      ),
      findsOneWidget,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(kLyricsDisplaySettings.name),
      contains('"desktop.playedColorSource":"surface"'),
    );
  });

  testWidgets('桌面歌词页：暂停时隐藏默认开，置灰的回退行随开关恢复', (tester) async {
    useLargeViewport(tester);
    await pumpApp(tester, const DesktopLyricsSettingsPage());

    expect(settings.desktopHideOnPause, isTrue);
    Finder pauseRow() => find.ancestor(
          of: find.text('When paused'),
          matching: find.byType(SettingsChoiceRow<LyricsPauseBehavior>),
        );
    // 默认整窗隐藏：回退策略不生效，行置灰但值保留。
    expect(pauseRow(), findsOneWidget);
    expect(
      tester.widget<SettingsChoiceRow<LyricsPauseBehavior>>(pauseRow()).enabled,
      isFalse,
    );

    final switchRow = find.ancestor(
      of: find.text('Hide when paused'),
      matching: find.byType(SettingsSwitchTile),
    );
    await tester.scrollUntilVisible(
      switchRow,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(switchRow);
    await tester.pumpAndSettle();

    expect(settings.desktopHideOnPause, isFalse);
    expect(
      tester.widget<SettingsChoiceRow<LyricsPauseBehavior>>(pauseRow()).enabled,
      isTrue,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(kLyricsDisplaySettings.name),
      contains('"desktop.hideOnPause":false'),
    );
  });

  testWidgets('系统媒体歌词页：通知格式分段切回「仅歌词」', (tester) async {
    useLargeViewport(tester);
    await pumpApp(tester, const SystemMediaLyricsSettingsPage());
    await settings.setNotificationFormat(LyricsMetadataFormat.titleLyric);
    await tester.pumpAndSettle();

    // 通知与蓝牙两组都有「格式」分段：按分组卡片限定作用域。
    final notificationSection = find.ancestor(
      of: find.text('Notification & lock screen'),
      matching: find.byType(SettingsSectionCard),
    );
    await tester.tap(
      find.descendant(
        of: notificationSection,
        matching: find.text('Lyrics only'),
      ),
    );
    await tester.pumpAndSettle();

    expect(settings.notificationFormat, LyricsMetadataFormat.lyric);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(kLyricsDisplaySettings.name),
      contains('"notification.format":"lyric"'),
    );
  });

  testWidgets('系统媒体歌词页：权限被拒且通知开关打开时显示系统设置深链', (tester) async {
    const channel = MethodChannel('top.stillmisty.molia/notifications');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'permissionStatus') return 'denied';
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await pumpApp(tester, const SystemMediaLyricsSettingsPage());
    // 开关未开时不提示（避免没启用输出就先报权限）。
    expect(
      find.byKey(const Key('lyricsNotificationPermissionItem')),
      findsNothing,
    );

    await settings.setNotificationEnabled(true);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('lyricsNotificationPermissionItem')),
      findsOneWidget,
    );
  });
}
