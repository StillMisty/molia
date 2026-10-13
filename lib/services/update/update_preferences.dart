import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/app_release.dart';

/// 应用内更新的本地偏好（SharedPreferences 直连）。
///
/// 这些键都是设备本地项（更新渠道 / 镜像在不同设备可以不同，且只有一个
/// 消费者），按仓库约定不登记进 `SettingsRegistry`（见 settings_keys.dart
/// 的分档说明）。
class UpdatePreferences {
  UpdatePreferences({SharedPreferences? prefs}) : _prefsOverride = prefs;

  static const String keyAutoCheck = 'update_auto_check';
  static const String keyChannel = 'update_channel';
  static const String keyManifestOverride = 'update_manifest_override';
  static const String keyDownloadPrefix = 'update_download_prefix';
  static const String keyLastCheckAt = 'update_last_check_at';

  /// 自动检查默认关闭：更新是低频行为，且桌面端会自动替换文件，
  /// 必须由用户显式开启（设置页「自动检查更新」）。
  static const bool defaultAutoCheck = false;
  static const UpdateChannel defaultChannel = UpdateChannel.stable;

  final SharedPreferences? _prefsOverride;
  SharedPreferences? _prefs;

  bool _autoCheck = defaultAutoCheck;
  UpdateChannel _channel = defaultChannel;
  String _manifestOverride = '';
  String _downloadPrefix = '';
  DateTime? _lastCheckedAt;

  bool get autoCheckEnabled => _autoCheck;
  UpdateChannel get channel => _channel;
  String get manifestUrlOverride => _manifestOverride;
  String get downloadPrefix => _downloadPrefix;
  DateTime? get lastCheckedAt => _lastCheckedAt;

  Future<void> load() async {
    final prefs = await _prefsInstance();
    try {
      _autoCheck = prefs.getBool(keyAutoCheck) ?? defaultAutoCheck;
      _channel = UpdateChannel.fromWire(
        prefs.getString(keyChannel) ?? defaultChannel.wireName,
      );
      _manifestOverride = prefs.getString(keyManifestOverride) ?? '';
      _downloadPrefix = prefs.getString(keyDownloadPrefix) ?? '';
      final lastCheck = prefs.getInt(keyLastCheckAt);
      _lastCheckedAt = lastCheck == null || lastCheck <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastCheck);
    } catch (_) {
      // 读取失败保持默认值：更新配置坏了不应该影响启动。
    }
  }

  Future<void> setAutoCheckEnabled(bool value) async {
    _autoCheck = value;
    await _write(keyAutoCheck, value);
  }

  Future<void> setChannel(UpdateChannel channel) async {
    _channel = channel;
    await _write(keyChannel, channel.wireName);
  }

  Future<void> setManifestUrlOverride(String value) async {
    _manifestOverride = value.trim();
    await _write(keyManifestOverride, _manifestOverride);
  }

  Future<void> setDownloadPrefix(String value) async {
    _downloadPrefix = value.trim();
    await _write(keyDownloadPrefix, _downloadPrefix);
  }

  Future<void> markChecked(DateTime at) async {
    _lastCheckedAt = at;
    await _write(keyLastCheckAt, at.millisecondsSinceEpoch);
  }

  Future<void> _write(String key, Object value) async {
    try {
      final prefs = await _prefsInstance();
      if (value is bool) {
        await prefs.setBool(key, value);
      } else if (value is int) {
        await prefs.setInt(key, value);
      } else {
        await prefs.setString(key, value.toString());
      }
    } catch (_) {
      // 持久化失败只丢偏好：内存值已更新，本次会话内仍然生效。
    }
  }

  Future<SharedPreferences> _prefsInstance() async =>
      _prefs ??= _prefsOverride ?? await SharedPreferences.getInstance();
}
