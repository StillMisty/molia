import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用显示名称（顶栏回退文案与设置项）。
///
/// 默认名随界面语言本地化（英文 Molia / 中文 茉咏）：locale 就绪后由
/// composition root 通过 [applyLocalizedDefault] 注入；设置页可自定义并
/// 持久化（SharedPreferences），自定义后不再随语言切换。
/// UI 通过 [titleNotifier] 订阅，修改后立即生效。
class AppBrandingService {
  AppBrandingService._();

  /// 兜底品牌名（本地化默认值注入前使用）。
  static const String fallbackTitle = 'Molia';

  static String _defaultTitle = fallbackTitle;

  /// 当前生效的默认名（本地化后为 Molia / 茉咏）。
  static String get defaultTitle => _defaultTitle;

  static const int maxLength = 24;

  static const String _prefsKey = 'app_display_title';

  /// 用户是否自定义过名称；自定义后默认名不覆盖标题。
  static bool _customized = false;

  static final ValueNotifier<String> titleNotifier =
      ValueNotifier<String>(fallbackTitle);

  /// 启动时载入已保存名称（main 的 composition root 调用）。
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKey)?.trim();
      if (saved != null && saved.isNotEmpty) {
        _customized = true;
        titleNotifier.value = saved;
      } else {
        titleNotifier.value = _defaultTitle;
      }
    } catch (_) {
      // 读取失败保持默认名称。
    }
  }

  /// 应用本地化默认名（locale 变化时由 composition root 调用）。
  ///
  /// 未自定义名称时同步更新标题；已自定义的不受影响。
  static void applyLocalizedDefault(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == _defaultTitle) return;
    _defaultTitle = trimmed;
    if (!_customized) {
      titleNotifier.value = trimmed;
    }
  }

  /// 保存自定义名称；空白输入回退默认名称（并清除持久化的自定义值）。
  static Future<void> setTitle(String value) async {
    final trimmed = value.trim();
    final effective = trimmed.isEmpty
        ? _defaultTitle
        : trimmed.substring(0, trimmed.length.clamp(0, maxLength));
    _customized = trimmed.isNotEmpty;
    titleNotifier.value = effective;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (trimmed.isEmpty) {
        await prefs.remove(_prefsKey);
      } else {
        await prefs.setString(_prefsKey, effective);
      }
    } catch (_) {
      // 写入失败仅影响下次启动的持久化，本次会话已生效。
    }
  }
}
