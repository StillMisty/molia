import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';

/// 迁移基线：v1–v5 测试版库打开即整库重建（drop 全部实体 + createAll，
/// 旧数据不保留）；v6 起恢复增量迁移承诺，缺迁移步骤必须显式抛错
/// （决策与代价见 ADR-0005 修订）。
void main() {
  /// 预置一个「测试版旧库」：user_version = 5，且带一张旧形状的表与一行数据。
  NativeDatabase oldVersionDatabase() => NativeDatabase.memory(
        setup: (raw) async {
          raw.execute('PRAGMA user_version = 5;');
          raw.execute('''
            CREATE TABLE playlists (
              id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              createdAt INTEGER NOT NULL,
              updatedAt INTEGER NOT NULL DEFAULT 0,
              updatedBy TEXT NOT NULL DEFAULT ''
            );
          ''');
          raw.execute(
            "INSERT INTO playlists (name, createdAt, updatedAt, updatedBy) "
            "VALUES ('旧歌单', 1, 1, 'old-device');",
          );
          // 旧库还留着会被重建的索引：drop 必须幂等（IF EXISTS）。
          raw.execute(
            'CREATE INDEX idx_playlists_syncId ON playlists (createdAt);',
          );
        },
      );

  test('测试版旧库（v5）打开即整库重建：旧数据清空、新 schema 可读写', () async {
    final db = MoliaDatabase(oldVersionDatabase());
    addTearDown(db.close);

    // 打开触发 onUpgrade(5 → 6)：旧行不保留。
    expect(db.schemaVersion, 6);
    expect(await db.select(db.playlists).get(), isEmpty);

    // 旧形状的列已消失、新版本列就位。
    final columns = [
      for (final row in await db.customSelect('PRAGMA table_info(playlists)').get())
        row.data['name'] as String,
    ];
    expect(columns, contains('versionPhysical'));
    expect(columns, contains('versionCounter'));
    expect(columns, contains('deviceId'));
    expect(columns, isNot(contains('updatedAt')));

    // 全部实体（含索引）按新 schema 重建：新表可写可读。
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(
          name: '新歌单',
          createdAt: 2,
          syncId: const Value('sync-1'),
          versionPhysical: const Value(10),
          deviceId: const Value('device-a'),
        ));
    final rows = await db.select(db.playlists).get();
    expect(rows.single.name, '新歌单');
    expect(rows.single.versionPhysical, 10);

    // 表集合完整（重建后每张表都在）。
    final tables = [
      for (final row in await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
          )
          .get())
        row.data['name'],
    ];
    expect(
      tables,
      containsAll([
        'downloads',
        'play_contexts',
        'play_events',
        'play_history',
        'playlist_tracks',
        'playlists',
        'sync_tombstones',
      ]),
    );

    // 部分唯一索引随重建生效（重复 syncId 被拒）。
    await expectLater(
      db.into(db.playlists).insert(PlaylistsCompanion.insert(
            name: '重复',
            createdAt: 3,
            syncId: const Value('sync-1'),
          )),
      throwsA(anything),
    );
  });

  test('降级打开同样整库重建（版本不同即重建，不崩）', () async {
    final db = MoliaDatabase(
      NativeDatabase.memory(
        setup: (raw) async {
          // 一个「未来版本」的库：打开时 to < from，走整库重建分支。
          raw.execute('PRAGMA user_version = 99;');
          raw.execute('''
            CREATE TABLE playlists (
              id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              createdAt INTEGER NOT NULL
            );
          ''');
          raw.execute("INSERT INTO playlists (name, createdAt) VALUES ('未来歌单', 1);");
        },
      ),
    );
    addTearDown(db.close);

    // 已知 schema 实体按当前版本重建：旧行清空、旧形状的列消失。
    expect(await db.select(db.playlists).get(), isEmpty);
    final columns = [
      for (final row in await db.customSelect('PRAGMA table_info(playlists)').get())
        row.data['name'] as String,
    ];
    expect(columns, contains('versionPhysical'));
  });

  test('v6 起缺迁移步骤：版本前进必须抛错，不静默重建', () async {
    // 子类把 schemaVersion 抬到 7，模拟「改了表但没写迁移」的开发错误：
    // 打开 v6 库时 onUpgrade(6 → 7) 必须抛 StateError。
    final db = _FutureVersionDatabase(
      NativeDatabase.memory(
        setup: (raw) async => raw.execute('PRAGMA user_version = 6;'),
      ),
    );
    addTearDown(db.close);

    await expectLater(
      db.select(db.playlists).get(),
      throwsA(isA<StateError>()),
    );
  });

  test('外键 pragma 在打开后开启（beforeOpen 契约不变）', () async {
    final db = MoliaDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final pragma = await db.customSelect('PRAGMA foreign_keys').getSingle();
    expect(pragma.data.values.single, 1);
  });
}

/// 只抬高 schemaVersion 的测试替身：模拟未接入迁移的下一次结构变更。
class _FutureVersionDatabase extends MoliaDatabase {
  _FutureVersionDatabase(super.e);

  @override
  int get schemaVersion => 7;
}
