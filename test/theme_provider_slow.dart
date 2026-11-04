import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/providers/theme_provider.dart';
import 'package:molia/theme/scheme_builder.dart';

import 'support/settings_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('初始状态：基础配色=壁纸（无莫奈时回退种子色）、封面覆盖开、纯黑关', () async {
    final provider = ThemeProvider(settings: testSettingsRegistry());
    await provider.preferencesReady;
    expect(provider.themeMode, ThemeMode.system);
    // 从未配置过 → 新默认壁纸；测试环境无莫奈注入，配色回退种子色。
    expect(provider.baseColorSource, ColorBaseSource.wallpaper);
    expect(provider.followArtworkEnabled, isTrue);
    expect(provider.systemColorAvailable, isFalse);
    expect(provider.systemBaseColorSource, SystemBaseColorSource.unavailable);
    expect(provider.pureBlackEnabled, isFalse);
    expect(provider.seedColor.toARGB32(), Colors.blue.toARGB32());
    expect(
      provider.colorScheme,
      buildColorScheme(Colors.blue, Brightness.light),
    );
    expect(provider.artworkColorScheme, isNull);
    // 缺键时把新键的默认值物化，下次启动走「已有值」分支。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('color_base'), 'wallpaper');
  });

  test('全局应用字体：持久化、恢复与清除', () async {
    SharedPreferences.setMockInitialValues({
      'app_font_family': 'Noto Sans CJK SC',
    });
    final provider = ThemeProvider(settings: testSettingsRegistry());
    await provider.preferencesReady;
    expect(provider.appFontFamily, 'Noto Sans CJK SC');

    await provider.setAppFontFamily('serif');
    expect(provider.appFontFamily, 'serif');
    var prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('app_font_family'), 'serif');

    await provider.setAppFontFamily(null);
    expect(provider.appFontFamily, isNull);
    prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('app_font_family'), isNull);
  });

  testWidgets('ThemeProvider updates when system brightness changes', (
    tester,
  ) async {
    final themeProvider = ThemeProvider(settings: testSettingsRegistry());
    await themeProvider.preferencesReady;

    Future<void> pumpWithBrightness(Brightness brightness) async {
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: themeProvider,
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(platformBrightness: brightness),
              child: Builder(
                builder: (context) {
                  final scheme = context.watch<ThemeProvider>().colorScheme;
                  return ElevatedButton(
                    onPressed: () => context
                        .read<ThemeProvider>()
                        .updateThemeFromSystem(context),
                    child: Text(
                      scheme.brightness == Brightness.dark ? 'dark' : 'light',
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
    }

    await pumpWithBrightness(Brightness.light);
    expect(find.text('light'), findsOneWidget);

    await pumpWithBrightness(Brightness.dark);
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();

    expect(find.text('dark'), findsOneWidget);
  });

  testWidgets('强制主题模式覆盖平台亮度并持久化', (tester) async {
    final provider = ThemeProvider(settings: testSettingsRegistry());
    await provider.preferencesReady;

    late BuildContext ctx;
    Future<void> pumpWithBrightness(Brightness brightness) async {
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(platformBrightness: brightness),
              child: Builder(
                builder: (context) {
                  ctx = context;
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
    }

    await pumpWithBrightness(Brightness.light);
    await provider.setThemeMode(
      ThemeMode.dark,
      platformBrightness: Brightness.light,
    );
    expect(provider.themeMode, ThemeMode.dark);
    expect(provider.colorScheme.brightness, Brightness.dark);

    // 强制浅色时，平台切换为深色也不改变应用亮度。
    await provider.setThemeMode(
      ThemeMode.light,
      platformBrightness: Brightness.dark,
    );
    expect(provider.colorScheme.brightness, Brightness.light);
    await pumpWithBrightness(Brightness.dark);
    provider.updateThemeFromSystem(ctx);
    expect(provider.colorScheme.brightness, Brightness.light);

    // system 模式跟随平台亮度。
    await provider.setThemeMode(
      ThemeMode.system,
      platformBrightness: Brightness.dark,
    );
    expect(provider.colorScheme.brightness, Brightness.dark);
    await pumpWithBrightness(Brightness.light);
    provider.updateThemeFromSystem(ctx);
    expect(provider.colorScheme.brightness, Brightness.light);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'system');
  });

  test('平台亮度入口（runApp 前首帧同路径）：system 跟随、强制模式覆盖', () async {
    final provider = ThemeProvider(settings: testSettingsRegistry());
    await provider.preferencesReady;

    // 默认 system：直接按平台亮度出方案。
    provider.applyPlatformBrightness(Brightness.dark);
    expect(provider.colorScheme.brightness, Brightness.dark);
    provider.applyPlatformBrightness(Brightness.light);
    expect(provider.colorScheme.brightness, Brightness.light);

    // 强制深色：平台亮度不生效。
    await provider.setThemeMode(ThemeMode.dark);
    provider.applyPlatformBrightness(Brightness.light);
    expect(provider.colorScheme.brightness, Brightness.dark);
  });

  test('封面覆盖：开启时覆盖基础配色，关闭回退且歌词方案仍可用', () async {
    final provider = ThemeProvider(settings: testSettingsRegistry());
    await provider.preferencesReady;
    final seedScheme = buildColorScheme(Colors.blue, Brightness.light);

    provider.applyArtworkSeed(Colors.green);
    final artworkScheme = provider.colorScheme;
    expect(artworkScheme, buildColorScheme(Colors.green, Brightness.light));
    // 消费面（桌面歌词 / 海报）的「跟随封面」方案与主题输出同源。
    expect(provider.artworkColorScheme, artworkScheme);

    // 关闭封面覆盖：主题回退基础配色，但封面色板本身保留。
    await provider.setFollowArtworkEnabled(false);
    expect(provider.followArtworkEnabled, isFalse);
    expect(provider.colorScheme, seedScheme);
    expect(
      provider.artworkColorScheme,
      buildColorScheme(Colors.green, Brightness.light),
    );

    // 重新开启：恢复最近一次封面取色。
    await provider.setFollowArtworkEnabled(true);
    expect(provider.colorScheme, artworkScheme);

    // 当前曲目无封面：清除 seed 回退基础配色。
    provider.clearArtworkSeed();
    expect(provider.colorScheme, seedScheme);
    expect(provider.artworkColorScheme, isNull);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('follow_artwork_enabled'), isTrue);
  });

  test('优先级：封面覆盖 > 壁纸 > 自定义种子色', () async {
    final provider = ThemeProvider(settings: testSettingsRegistry());
    await provider.preferencesReady;
    final monetLight = buildColorScheme(Colors.pink, Brightness.light);
    final monetDark = buildColorScheme(Colors.pink, Brightness.dark);
    provider.updateMonetSchemes(monetLight, monetDark);
    expect(provider.systemColorAvailable, isTrue);
    expect(provider.systemBaseColorSource, SystemBaseColorSource.accent);
    // 默认基础配色=壁纸：莫奈注入即生效。
    expect(provider.colorScheme, monetLight);

    // 切到自定义：莫奈不生效，回退种子色。
    await provider.setBaseColorSource(ColorBaseSource.custom);
    expect(
      provider.colorScheme,
      buildColorScheme(Colors.blue, Brightness.light),
    );

    await provider.setBaseColorSource(ColorBaseSource.wallpaper);
    expect(provider.colorScheme, monetLight);

    // 深色模式取对应壁纸方案。
    await provider.setThemeMode(
      ThemeMode.dark,
      platformBrightness: Brightness.light,
    );
    expect(provider.colorScheme, monetDark);

    // 封面 seed 覆盖壁纸（含覆盖莫奈）。
    provider.applyArtworkSeed(Colors.green);
    expect(
      provider.colorScheme,
      buildColorScheme(Colors.green, Brightness.dark),
    );

    // 关闭封面覆盖：回到壁纸方案。
    await provider.setFollowArtworkEnabled(false);
    expect(provider.colorScheme, monetDark);

    // 平台不提供壁纸（清空注入）：回退自定义种子色。
    provider.updateMonetSchemes(null, null);
    expect(
      provider.colorScheme,
      buildColorScheme(Colors.blue, Brightness.dark),
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('color_base'), 'wallpaper');
  });

  test('桌面壁纸 seed 层：壁纸 > 强调色，封面 > 壁纸，自定义忽略两者', () async {
    final provider = ThemeProvider(settings: testSettingsRegistry());
    await provider.preferencesReady;
    expect(provider.systemBaseColorSource, SystemBaseColorSource.unavailable);

    final monetLight = buildColorScheme(Colors.pink, Brightness.light);
    final monetDark = buildColorScheme(Colors.pink, Brightness.dark);
    provider.updateMonetSchemes(monetLight, monetDark);
    expect(provider.systemColorAvailable, isTrue);
    expect(provider.systemBaseColorSource, SystemBaseColorSource.accent);
    expect(provider.colorScheme, monetLight);

    // 壁纸 seed 按亮度各生效一张，压过强调色方案。
    provider.updateSystemWallpaperSeed(Colors.green, Colors.teal);
    expect(provider.systemBaseColorSource, SystemBaseColorSource.wallpaper);
    expect(
      provider.colorScheme,
      buildColorScheme(Colors.green, Brightness.light),
    );
    await provider.setThemeMode(
      ThemeMode.dark,
      platformBrightness: Brightness.light,
    );
    expect(
      provider.colorScheme,
      buildColorScheme(Colors.teal, Brightness.dark),
    );

    // 封面 seed 压过壁纸；清除后回壁纸方案。
    provider.applyArtworkSeed(Colors.amber);
    expect(
      provider.colorScheme,
      buildColorScheme(Colors.amber, Brightness.dark),
    );
    provider.clearArtworkSeed();
    expect(
      provider.colorScheme,
      buildColorScheme(Colors.teal, Brightness.dark),
    );

    // 自定义档忽略壁纸与强调色；期间记录的 seed 不丢，切回后生效。
    await provider.setBaseColorSource(ColorBaseSource.custom);
    provider.updateSystemWallpaperSeed(Colors.lime, Colors.lime);
    expect(
      provider.colorScheme,
      buildColorScheme(Colors.blue, Brightness.dark),
    );
    await provider.setBaseColorSource(ColorBaseSource.wallpaper);
    expect(
      provider.colorScheme,
      buildColorScheme(Colors.lime, Brightness.dark),
    );
  });

  test('纯黑叠加壁纸 seed：surface 系列黑掉，取色仍来自壁纸', () async {
    final provider = ThemeProvider(settings: testSettingsRegistry());
    await provider.preferencesReady;
    await provider.setThemeMode(
      ThemeMode.dark,
      platformBrightness: Brightness.light,
    );
    await provider.setPureBlackEnabled(true);

    provider.updateSystemWallpaperSeed(null, Colors.teal);
    final scheme = provider.colorScheme;
    expect(scheme.surface.toARGB32(), 0xFF000000);
    expect(scheme.surfaceContainerHighest.toARGB32(), 0xFF000000);
    expect(
      scheme.primary,
      buildColorScheme(Colors.teal, Brightness.dark).primary,
    );
  });

  test('种子色持久化并在重启时加载', () async {
    final first = ThemeProvider(settings: testSettingsRegistry());
    await first.preferencesReady;
    expect(first.seedColor.toARGB32(), Colors.blue.toARGB32());

    await first.setSeedColor(Colors.green);
    expect(first.seedColor.toARGB32(), Colors.green.toARGB32());
    expect(first.colorScheme, buildColorScheme(Colors.green, Brightness.light));

    // 模拟重启：新实例从 SharedPreferences 恢复。
    final second = ThemeProvider(settings: testSettingsRegistry());
    await second.preferencesReady;
    expect(second.seedColor.toARGB32(), Colors.green.toARGB32());
    expect(
      second.colorScheme,
      buildColorScheme(Colors.green, Brightness.light),
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('seed_color'), Colors.green.toARGB32());
  });

  test('主题模式与封面覆盖开关在重启时加载', () async {
    final first = ThemeProvider(settings: testSettingsRegistry());
    await first.preferencesReady;
    await first.setThemeMode(
      ThemeMode.dark,
      platformBrightness: Brightness.light,
    );
    await first.setFollowArtworkEnabled(false);

    final second = ThemeProvider(settings: testSettingsRegistry());
    await second.preferencesReady;
    expect(second.themeMode, ThemeMode.dark);
    expect(second.colorScheme.brightness, Brightness.dark);
    expect(second.followArtworkEnabled, isFalse);
  });

  test('纯黑背景：仅深色模式覆盖 surface，浅色不生效', () async {
    final provider = ThemeProvider(settings: testSettingsRegistry());
    await provider.preferencesReady;

    await provider.setThemeMode(
      ThemeMode.dark,
      platformBrightness: Brightness.light,
    );
    await provider.setPureBlackEnabled(true);
    expect(provider.colorScheme.surface.toARGB32(), 0xFF000000);
    expect(provider.colorScheme.surfaceContainerHighest.toARGB32(), 0xFF000000);
    // surfaceBright/surfaceTint 一并黑掉，避免纯黑上出现发灰浮层。
    expect(provider.colorScheme.surfaceBright.toARGB32(), 0xFF000000);
    expect(provider.colorScheme.surfaceTint.toARGB32(), 0xFF000000);
    expect(provider.colorScheme.brightness, Brightness.dark);

    // 纯黑与取色来源正交：封面覆盖/壁纸同样被叠加。
    provider.applyArtworkSeed(Colors.green);
    expect(provider.colorScheme.surface.toARGB32(), 0xFF000000);

    // 浅色模式不覆盖。
    await provider.setThemeMode(
      ThemeMode.light,
      platformBrightness: Brightness.dark,
    );
    expect(provider.colorScheme.surface.toARGB32(), isNot(0xFF000000));
    expect(provider.colorScheme.surfaceBright.toARGB32(), isNot(0xFF000000));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('pure_black_enabled'), isTrue);
  });
}
