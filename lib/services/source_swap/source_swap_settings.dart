import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 换源偏好：自动换源开关（设置 › 播放，**默认开**）。
///
/// 只影响播放失败后的自动行为；手动换源不受开关控制。
class SourceSwapSettings extends ChangeNotifier {
  SourceSwapSettings({SharedPreferences? preferences})
      : _prefsOverride = preferences;

  static const String keyAutoEnabled = 'source_swap_auto_enabled';
  static const bool defaultAutoEnabled = true;

  final SharedPreferences? _prefsOverride;

  bool _autoEnabled = defaultAutoEnabled;
  bool get autoEnabled => _autoEnabled;

  /// 读取持久化值（失败/缺项保持默认；不抛异常）。
  Future<void> init() async {
    try {
      final prefs = _prefsOverride ?? await SharedPreferences.getInstance();
      final value = prefs.getBool(keyAutoEnabled);
      if (value != null) _autoEnabled = value;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setAutoEnabled(bool value) async {
    if (_autoEnabled == value) return;
    _autoEnabled = value;
    notifyListeners();
    try {
      final prefs = _prefsOverride ?? await SharedPreferences.getInstance();
      await prefs.setBool(keyAutoEnabled, value);
    } catch (_) {}
  }
}
