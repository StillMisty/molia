import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/any_listen.dart';

/// 领域模型已迁移到 `lib/domain/models/any_listen.dart`（Wave 7 分层收口），
/// 这里 export 以保持既有 `sources/any_listen/any_listen_config.dart`
/// import 的下游（测试/适配器/管理器）零改动。
export '../../domain/models/any_listen.dart' show AnyListenConfig;

/// [AnyListenConfig] 的 shared_preferences 持久化。
///
/// 「零影响」原则：读取失败（如测试环境无插件、存储损坏）静默返回默认配置，
/// 写入失败返回 false，由调用方决定是否提示，绝不抛出未捕获异常。
class AnyListenConfigStore {
  Future<AnyListenConfig> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return AnyListenConfig(
        serverUrl: AnyListenConfig.normalizeServerUrl(
          prefs.getString(AnyListenConfig.prefsServerUrlKey) ?? '',
        ),
        token: prefs.getString(AnyListenConfig.prefsTokenKey) ?? '',
        enabled: prefs.getBool(AnyListenConfig.prefsEnabledKey) ?? false,
      );
    } catch (_) {
      return AnyListenConfig.empty;
    }
  }

  /// 保存配置，成功返回 true。
  Future<bool> save(AnyListenConfig config) async {
    try {
      final normalized = config.normalizedCopy();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          AnyListenConfig.prefsServerUrlKey, normalized.serverUrl);
      await prefs.setString(AnyListenConfig.prefsTokenKey, normalized.token);
      await prefs.setBool(AnyListenConfig.prefsEnabledKey, normalized.enabled);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 清空配置，成功返回 true。
  Future<bool> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(AnyListenConfig.prefsServerUrlKey);
      await prefs.remove(AnyListenConfig.prefsTokenKey);
      await prefs.remove(AnyListenConfig.prefsEnabledKey);
      return true;
    } catch (_) {
      return false;
    }
  }
}
