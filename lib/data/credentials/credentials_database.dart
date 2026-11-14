/// 本机凭据库：B 站 Cookie / AI Key / scrobble Token / 同步口令 / WebDAV 密码。
///
/// 为什么单独一个 SQLite 文件：凭据与资料库的生命周期不同——资料库可以按
/// 产品迭代整库重建，凭据在换库 / 迁移时仍要保留；独立文件也避免凭据表进入
/// 资料库 schema 的迁移链。
///
/// **安全口径（明确取舍）**：本库是普通 SQLite，明文落盘。应用沙箱 / 本机
/// 文件权限之外没有额外加密；能读到本机数据库的用户也能读到凭据。这是
/// 「无系统钥匙串环境也能启动与使用」的代价（见 ADR-0016 修订）。
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../files/app_data_directory.dart';
import '../molia_database.dart' show MoliaDatabase;

part 'credentials_database.g.dart';

/// 凭据键值表：键名与 `SettingsValueStore.secure` 的设置键同名。
class Credentials extends Table {
  TextColumn get key => text()();

  TextColumn get value => text()();

  /// 最后写入时间（毫秒时间戳；诊断 / 同步戳参考，不做业务判断）。
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

@DriftDatabase(tables: [Credentials])
class CredentialsDatabase extends _$CredentialsDatabase {
  CredentialsDatabase(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());

  static const String fileName = 'molia_credentials_v1';

  static CredentialsDatabase? _instance;

  /// 懒打开：首个凭据读写才碰文件；与资料库一样放应用数据目录。
  static CredentialsDatabase get instance =>
      _instance ??= CredentialsDatabase(_open());

  static QueryExecutor _open() => DatabaseConnection.delayed(
    Future(() async {
      final directory = await appDataDirectory();
      final tempDirectory = await getTemporaryDirectory();
      final file = File(p.join(directory.path, '$fileName.sqlite'));
      return MoliaDatabase.openAt(file, tempDirectory);
    }),
  );

  @override
  Future<void> close() async {
    if (identical(_instance, this)) _instance = null;
    await super.close();
  }
}
