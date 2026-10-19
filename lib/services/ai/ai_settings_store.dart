/// AI 推歌配置存储：LLM 连接信息（secure 盒）+ 确认 / 开关 / 缓存偏好。
///
/// - Base URL / API Key / 模型走 secure 盒（生产 = `flutter_secure_storage`，
///   桌面端依赖系统 keyring），随凭证类别加密同步；
/// - 确认标记 / 功能开关 / 缓存有效期走普通 prefs（跟人走）；
/// - 读取失败/缺项一律降级为「未配置」，不抛异常（页面据此引导）。
library;

import '../../data/settings/settings_access.dart';
import '../../data/settings/settings_keys.dart';
import '../../domain/models/ai_dj.dart';

class AiSettingsStore {
  AiSettingsStore({required SettingsAccess settings}) : _settings = settings;

  final SettingsAccess _settings;

  /// 读取配置；缺项/读取失败返回 null（调用方引导填写）。
  Future<LlmConfig?> readConfig() async {
    try {
      final baseUrl = await _settings.read(kAiDjBaseUrl);
      final apiKey = await _settings.read(kAiDjApiKey);
      final model = await _settings.read(kAiDjModel);
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
    await _settings.write(kAiDjBaseUrl, config.baseUrl.trim());
    await _settings.write(kAiDjApiKey, config.apiKey.trim());
    await _settings.write(kAiDjModel, config.model.trim());
  }

  Future<void> clearConfig() async {
    await _settings.clear(kAiDjBaseUrl);
    await _settings.clear(kAiDjApiKey);
    await _settings.clear(kAiDjModel);
  }

  /// 是否已确认隐私说明。
  Future<bool> hasConsent() async {
    try {
      return await _settings.read(kAiDjConsent);
    } catch (_) {
      return false;
    }
  }

  Future<void> grantConsent() => _settings.write(kAiDjConsent, true);

  /// 撤销确认（关闭 AI 推歌时可选调用）。
  Future<void> revokeConsent() => _settings.clear(kAiDjConsent);

  /// 功能启用状态（默认关闭：AI 是可选功能）。
  Future<bool> readEnabled() async {
    try {
      return await _settings.read(kAiDjEnabled);
    } catch (_) {
      return false;
    }
  }

  Future<void> saveEnabled(bool enabled) =>
      _settings.write(kAiDjEnabled, enabled);

  /// 推荐列表缓存有效期（天；非法值回退默认；0 = 永久）。
  Future<int> readCacheTtlDays() async {
    final value = await _settings.read(kAiDjCacheTtlDays);
    if (!kAiCacheTtlDayOptions.contains(value)) {
      return kAiDefaultCacheTtlDays;
    }
    return value;
  }

  Future<void> saveCacheTtlDays(int days) async {
    if (!kAiCacheTtlDayOptions.contains(days)) return;
    await _settings.write(kAiDjCacheTtlDays, days);
  }
}
