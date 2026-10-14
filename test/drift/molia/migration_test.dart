// dart format width=80
// ignore_for_file: unused_local_variable, unused_import
import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:molia/data/molia_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'generated/schema.dart';

import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v2.dart' as v2;
import 'generated/schema_v3.dart' as v3;
import 'generated/schema_v4.dart' as v4;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('simple database migrations', () {
    // These simple tests verify all possible schema updates with a simple (no
    // data) migration. This is a quick way to ensure that written database
    // migrations properly alter the schema.
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

  // 迁移不破坏既有数据：v1 → v2 只新增 downloads 表，其余表逐行保留。
  test('migration from v1 to v2 does not corrupt data', () async {
    final oldPlayContextsData = [
      const v1.PlayContextsData(
        contextUri: 'lx:测试歌单',
        contextType: 'lx',
        contextName: '测试歌单',
        imageUrl: 'https://example.com/a.jpg',
        lastPlayedAt: 100,
      ),
    ];
    final expectedNewPlayContextsData = [
      const v2.PlayContextsData(
        contextUri: 'lx:测试歌单',
        contextType: 'lx',
        contextName: '测试歌单',
        imageUrl: 'https://example.com/a.jpg',
        lastPlayedAt: 100,
      ),
    ];

    final oldPlayHistoryData = [
      const v1.PlayHistoryData(
        sourceKey: 'wy',
        songId: '1',
        title: '历史',
        artist: '歌手',
        album: '专辑',
        coverUrl: 'https://example.com/h.jpg',
        durationMs: 200000,
        raw: '{"songmid":"1"}',
        playedAt: 200,
      ),
    ];
    final expectedNewPlayHistoryData = [
      const v2.PlayHistoryData(
        sourceKey: 'wy',
        songId: '1',
        title: '历史',
        artist: '歌手',
        album: '专辑',
        coverUrl: 'https://example.com/h.jpg',
        durationMs: 200000,
        raw: '{"songmid":"1"}',
        playedAt: 200,
      ),
    ];

    final oldPlaylistsData = [
      const v1.PlaylistsData(
        id: 1,
        name: '列表',
        createdAt: 300,
        syncId: 'sync-1',
        updatedAt: 300,
        updatedBy: 'device-a',
      ),
    ];
    final expectedNewPlaylistsData = [
      const v2.PlaylistsData(
        id: 1,
        name: '列表',
        createdAt: 300,
        syncId: 'sync-1',
        updatedAt: 300,
        updatedBy: 'device-a',
      ),
    ];

    final oldPlaylistTracksData = [
      const v1.PlaylistTracksData(
        id: 1,
        playlistId: 1,
        sourceKey: 'wy',
        songId: '1',
        title: '列表曲目',
        artist: '歌手',
        album: '专辑',
        coverUrl: null,
        durationMs: 200000,
        raw: '{"songmid":"1"}',
        addedAt: 300,
        sortOrder: 0,
        updatedAt: 300,
        updatedBy: 'device-a',
      ),
    ];
    final expectedNewPlaylistTracksData = [
      const v2.PlaylistTracksData(
        id: 1,
        playlistId: 1,
        sourceKey: 'wy',
        songId: '1',
        title: '列表曲目',
        artist: '歌手',
        album: '专辑',
        coverUrl: null,
        durationMs: 200000,
        raw: '{"songmid":"1"}',
        addedAt: 300,
        sortOrder: 0,
        updatedAt: 300,
        updatedBy: 'device-a',
      ),
    ];

    final oldSyncTombstonesData = [
      const v1.SyncTombstonesData(
        category: 'history',
        key: 'wy:2',
        updatedAt: 400,
        updatedBy: 'device-a',
      ),
    ];
    final expectedNewSyncTombstonesData = [
      const v2.SyncTombstonesData(
        category: 'history',
        key: 'wy:2',
        updatedAt: 400,
        updatedBy: 'device-a',
      ),
    ];

    final oldPlayEventsData = [
      const v1.PlayEventsData(
        id: 1,
        sourceKey: 'wy',
        songId: '1',
        title: '事件',
        artist: '歌手',
        album: '专辑',
        coverUrl: null,
        durationMs: 200000,
        raw: '{}',
        startedAt: 500,
        endedAt: 600,
        listenedMs: 100000,
        maxPositionMs: 100000,
        endReason: 'completed',
        syncKey: 'key-1',
        originDeviceId: 'device-a',
      ),
    ];
    final expectedNewPlayEventsData = [
      const v2.PlayEventsData(
        id: 1,
        sourceKey: 'wy',
        songId: '1',
        title: '事件',
        artist: '歌手',
        album: '专辑',
        coverUrl: null,
        durationMs: 200000,
        raw: '{}',
        startedAt: 500,
        endedAt: 600,
        listenedMs: 100000,
        maxPositionMs: 100000,
        endReason: 'completed',
        syncKey: 'key-1',
        originDeviceId: 'device-a',
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
        // v2 新增表：迁移后存在且为空。
        expect(await newDb.select(newDb.downloads).get(), isEmpty);
      },
    );
  });

  // 迁移不破坏既有数据：v2 → v3 只把 downloads.filePath 改为可空，
  // 已有下载记录（含音频路径）逐行保留。
  test('migration from v2 to v3 keeps download records', () async {
    const oldDownloadsData = [
      v2.DownloadsData(
        id: 1,
        originSourceKey: 'kw',
        originSongId: 'a',
        title: 'Title a',
        artist: 'Artist a',
        album: 'Album a',
        coverUrl: 'https://example.com/a.jpg',
        durationMs: 245000,
        raw: '{"id":"a"}',
        quality: '320k',
        filePath: '/downloads/Artist a - Title a.mp3',
        sizeBytes: 3 * 1024 * 1024,
        lyricPath: '/downloads/lyrics/Artist a - Title a.lrc',
        coverPath: '/downloads/covers/Artist a - Title a.jpg',
        downloadedAt: 1000,
      ),
    ];

    await verifier.testWithDataIntegrity(
      oldVersion: 2,
      newVersion: 3,
      createOld: v2.DatabaseAtV2.new,
      createNew: v3.DatabaseAtV3.new,
      openTestedDatabase: MoliaDatabase.new,
      createItems: (batch, oldDb) {
        batch.insertAll(oldDb.downloads, oldDownloadsData);
      },
      validateItems: (newDb) async {
        final rows = await newDb.select(newDb.downloads).get();
        expect(rows, hasLength(1));
        expect(rows.single.filePath, '/downloads/Artist a - Title a.mp3');
        expect(rows.single.lyricPath, '/downloads/lyrics/Artist a - Title a.lrc');
        expect(rows.single.coverPath, '/downloads/covers/Artist a - Title a.jpg');
        expect(rows.single.quality, '320k');
      },
    );
  });

  // 迁移不破坏既有数据：v3 → v4 只新增可空列 publicUri，
  // 既有下载记录（含音频 / 歌词 / 封面路径）逐行保留，publicUri 为 null。
  test('migration from v3 to v4 keeps download records', () async {
    const oldDownloadsData = [
      v3.DownloadsData(
        id: 1,
        originSourceKey: 'kw',
        originSongId: 'a',
        title: 'Title a',
        artist: 'Artist a',
        album: 'Album a',
        coverUrl: 'https://example.com/a.jpg',
        durationMs: 245000,
        raw: '{"id":"a"}',
        quality: '320k',
        filePath: '/downloads/Artist a - Title a.mp3',
        sizeBytes: 3 * 1024 * 1024,
        lyricPath: '/downloads/lyrics/Artist a - Title a.lrc',
        coverPath: '/downloads/covers/Artist a - Title a.jpg',
        downloadedAt: 1000,
      ),
      // 分项记录（只有歌词、无音频）：v3 起 filePath 可空，迁移后保持 null。
      v3.DownloadsData(
        id: 2,
        originSourceKey: 'tx',
        originSongId: 'b',
        title: 'Title b',
        artist: 'Artist b',
        album: '',
        coverUrl: null,
        durationMs: null,
        raw: '{}',
        quality: '',
        filePath: null,
        sizeBytes: 0,
        lyricPath: '/downloads/lyrics/Artist b - Title b.lrc',
        coverPath: null,
        downloadedAt: 2000,
      ),
    ];

    await verifier.testWithDataIntegrity(
      oldVersion: 3,
      newVersion: 4,
      createOld: v3.DatabaseAtV3.new,
      createNew: v4.DatabaseAtV4.new,
      openTestedDatabase: MoliaDatabase.new,
      createItems: (batch, oldDb) {
        batch.insertAll(oldDb.downloads, oldDownloadsData);
      },
      validateItems: (newDb) async {
        final rows = await newDb.select(newDb.downloads).get()
          ..sort((a, b) => a.id.compareTo(b.id));
        expect(rows, hasLength(2));
        expect(rows.first.filePath, '/downloads/Artist a - Title a.mp3');
        expect(rows.first.lyricPath, '/downloads/lyrics/Artist a - Title a.lrc');
        expect(rows.first.coverPath, '/downloads/covers/Artist a - Title a.jpg');
        expect(rows.first.quality, '320k');
        expect(rows.first.publicUri, null, reason: 'v4 新列默认 null');
        expect(rows.last.filePath, null);
        expect(rows.last.lyricPath, '/downloads/lyrics/Artist b - Title b.lrc');
        expect(rows.last.publicUri, null);
      },
    );
  });
}
