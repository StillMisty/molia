import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/database_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 数据库迁移测试：v3 → v4 新增 play_events 且保留旧数据。
void main() {
  sqfliteFfiInit();

  late Directory tempDir;
  late String path;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('molia_migration_test');
    path = '${tempDir.path}/molia.db';
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // 清理失败不影响测试结果。
    }
  });

  test('v3 → v4：补建 play_events，旧表数据原样保留', () async {
    // 以 v3 打开：仅老 schema（play_contexts + 资料库表）。
    var db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (database, version) async {
          await DatabaseHelper.createPlayContextsSchema(database);
          await DatabaseHelper.createLibrarySchema(database);
        },
      ),
    );
    await db.insert('play_history', {
      'sourceKey': 'wy',
      'songId': 'kept',
      'title': '旧数据',
      'playedAt': 111,
    });
    expect(
      await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'play_events'",
      ),
      isEmpty,
    );
    await db.close();

    // 以当前版本重新打开：onUpgrade 走 upgradeSchema。
    db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.dbVersion,
        onUpgrade: (database, oldVersion, newVersion) =>
            DatabaseHelper.upgradeSchema(database, oldVersion, newVersion),
      ),
    );

    final history = await db.query('play_history');
    expect(history, hasLength(1));
    expect(history.single['songId'], 'kept');
    expect(history.single['playedAt'], 111);

    // 新表可用（写入 + 读出）。
    await db.insert('play_events', {
      'sourceKey': 'kw',
      'songId': '1',
      'title': 'T',
      'startedAt': 1000,
      'endedAt': 2000,
      'endReason': 'completed',
    });
    final events = await db.query('play_events');
    expect(events, hasLength(1));
    expect(events.single['endReason'], 'completed');

    await db.close();
  });

  test('全新建库（createSchema）包含统计表', () async {
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.dbVersion,
        onCreate: (database, version) => DatabaseHelper.createSchema(database),
      ),
    );

    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final names = tables.map((row) => row['name']).toSet();
    expect(names, contains('play_events'));
    expect(names, contains('play_history'));
    expect(names, contains('playlists'));
    expect(names, contains('play_contexts'));

    await db.close();
  });
}
