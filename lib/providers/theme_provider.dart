import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:logger/logger.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:shared_preferences/shared_preferences.dart';

final logger = Logger();

/// 应用主题唯一来源：主题模式 + 系统亮度 + 封面取色 + 用户种子色。
///
/// 持久化键（SharedPreferences）：
/// - `theme_mode`：`system` / `light` / `dark`；
/// - `dynamic_color_enabled`：是否用专辑封面取色（默认开启）；
/// - `monet_color_enabled`：是否用系统莫奈（壁纸）取色（默认关闭）；
/// - `pure_black_enabled`：深色模式是否使用纯黑背景（默认关闭）；
/// - `seed_color`：取色关闭（或尚无封面/壁纸）时的种子色，存 ARGB int。
///
/// 亮度规则：`themeMode` 非 system 时覆盖平台亮度。
/// 配色优先级：莫奈（系统壁纸）> 封面取色 > [seedColor]；纯黑背景在
/// 深色模式下覆盖 surface 系列。
class ThemeProvider extends ChangeNotifier {
  static const String _themeModeKey = 'theme_mode';
  static const String _dynamicColorKey = 'dynamic_color_enabled';
  static const String _monetColorKey = 'monet_color_enabled';
  static const String _pureBlackKey = 'pure_black_enabled';
  static const String _seedColorKey = 'seed_color';

  /// 主题色预设（设置页色点顺序）：默认蓝与当前行为一致。
  static const List<Color> presetSeedColors = <Color>[
    Colors.blue,
    Colors.purple,
    Colors.green,
    Colors.orange,
    Colors.pink,
    Colors.teal,
  ];

  ColorScheme _colorScheme = ColorScheme.fromSeed(seedColor: Colors.blue);
  final LinkedHashMap<String, ({ColorScheme scheme, Color seed})> _paletteCache =
      LinkedHashMap<String, ({ColorScheme scheme, Color seed})>();
  static const int _maxCacheEntries = 8;
  int _paletteRequestId = 0;

  ThemeMode _themeMode = ThemeMode.system;
  bool _dynamicColorEnabled = true;
  bool _monetColorEnabled = false;
  bool _pureBlackEnabled = false;
  Color _seedColor = Colors.blue;

  /// 系统莫奈配色，由宿主（DynamicColorBuilder）经 [updateMonetSchemes]
  /// 注入；平台不支持时为 null。
  ColorScheme? _monetLightScheme;
  ColorScheme? _monetDarkScheme;

  /// 最近一次封面取色得到的种子色：亮度重建与重新开启动态取色时复用。
  Color? _activeDynamicSeed;

  late final Future<void> _preferencesReady;

  ThemeProvider() {
    _preferencesReady = _loadPreferences();
  }

  ColorScheme get colorScheme => _colorScheme;

  ThemeMode get themeMode => _themeMode;

  bool get dynamicColorEnabled => _dynamicColorEnabled;

  bool get monetColorEnabled => _monetColorEnabled;

  bool get pureBlackEnabled => _pureBlackEnabled;

  /// 平台是否提供莫奈配色（Android 12+ 支持时非 null）。
  bool get monetAvailable =>
      _monetLightScheme != null || _monetDarkScheme != null;

  Color get seedColor => _seedColor;

  /// 持久化偏好加载完成（测试等待启动态就绪）。
  Future<void> get preferencesReady => _preferencesReady;

  /// 宿主触发的亮度刷新（启动 / 生命周期恢复 / 系统亮度变化）。
  ///
  /// `themeMode` 非 system 时用强制亮度覆盖平台亮度。
  void updateThemeFromSystem(BuildContext context) {
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    _applyColorScheme(
      _schemeForBrightness(_effectiveBrightness(platformBrightness)),
    );
  }

  /// 设置主题模式并立即应用（可选传平台亮度，让 system 模式即时生效）。
  Future<void> setThemeMode(
    ThemeMode mode, {
    Brightness? platformBrightness,
  }) async {
    final changed = _themeMode != mode;
    _themeMode = mode;
    _applyColorScheme(
      _schemeForBrightness(
        _effectiveBrightness(platformBrightness ?? _colorScheme.brightness),
      ),
      forceNotify: true,
    );
    if (!changed) return;
    await _persist((prefs) => prefs.setString(_themeModeKey, mode.name));
  }

  /// 动态取色开关：关闭立即回退种子色；重新开启恢复最近封面取色。
  Future<void> setDynamicColorEnabled(bool enabled) async {
    if (_dynamicColorEnabled == enabled) return;
    _dynamicColorEnabled = enabled;
    _applyColorScheme(
      _schemeForBrightness(_colorScheme.brightness),
      forceNotify: true,
    );
    await _persist((prefs) => prefs.setBool(_dynamicColorKey, enabled));
  }

  /// 莫奈取色开关：开启后优先使用系统壁纸配色（> 封面取色 > 种子色）。
  Future<void> setMonetColorEnabled(bool enabled) async {
    if (_monetColorEnabled == enabled) return;
    _monetColorEnabled = enabled;
    _applyColorScheme(
      _schemeForBrightness(_colorScheme.brightness),
      forceNotify: true,
    );
    await _persist((prefs) => prefs.setBool(_monetColorKey, enabled));
  }

  /// 纯黑背景开关（仅深色模式生效，OLED 省电观感）。
  Future<void> setPureBlackEnabled(bool enabled) async {
    if (_pureBlackEnabled == enabled) return;
    _pureBlackEnabled = enabled;
    _applyColorScheme(
      _schemeForBrightness(_colorScheme.brightness),
      forceNotify: true,
    );
    await _persist((prefs) => prefs.setBool(_pureBlackKey, enabled));
  }

  /// 宿主注入系统莫奈配色；平台不支持时传 null。
  ///
  /// 未开启莫奈时只记录备用，不触发重算；配色实际变化时才应用。
  void updateMonetSchemes(ColorScheme? light, ColorScheme? dark) {
    if (_monetLightScheme == light && _monetDarkScheme == dark) return;
    _monetLightScheme = light;
    _monetDarkScheme = dark;
    if (!_monetColorEnabled) return;
    _applyColorScheme(
      _schemeForBrightness(_colorScheme.brightness),
      forceNotify: true,
    );
  }

  /// 选择种子色：用户显式选色立即生效；封面色待下一次曲目切换再接管。
  Future<void> setSeedColor(Color color) async {
    if (_seedColor.toARGB32() == color.toARGB32()) return;
    _seedColor = color;
    _activeDynamicSeed = null;
    _applyColorScheme(
      _schemeForBrightness(_colorScheme.brightness),
      forceNotify: true,
    );
    await _persist((prefs) => prefs.setInt(_seedColorKey, color.toARGB32()));
  }

  /// 当前模式下的有效亮度：非 system 强制覆盖平台亮度。
  Brightness _effectiveBrightness(Brightness platformBrightness) {
    return switch (_themeMode) {
      ThemeMode.system => platformBrightness,
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
    };
  }

  /// 目标亮度的配色优先级：莫奈（系统壁纸）> 封面取色 > 种子色；
  /// 纯黑背景在深色模式下覆盖 surface 系列。
  ColorScheme _schemeForBrightness(Brightness brightness) {
    final monet = _monetColorEnabled
        ? (brightness == Brightness.dark
            ? _monetDarkScheme
            : _monetLightScheme)
        : null;
    final ColorScheme scheme;
    if (monet != null) {
      scheme = monet;
    } else {
      final seed = _dynamicColorEnabled
          ? (_activeDynamicSeed ?? _seedColor)
          : _seedColor;
      scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    }
    return _pureBlackEnabled ? _applyPureBlack(scheme) : scheme;
  }

  /// 纯黑背景：仅深色模式生效，surface 系列全部覆盖为纯黑。
  ///
  /// 同时黑掉 surfaceBright/surfaceTint：前者是「更亮的面」角色，后者是
  /// 高程叠加色调，留色会让纯黑出现发灰的浮层；其余角色（inverseSurface、
  /// outline 等）保持原样以保留弹层/边界的可辨识度。
  ColorScheme _applyPureBlack(ColorScheme scheme) {
    if (scheme.brightness != Brightness.dark) return scheme;
    const black = Color(0xFF000000);
    return scheme.copyWith(
      surface: black,
      surfaceDim: black,
      surfaceBright: black,
      surfaceTint: black,
      surfaceContainerLowest: black,
      surfaceContainerLow: black,
      surfaceContainer: black,
      surfaceContainerHigh: black,
      surfaceContainerHighest: black,
    );
  }

  void _applyColorScheme(ColorScheme newScheme, {bool forceNotify = false}) {
    final changed = _colorScheme != newScheme;
    if (!changed && !forceNotify) {
      return;
    }
    _colorScheme = newScheme;
    notifyListeners();
  }

  Future<void> updateThemeFromImage({
    required ImageProvider imageProvider,
    required Brightness brightness,
    String? cacheKey,
  }) async {
    // 关闭动态取色或启用莫奈：忽略封面取色结果。
    if (!_dynamicColorEnabled || _monetColorEnabled) {
      return;
    }

    // 传入的是平台亮度；强制模式下取有效亮度，避免封面取色破坏深/浅色模式。
    final effectiveBrightness = _effectiveBrightness(brightness);
    final normalizedCacheKey =
        cacheKey != null ? '${cacheKey}_${effectiveBrightness.name}' : null;

    if (normalizedCacheKey != null &&
        _paletteCache.containsKey(normalizedCacheKey)) {
      final cached = _paletteCache[normalizedCacheKey]!;
      _activeDynamicSeed = cached.seed;
      _applyColorScheme(_schemeForBrightness(effectiveBrightness));
      return;
    }

    final int requestId = ++_paletteRequestId;

    try {
      final pixels = await _extractPixelsFromImage(imageProvider);
      if (pixels.isEmpty) {
        logger.w('无法从图片提取像素');
        return;
      }

      // 量化颜色并评分选择最佳种子色
      final quantizerResult = await QuantizerCelebi().quantize(pixels, 128);
      final ranked = Score.score(quantizerResult.colorToCount);

      if (ranked.isEmpty) {
        logger.w('无法从图片提取种子色');
        return;
      }

      if (requestId != _paletteRequestId) {
        return;
      }

      final seedColor = Color(ranked.first);
      logger.d('种子色: #${ranked.first.toRadixString(16).padLeft(8, '0')}');

      final ColorScheme nextScheme = ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: effectiveBrightness,
      );

      if (normalizedCacheKey != null) {
        _cacheColorScheme(normalizedCacheKey, nextScheme, seedColor);
      }

      _activeDynamicSeed = seedColor;
      _applyColorScheme(_schemeForBrightness(effectiveBrightness));
    } catch (e) {
      logger.e('更新主题颜色失败: $e');
    }
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final modeName = prefs.getString(_themeModeKey);
      _themeMode = ThemeMode.values.firstWhere(
        (mode) => mode.name == modeName,
        orElse: () => ThemeMode.system,
      );
      _dynamicColorEnabled = prefs.getBool(_dynamicColorKey) ?? true;
      _monetColorEnabled = prefs.getBool(_monetColorKey) ?? false;
      _pureBlackEnabled = prefs.getBool(_pureBlackKey) ?? false;
      final seedValue = prefs.getInt(_seedColorKey);
      if (seedValue != null) {
        _seedColor = Color(seedValue);
      }
      // system 模式保留当前亮度，等宿主回调按平台亮度刷新。
      _applyColorScheme(
        _schemeForBrightness(
          _effectiveBrightness(_colorScheme.brightness),
        ),
        forceNotify: true,
      );
    } catch (e) {
      logger.e('加载主题偏好失败: $e');
    }
  }

  Future<void> _persist(Future<void> Function(SharedPreferences) write) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await write(prefs);
    } catch (e) {
      logger.e('保存主题偏好失败: $e');
    }
  }

  Future<List<int>> _extractPixelsFromImage(ImageProvider imageProvider) async {
    final completer = Completer<ui.Image>();
    final stream = imageProvider.resolve(ImageConfiguration.empty);

    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        completer.complete(info.image);
        stream.removeListener(listener);
      },
      onError: (exception, stackTrace) {
        completer.completeError(exception, stackTrace);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);

    final image = await completer.future;

    // 采样到约 100x100 以提高性能
    const targetSize = 100;
    final width = image.width;
    final height = image.height;
    final stepX = (width / targetSize).ceil().clamp(1, width);
    final stepY = (height / targetSize).ceil().clamp(1, height);

    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) {
      return [];
    }

    final pixels = <int>[];
    final bytes = byteData.buffer.asUint8List();

    for (var y = 0; y < height; y += stepY) {
      for (var x = 0; x < width; x += stepX) {
        final index = (y * width + x) * 4;
        if (index + 3 < bytes.length) {
          final r = bytes[index];
          final g = bytes[index + 1];
          final b = bytes[index + 2];
          final a = bytes[index + 3];

          if (a < 128) continue;

          final argb = (a << 24) | (r << 16) | (g << 8) | b;
          pixels.add(argb);
        }
      }
    }

    return pixels;
  }

  void _cacheColorScheme(String cacheKey, ColorScheme scheme, Color seed) {
    _paletteCache[cacheKey] = (scheme: scheme, seed: seed);
    if (_paletteCache.length > _maxCacheEntries) {
      _paletteCache.remove(_paletteCache.keys.first);
    }
  }
}
