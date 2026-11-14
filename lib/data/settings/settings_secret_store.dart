import 'package:logging/logging.dart';

import '../credentials/credentials_database.dart';

/// 凭据存储的最小接口（测试注入内存实现）。
abstract interface class SettingsSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// 生产实现：本机凭据库（`molia_credentials_v1.sqlite`，明文 SQLite）。
///
/// 这是明确的取舍：不再依赖系统钥匙串 / Keystore，因此没有钥匙串的
/// WSLg / 容器里也不会在启动或读凭据时被 libsecret 原生异常终止；代价是
/// 凭据明文落盘，能读本机数据目录的用户也能读到。同步载荷仍由同步口令
/// 加密，口令本身只在本机凭据库中保存（见 ADR-0016 修订）。
class DatabaseSettingsSecretStore implements SettingsSecretStore {
  const DatabaseSettingsSecretStore({this.database});

  /// 测试注入内存库；生产为 null，使用懒加载的进程单例。
  final CredentialsDatabase? database;
  static final Logger _logger = Logger('molia.settings_secret_store');

  CredentialsDatabase get _db => database ?? CredentialsDatabase.instance;

  @override
  Future<String?> read(String key) async {
    try {
      final row = await (_db.select(
        _db.credentials,
      )..where((row) => row.key.equals(key))).getSingleOrNull();
      return row?.value;
    } catch (e) {
      // 读取失败按「未设置」处理：可选子系统不能阻断启动 / 播放。
      _logger.warning('凭据读取失败（按未设置处理）: $key -> $e');
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    await _db
        .into(_db.credentials)
        .insertOnConflictUpdate(
          CredentialsCompanion.insert(
            key: key,
            value: value,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
  }

  @override
  Future<void> delete(String key) async {
    await (_db.delete(
      _db.credentials,
    )..where((row) => row.key.equals(key))).go();
  }
}
