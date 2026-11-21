/// 窗口行为设置（设备本地项：是否记住窗口位置与大小）。
///
/// 为什么不登记 `SettingsRegistry`：窗口几何是设备相关项（每台显示器的
/// 分辨率与摆放都不同），同步到别的设备只会把窗口丢到看不见的地方——
/// 与省流 / 托盘行为同一取舍，键名只出现在 `device_settings_keys.dart`。
///
/// 开关状态在启动早期（窗口创建之前）就要判定，所以持久化值由 [load]
/// 一次读进 [rememberBoundsNotifier] 常驻内存；读取失败保持默认开启。
library;

import 'package:flutter/foundation.dart';

import '../../data/settings/device_settings.dart';
import '../../data/settings/device_settings_keys.dart';

/// 窗口行为偏好：读写设备本地设置，变更即时生效
/// （`WindowChrome` 的恢复与保存路径每次读取）。
class WindowSettings {
  WindowSettings._();

  /// 持久化键名（设备本地键，不登记同步注册表）。
  static const String keyRememberBounds = kWindowRememberBoundsKeyName;

  /// 默认开启：记住窗口几何是桌面播放器的默认预期。
  static const bool defaultRememberBounds = kDefaultWindowRememberBounds;

  /// 设备本地入口；测试用 `SharedPreferences.setMockInitialValues` 换存储，
  /// 生产懒取 `SharedPreferences.getInstance()`。
  static final DeviceSettings _settings = DeviceSettings();

  /// 当前开关（设置页订阅；写入后立即生效，无需重启）。
  static final ValueNotifier<bool> rememberBoundsNotifier = ValueNotifier<bool>(
    defaultRememberBounds,
  );

  /// 是否记住窗口位置与大小（高频读取，直接走内存值）。
  static bool get rememberBounds => rememberBoundsNotifier.value;

  /// 启动时载入已保存开关（组合根在建窗之前 await 一次）。
  static Future<void> load() async {
    rememberBoundsNotifier.value = await _settings.read(
      kWindowRememberBoundsKey,
    );
  }

  /// 设置页开关：立即生效并尽力持久化（写入失败只影响下次启动）。
  static Future<void> setRememberBounds(bool value) async {
    if (rememberBoundsNotifier.value == value) return;
    rememberBoundsNotifier.value = value;
    await _settings.write(kWindowRememberBoundsKey, value);
  }
}
