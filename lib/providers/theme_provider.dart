import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/settings/settings_access.dart';
import '../data/settings/settings_keys.dart';
import '../theme/scheme_builder.dart';

final logger = Logger('molia.theme_provider');

/// 「基础配色 = 壁纸」档实际生效的来源（设置页副标题 / 选项可用性用）。
///
/// 三态互斥用单个枚举表达，避免两个布尔出现自相矛盾的组合。
enum SystemBaseColorSource {
  /// 壁纸图 seed 可用（桌面：真实系统壁纸取色）。
  wallpaper,

  /// 壁纸图不可用：回退系统强调色（`dynamic_color` 提供的莫奈方案）。
  accent,

  /// 壁纸图与强调色都不可用：配色回退自定义种子色。
  unavailable,
}

/// 应用主题唯一来源：主题模式 + 系统亮度 + 基础配色 + 封面覆盖 + 纯黑。
///
/// 取色模型（两层 + 一个正交修饰，行为完全可预知）：
///
/// 1. **基础配色** [baseColorSource]：壁纸或自定义种子色，二选一；壁纸档
///    桌面优先真实壁纸图 seed，其次系统强调色（移动端即莫奈），都不可用时
///    回退自定义种子色；
/// 2. **封面覆盖** [followArtworkEnabled]：开启且有封面取色结果时，用封面
///    seed 覆盖基础配色（包括覆盖壁纸）；无封面回退基础配色；
/// 3. **纯黑背景** [pureBlackEnabled]：深色模式下覆盖 surface 系列，
///    与取色来源正交可叠加。
///
/// 解析顺序（唯一）：
/// `封面 seed > 壁纸图 seed（桌面，基础=壁纸）> 强调色方案（基础=壁纸且可用）
/// > 自定义 seed`，再叠加纯黑。
///
/// 持久化键（登记进设置注册表，跟人走）：
/// - `theme_mode`：`system` / `light` / `dark`；
/// - `color_base`：`wallpaper` / `custom`（默认壁纸，平台不可用时回退种子色）；
/// - `follow_artwork_enabled`：播放有封面时是否用封面取色覆盖基础配色
///   （默认开启）；
/// - `pure_black_enabled`：深色模式是否使用纯黑表面（默认关闭）；
/// - `seed_color`：自定义种子色（ARGB int）；
/// - `app_font_family`：全局应用字体族名（null = 系统默认）。
///
/// 缺键时把新键的默认值物化一次，之后启动都走「已有值」的读取路径。
class ThemeProvider extends ChangeNotifier {
  /// 设备本地键（字体来自本机已装字体，不跟人走）。
  static const String _appFontKey = 'app_font_family';

  ColorScheme _colorScheme = buildColorScheme(
    Color(kSeedColor.defaultValue),
    Brightness.light,
  );

  ThemeMode _themeMode = _themeModeOf(kThemeMode.defaultValue);

  /// 基础配色默认壁纸：桌面用真实壁纸图 seed（[updateSystemWallpaperSeed]）、
  /// 平台强调色（[updateMonetSchemes]）兜底；两者都没有时
  /// [_schemeForBrightness] 自然回退自定义种子色。
  ColorBaseSource _baseColorSource = _colorBaseOf(kColorBase.defaultValue);
  bool _followArtworkEnabled = kFollowArtworkEnabled.defaultValue;
  bool _pureBlackEnabled = kPureBlackEnabled.defaultValue;
  Color _seedColor = Color(kSeedColor.defaultValue);

  /// 全局应用字体族名（设备已装字体）；null 表示系统默认字体。
  String? _appFontFamily;

  /// 系统强调色方案，由宿主（`DynamicColorBuilder`）经 [updateMonetSchemes]
  /// 注入；平台不支持时为 null。
  ColorScheme? _monetLightScheme;
  ColorScheme? _monetDarkScheme;

  /// 桌面壁纸图 seed（浅 / 深各一张），由组合根经 [updateSystemWallpaperSeed]
  /// 注入；拿不到壁纸文件 / 解码失败时为 null。
  Color? _wallpaperLightSeed;
  Color? _wallpaperDarkSeed;

  /// 最近一次封面取色的种子色：封面覆盖层的数据源，与主题输出解耦
  /// （即使当前未跟随封面，也保留以便桌面歌词 / 海报按需解析）。
  Color? _artworkSeed;

  late final Future<void> _preferencesReady;

  ThemeProvider({required SettingsAccess settings}) : _settings = settings {
    _settings.bindReload(kThemeMode, reloadFromPreferences);
    _settings.bindReload(kColorBase, reloadFromPreferences);
    _settings.bindReload(kFollowArtworkEnabled, reloadFromPreferences);
    _settings.bindReload(kPureBlackEnabled, reloadFromPreferences);
    _settings.bindReload(kSeedColor, reloadFromPreferences);
    _preferencesReady = _loadPreferences();
  }

  final SettingsAccess _settings;

  ColorScheme get colorScheme => _colorScheme;

  ThemeMode get themeMode => _themeMode;

  /// 基础配色来源（壁纸 / 自定义）。
  ColorBaseSource get baseColorSource => _baseColorSource;

  /// 播放有封面时是否用封面取色覆盖基础配色。
  bool get followArtworkEnabled => _followArtworkEnabled;

  bool get pureBlackEnabled => _pureBlackEnabled;

  /// 「壁纸」档是否可用（壁纸图 seed 或系统强调色任一存在）。
  ///
  /// 桌面壁纸图优先，强调色是桌面（拿不到壁纸）/ 移动端（Android 12+ 莫奈）
  /// 的兜底；两者都不可用时配色回退自定义种子色。
  bool get systemColorAvailable =>
      systemBaseColorSource != SystemBaseColorSource.unavailable;

  /// 「壁纸」档当前实际生效的来源（三态：壁纸图 / 强调色 / 都不可用）。
  SystemBaseColorSource get systemBaseColorSource {
    if (_wallpaperLightSeed != null || _wallpaperDarkSeed != null) {
      return SystemBaseColorSource.wallpaper;
    }
    if (_monetLightScheme != null || _monetDarkScheme != null) {
      return SystemBaseColorSource.accent;
    }
    return SystemBaseColorSource.unavailable;
  }

  Color get seedColor => _seedColor;

  /// 全局应用字体族名；null 表示系统默认。
  String? get appFontFamily => _appFontFamily;

  /// 当前曲目封面的取色方案；无封面取色结果时为 null。
  ///
  /// 消费面（桌面歌词 / 海报）选「跟随封面」时用；亮度跟随当前应用方案。
  ColorScheme? get artworkColorScheme {
    final seed = _artworkSeed;
    if (seed == null) return null;
    return buildColorScheme(seed, _colorScheme.brightness);
  }

  /// 持久化偏好加载完成（测试等待启动态就绪）。
  Future<void> get preferencesReady => _preferencesReady;

  /// 重新读取持久化偏好（跨设备同步应用远端设置后由组合根调用）。
  Future<void> reloadFromPreferences() => _loadPreferences();

  /// 宿主触发的亮度刷新（启动 / 生命周期恢复 / 系统亮度变化）。
  ///
  /// `themeMode` 非 system 时用强制亮度覆盖平台亮度。
  void updateThemeFromSystem(BuildContext context) {
    applyPlatformBrightness(MediaQuery.platformBrightnessOf(context));
  }

  /// 平台亮度入口（无 context）：`runApp` 前的首帧亮度与 AppShell 的回填
  /// 共用同一条解析路径，系统深色模式下首帧即深色方案。
  void applyPlatformBrightness(Brightness platformBrightness) {
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
    await _persist(() => _settings.write(kThemeMode, mode.name));
  }

  /// 设置基础配色来源（壁纸 / 自定义）。
  Future<void> setBaseColorSource(ColorBaseSource source) async {
    if (_baseColorSource == source) return;
    _baseColorSource = source;
    _applyColorScheme(
      _schemeForBrightness(_colorScheme.brightness),
      forceNotify: true,
    );
    await _persist(() => _settings.write(kColorBase, source.name));
  }

  /// 封面覆盖开关：关闭立即回退基础配色；重新开启恢复最近封面取色。
  Future<void> setFollowArtworkEnabled(bool enabled) async {
    if (_followArtworkEnabled == enabled) return;
    _followArtworkEnabled = enabled;
    _applyColorScheme(
      _schemeForBrightness(_colorScheme.brightness),
      forceNotify: true,
    );
    await _persist(() => _settings.write(kFollowArtworkEnabled, enabled));
  }

  /// 纯黑背景开关（仅深色模式生效，与取色来源正交）。
  Future<void> setPureBlackEnabled(bool enabled) async {
    if (_pureBlackEnabled == enabled) return;
    _pureBlackEnabled = enabled;
    _applyColorScheme(
      _schemeForBrightness(_colorScheme.brightness),
      forceNotify: true,
    );
    await _persist(() => _settings.write(kPureBlackEnabled, enabled));
  }

  /// 宿主注入系统强调色方案（`DynamicColorBuilder` 的莫奈）；不支持时传 null。
  ///
  /// 未选壁纸基础配色时只记录备用，不触发重算；配色实际变化时才应用。
  void updateMonetSchemes(ColorScheme? light, ColorScheme? dark) {
    if (_monetLightScheme == light && _monetDarkScheme == dark) return;
    _monetLightScheme = light;
    _monetDarkScheme = dark;
    if (_baseColorSource != ColorBaseSource.wallpaper) return;
    _applyColorScheme(
      _schemeForBrightness(_colorScheme.brightness),
      forceNotify: true,
    );
  }

  /// 注入桌面壁纸图 seed（浅 / 深各一张；无可用壁纸传 null）。
  ///
  /// 镜像 [updateMonetSchemes]：非壁纸档只记录备用、不触发重算；壁纸 seed
  /// 优先于强调色方案（见 [_schemeForBrightness]）。
  void updateSystemWallpaperSeed(Color? light, Color? dark) {
    if (_wallpaperLightSeed?.toARGB32() == light?.toARGB32() &&
        _wallpaperDarkSeed?.toARGB32() == dark?.toARGB32()) {
      return;
    }
    _wallpaperLightSeed = light;
    _wallpaperDarkSeed = dark;
    if (_baseColorSource != ColorBaseSource.wallpaper) return;
    _applyColorScheme(
      _schemeForBrightness(_colorScheme.brightness),
      forceNotify: true,
    );
  }

  /// 应用封面取色结果（由 composition root 的取色链路注入）。
  ///
  /// 即使当前未开启封面覆盖也记录 seed（供歌词 / 海报按需解析），
  /// 并强制通知：消费面需要重新解析「跟随封面」颜色。
  void applyArtworkSeed(Color seed) {
    if (_artworkSeed?.toARGB32() == seed.toARGB32()) return;
    _artworkSeed = seed;
    _applyColorScheme(
      _schemeForBrightness(_colorScheme.brightness),
      forceNotify: true,
    );
  }

  /// 当前曲目无封面：清除封面 seed，主题回退基础配色。
  void clearArtworkSeed() {
    if (_artworkSeed == null) return;
    _artworkSeed = null;
    _applyColorScheme(
      _schemeForBrightness(_colorScheme.brightness),
      forceNotify: true,
    );
  }

  /// 选择自定义种子色：立即生效（封面覆盖开启时随下一次无封面回退显示）。
  Future<void> setSeedColor(Color color) async {
    if (_seedColor.toARGB32() == color.toARGB32()) return;
    _seedColor = color;
    _applyColorScheme(
      _schemeForBrightness(_colorScheme.brightness),
      forceNotify: true,
    );
    await _persist(() => _settings.write(kSeedColor, color.toARGB32()));
  }

  /// 设置全局应用字体（null = 系统默认）；字体变化不重算配色，直接通知重build。
  Future<void> setAppFontFamily(String? family) async {
    if (_appFontFamily == family) return;
    _appFontFamily = family;
    notifyListeners();
    await _persist(() async {
      final prefs = await SharedPreferences.getInstance();
      if (family == null) {
        await prefs.remove(_appFontKey);
      } else {
        await prefs.setString(_appFontKey, family);
      }
    });
  }

  /// 主题模式 / 基础配色：键默认值是唯一来源，模块只把字符串映射成枚举。
  static ThemeMode _themeModeOf(String name) => ThemeMode.values.firstWhere(
        (mode) => mode.name == name,
        orElse: () => ThemeMode.values.firstWhere(
          (mode) => mode.name == kThemeMode.defaultValue,
        ),
      );

  static ColorBaseSource _colorBaseOf(String name) =>
      ColorBaseSource.values.firstWhere(
        (source) => source.name == name,
        orElse: () => ColorBaseSource.values.firstWhere(
          (source) => source.name == kColorBase.defaultValue,
        ),
      );

  /// 当前模式下的有效亮度：非 system 强制覆盖平台亮度。
  Brightness _effectiveBrightness(Brightness platformBrightness) {
    return switch (_themeMode) {
      ThemeMode.system => platformBrightness,
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
    };
  }

  /// 目标亮度的配色优先级：封面 seed > 壁纸图 seed（桌面）> 强调色方案 >
  /// 自定义 seed；纯黑背景在深色模式下覆盖 surface 系列。
  ColorScheme _schemeForBrightness(Brightness brightness) {
    final ColorScheme scheme;
    final artworkSeed = _artworkSeed;
    if (_followArtworkEnabled && artworkSeed != null) {
      scheme = buildColorScheme(artworkSeed, brightness);
    } else if (_baseColorSource == ColorBaseSource.wallpaper) {
      final wallpaperSeed = brightness == Brightness.dark
          ? _wallpaperDarkSeed
          : _wallpaperLightSeed;
      final monet =
          brightness == Brightness.dark ? _monetDarkScheme : _monetLightScheme;
      scheme = wallpaperSeed != null
          ? buildColorScheme(wallpaperSeed, brightness)
          : (monet ?? buildColorScheme(_seedColor, brightness));
    } else {
      scheme = buildColorScheme(_seedColor, brightness);
    }
    return _pureBlackEnabled ? applyPureBlackScheme(scheme) : scheme;
  }

  void _applyColorScheme(ColorScheme newScheme, {bool forceNotify = false}) {
    final changed = _colorScheme != newScheme;
    if (!changed && !forceNotify) return;
    _colorScheme = newScheme;
    notifyListeners();
  }

  Future<void> _loadPreferences() async {
    try {
      final modeName = await _settings.read(kThemeMode);
      _themeMode = _themeModeOf(modeName);

      // 新键缺省时把默认值物化一次；之后启动都走「已有值」的读取路径。
      final prefs = await SharedPreferences.getInstance();
      final baseName = await _settings.read(kColorBase);
      _baseColorSource = _colorBaseOf(baseName);
      _followArtworkEnabled = await _settings.read(kFollowArtworkEnabled);
      if (!prefs.containsKey(kColorBase.name)) {
        await _settings.write(kColorBase, _baseColorSource.name);
      }
      if (!prefs.containsKey(kFollowArtworkEnabled.name)) {
        await _settings.write(kFollowArtworkEnabled, _followArtworkEnabled);
      }

      _pureBlackEnabled = await _settings.read(kPureBlackEnabled);
      _seedColor = Color(await _settings.read(kSeedColor));
      _appFontFamily = prefs.getString(_appFontKey);
      // system 模式保留当前亮度，等宿主回调按平台亮度刷新。
      _applyColorScheme(
        _schemeForBrightness(_effectiveBrightness(_colorScheme.brightness)),
        forceNotify: true,
      );
    } catch (e) {
      logger.severe('加载主题偏好失败: $e');
    }
  }

  Future<void> _persist(Future<void> Function() write) async {
    try {
      await write();
    } catch (e) {
      logger.severe('保存主题偏好失败: $e');
    }
  }
}
