import '../../data/settings/settings_keys.dart';
import '../../data/settings/settings_registry.dart';
import '../../domain/models/any_listen.dart';

/// 领域模型定义在 `lib/domain/models/any_listen.dart`，这里 export 以保持既有
/// `sources/any_listen/any_listen_config.dart` import 的下游（测试/适配器/管理器）
/// 零改动。
export '../../domain/models/any_listen.dart' show AnyListenConfig;

/// [AnyListenConfig] 的持久化（经设置注册表，键见 settings_keys.dart）。
///
/// 「零影响」原则：读取失败（如测试环境无插件、存储损坏）静默返回默认配置，
/// 写入失败返回 false，由调用方决定是否提示，绝不抛出未捕获异常。
class AnyListenConfigStore {
  AnyListenConfigStore({SettingsRegistry? settings})
      : _settings = settings ?? SettingsRegistry(keys: kAllSettingsKeys);

  final SettingsRegistry _settings;

  Future<AnyListenConfig> load() async {
    try {
      return AnyListenConfig(
        serverUrl: AnyListenConfig.normalizeServerUrl(
          await _settings.read(kAnyListenServerUrl),
        ),
        token: await _settings.read(kAnyListenToken),
        enabled: await _settings.read(kAnyListenEnabled),
      );
    } catch (_) {
      return AnyListenConfig.empty;
    }
  }

  /// 保存配置，成功返回 true。
  Future<bool> save(AnyListenConfig config) async {
    try {
      final normalized = config.normalizedCopy();
      await _settings.write(kAnyListenServerUrl, normalized.serverUrl);
      await _settings.write(kAnyListenToken, normalized.token);
      await _settings.write(kAnyListenEnabled, normalized.enabled);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 清空配置，成功返回 true。
  Future<bool> clear() async {
    try {
      await _settings.clear(kAnyListenServerUrl);
      await _settings.clear(kAnyListenToken);
      await _settings.clear(kAnyListenEnabled);
      return true;
    } catch (_) {
      return false;
    }
  }
}
