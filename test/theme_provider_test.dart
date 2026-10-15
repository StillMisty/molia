import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/providers/theme_provider.dart';
import 'package:molia/theme/scheme_builder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('初始状态：基础配色=壁纸（无莫奈时回退种子色）、封面覆盖开、纯黑关', () async {
    final provider = ThemeProvider();
    await provider.preferencesReady;
    expect(provider.colorScheme, isNotNull);
    expect(provider.themeMode, ThemeMode.system);
    // 从未配置过 → 新默认壁纸；测试环境无莫奈注入，配色回退种子色。
    expect(provider.baseColorSource, ColorBaseSource.wallpaper);
    expect(provider.followArtworkEnabled, isTrue);
    expect(provider.monetAvailable, isFalse);
    expect(provider.pureBlackEnabled, isFalse);
    expect(provider.seedColor.toARGB32(), Colors.blue.toARGB32());
    expect(
      provider.colorScheme,
      buildColorScheme(Colors.blue, Brightness.light),
    );
    expect(provider.artworkColorScheme, isNull);
    // 迁移把缺省键物化（值 = 新默认），下次启动走「已有新键」分支。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('color_base'), 'wallpaper');
  });

  test('全局应用字体：持久化、恢复与清除', () async {
    SharedPreferences.setMockInitialValues(
        {'app_font_family': 'Noto Sans CJK SC'});
    final provider = ThemeProvider();
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

  testWidgets('ThemeProvider updates when system brightness changes',
      (tester) async {
    final themeProvider = ThemeProvider();
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
                    child: Text(scheme.brightness == Brightness.dark
                        ? 'dark'
                        : 'light'),
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
    final provider = ThemeProvider();
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
    final provider = ThemeProvider();
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
    final provider = ThemeProvider();
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
    final provider = ThemeProvider();
    await provider.preferencesReady;
    final monetLight = buildColorScheme(Colors.pink, Brightness.light);
    final monetDark = buildColorScheme(Colors.pink, Brightness.dark);
    provider.updateMonetSchemes(monetLight, monetDark);
    expect(provider.monetAvailable, isTrue);
    // 默认基础配色=壁纸：莫奈注入即生效。
    expect(provider.colorScheme, monetLight);

    // 切到自定义：莫奈不生效，回退种子色。
    await provider.setBaseColorSource(ColorBaseSource.custom);
    expect(
        provider.colorScheme, buildColorScheme(Colors.blue, Brightness.light));

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
        provider.colorScheme, buildColorScheme(Colors.green, Brightness.dark));

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

  test('种子色持久化并在重启时加载', () async {
    final first = ThemeProvider();
    await first.preferencesReady;
    expect(first.seedColor.toARGB32(), Colors.blue.toARGB32());

    await first.setSeedColor(Colors.green);
    expect(first.seedColor.toARGB32(), Colors.green.toARGB32());
    expect(first.colorScheme, buildColorScheme(Colors.green, Brightness.light));

    // 模拟重启：新实例从 SharedPreferences 恢复。
    final second = ThemeProvider();
    await second.preferencesReady;
    expect(second.seedColor.toARGB32(), Colors.green.toARGB32());
    expect(
        second.colorScheme, buildColorScheme(Colors.green, Brightness.light));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('seed_color'), Colors.green.toARGB32());
  });

  test('主题模式与封面覆盖开关在重启时加载', () async {
    final first = ThemeProvider();
    await first.preferencesReady;
    await first.setThemeMode(
      ThemeMode.dark,
      platformBrightness: Brightness.light,
    );
    await first.setFollowArtworkEnabled(false);

    final second = ThemeProvider();
    await second.preferencesReady;
    expect(second.themeMode, ThemeMode.dark);
    expect(second.colorScheme.brightness, Brightness.dark);
    expect(second.followArtworkEnabled, isFalse);
  });

  test('旧键一次性迁移：莫奈/动态取色 → 基础配色/封面覆盖', () async {
    SharedPreferences.setMockInitialValues({
      'monet_color_enabled': true,
      'dynamic_color_enabled': false,
      'seed_color': 0xFF00FF00,
      'pure_black_enabled': true,
    });
    final provider = ThemeProvider();
    await provider.preferencesReady;
    expect(provider.baseColorSource, ColorBaseSource.wallpaper);
    expect(provider.followArtworkEnabled, isFalse);
    expect(provider.pureBlackEnabled, isTrue);
    expect(provider.seedColor.toARGB32(), 0xFF00FF00);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('color_base'), 'wallpaper');
    expect(prefs.getBool('follow_artwork_enabled'), isFalse);
    expect(prefs.getBool('monet_color_enabled'), isNull);
    expect(prefs.getBool('dynamic_color_enabled'), isNull);
  });

  test('旧键迁移只在缺新键时执行，已有新键不被覆盖', () async {
    SharedPreferences.setMockInitialValues({
      'monet_color_enabled': true,
      'dynamic_color_enabled': true,
      'color_base': 'custom',
      'follow_artwork_enabled': false,
    });
    final provider = ThemeProvider();
    await provider.preferencesReady;
    expect(provider.baseColorSource, ColorBaseSource.custom);
    expect(provider.followArtworkEnabled, isFalse);
    // 旧键存在但未被采纳，也不清理（保守策略）。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('monet_color_enabled'), isTrue);
    expect(prefs.getString('color_base'), 'custom');
  });

  test('旧键显式关闭莫奈：迁移保持自定义，不吃壁纸默认', () async {
    SharedPreferences.setMockInitialValues({'monet_color_enabled': false});
    final provider = ThemeProvider();
    await provider.preferencesReady;
    expect(provider.baseColorSource, ColorBaseSource.custom);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('color_base'), 'custom');
    expect(prefs.getBool('monet_color_enabled'), isNull);
  });

  test('纯黑背景：仅深色模式覆盖 surface，浅色不生效', () async {
    final provider = ThemeProvider();
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
