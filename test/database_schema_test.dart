/// 本地库 schema 回归钉子：drift 声明与建表结果逐字核对。
///
/// 表集合、列名与顺序、类型、NOT NULL、默认值、主键序、UNIQUE、外键级联、
/// 索引文本都在本测试里钉死；任一字段声明或 drift DSL 被改动即红。
///
/// 唯一归一化：`INTEGER PRIMARY KEY`（rowid 别名）插入 NULL 时会自动分配
/// rowid，PRAGMA 元数据报 notnull=0，而 drift 生成的 DDL 显式写 NOT NULL——
/// 行为一致，只差元数据，比较前统一按 0 处理。
library;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';

void main() {
  late MoliaDatabase db;

  setUp(() => db = MoliaDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<List<Map<String, Object?>>> rowsOf(String sql) async =>
      [for (final row in await db.customSelect(sql).get()) row.data];

  /// `PRAGMA table_info` 快照行：`名称|类型|NOT NULL|默认值|主键序`。
  String columnSnapshot(Map<String, Object?> row) {
    final type = row['type'] as String;
    final pk = row['pk'] as int;
    final notNull = type == 'INTEGER' && pk > 0 ? 0 : row['notnull'] as int;
    return '${row['name']}|$type|$notNull|${row['dflt_value']}|$pk';
  }

  test('外键在打开数据库时已开启（beforeOpen 契约）', () async {
    final pragma = await rowsOf('PRAGMA foreign_keys');
    expect(pragma.single.values.single, 1);
  });

  test('表集合完整', () async {
    final rows = await rowsOf(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
    );
    expect(
      [for (final row in rows) row['name']],
      [
        'downloads',
        'play_contexts',
        'play_events',
        'play_history',
        'playlist_tracks',
        'playlists',
        'sqlite_sequence',
        'sync_known',
        'sync_tombstones',
      ],
    );
  });

  test('列定义逐字一致（名/类型/NOT NULL/默认值/主键序）', () async {
    const expected = <String, List<String>>{
      'downloads': [
        'id|INTEGER|0|null|1',
        'originSourceKey|TEXT|1|null|0',
        'originSongId|TEXT|1|null|0',
        'title|TEXT|1|null|0',
        "artist|TEXT|1|''|0",
        "album|TEXT|1|''|0",
        'coverUrl|TEXT|0|null|0',
        'durationMs|INTEGER|0|null|0',
        "raw|TEXT|1|'{}'|0",
        "quality|TEXT|1|''|0",
        'filePath|TEXT|0|null|0',
        'sizeBytes|INTEGER|1|0|0',
        'lyricPath|TEXT|0|null|0',
        'coverPath|TEXT|0|null|0',
        'publicUri|TEXT|0|null|0',
        'imported|INTEGER|1|0|0',
        'downloadedAt|INTEGER|1|null|0',
      ],
      'play_contexts': [
        'contextUri|TEXT|0|null|1',
        'contextType|TEXT|1|null|0',
        'contextName|TEXT|1|null|0',
        'imageUrl|TEXT|0|null|0',
        'lastPlayedAt|INTEGER|1|null|0',
      ],
      'play_history': [
        'sourceKey|TEXT|1|null|0',
        'songId|TEXT|1|null|0',
        'title|TEXT|1|null|0',
        "artist|TEXT|1|''|0",
        "album|TEXT|1|''|0",
        'coverUrl|TEXT|0|null|0',
        'durationMs|INTEGER|0|null|0',
        "raw|TEXT|1|'{}'|0",
        'playedAt|INTEGER|1|null|0',
        'versionPhysical|INTEGER|1|0|0',
        'versionCounter|INTEGER|1|0|0',
        "deviceId|TEXT|1|''|0",
      ],
      'playlists': [
        'id|INTEGER|0|null|1',
        'name|TEXT|1|null|0',
        'createdAt|INTEGER|1|null|0',
        'syncId|TEXT|0|null|0',
        'versionPhysical|INTEGER|1|0|0',
        'versionCounter|INTEGER|1|0|0',
        "deviceId|TEXT|1|''|0",
      ],
      'playlist_tracks': [
        'id|INTEGER|0|null|1',
        'playlistId|INTEGER|1|null|0',
        'sourceKey|TEXT|1|null|0',
        'songId|TEXT|1|null|0',
        'title|TEXT|1|null|0',
        "artist|TEXT|1|''|0",
        "album|TEXT|1|''|0",
        'coverUrl|TEXT|0|null|0',
        'durationMs|INTEGER|0|null|0',
        "raw|TEXT|1|'{}'|0",
        'addedAt|INTEGER|1|null|0',
        'sortOrder|INTEGER|1|0|0',
        'versionPhysical|INTEGER|1|0|0',
        'versionCounter|INTEGER|1|0|0',
        "deviceId|TEXT|1|''|0",
      ],
      'sync_known': [
        'category|TEXT|1|null|1',
        'key|TEXT|1|null|2',
        'versionPhysical|INTEGER|1|null|0',
        'versionCounter|INTEGER|1|0|0',
        "deviceId|TEXT|1|''|0",
      ],
      'sync_tombstones': [
        'category|TEXT|1|null|1',
        'key|TEXT|1|null|2',
        'versionPhysical|INTEGER|1|null|0',
        'versionCounter|INTEGER|1|0|0',
        "deviceId|TEXT|1|''|0",
        'deletedAt|INTEGER|1|0|0',
      ],
      'play_events': [
        'id|INTEGER|0|null|1',
        'sourceKey|TEXT|1|null|0',
        'songId|TEXT|1|null|0',
        "title|TEXT|1|''|0",
        "artist|TEXT|1|''|0",
        "album|TEXT|1|''|0",
        'coverUrl|TEXT|0|null|0',
        'durationMs|INTEGER|0|null|0',
        "raw|TEXT|1|'{}'|0",
        'startedAt|INTEGER|1|null|0',
        'endedAt|INTEGER|0|null|0',
        'listenedMs|INTEGER|1|0|0',
        'maxPositionMs|INTEGER|1|0|0',
        'endReason|TEXT|0|null|0',
        'syncKey|TEXT|0|null|0',
        "originDeviceId|TEXT|1|''|0",
        'versionPhysical|INTEGER|1|0|0',
        'versionCounter|INTEGER|1|0|0',
      ],
    };

    for (final entry in expected.entries) {
      final rows = await rowsOf('PRAGMA table_info(${entry.key})');
      expect(
        [for (final row in rows) columnSnapshot(row)],
        entry.value,
        reason: '表 ${entry.key} 的列定义与 schema 声明不一致',
      );
    }
  });

  test('索引逐字一致（含两个部分唯一索引）', () async {
    final rows = await rowsOf(
      "SELECT name, sql FROM sqlite_master WHERE type = 'index' "
      'AND sql IS NOT NULL ORDER BY name',
    );
    expect(
      {for (final row in rows) row['name']: row['sql']},
      {
        'idx_downloads_downloadedAt':
            'CREATE INDEX idx_downloads_downloadedAt ON downloads (downloadedAt)',
        'idx_play_contexts_lastPlayedAt':
            'CREATE INDEX idx_play_contexts_lastPlayedAt '
                'ON play_contexts (lastPlayedAt)',
        'idx_play_history_playedAt':
            'CREATE INDEX idx_play_history_playedAt ON play_history (playedAt)',
        'idx_playlists_syncId': 'CREATE UNIQUE INDEX idx_playlists_syncId '
            'ON playlists (syncId) WHERE syncId IS NOT NULL',
        'idx_playlist_tracks_order': 'CREATE INDEX idx_playlist_tracks_order '
            'ON playlist_tracks (playlistId, sortOrder, addedAt)',
        'idx_play_events_startedAt':
            'CREATE INDEX idx_play_events_startedAt ON play_events (startedAt)',
        'idx_play_events_track': 'CREATE INDEX idx_play_events_track '
            'ON play_events (sourceKey, songId)',
        'idx_play_events_syncKey': 'CREATE UNIQUE INDEX idx_play_events_syncKey '
            'ON play_events (syncKey) WHERE syncKey IS NOT NULL',
      },
    );
  });

  test('列表曲目外键级联', () async {
    final fk = await rowsOf('PRAGMA foreign_key_list(playlist_tracks)');
    expect(
      fk.map((row) => [
            row['table'],
            row['from'],
            row['to'],
            row['on_update'],
            row['on_delete'],
          ]),
      [
        ['playlists', 'playlistId', 'id', 'NO ACTION', 'CASCADE'],
      ],
    );
  });

  test('外键约束生效：孤立曲目写入被拒，删除列表级联删曲目', () async {
    await expectLater(
      db.into(db.playlistTracks).insert(PlaylistTracksCompanion.insert(
            playlistId: 404,
            sourceKey: 'wy',
            songId: '1',
            title: 'T',
            addedAt: 1,
          )),
      throwsA(predicate((e) => e.toString().contains('FOREIGN KEY'))),
    );

    final playlistId = await db.into(db.playlists).insert(
          PlaylistsCompanion.insert(name: 'L', createdAt: 1),
        );
    await db.into(db.playlistTracks).insert(PlaylistTracksCompanion.insert(
          playlistId: playlistId,
          sourceKey: 'wy',
          songId: '1',
          title: 'T',
          addedAt: 1,
        ));
    await (db.delete(db.playlists)..where((t) => t.id.equals(playlistId))).go();
    expect(await db.select(db.playlistTracks).get(), isEmpty);
  });

  test('部分唯一索引：syncId/syncKey 允许多个 NULL、拒绝重复值', () async {
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(
          name: 'A',
          createdAt: 1,
        ));
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(
          name: 'B',
          createdAt: 2,
        ));
    await db.into(db.playlists).insert(
          PlaylistsCompanion.insert(name: 'C', createdAt: 3, syncId: const Value('s1')),
        );
    await expectLater(
      db.into(db.playlists).insert(
            PlaylistsCompanion.insert(
                name: 'D', createdAt: 4, syncId: const Value('s1')),
          ),
      throwsA(anything),
    );

    await db.into(db.playEvents).insert(PlayEventsCompanion.insert(
          sourceKey: 'wy',
          songId: '1',
          startedAt: 1,
        ));
    await db.into(db.playEvents).insert(PlayEventsCompanion.insert(
          sourceKey: 'wy',
          songId: '2',
          startedAt: 2,
        ));
    final eventId = await db.into(db.playEvents).insert(
          PlayEventsCompanion.insert(
              sourceKey: 'wy', songId: '3', startedAt: 3, syncKey: const Value('k1')),
        );
    await expectLater(
      db.into(db.playEvents).insert(
            PlayEventsCompanion.insert(
                sourceKey: 'wy', songId: '4', startedAt: 4, syncKey: const Value('k1')),
          ),
      throwsA(anything),
    );
    expect(eventId, greaterThan(0));
  });

  test('历史唯一键与列表曲目唯一键走 INSERT OR REPLACE / IGNORE 语义', () async {
    PlayHistoryCompanion history(String songId, int playedAt) =>
        PlayHistoryCompanion.insert(
          sourceKey: 'wy',
          songId: songId,
          title: 'T$songId',
          playedAt: playedAt,
        );
    await db.into(db.playHistory).insert(history('1', 100),
        mode: InsertMode.insertOrReplace);
    await db.into(db.playHistory).insert(history('1', 300),
        mode: InsertMode.insertOrReplace);
    final entries = await db.select(db.playHistory).get();
    expect(entries, hasLength(1));
    expect(entries.single.playedAt, 300);

    final playlistId = await db.into(db.playlists).insert(
          PlaylistsCompanion.insert(name: 'L', createdAt: 1),
        );
    PlaylistTracksCompanion track(String songId) =>
        PlaylistTracksCompanion.insert(
          playlistId: playlistId,
          sourceKey: 'wy',
          songId: songId,
          title: 'T',
          addedAt: 1,
        );
    await db.into(db.playlistTracks).insert(track('1'));
    await db.into(db.playlistTracks).insert(track('1'),
        mode: InsertMode.insertOrIgnore);
    expect(await db.select(db.playlistTracks).get(), hasLength(1));
  });
}
