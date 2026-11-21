/// 托盘与关闭行为设置（设备本地项：关闭窗口时是否最小化到托盘）。
///
/// 为什么**不登记**进 `SettingsRegistry`：托盘是桌面平台能力（移动端没有），
/// 同步到那些设备只会在不支持托盘的一端产生「点了关闭不知道去哪」的
/// 歧义（与缓存策略、下载设置同一取舍）。键名只出现在
/// `device_settings_keys.dart`。
library;

import 'package:flutter/foundation.dart';

import '../../data/settings/device_settings.dart';
import '../../data/settings/device_settings_keys.dart';

/// 托盘行为偏好：读写设备本地设置，变更即时生效
/// （`WindowChrome` 的关闭策略每次读取）。
class TraySettings extends ChangeNotifier {
  /// [settings] 仅测试注入；生产构造自己的设备本地入口。
  TraySettings({DeviceSettings? settings})
    : _settings = settings ?? DeviceSettings();

  static const String keyCloseToTray = kTrayCloseToTrayKeyName;

  /// 默认「关闭即最小化到托盘」（播放器惯例：关闭窗口不打断播放）。
  static const bool defaultCloseToTray = kDefaultTrayCloseToTray;

  final DeviceSettings _settings;

  bool _closeToTray = defaultCloseToTray;

  /// 点关闭时最小化到托盘；false = 直接退出应用。
  bool get closeToTray => _closeToTray;

  /// 加载已保存值（组合根 / 测试调用一次）。
  Future<void> init() async {
    _closeToTray = await _settings.read(kTrayCloseToTrayKey);
    notifyListeners();
  }

  Future<void> setCloseToTray(bool value) async {
    if (value == _closeToTray) return;
    _closeToTray = value;
    await _settings.write(kTrayCloseToTrayKey, value);
    notifyListeners();
  }
}
