import 'package:drift/native.dart';
import 'package:molia/data/molia_database.dart';

/// 测试用内存数据库：schema 与生产一致（首个查询才建表建连接）。
///
/// 生产库的执行器只走 drift_flutter（见 lib/data/molia_database.dart）；
/// `NativeDatabase.memory()` 仅测试使用。关闭由调用方负责（`await db.close()`）。
MoliaDatabase openMemoryDatabase() => MoliaDatabase(NativeDatabase.memory());

/// 按原列名读出一张表的全部行（断言沿用列名取值，不关心 drift 行类型）。
Future<List<Map<String, Object?>>> tableRows(
  MoliaDatabase db,
  String table,
) async {
  final rows = await db.customSelect('SELECT * FROM $table').get();
  return [for (final row in rows) row.data];
}
