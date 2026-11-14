import 'dart:async';

import '../../data/settings/settings_access.dart';
import '../../data/settings/settings_key.dart';
import '../../data/settings/settings_keys.dart';

/// 海报取色来源（与全局主题互相独立）。
enum PosterColorSource {
  /// 跟随应用当前主题方案。
  appTheme,

  /// 按当前曲目封面取色；无封面 / 取色不可用时回退应用主题。
  artwork,

  /// 海报专属自定义色（任意取色，不影响全局主题）。
  custom,
}

/// 海报样式（取色来源 / 自定义种子色 / 字体覆盖）的**跟人走**持久化。
///
/// 为什么进设置注册表：歌词海报、统计海报与年度报告共用同一组偏好，换设备
/// 后用户期望看到同一套样式；三键没有设备能力依赖（字体族缺失时渲染层
/// 回退），因此与主题 / 歌词显示同属 `SyncCategory.settings`，也随完整备份
/// 导出。全静态服务，组合根 `attachSettings` 注入窄作用域，远端应用后的
/// 重载由组合根代绑（与语言 / 品牌名 / 快捷键同一模式）。
class PosterStyleSettings {
  PosterStyleSettings._();

  static const PosterColorSource defaultSource = PosterColorSource.appTheme;
  static const int defaultSeed = 0xFF2196F3;

  /// 设置注册表（组合根启动时注入）；测试 / 独立挂载时为 null：
  /// 此时状态只留在内存，不落盘。
  static SettingsAccess? _settings;

  /// 最近一次载入；[ensureLoaded] 复用它避免海报页与分享链路重复读键。
  static Future<void>? _loading;

  static PosterColorSource _colorSource = defaultSource;
  static int _seed = defaultSeed;
  static String? _fontFamily;

  static PosterColorSource get colorSource => _colorSource;
  static int get seed => _seed;

  /// null = 跟随应用字体；空串 = 系统默认；其它 = 字体族名。
  static String? get fontFamily => _fontFamily;

  /// 注入注册表并触发一次异步载入（组合根不必 await）。
  static void attachSettings(SettingsAccess settings) {
    _settings = settings;
    unawaited(load());
  }

  /// 首次使用前确保已从注册表读过一次；已载入直接返回。
  static Future<void> ensureLoaded() => _loading ?? load();

  /// 读取三个登记键；读取失败 / 未接线保持当前值。
  static Future<void> load() {
    final settings = _settings;
    if (settings == null) return Future<void>.value();
    final future = _load(settings);
    _loading = future;
    return future;
  }

  static Future<void> _load(SettingsAccess settings) async {
    try {
      final source = parseSource(await settings.read(kPosterColorSourceKey));
      final seed = await settings.read(kPosterSeedColor);
      final font = await settings.read(kPosterFontFamily);
      _colorSource = source;
      _seed = seed;
      _fontFamily = font;
    } catch (_) {
      // 读取失败按当前值 / 默认值继续，不阻断海报生成。
    }
  }

  /// 同步应用远端设置后的重载（组合根 mount 时绑定的钩子）。
  static Future<void> reload() => load();

  /// 解析持久化值；未知值（旧数据 / 同步来的新枚举）回退跟随应用主题。
  static PosterColorSource parseSource(String? raw) {
    for (final value in PosterColorSource.values) {
      if (value.name == raw) return value;
    }
    return defaultSource;
  }

  static Future<void> setColorSource(PosterColorSource value) async {
    if (_colorSource == value) return;
    _colorSource = value;
    await _write(kPosterColorSourceKey, value.name);
  }

  static Future<void> setSeed(int value) async {
    if (_seed == value) return;
    _seed = value;
    await _write(kPosterSeedColor, value);
  }

  /// 自定义取色一次写两键：同一次选择不应留下「种子已变、来源仍旧」的中间态。
  static Future<void> setCustomColor(int value) async {
    await setSeed(value);
    await setColorSource(PosterColorSource.custom);
  }

  static Future<void> setFontFamily(String? value) async {
    if (_fontFamily == value) return;
    _fontFamily = value;
    await _write(kPosterFontFamily, value);
  }

  static Future<void> _write<T extends Object?>(
    SettingsKey<T> key,
    T value,
  ) async {
    final settings = _settings;
    if (settings == null) return;
    try {
      await settings.write(key, value);
    } catch (_) {
      // 写入失败只影响下次启动 / 其它设备，本次会话已按新值生效。
    }
  }
}
