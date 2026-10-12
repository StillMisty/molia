/// AI 推歌配置存储：LLM 连接信息（安全存储）+ 隐私确认（SharedPreferences）。
///
/// - Base URL / API Key / 模型走安全存储（生产 = `flutter_secure_storage`，
///   沿用 `SettingsService` 模式；桌面端依赖系统 keyring）；
/// - 确认标记走 SharedPreferences（非敏感）；
/// - 读取失败/缺项一律降级为「未配置」，不抛异常（页面据此引导）。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/ai_dj.dart';
/// 密钥键值存储的最小接口（测试注入内存实现）。
abstract interface class AiSecretStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// 生产实现：flutter_secure_storage。
class SecureAiSecretStorage implements AiSecretStorage {
  const SecureAiSecretStorage();

  FlutterSecureStorage get _storage => const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class AiSettingsStore {
  /// [secrets] / [preferences] 仅测试注入；生产走默认实现。
  AiSettingsStore({
    AiSecretStorage? secrets,
    SharedPreferences? preferences,
  })  : _secrets = secrets ?? const SecureAiSecretStorage(),
        _preferences = preferences;

  static const String baseUrlKey = 'ai_dj_base_url';
  static const String apiKeyKey = 'ai_dj_api_key';
  static const String modelKey = 'ai_dj_model';

  /// 首次开启前的隐私确认标记（版本化：内容变化时升 v2 重新确认）。
  static const String consentKey = 'ai_dj_consent_v1';

  /// 功能启用标记（与「推歌会话」解耦：退出队列不关功能）。
  static const String enabledKey = 'ai_dj_enabled';

  /// 推荐列表缓存有效期（天；0 = 永久）。
  static const String cacheTtlDaysKey = 'ai_dj_cache_ttl_days';

  final AiSecretStorage _secrets;
  final SharedPreferences? _preferences;

  Future<SharedPreferences?> _prefsOrNull() async {
    try {
      return _preferences ?? await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  /// 读取配置；缺项/读取失败返回 null（调用方引导填写）。
  Future<LlmConfig?> readConfig() async {
    try {
      final baseUrl = await _secrets.read(baseUrlKey) ?? '';
      final apiKey = await _secrets.read(apiKeyKey) ?? '';
      final model = await _secrets.read(modelKey) ?? '';
      final config = LlmConfig(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
      );
      return config.isComplete ? config : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveConfig(LlmConfig config) async {
    await _secrets.write(baseUrlKey, config.baseUrl.trim());
    await _secrets.write(apiKeyKey, config.apiKey.trim());
    await _secrets.write(modelKey, config.model.trim());
  }

  Future<void> clearConfig() async {
    await _secrets.delete(baseUrlKey);
    await _secrets.delete(apiKeyKey);
    await _secrets.delete(modelKey);
  }

  /// 是否已确认隐私说明。
  Future<bool> hasConsent() async {
    final prefs = await _prefsOrNull();
    return prefs?.getBool(consentKey) ?? false;
  }

  Future<void> grantConsent() async {
    final prefs = await _prefsOrNull();
    await prefs?.setBool(consentKey, true);
  }

  /// 撤销确认（关闭 AI 推歌时可选调用）。
  Future<void> revokeConsent() async {
    final prefs = await _prefsOrNull();
    await prefs?.remove(consentKey);
  }

  /// 功能启用状态（默认关闭：AI 是可选功能）。
  Future<bool> readEnabled() async {
    final prefs = await _prefsOrNull();
    return prefs?.getBool(enabledKey) ?? false;
  }

  Future<void> saveEnabled(bool enabled) async {
    final prefs = await _prefsOrNull();
    await prefs?.setBool(enabledKey, enabled);
  }

  /// 推荐列表缓存有效期（天；非法值回退默认；0 = 永久）。
  Future<int> readCacheTtlDays() async {
    final prefs = await _prefsOrNull();
    final value = prefs?.getInt(cacheTtlDaysKey);
    if (value == null || !kAiCacheTtlDayOptions.contains(value)) {
      return kAiDefaultCacheTtlDays;
    }
    return value;
  }

  Future<void> saveCacheTtlDays(int days) async {
    if (!kAiCacheTtlDayOptions.contains(days)) return;
    final prefs = await _prefsOrNull();
    await prefs?.setInt(cacheTtlDaysKey, days);
  }
}

