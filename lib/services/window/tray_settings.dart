/// 托盘与关闭行为设置（设备本地项：关闭窗口时是否最小化到托盘）。
///
/// 为什么**不登记**进 `SettingsRegistry`：托盘是桌面平台能力（移动端没有），
/// 同步到那些设备只会在不支持托盘的一端产生「点了关闭不知道去哪」的
/// 歧义（与缓存策略、下载设置同一取舍）。键名只出现在
/// `device_settings_keys.dart`。
library;

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../app/bootstrap/runtime_providers.dart';
import '../../data/settings/device_settings.dart';
import '../../data/settings/device_settings_keys.dart';

part 'tray_settings.g.dart';

/// 托盘偏好快照。
@immutable
class TraySettingsState {
  const TraySettingsState({required this.closeToTray});

  final bool closeToTray;
}

/// 托盘行为偏好：读写设备本地设置，变更即时生效
/// （`WindowChrome` 的关闭策略每次读取）。
@Riverpod(keepAlive: true, name: 'traySettingsProvider')
class TraySettings extends _$TraySettings {
  static const String keyCloseToTray = kTrayCloseToTrayKeyName;
  static const bool defaultCloseToTray = kDefaultTrayCloseToTray;

  late final DeviceSettings _settings;
  Future<void> _ready = Future.value();

  @override
  TraySettingsState build() {
    _settings = ref.watch(deviceSettingsProvider);
    _ready = _load();
    return const TraySettingsState(closeToTray: defaultCloseToTray);
  }

  bool get closeToTray => state.closeToTray;
  Future<void> get preferencesReady => _ready;

  Future<void> init() => _ready = _load();

  Future<void> _load() async {
    final value = await _settings.read(kTrayCloseToTrayKey);
    state = TraySettingsState(closeToTray: value);
  }

  Future<void> setCloseToTray(bool value) async {
    if (state.closeToTray == value) return;
    state = TraySettingsState(closeToTray: value);
    await _settings.write(kTrayCloseToTrayKey, value);
  }
}
