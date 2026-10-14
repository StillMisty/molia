import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/settings/settings_keys.dart';
import '../data/settings/settings_registry.dart';
import '../theme/scheme_builder.dart';

final logger = Logger('molia.theme_provider');

/// 应用主题唯一来源：主题模式 + 系统亮度 + 基础配色 + 封面覆盖 + 纯黑。
///
/// 取色模型（两层 + 一个正交修饰，行为完全可预知）：
///
/// 1. **基础配色** [baseColorSource]：壁纸（莫奈）或自定义种子色，二选一；
/// 2. **封面覆盖** [followArtworkEnabled]：开启且有封面取色结果时，用封面
///    seed 覆盖基础配色（包括覆盖莫奈）；无封面回退基础配色；
/// 3. **纯黑背景** [pureBlackEnabled]：深色模式下覆盖 surface 系列，
///    与取色来源正交可叠加。
///
/// 解析顺序（唯一）：
/// `封面 seed > 壁纸（基础=壁纸且平台可用）> 自定义 seed`，再叠加纯黑。
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
/// 旧键 `dynamic_color_enabled` / `monet_color_enabled` 只读一次并迁移：
/// 莫奈开 → 基础=壁纸；否则基础=自定义；动态取色 → 封面覆盖开关。
class ThemeProvider extends ChangeNotifier {
  /// 设备本地键（字体来自本机已装字体，不跟人走）。
  static const String _appFontKey = 'app_font_family';

  /// 旧版键（迁移后删除）。
  static const String _legacyDynamicKey = 'dynamic_color_enabled';
  static const String _legacyMonetKey = 'monet_color_enabled';

  ColorScheme _colorScheme = buildColorScheme(Colors.blue, Brightness.light);

  ThemeMode _themeMode = ThemeMode.system;

  /// 基础配色默认壁纸（Monet）：平台不支持时 [updateMonetSchemes] 不会注入
  /// 方案，[_schemeForBrightness] 自然回退自定义种子色。
  ColorBaseSource _baseColorSource = ColorBaseSource.wallpaper;
  bool _followArtworkEnabled = true;
  bool _pureBlackEnabled = false;
  Color _seedColor = Colors.blue;

  /// 全局应用字体族名（设备已装字体）；null 表示系统默认字体。
  String? _appFontFamily;

  /// 系统莫奈配色，由宿主（DynamicColorBuilder）经 [updateMonetSchemes]
  /// 注入；平台不支持时为 null。
  ColorScheme? _monetLightScheme;
  ColorScheme? _monetDarkScheme;

  /// 最近一次封面取色的种子色：封面覆盖层的数据源，与主题输出解耦
  /// （即使当前未跟随封面，也保留以便桌面歌词 / 海报按需解析）。
  Color? _artworkSeed;

  late final Future<void> _preferencesReady;

  ThemeProvider({SettingsRegistry? settings})
      : _settings = settings ?? SettingsRegistry(keys: kAllSettingsKeys) {
    _settings.bindReload(kThemeMode, reloadFromPreferences);
    _settings.bindReload(kColorBase, reloadFromPreferences);
    _settings.bindReload(kFollowArtworkEnabled, reloadFromPreferences);
    _settings.bindReload(kPureBlackEnabled, reloadFromPreferences);
    _settings.bindReload(kSeedColor, reloadFromPreferences);
    _preferencesReady = _loadPreferences();
  }

  final SettingsRegistry _settings;

  ColorScheme get colorScheme => _colorScheme;

  ThemeMode get themeMode => _themeMode;

  /// 基础配色来源（壁纸 / 自定义）。
  ColorBaseSource get baseColorSource => _baseColorSource;

  /// 播放有封面时是否用封面取色覆盖基础配色。
  bool get followArtworkEnabled => _followArtworkEnabled;

  bool get pureBlackEnabled => _pureBlackEnabled;

  /// 平台是否提供莫奈配色（Android 12+ 支持时非 null）。
  bool get monetAvailable =>
      _monetLightScheme != null || _monetDarkScheme != null;

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

  /// 宿主注入系统莫奈配色；平台不支持时传 null。
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

  /// 当前模式下的有效亮度：非 system 强制覆盖平台亮度。
  Brightness _effectiveBrightness(Brightness platformBrightness) {
    return switch (_themeMode) {
      ThemeMode.system => platformBrightness,
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
    };
  }

  /// 外观预览用：给定「基础配色来源 + 亮度」解析出的方案。
  ///
  /// 与 [_schemeForBrightness] 同一取色优先级（壁纸可用时莫奈 > 自定义种子）
  /// 并叠加纯黑，但**不含封面覆盖**：设置页 swatch 预览要与基础配色选项
  /// 一一对应且稳定（封面覆盖是独立开关行，效果在播放时的真实界面里可见）。
  ColorScheme previewScheme(ColorBaseSource source, Brightness brightness) {
    final monet = source == ColorBaseSource.wallpaper
        ? (brightness == Brightness.dark
            ? _monetDarkScheme
            : _monetLightScheme)
        : null;
    return _applyPureBlack(monet ?? buildColorScheme(_seedColor, brightness));
  }

  /// 目标亮度的配色优先级：封面 seed > 壁纸（基础=壁纸且可用）> 自定义 seed；
  /// 纯黑背景在深色模式下覆盖 surface 系列。
  ColorScheme _schemeForBrightness(Brightness brightness) {
    final artworkSeed = _artworkSeed;
    if (_followArtworkEnabled && artworkSeed != null) {
      return _applyPureBlack(buildColorScheme(artworkSeed, brightness));
    }
    return previewScheme(_baseColorSource, brightness);
  }

  ColorScheme _applyPureBlack(ColorScheme scheme) =>
      _pureBlackEnabled ? applyPureBlackScheme(scheme) : scheme;

  void _applyColorScheme(ColorScheme newScheme, {bool forceNotify = false}) {
    final changed = _colorScheme != newScheme;
    if (!changed && !forceNotify) return;
    _colorScheme = newScheme;
    notifyListeners();
  }

  Future<void> _loadPreferences() async {
    try {
      final modeName = await _settings.read(kThemeMode);
      _themeMode = ThemeMode.values.firstWhere(
        (mode) => mode.name == modeName,
        orElse: () => ThemeMode.system,
      );

      // 新键优先；两个新键都不存在时从旧键一次性迁移并清理旧键。
      // 旧键不登记（迁移后即废弃），因此这里仍需直接访问 prefs。
      final prefs = await SharedPreferences.getInstance();
      final hasBase = prefs.containsKey(kColorBase.name) ||
          prefs.containsKey(kFollowArtworkEnabled.name);
      if (!hasBase) {
        // 旧键显式关闭莫奈 → 保持自定义（尊重老用户的选择）；
        // 从未配置过（无旧键）→ 吃新默认：壁纸（平台支持时）。
        _baseColorSource = prefs.getBool(_legacyMonetKey) == false
            ? ColorBaseSource.custom
            : ColorBaseSource.wallpaper;
        _followArtworkEnabled = prefs.getBool(_legacyDynamicKey) ?? true;
        await _settings.write(kColorBase, _baseColorSource.name);
        await _settings.write(kFollowArtworkEnabled, _followArtworkEnabled);
        await prefs.remove(_legacyMonetKey);
        await prefs.remove(_legacyDynamicKey);
      } else {
        final baseName = await _settings.read(kColorBase);
        _baseColorSource = ColorBaseSource.values.firstWhere(
          (source) => source.name == baseName,
          orElse: () => ColorBaseSource.wallpaper,
        );
        _followArtworkEnabled = await _settings.read(kFollowArtworkEnabled);
      }

      _pureBlackEnabled = await _settings.read(kPureBlackEnabled);
      _seedColor = Color(await _settings.read(kSeedColor));
      _appFontFamily = prefs.getString(_appFontKey);
      // system 模式保留当前亮度，等宿主回调按平台亮度刷新。
      _applyColorScheme(
        _schemeForBrightness(
          _effectiveBrightness(_colorScheme.brightness),
        ),
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
