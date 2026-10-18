// dart format width=80
import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';

import 'package:molia/data/stats_payload_codec.dart';

import 'generated/schema.dart';
import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v2.dart' as v2;
import 'generated/schema_v3.dart' as v3;
import 'generated/schema_v4.dart' as v4;
import 'generated/schema_v5.dart' as v5;

/// 增量迁移链：v1 → v2 新增 `sync_known`，v2 → v3 新增增量日志
/// （`sync_journal` + `sync_journal_state`），v3 → v4 新增统计索引，
/// v4 → v5 统计载荷与元数据移入 `play_tracks`（事件表只留 `trackId`），
/// 每一步都保留既有数据。
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

  test('migration from v4 to v5 moves payloads into play_tracks', () async {
    final oldPlayEventsData = [
      const v4.PlayEventsData(
        id: 1,
        sourceKey: 'kuwo',
        songId: 'song-1',
        title: '旧标题',
        artist: '歌手',
        album: '专辑',
        coverUrl: 'https://example.com/a.jpg',
        durationMs: 180000,
        raw: '{"rid":1}',
        startedAt: 800,
        endedAt: 900,
        listenedMs: 100000,
        maxPositionMs: 100000,
        endReason: 'completed',
        syncKey: 'event-1',
        originDeviceId: 'devA',
        versionPhysical: 900,
        versionCounter: 0,
      ),
      // 同一曲的第二次播放：内容行取这一行（最新）的快照与载荷。
      const v4.PlayEventsData(
        id: 2,
        sourceKey: 'kuwo',
        songId: 'song-1',
        title: '新标题',
        artist: '歌手',
        album: '专辑',
        coverUrl: 'https://example.com/b.jpg',
        durationMs: 200000,
        raw: '{"rid":2}',
        startedAt: 1000,
        endedAt: 1100,
        listenedMs: 120000,
        maxPositionMs: 120000,
        endReason: 'completed',
        syncKey: 'event-2',
        originDeviceId: 'devA',
        versionPhysical: 1100,
        versionCounter: 0,
      ),
      const v4.PlayEventsData(
        id: 3,
        sourceKey: 'wy',
        songId: 'song-2',
        title: '第二首',
        artist: '歌手二',
        album: '',
        raw: '{}',
        startedAt: 1200,
        endedAt: 1300,
        listenedMs: 60000,
        maxPositionMs: 60000,
        endReason: 'skipped',
        syncKey: 'event-3',
        originDeviceId: 'devB',
        versionPhysical: 1300,
        versionCounter: 1,
      ),
    ];

    await verifier.testWithDataIntegrity(
      oldVersion: 4,
      newVersion: 5,
      createOld: v4.DatabaseAtV4.new,
      createNew: v5.DatabaseAtV5.new,
      openTestedDatabase: MoliaDatabase.new,
      createItems: (batch, oldDb) =>
          batch.insertAll(oldDb.playEvents, oldPlayEventsData),
      validateItems: (newDb) async {
        // 事件全保留（id / 时间 / 进度 / 版本列一致），曲目改成外键引用。
        final events = await newDb.select(newDb.playEvents).get()
          ..sort((a, b) => a.id.compareTo(b.id));
        expect(events.map((event) => event.id), [1, 2, 3]);
        expect(events.map((event) => event.startedAt), [800, 1000, 1200]);
        expect(events.map((event) => event.listenedMs), [100000, 120000, 60000]);
        expect(
          events.map((event) => event.syncKey),
          ['event-1', 'event-2', 'event-3'],
        );
        expect(events[1].endReason, 'completed');
        expect(events[0].trackId, events[1].trackId, reason: '同曲同一内容行');

        // 内容行：每曲一行；元数据与载荷取该曲最新一行的快照。
        final tracks = await newDb.select(newDb.playTracks).get()
          ..sort((a, b) => a.sourceKey.compareTo(b.sourceKey));
        expect(tracks, hasLength(2));
        final kuwo = tracks.firstWhere((track) => track.sourceKey == 'kuwo');
        expect(kuwo.title, '新标题');
        expect(kuwo.coverUrl, 'https://example.com/b.jpg');
        expect(kuwo.durationMs, 200000);
        expect(kuwo.updatedAt, 1000);
        expect(decodeStatsPayload(kuwo.raw), '{"rid":2}');
        final wy = tracks.firstWhere((track) => track.sourceKey == 'wy');
        expect(wy.updatedAt, 1200);
        expect(decodeStatsPayload(wy.raw), '{}');

        // 迁移后的结构可写：内容行 + 事件行（外键指向新内容行）。
        final trackId = await newDb.into(newDb.playTracks).insert(
              v5.PlayTracksData(
                id: 10,
                sourceKey: 'kw',
                songId: 'song-9',
                title: '迁移后写入',
                artist: '',
                album: '',
                raw: encodeStatsPayload('{"rid":9}'),
                updatedAt: 2000,
              ),
            );
        await newDb.into(newDb.playEvents).insert(
              v5.PlayEventsData(
                id: 20,
                trackId: trackId,
                startedAt: 2000,
                endedAt: 2100,
                listenedMs: 1000,
                maxPositionMs: 1000,
                endReason: 'skipped',
                syncKey: 'event-9',
                originDeviceId: 'devA',
                versionPhysical: 2100,
                versionCounter: 0,
              ),
            );
        final written = await newDb.select(newDb.playEvents).get();
        expect(written, hasLength(4));
        expect(
          decodeStatsPayload(
            (await newDb.select(newDb.playTracks).get())
                .firstWhere((track) => track.songId == 'song-9')
                .raw,
          ),
          '{"rid":9}',
        );
      },
    );
  });
}
