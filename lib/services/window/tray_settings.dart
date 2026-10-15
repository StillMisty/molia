/// 托盘与关闭行为设置（设备本地项：关闭窗口时是否最小化到托盘）。
///
/// 为什么**不登记**进 `SettingsRegistry`：托盘是桌面平台能力（移动端 / Web
/// 没有），同步到那些设备只会在不支持托盘的一端产生「点了关闭不知道去哪」的
/// 歧义（与缓存策略、下载设置同一取舍）。键名只出现在本文件
/// （`settings_keys_test` 只约束登记键）。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 托盘行为偏好：读 / 写 `SharedPreferences`，变更即时生效
/// （`WindowChrome` 的关闭策略每次读取）。
class TraySettings extends ChangeNotifier {
  TraySettings({SharedPreferences? prefs}) : _prefs = prefs;

  static const String keyCloseToTray = 'tray_close_to_tray';

  /// 默认「关闭即最小化到托盘」（播放器惯例：关闭窗口不打断播放）。
  static const bool defaultCloseToTray = true;

  SharedPreferences? _prefs;

  bool _closeToTray = defaultCloseToTray;

  /// 点关闭时最小化到托盘；false = 直接退出应用。
  bool get closeToTray => _closeToTray;

  /// 绑定 prefs 并加载已保存值（组合根 / 测试调用一次）。
  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    _closeToTray = _prefs?.getBool(keyCloseToTray) ?? defaultCloseToTray;
    notifyListeners();
  }

  Future<void> setCloseToTray(bool value) async {
    if (value == _closeToTray) return;
    _closeToTray = value;
    await _prefs?.setBool(keyCloseToTray, value);
    notifyListeners();
  }
}
