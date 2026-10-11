import 'package:shared_preferences/shared_preferences.dart';

/// 海报取色来源（与全局主题互相独立）。
enum PosterColorSource {
  /// 跟随应用当前主题方案。
  appTheme,

  /// 按当前曲目封面取色；无封面 / 取色不可用时回退应用主题。
  artwork,

  /// 海报专属自定义色（任意取色，不影响全局主题）。
  custom,
}

/// 海报取色偏好持久化（来源 + 自定义种子色）。
///
/// 与 `PosterFontStore` 同一模式：海报设置独立于全局主题，
/// 读取失败按默认值（跟随应用主题）处理。
class PosterColorStore {
  PosterColorStore._();

  static const String _sourceKey = 'poster_color_source';
  static const String _seedKey = 'poster_seed_color';

  /// 默认来源：跟随应用主题。
  static const PosterColorSource defaultSource = PosterColorSource.appTheme;

  /// 默认海报自定义色（与应用默认种子色一致）。
  static const int defaultSeed = 0xFF2196F3;

  /// 读取海报取色偏好。
  static Future<({PosterColorSource source, int seed})> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sourceName = prefs.getString(_sourceKey);
      final source = PosterColorSource.values.firstWhere(
        (value) => value.name == sourceName,
        orElse: () => defaultSource,
      );
      return (source: source, seed: prefs.getInt(_seedKey) ?? defaultSeed);
    } catch (_) {
      return (source: defaultSource, seed: defaultSeed);
    }
  }

  static Future<void> saveSource(PosterColorSource source) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sourceKey, source.name);
    } catch (_) {
      // 持久化失败不影响本次会话内的选择生效。
    }
  }

  static Future<void> saveSeed(int seed) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_seedKey, seed);
    } catch (_) {
      // 持久化失败不影响本次会话内的选择生效。
    }
  }
}
