import 'package:shared_preferences/shared_preferences.dart';

/// 海报字体覆盖的持久化。
///
/// 取值约定（与 `ThemeProvider` 的全局应用字体互相独立）：
/// - 键不存在：跟随应用字体（默认）；
/// - 空字符串：强制系统默认字体；
/// - 其它：指定字体族名。
class PosterFontStore {
  PosterFontStore._();

  static const String _key = 'poster_font_family';

  /// 读取海报字体覆盖；读取失败按「跟随应用字体」处理。
  static Future<String?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_key);
    } catch (_) {
      return null;
    }
  }

  /// 保存海报字体覆盖（null 表示跟随应用字体）。
  static Future<void> save(String? value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (value == null) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, value);
      }
    } catch (_) {
      // 持久化失败不影响本次会话内的选择生效。
    }
  }
}
