/// 数据库完整性辅助：把 `PRAGMA` 探测收在 data 层，服务层只消费类型化结果。
///
/// 只读、不迁移、不修复；调用方负责超时与结果映射。
library;

import '../molia_database.dart';

/// 读取 SQLite `user_version`（drift 打开库时把 schemaVersion 写在这里）。
///
/// 返回 null 表示读不到（执行器不可用 / 行结构异常）；原始异常仍向上抛，
/// 由检查实现归一化。
Future<int?> readMoliaSchemaVersion([MoliaDatabase? database]) async {
  final db = database ?? MoliaDatabase.instance;
  final rows = await db.customSelect('PRAGMA user_version').get();
  if (rows.isEmpty) return null;
  final value = rows.first.data.values.first;
  if (value is int) return value;
  return int.tryParse('$value');
}

/// 执行 `PRAGMA quick_check`：只有首行 `ok` 才算通过。
///
/// 数据库损坏时 SQLite 会返回一行或多行问题描述；这里只保留"是否通过"，
/// 原始描述不进入诊断结果（可能带表名 / 行号等内部信息）。
Future<bool> moliaDatabaseQuickCheck([MoliaDatabase? database]) async {
  final db = database ?? MoliaDatabase.instance;
  final rows = await db.customSelect('PRAGMA quick_check').get();
  if (rows.isEmpty) return false;
  final value = rows.first.data.values.first;
  return '$value'.trim().toLowerCase() == 'ok';
}
