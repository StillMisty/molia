import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 安全存储的最小接口（测试注入内存实现）。
abstract interface class SettingsSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// 生产实现：flutter_secure_storage（桌面端依赖系统 keyring）。
class SecureSettingsSecretStore implements SettingsSecretStore {
  const SecureSettingsSecretStore();

  FlutterSecureStorage get _storage => const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
