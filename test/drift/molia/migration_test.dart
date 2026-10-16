// dart format width=80
import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';

import 'generated/schema.dart';
import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v2.dart' as v2;
import 'generated/schema_v3.dart' as v3;

/// 增量迁移链：v1 → v2 新增 `sync_known`，v2 → v3 新增增量日志
/// （`sync_journal` + `sync_journal_state`），每一步都保留既有数据。
///
/// 简单用例验证「空库迁移后的 schema 与声明一致」；数据用例验证「带数据升级
/// 后数据仍在、新表可用」（ADR-0005：增量迁移必须保留数据）。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('simple database migrations', () {
    const versions = GeneratedHelper.versions;
    for (final (i, fromVersion) in versions.indexed) {
      group('from $fromVersion', () {
        for (final toVersion in versions.skip(i + 1)) {
          test('to $toVersion', () async {
            final schema = await verifier.schemaAt(fromVersion);
            final db = MoliaDatabase(schema.newConnection());
            await verifier.migrateAndValidate(db, toVersion);
            await db.close();
          });
        }
      });
    }
  });

  test('migration from v1 to v2 does not corrupt data', () async {
    final oldPlayContextsData = [
      const v1.PlayContextsData(
        contextUri: 'molia://context/album-1',
        contextType: 'album',
        contextName: '测试专辑',
        lastPlayedAt: 1000,
      ),
    ];
    final expectedNewPlayContextsData = [
      const v2.PlayContextsData(
        contextUri: 'molia://context/album-1',
        contextType: 'album',
        contextName: '测试专辑',
        lastPlayedAt: 1000,
      ),
    ];

    final oldPlayHistoryData = [
      const v1.PlayHistoryData(
        sourceKey: 'kuwo',
        songId: 'song-1',
        title: '测试歌曲',
        artist: '测试歌手',
        album: '测试专辑',
        raw: '{}',
        playedAt: 900,
        versionPhysical: 900,
        versionCounter: 0,
        deviceId: 'devA',
      ),
    ];
    final expectedNewPlayHistoryData = [
      const v2.PlayHistoryData(
        sourceKey: 'kuwo',
        songId: 'song-1',
        title: '测试歌曲',
        artist: '测试歌手',
        album: '测试专辑',
        raw: '{}',
        playedAt: 900,
        versionPhysical: 900,
        versionCounter: 0,
        deviceId: 'devA',
      ),
    ];

    final oldPlaylistsData = [
      const v1.PlaylistsData(
        id: 1,
        name: '我的收藏',
        createdAt: 100,
        syncId: '__favorites__',
        versionPhysical: 200,
        versionCounter: 0,
        deviceId: 'devA',
      ),
    ];
    final expectedNewPlaylistsData = [
      const v2.PlaylistsData(
        id: 1,
        name: '我的收藏',
        createdAt: 100,
        syncId: '__favorites__',
        versionPhysical: 200,
        versionCounter: 0,
        deviceId: 'devA',
      ),
    ];

    final oldPlaylistTracksData = [
      const v1.PlaylistTracksData(
        id: 1,
        playlistId: 1,
        sourceKey: 'kuwo',
        songId: 'song-1',
        title: '测试歌曲',
        artist: '测试歌手',
        album: '测试专辑',
        raw: '{}',
        addedAt: 150,
        sortOrder: 0,
        versionPhysical: 150,
        versionCounter: 0,
        deviceId: 'devA',
      ),
    ];
    final expectedNewPlaylistTracksData = [
      const v2.PlaylistTracksData(
        id: 1,
        playlistId: 1,
        sourceKey: 'kuwo',
        songId: 'song-1',
        title: '测试歌曲',
        artist: '测试歌手',
        album: '测试专辑',
        raw: '{}',
        addedAt: 150,
        sortOrder: 0,
        versionPhysical: 150,
        versionCounter: 0,
        deviceId: 'devA',
      ),
    ];

    final oldSyncTombstonesData = [
      const v1.SyncTombstonesData(
        category: 'history',
        key: 'kuwo\u0001song-2',
        versionPhysical: 300,
        versionCounter: 0,
        deviceId: 'devA',
        deletedAt: 290,
      ),
    ];
    final expectedNewSyncTombstonesData = [
      const v2.SyncTombstonesData(
        category: 'history',
        key: 'kuwo\u0001song-2',
        versionPhysical: 300,
        versionCounter: 0,
        deviceId: 'devA',
        deletedAt: 290,
      ),
    ];

    final oldPlayEventsData = [
      const v1.PlayEventsData(
        id: 1,
        sourceKey: 'kuwo',
        songId: 'song-1',
        title: '测试歌曲',
        artist: '测试歌手',
        album: '测试专辑',
        raw: '{}',
        startedAt: 800,
        endedAt: 900,
        listenedMs: 100000,
        maxPositionMs: 100000,
        syncKey: 'event-1',
        originDeviceId: 'devA',
        versionPhysical: 900,
        versionCounter: 0,
      ),
    ];
    final expectedNewPlayEventsData = [
      const v2.PlayEventsData(
        id: 1,
        sourceKey: 'kuwo',
        songId: 'song-1',
        title: '测试歌曲',
        artist: '测试歌手',
        album: '测试专辑',
        raw: '{}',
        startedAt: 800,
        endedAt: 900,
        listenedMs: 100000,
        maxPositionMs: 100000,
        syncKey: 'event-1',
        originDeviceId: 'devA',
        versionPhysical: 900,
        versionCounter: 0,
      ),
    ];

    final oldDownloadsData = [
      const v1.DownloadsData(
        id: 1,
        originSourceKey: 'kuwo',
        originSongId: 'song-1',
        title: '测试歌曲',
        artist: '测试歌手',
        album: '测试专辑',
        raw: '{}',
        quality: '320k',
        sizeBytes: 1024,
        imported: 0,
        downloadedAt: 700,
      ),
    ];
    final expectedNewDownloadsData = [
      const v2.DownloadsData(
        id: 1,
        originSourceKey: 'kuwo',
        originSongId: 'song-1',
        title: '测试歌曲',
        artist: '测试歌手',
        album: '测试专辑',
        raw: '{}',
        quality: '320k',
        sizeBytes: 1024,
        imported: 0,
        downloadedAt: 700,
      ),
    ];

    await verifier.testWithDataIntegrity(
      oldVersion: 1,
      newVersion: 2,
      createOld: v1.DatabaseAtV1.new,
      createNew: v2.DatabaseAtV2.new,
      openTestedDatabase: MoliaDatabase.new,
      createItems: (batch, oldDb) {
        batch.insertAll(oldDb.playContexts, oldPlayContextsData);
        batch.insertAll(oldDb.playHistory, oldPlayHistoryData);
        batch.insertAll(oldDb.playlists, oldPlaylistsData);
        batch.insertAll(oldDb.playlistTracks, oldPlaylistTracksData);
        batch.insertAll(oldDb.syncTombstones, oldSyncTombstonesData);
        batch.insertAll(oldDb.playEvents, oldPlayEventsData);
        batch.insertAll(oldDb.downloads, oldDownloadsData);
      },
      validateItems: (newDb) async {
        expect(expectedNewPlayContextsData,
            await newDb.select(newDb.playContexts).get());
        expect(expectedNewPlayHistoryData,
            await newDb.select(newDb.playHistory).get());
        expect(expectedNewPlaylistsData,
            await newDb.select(newDb.playlists).get());
        expect(expectedNewPlaylistTracksData,
            await newDb.select(newDb.playlistTracks).get());
        expect(expectedNewSyncTombstonesData,
            await newDb.select(newDb.syncTombstones).get());
        expect(expectedNewPlayEventsData,
            await newDb.select(newDb.playEvents).get());
        expect(expectedNewDownloadsData,
            await newDb.select(newDb.downloads).get());
        // 新表升级后立即可用（读写走同一套列声明）。
        await newDb.into(newDb.syncKnown).insert(
              const v2.SyncKnownData(
                category: 'history',
                key: 'kuwo\u0001song-1',
                versionPhysical: 900,
                versionCounter: 0,
                deviceId: 'devA',
              ),
            );
        final known = await newDb.select(newDb.syncKnown).getSingle();
        expect(known.category, 'history');
        expect(known.key, 'kuwo\u0001song-1');
        expect(known.versionPhysical, 900);
        expect(known.versionCounter, 0);
        expect(known.deviceId, 'devA');
      },
    );
  });

  test('migration from v2 to v3 does not corrupt data', () async {
    final oldPlayHistoryData = [
      const v2.PlayHistoryData(
        sourceKey: 'kuwo',
        songId: 'song-1',
        title: '测试歌曲',
        artist: '测试歌手',
        album: '测试专辑',
        raw: '{}',
        playedAt: 900,
        versionPhysical: 900,
        versionCounter: 0,
        deviceId: 'devA',
      ),
    ];
    final expectedNewPlayHistoryData = [
      const v3.PlayHistoryData(
        sourceKey: 'kuwo',
        songId: 'song-1',
        title: '测试歌曲',
        artist: '测试歌手',
        album: '测试专辑',
        raw: '{}',
        playedAt: 900,
        versionPhysical: 900,
        versionCounter: 0,
        deviceId: 'devA',
      ),
    ];

    final oldSyncKnownData = [
      const v2.SyncKnownData(
        category: 'history',
        key: 'kuwo\u0001song-1',
        versionPhysical: 900,
        versionCounter: 0,
        deviceId: 'devA',
      ),
    ];
    final expectedNewSyncKnownData = [
      const v3.SyncKnownData(
        category: 'history',
        key: 'kuwo\u0001song-1',
        versionPhysical: 900,
        versionCounter: 0,
        deviceId: 'devA',
      ),
    ];

    final oldPlaylistsData = [
      const v2.PlaylistsData(
        id: 1,
        name: '我的收藏',
        createdAt: 100,
        syncId: '__favorites__',
        versionPhysical: 200,
        versionCounter: 0,
        deviceId: 'devA',
      ),
    ];
    final expectedNewPlaylistsData = [
      const v3.PlaylistsData(
        id: 1,
        name: '我的收藏',
        createdAt: 100,
        syncId: '__favorites__',
        versionPhysical: 200,
        versionCounter: 0,
        deviceId: 'devA',
      ),
    ];

    await verifier.testWithDataIntegrity(
      oldVersion: 2,
      newVersion: 3,
      createOld: v2.DatabaseAtV2.new,
      createNew: v3.DatabaseAtV3.new,
      openTestedDatabase: MoliaDatabase.new,
      createItems: (batch, oldDb) {
        batch.insertAll(oldDb.playHistory, oldPlayHistoryData);
        batch.insertAll(oldDb.syncKnown, oldSyncKnownData);
        batch.insertAll(oldDb.playlists, oldPlaylistsData);
      },
      validateItems: (newDb) async {
        expect(expectedNewPlayHistoryData,
            await newDb.select(newDb.playHistory).get());
        expect(expectedNewSyncKnownData,
            await newDb.select(newDb.syncKnown).get());
        expect(expectedNewPlaylistsData,
            await newDb.select(newDb.playlists).get());
        // 新表升级后立即可用（读写走同一套列声明）。
        await newDb.into(newDb.syncJournal).insert(
              const v3.SyncJournalData(
                seq: 1,
                category: 'history',
                key: 'kuwo\u0001song-1',
                versionPhysical: 900,
                versionCounter: 0,
                deviceId: 'devA',
                deleted: 0,
                at: 901,
              ),
            );
        final entry = await newDb.select(newDb.syncJournal).getSingle();
        expect(entry.seq, 1);
        expect(entry.category, 'history');
        expect(entry.key, 'kuwo\u0001song-1');
        expect(entry.deleted, 0);
        expect(entry.data, null);

        await newDb.into(newDb.syncJournalState).insert(
              const v3.SyncJournalStateData(id: 0, baseSeq: 0, snapshotSeq: -1),
            );
        final journalState =
            await newDb.select(newDb.syncJournalState).getSingle();
        expect(journalState.baseSeq, 0);
        expect(journalState.snapshotSeq, -1);
      },
    );
  });
}
