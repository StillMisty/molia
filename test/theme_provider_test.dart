import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/providers/theme_provider.dart';

/// 4x4 纯色图片 provider：驱动封面取色路径（不依赖网络/资产）。
class _SolidColorImageProvider extends ImageProvider<_SolidColorImageProvider> {
  _SolidColorImageProvider(this.color);

  final Color color;

  @override
  Future<_SolidColorImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<_SolidColorImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
      _SolidColorImageProvider key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(
      _createImage().then((image) => ImageInfo(image: image)),
    );
  }

  Future<ui.Image> _createImage() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 4, 4),
      Paint()..color = color,
    );
    return recorder.endRecording().toImage(4, 4);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('ThemeProvider initializes with a color scheme', () async {
    final provider = ThemeProvider();
    await provider.preferencesReady;
    expect(provider.colorScheme, isNotNull);
    expect(provider.themeMode, ThemeMode.system);
    expect(provider.dynamicColorEnabled, isTrue);
    expect(provider.monetColorEnabled, isFalse);
    expect(provider.pureBlackEnabled, isFalse);
    expect(provider.seedColor.toARGB32(), Colors.blue.toARGB32());
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
                    child: Text(
                        scheme.brightness == Brightness.dark ? 'dark' : 'light'),
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

  testWidgets('动态取色开关：关闭忽略封面取色，重新开启恢复', (tester) async {
    final provider = ThemeProvider();
    await provider.preferencesReady;
    final seedScheme = ColorScheme.fromSeed(seedColor: Colors.blue);
    expect(provider.colorScheme, seedScheme);

    await provider.setDynamicColorEnabled(false);
    expect(provider.dynamicColorEnabled, isFalse);
    expect(provider.colorScheme, seedScheme);

    // 关闭状态：封面取色被忽略，配色保持不变。
    await tester.runAsync(() async {
      await provider.updateThemeFromImage(
        imageProvider: _SolidColorImageProvider(const Color(0xFF00FF00)),
        brightness: Brightness.light,
      );
    });
    expect(provider.colorScheme, seedScheme);

    // 开启：封面取色生效。
    await provider.setDynamicColorEnabled(true);
    await tester.runAsync(() async {
      await provider.updateThemeFromImage(
        imageProvider: _SolidColorImageProvider(const Color(0xFF00FF00)),
        brightness: Brightness.light,
      );
    });
    final dynamicScheme = provider.colorScheme;
    expect(dynamicScheme, isNot(seedScheme));

    // 关闭回退种子色；再次开启恢复最近一次封面取色。
    await provider.setDynamicColorEnabled(false);
    expect(provider.colorScheme, seedScheme);
    await provider.setDynamicColorEnabled(true);
    expect(provider.colorScheme, dynamicScheme);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('dynamic_color_enabled'), isTrue);
  });

  test('种子色持久化并在重启时加载', () async {
    final first = ThemeProvider();
    await first.preferencesReady;
    expect(first.seedColor.toARGB32(), Colors.blue.toARGB32());

    await first.setSeedColor(Colors.green);
    expect(first.seedColor.toARGB32(), Colors.green.toARGB32());
    expect(first.colorScheme, ColorScheme.fromSeed(seedColor: Colors.green));

    // 模拟重启：新实例从 SharedPreferences 恢复。
    final second = ThemeProvider();
    await second.preferencesReady;
    expect(second.seedColor.toARGB32(), Colors.green.toARGB32());
    expect(second.colorScheme, ColorScheme.fromSeed(seedColor: Colors.green));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('seed_color'), Colors.green.toARGB32());
  });

  test('主题模式与动态取色开关在重启时加载', () async {
    final first = ThemeProvider();
    await first.preferencesReady;
    await first.setThemeMode(
      ThemeMode.dark,
      platformBrightness: Brightness.light,
    );
    await first.setDynamicColorEnabled(false);

    final second = ThemeProvider();
    await second.preferencesReady;
    expect(second.themeMode, ThemeMode.dark);
    expect(second.colorScheme.brightness, Brightness.dark);
    expect(second.dynamicColorEnabled, isFalse);
  });

  test('莫奈取色：优先级高于封面取色与种子色，可持久化', () async {
    final provider = ThemeProvider();
    await provider.preferencesReady;
    expect(provider.monetColorEnabled, isFalse);
    expect(provider.monetAvailable, isFalse);

    final monetLight = ColorScheme.fromSeed(seedColor: Colors.pink);
    final monetDark = ColorScheme.fromSeed(
      seedColor: Colors.pink,
      brightness: Brightness.dark,
    );
    provider.updateMonetSchemes(monetLight, monetDark);
    expect(provider.monetAvailable, isTrue);
    // 未开启时不生效。
    expect(provider.colorScheme, ColorScheme.fromSeed(seedColor: Colors.blue));

    await provider.setMonetColorEnabled(true);
    expect(provider.colorScheme, monetLight);

    // 深色模式取对应方案。
    await provider.setThemeMode(
      ThemeMode.dark,
      platformBrightness: Brightness.light,
    );
    expect(provider.colorScheme, monetDark);

    // 关闭后回退种子色（深色）。
    await provider.setMonetColorEnabled(false);
    expect(
      provider.colorScheme,
      ColorScheme.fromSeed(
        seedColor: Colors.blue,
        brightness: Brightness.dark,
      ),
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('monet_color_enabled'), isFalse);
  });

  test('莫奈取色与纯黑背景在重启时加载', () async {
    SharedPreferences.setMockInitialValues({
      'monet_color_enabled': true,
      'pure_black_enabled': true,
    });
    final provider = ThemeProvider();
    await provider.preferencesReady;
    expect(provider.monetColorEnabled, isTrue);
    expect(provider.pureBlackEnabled, isTrue);
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
