import 'package:flutter/foundation.dart';

import '../../data/settings/settings_access.dart';
import '../../data/settings/settings_keys.dart';

/// 换源偏好：自动换源开关（设置 › 播放，**默认开**；跟人走）。
///
/// 只影响播放失败后的自动行为；手动换源不受开关控制。
class SourceSwapSettings extends ChangeNotifier {
  SourceSwapSettings({required SettingsAccess settings})
      : _settings = settings {
    _settings.bindReload(kSourceSwapAutoEnabled, init);
  }

  final SettingsAccess _settings;

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
