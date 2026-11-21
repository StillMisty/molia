/// 听歌同步的设备本地偏好与凭证读取。
///
/// 边界（ADR-0016 / 规格）：
/// - 访问口令 / 会话密钥 = 凭证类别，走 secure 盒并参与凭证同步
///   （[SettingsAccess] 只拿登记键）；
/// - 总开关、单个服务开关、同意标记、账号 = **设备本地**，走
///   `DeviceSettings`，不登记进设置注册表 —— 另一台设备同步凭据也不能悄悄
///   开始上报。
library;

import '../../data/settings/device_settings.dart';
import '../../data/settings/device_settings_keys.dart';
import '../../data/settings/settings_access.dart';
import '../../data/settings/settings_key.dart';
import '../../data/settings/settings_keys.dart';
import '../../domain/models/scrobble.dart';

/// 同意条款版本：文案或发送字段变化时递增，UI 会重新要求确认。
const int kScrobbleConsentVersion = 1;

class ScrobblePreferences {
  /// [deviceSettings] 仅测试注入；生产构造自己的设备本地入口。
  /// [settings] 是凭证键的窄作用域，与设备本地开关无关。
  ScrobblePreferences({required this._settings, DeviceSettings? deviceSettings})
    : _deviceSettings = deviceSettings ?? DeviceSettings();

  static const String keyMasterEnabled = kScrobbleMasterEnabledKeyName;
  static const String keyListenBrainzEnabled =
      kScrobbleListenBrainzEnabledKeyName;
  static const String keyLastFmEnabled = kScrobbleLastFmEnabledKeyName;
  static const String keyListenBrainzConsent =
      kScrobbleListenBrainzConsentKeyName;
  static const String keyLastFmConsent = kScrobbleLastFmConsentKeyName;
  static const String keyListenBrainzAccount =
      kScrobbleListenBrainzAccountKeyName;
  static const String keyLastFmAccount = kScrobbleLastFmAccountKeyName;

  final SettingsAccess _settings;
  final DeviceSettings _deviceSettings;

  bool _masterEnabled = false;
  bool _listenBrainzEnabled = false;
  bool _lastFmEnabled = false;
  int _listenBrainzConsent = 0;
  int _lastFmConsent = 0;
  String _listenBrainzAccount = '';
  String _lastFmAccount = '';

  bool get masterEnabled => _masterEnabled;

  bool enabledFor(ScrobbleTarget target) => switch (target) {
    ScrobbleTarget.listenBrainz => _listenBrainzEnabled,
    ScrobbleTarget.lastFm => _lastFmEnabled,
  };

  bool consentFor(ScrobbleTarget target) =>
      consentVersionFor(target) >= kScrobbleConsentVersion;

  int consentVersionFor(ScrobbleTarget target) => switch (target) {
    ScrobbleTarget.listenBrainz => _listenBrainzConsent,
    ScrobbleTarget.lastFm => _lastFmConsent,
  };

  String accountFor(ScrobbleTarget target) => switch (target) {
    ScrobbleTarget.listenBrainz => _listenBrainzAccount,
    ScrobbleTarget.lastFm => _lastFmAccount,
  };

  /// 读取设备本地偏好；存储不可用时按键默认（关闭）处理。
  Future<void> init() async {
    _masterEnabled = await _deviceSettings.read(kScrobbleMasterEnabledKey);
    _listenBrainzEnabled = await _deviceSettings.read(
      kScrobbleListenBrainzEnabledKey,
    );
    _lastFmEnabled = await _deviceSettings.read(kScrobbleLastFmEnabledKey);
    _listenBrainzConsent = await _deviceSettings.read(
      kScrobbleListenBrainzConsentKey,
    );
    _lastFmConsent = await _deviceSettings.read(kScrobbleLastFmConsentKey);
    _listenBrainzAccount = await _deviceSettings.read(
      kScrobbleListenBrainzAccountKey,
    );
    _lastFmAccount = await _deviceSettings.read(kScrobbleLastFmAccountKey);
  }

  Future<void> setMasterEnabled(bool value) async {
    _masterEnabled = value;
    await _deviceSettings.write(kScrobbleMasterEnabledKey, value);
  }

  Future<void> setEnabled(ScrobbleTarget target, bool value) async {
    switch (target) {
      case ScrobbleTarget.listenBrainz:
        _listenBrainzEnabled = value;
      case ScrobbleTarget.lastFm:
        _lastFmEnabled = value;
    }
    await _deviceSettings.write(_enabledKey(target), value);
  }

  Future<void> recordConsent(ScrobbleTarget target) async {
    switch (target) {
      case ScrobbleTarget.listenBrainz:
        _listenBrainzConsent = kScrobbleConsentVersion;
      case ScrobbleTarget.lastFm:
        _lastFmConsent = kScrobbleConsentVersion;
    }
    await _deviceSettings.write(_consentKey(target), kScrobbleConsentVersion);
  }

  Future<void> setAccount(ScrobbleTarget target, String account) async {
    switch (target) {
      case ScrobbleTarget.listenBrainz:
        _listenBrainzAccount = account;
      case ScrobbleTarget.lastFm:
        _lastFmAccount = account;
    }
    await _deviceSettings.write(_accountKey(target), account);
  }

  Future<String> readCredential(ScrobbleTarget target) async {
    try {
      final value = await _settings.read(_credentialKey(target));
      return value.trim();
    } catch (_) {
      return '';
    }
  }

  Future<void> writeCredential(ScrobbleTarget target, String value) =>
      _settings.write(_credentialKey(target), value.trim());

  Future<void> clearCredential(ScrobbleTarget target) =>
      _settings.clear(_credentialKey(target));

  static DeviceSettingKey<bool> _enabledKey(ScrobbleTarget target) =>
      switch (target) {
        ScrobbleTarget.listenBrainz => kScrobbleListenBrainzEnabledKey,
        ScrobbleTarget.lastFm => kScrobbleLastFmEnabledKey,
      };

  static DeviceSettingKey<int> _consentKey(ScrobbleTarget target) =>
      switch (target) {
        ScrobbleTarget.listenBrainz => kScrobbleListenBrainzConsentKey,
        ScrobbleTarget.lastFm => kScrobbleLastFmConsentKey,
      };

  static DeviceSettingKey<String> _accountKey(ScrobbleTarget target) =>
      switch (target) {
        ScrobbleTarget.listenBrainz => kScrobbleListenBrainzAccountKey,
        ScrobbleTarget.lastFm => kScrobbleLastFmAccountKey,
      };

  static SettingsKey<String> _credentialKey(ScrobbleTarget target) =>
      switch (target) {
        ScrobbleTarget.listenBrainz => kListenBrainzToken,
        ScrobbleTarget.lastFm => kLastFmSessionKey,
      };
}
