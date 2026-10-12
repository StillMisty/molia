import 'package:flutter/foundation.dart';

import '../../data/settings/settings_keys.dart';
import '../../data/settings/settings_registry.dart';

/// 换源偏好：自动换源开关（设置 › 播放，**默认开**；跟人走）。
///
/// 只影响播放失败后的自动行为；手动换源不受开关控制。
class SourceSwapSettings extends ChangeNotifier {
  SourceSwapSettings({SettingsRegistry? settings})
      : _settings = settings ?? SettingsRegistry(keys: kAllSettingsKeys) {
    _settings.bindReload(kSourceSwapAutoEnabled, init);
  }

  final SettingsRegistry _settings;

  bool _autoEnabled = kSourceSwapAutoEnabled.defaultValue;
  bool get autoEnabled => _autoEnabled;

  /// 读取持久化值（失败/缺项保持默认；不抛异常）。
  Future<void> init() async {
    try {
      _autoEnabled = await _settings.read(kSourceSwapAutoEnabled);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setAutoEnabled(bool value) async {
    if (_autoEnabled == value) return;
    _autoEnabled = value;
    notifyListeners();
    try {
      await _settings.write(kSourceSwapAutoEnabled, value);
    } catch (_) {}
  }
}
