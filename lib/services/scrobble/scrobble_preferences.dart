/// 听歌同步的设备本地偏好与凭证读取。
///
/// 边界（ADR-0016 / 规格）：
/// - 访问口令 / 会话密钥 = 凭证类别，走 secure 盒并参与凭证同步
///   （[SettingsAccess] 只拿登记键）；
/// - 总开关、单个服务开关、同意标记 = **设备本地**，留在 SharedPreferences，
///   不登记进设置注册表 —— 另一台设备同步凭据也不能悄悄开始上报。
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../../data/settings/settings_access.dart';
import '../../data/settings/settings_keys.dart';
import '../../domain/models/scrobble.dart';

/// 同意条款版本：文案或发送字段变化时递增，UI 会重新要求确认。
const int kScrobbleConsentVersion = 1;

class ScrobblePreferences {
  ScrobblePreferences({required this._settings, SharedPreferences? prefs})
    : _prefsOverride = prefs;

  static const String keyMasterEnabled = 'scrobble_master_enabled_v1';
  static const String keyListenBrainzEnabled =
      'scrobble_listenbrainz_enabled_v1';
  static const String keyListenBrainzConsent =
      'scrobble_listenbrainz_consent_v1';
  static const String keyListenBrainzAccount =
      'scrobble_listenbrainz_account_v1';

  final SettingsAccess _settings;
  final SharedPreferences? _prefsOverride;
  SharedPreferences? _prefs;

  bool _masterEnabled = false;
  bool _listenBrainzEnabled = false;
  int _listenBrainzConsent = 0;
  String _listenBrainzAccount = '';

  bool get masterEnabled => _masterEnabled;

  bool enabledFor(ScrobbleTarget target) => _listenBrainzEnabled;

  bool consentFor(ScrobbleTarget target) =>
      consentVersionFor(target) >= kScrobbleConsentVersion;

  int consentVersionFor(ScrobbleTarget target) => _listenBrainzConsent;

  String accountFor(ScrobbleTarget target) => _listenBrainzAccount;

  Future<SharedPreferences> _prefsStore() async =>
      _prefs ??= _prefsOverride ?? await SharedPreferences.getInstance();

  /// 读取设备本地偏好；存储不可用时保持默认（关闭）。
  Future<void> init() async {
    try {
      final prefs = await _prefsStore();
      _masterEnabled = prefs.getBool(keyMasterEnabled) ?? false;
      _listenBrainzEnabled = prefs.getBool(keyListenBrainzEnabled) ?? false;
      _listenBrainzConsent = prefs.getInt(keyListenBrainzConsent) ?? 0;
      _listenBrainzAccount = prefs.getString(keyListenBrainzAccount) ?? '';
    } catch (_) {
      // 设备本地偏好读不到 = 未开启；不阻塞启动。
    }
  }

  Future<void> setMasterEnabled(bool value) async {
    _masterEnabled = value;
    try {
      final prefs = await _prefsStore();
      await prefs.setBool(keyMasterEnabled, value);
    } catch (_) {}
  }

  Future<void> setEnabled(ScrobbleTarget target, bool value) async {
    _listenBrainzEnabled = value;
    try {
      final prefs = await _prefsStore();
      await prefs.setBool(keyListenBrainzEnabled, value);
    } catch (_) {}
  }

  Future<void> recordConsent(ScrobbleTarget target) async {
    _listenBrainzConsent = kScrobbleConsentVersion;
    try {
      final prefs = await _prefsStore();
      await prefs.setInt(keyListenBrainzConsent, kScrobbleConsentVersion);
    } catch (_) {}
  }

  Future<void> setAccount(ScrobbleTarget target, String account) async {
    _listenBrainzAccount = account;
    try {
      final prefs = await _prefsStore();
      await prefs.setString(keyListenBrainzAccount, account);
    } catch (_) {}
  }

  Future<String> readCredential(ScrobbleTarget target) async {
    try {
      final value = await _settings.read(kListenBrainzToken);
      return value.trim();
    } catch (_) {
      return '';
    }
  }

  Future<void> writeCredential(ScrobbleTarget target, String value) =>
      _settings.write(kListenBrainzToken, value.trim());

  Future<void> clearCredential(ScrobbleTarget target) =>
      _settings.clear(kListenBrainzToken);
}
