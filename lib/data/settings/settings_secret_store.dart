import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';

/// 安全存储的最小接口（测试注入内存实现）。
abstract interface class SettingsSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// 生产实现：flutter_secure_storage（桌面端依赖系统 keyring）。
///
/// **读取必须容错**：本机没有系统钥匙串（WSLg / 容器 / 无 keyring 的最小
/// 桌面）时 libsecret 抛 `PlatformException`，语义上等价于「没有存过这个
/// 口令」，不能把异常抛给调用方——同步是可选子系统，它的小故障不允许
/// 阻断应用启动（历史回归：`SyncProvider.init` 在 `runApp` 前抛异常，
/// 表现为桌面端永久黑窗，见 docs/pitfalls.md #31）。
///
/// 写入 / 删除保持抛出：那是用户主动操作，失败必须让调用方知道没存进去。
class SecureSettingsSecretStore implements SettingsSecretStore {
  const SecureSettingsSecretStore();

  static final Logger _logger = Logger('molia.settings_secret_store');
  static bool _readFailureLogged = false;

  FlutterSecureStorage get _storage => _secureStorage;

  /// macOS 走传统 Keychain（`usesDataProtectionKeychain: false`）：
  /// 数据保护钥匙串需要 `keychain-access-groups` 权限，而该权限要求
  /// provisioning profile；本仓的 macOS 产物是 ad-hoc 签名、无开发者账号，
  /// 加上它会让构建产物只能在构建机上启动（见 flutter_secure_storage
  /// README「macOS: Keychain Sharing requires provisioning」）。
  static final FlutterSecureStorage _secureStorage =
      defaultTargetPlatform == TargetPlatform.macOS
          ? const FlutterSecureStorage(
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            )
          : const FlutterSecureStorage();

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on PlatformException catch (e) {
      _logReadFailure(key, e);
      return null;
    } on MissingPluginException catch (e) {
      _logReadFailure(key, e);
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  /// 只记一次：每次读口令都打会刷屏（同步页 / 定时轮询都会读）。
  static void _logReadFailure(String key, Object error) {
    if (_readFailureLogged) return;
    _readFailureLogged = true;
    _logger.warning('安全存储读取失败（按「未设置」处理）: $key -> $error');
  }
}
