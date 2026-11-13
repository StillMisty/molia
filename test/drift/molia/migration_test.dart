// dart format width=80
// ignore_for_file: unused_local_variable, unused_import
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/local_identity.dart';
import 'package:molia/data/local_identity_migration.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/stats_payload_codec.dart';

import 'generated/schema.dart';

import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v2.dart' as v2;
import 'generated/schema_v3.dart' as v3;

/// v1 → v2：新增播放会话两表，现有资料库 / 统计 / 下载数据保留。
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

  test(
    'migration from v1 to v2 preserves data and creates session tables',
    () async {
      final oldPlayHistoryData = [
        const v1.PlayHistoryData(
          sourceKey: 'wy',
          songId: 'song-1',
          title: '歌曲一',
          artist: '歌手',
          album: '专辑',
          coverUrl: 'https://img.example/a.jpg',
          durationMs: 200000,
          raw: '{"id":"song-1"}',
          playedAt: 1000,
          versionPhysical: 7,
          versionCounter: 3,
          deviceId: 'devA',
        ),
      ];
      const expectedNewPlayHistoryData = <v2.PlayHistoryData>[
        v2.PlayHistoryData(
          sourceKey: 'wy',
          songId: 'song-1',
          title: '歌曲一',
          artist: '歌手',
          album: '专辑',
          coverUrl: 'https://img.example/a.jpg',
          durationMs: 200000,
          raw: '{"id":"song-1"}',
          playedAt: 1000,
          versionPhysical: 7,
          versionCounter: 3,
          deviceId: 'devA',
        ),
      ];

      final oldPlaylistsData = [
        const v1.PlaylistsData(
          id: 1,
          name: '收藏',
          createdAt: 500,
          syncId: 'sync-list-1',
          versionPhysical: 4,
          versionCounter: 0,
          deviceId: 'devA',
        ),
      ];
      const expectedNewPlaylistsData = <v2.PlaylistsData>[
        v2.PlaylistsData(
          id: 1,
          name: '收藏',
          createdAt: 500,
          syncId: 'sync-list-1',
          versionPhysical: 4,
          versionCounter: 0,
          deviceId: 'devA',
        ),
      ];

      final oldPlaylistTracksData = [
        const v1.PlaylistTracksData(
          id: 1,
          playlistId: 1,
          sourceKey: 'wy',
          songId: 'song-1',
          title: '歌曲一',
          artist: '歌手',
          album: '专辑',
          raw: '{}',
          addedAt: 600,
          sortOrder: 0,
          versionPhysical: 4,
          versionCounter: 0,
          deviceId: 'devA',
        ),
      ];
      const expectedNewPlaylistTracksData = <v2.PlaylistTracksData>[
        v2.PlaylistTracksData(
          id: 1,
          playlistId: 1,
          sourceKey: 'wy',
          songId: 'song-1',
          title: '歌曲一',
          artist: '歌手',
          album: '专辑',
          raw: '{}',
          addedAt: 600,
          sortOrder: 0,
          versionPhysical: 4,
          versionCounter: 0,
          deviceId: 'devA',
        ),
      ];

      final oldDownloadsData = [
        const v1.DownloadsData(
          id: 1,
          originSourceKey: 'wy',
          originSongId: 'song-1',
          title: '歌曲一',
          artist: '歌手',
          album: '专辑',
          raw: '{}',
          quality: '320k',
          filePath: '/downloads/song-1.mp3',
          sizeBytes: 1024,
          imported: 0,
          downloadedAt: 2000,
        ),
      ];
      const expectedNewDownloadsData = <v2.DownloadsData>[
        v2.DownloadsData(
          id: 1,
          originSourceKey: 'wy',
          originSongId: 'song-1',
          title: '歌曲一',
          artist: '歌手',
          album: '专辑',
          raw: '{}',
          quality: '320k',
          filePath: '/downloads/song-1.mp3',
          sizeBytes: 1024,
          imported: 0,
          downloadedAt: 2000,
        ),
      ];

      await verifier.testWithDataIntegrity(
        oldVersion: 1,
        newVersion: 2,
        createOld: v1.DatabaseAtV1.new,
        createNew: v2.DatabaseAtV2.new,
        openTestedDatabase: MoliaDatabase.new,
        createItems: (batch, oldDb) {
          batch.insertAll(oldDb.playHistory, oldPlayHistoryData);
          batch.insertAll(oldDb.playlists, oldPlaylistsData);
          batch.insertAll(oldDb.playlistTracks, oldPlaylistTracksData);
          batch.insertAll(oldDb.downloads, oldDownloadsData);
        },
        validateItems: (newDb) async {
          expect(
            expectedNewPlayHistoryData,
            await newDb.select(newDb.playHistory).get(),
          );
          expect(
            expectedNewPlaylistsData,
            await newDb.select(newDb.playlists).get(),
          );
          expect(
            expectedNewPlaylistTracksData,
            await newDb.select(newDb.playlistTracks).get(),
          );
          expect(
            expectedNewDownloadsData,
            await newDb.select(newDb.downloads).get(),
          );

          // 新表存在且为空；单行会话可正常写入。
          expect(
            await newDb.select(newDb.playbackSessionCursors).get(),
            isEmpty,
          );
          await newDb
              .into(newDb.playbackSessionPayloads)
              .insert(
                v2.PlaybackSessionPayloadsCompanion.insert(
                  id: const Value(1),
                  json: '{"tracks":[]}',
                  updatedAt: 1,
                ),
              );
          expect(
            await newDb.select(newDb.playbackSessionPayloads).get(),
            hasLength(1),
          );
        },
      );
    },
  );

  _v2ToV3Tests();
}

/// v2 → v3：本地稳定 id + 扫描 / 缺文件列 + 列表增强列，现有数据保留。
void _v2ToV3Tests() {
  const aPath = '/music/Artist A/Album A/01 Song A.mp3';
  const bPath = '/music/Artist B/02 Song B.flac';
  const orphanPath = '/music/orphan.mp3';
  const aLegacy = 'local:$aPath';
  const orphanLegacy = 'local:$orphanPath';

  Map<String, dynamic> payload(String songId, String path) => {
    'songId': songId,
    'path': path,
  };

  v2.PlaylistsData playlist({
    required int id,
    required String name,
    String? syncId,
    int physical = 1,
  }) => v2.PlaylistsData(
    id: id,
    name: name,
    createdAt: id * 10,
    syncId: syncId,
    versionPhysical: physical,
    versionCounter: 0,
    deviceId: 'devA',
  );

  v2.PlaylistTracksData playlistTrack({
    required int id,
    required int playlistId,
    required String sourceKey,
    required String songId,
    required String title,
    required String raw,
    int sortOrder = 0,
  }) => v2.PlaylistTracksData(
    id: id,
    playlistId: playlistId,
    sourceKey: sourceKey,
    songId: songId,
    title: title,
    artist: '',
    album: '',
    raw: raw,
    addedAt: 30 + id,
    sortOrder: sortOrder,
    versionPhysical: 3,
    versionCounter: 0,
    deviceId: 'devA',
  );

  v2.DownloadsData download({
    required int id,
    required String sourceKey,
    required String songId,
    required String title,
    required String? filePath,
    required int sizeBytes,
    required int imported,
    required int downloadedAt,
  }) => v2.DownloadsData(
    id: id,
    originSourceKey: sourceKey,
    originSongId: songId,
    title: title,
    artist: '',
    album: '',
    raw: '{}',
    quality: '',
    filePath: filePath,
    sizeBytes: sizeBytes,
    imported: imported,
    downloadedAt: downloadedAt,
  );

  v2.PlayHistoryData history({
    required String sourceKey,
    required String songId,
    required String title,
    required String raw,
    required int playedAt,
  }) => v2.PlayHistoryData(
    sourceKey: sourceKey,
    songId: songId,
    title: title,
    artist: '',
    album: '',
    raw: raw,
    playedAt: playedAt,
    versionPhysical: 5,
    versionCounter: 0,
    deviceId: 'devA',
  );

  v2.PlayTracksData playTrack({
    required int id,
    required String sourceKey,
    required String songId,
    required String title,
    required Map<String, dynamic> payload,
  }) => v2.PlayTracksData(
    id: id,
    sourceKey: sourceKey,
    songId: songId,
    title: title,
    artist: '',
    album: '',
    raw: encodeStatsPayload(jsonEncode(payload)),
    updatedAt: 300 + id,
  );

  test('v2 → v3 rewrites imported identities and keeps other rows', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final sessionJson = jsonEncode({
      'v': 1,
      'index': 1,
      'positionMs': 42000,
      'mode': 'listLoop',
      'savedAt': 9000,
      'tracks': [
        {
          'sourceKey': 'local',
          'id': aLegacy,
          'title': 'Song A',
          'payload': payload(aLegacy, aPath),
        },
        {
          'sourceKey': 'wy',
          'id': 'wy-1',
          'title': 'Online',
          'payload': {'songId': 'wy-1'},
        },
      ],
    });

    await verifier.testWithDataIntegrity(
      oldVersion: 2,
      newVersion: 3,
      createOld: v2.DatabaseAtV2.new,
      createNew: v3.DatabaseAtV3.new,
      openTestedDatabase: MoliaDatabase.new,
      createItems: (batch, oldDb) {
        batch.insertAll(oldDb.playlists, [
          playlist(id: 1, name: '收藏', syncId: '__favorites__'),
          playlist(id: 2, name: '我的列表', syncId: 'sync-2'),
        ]);
        batch.insertAll(oldDb.playlistTracks, [
          playlistTrack(
            id: 1,
            playlistId: 1,
            sourceKey: 'local',
            songId: aLegacy,
            title: 'Song A',
            raw: jsonEncode(payload(aLegacy, aPath)),
          ),
          playlistTrack(
            id: 2,
            playlistId: 2,
            sourceKey: 'local',
            songId: orphanLegacy,
            title: 'Orphan',
            raw: jsonEncode(payload(orphanLegacy, orphanPath)),
          ),
          playlistTrack(
            id: 3,
            playlistId: 2,
            sourceKey: 'wy',
            songId: 'wy-1',
            title: 'Online',
            raw: '{}',
            sortOrder: 1,
          ),
        ]);
        batch.insertAll(oldDb.downloads, [
          download(
            id: 1,
            sourceKey: 'local',
            songId: aPath,
            title: 'Song A',
            filePath: aPath,
            sizeBytes: 100,
            imported: 1,
            downloadedAt: 100,
          ),
          download(
            id: 2,
            sourceKey: 'local',
            songId: bPath,
            title: 'Song B',
            filePath: bPath,
            sizeBytes: 200,
            imported: 1,
            downloadedAt: 101,
          ),
          download(
            id: 3,
            sourceKey: 'wy',
            songId: 'wy-1',
            title: 'Online',
            filePath: '/downloads/online.mp3',
            sizeBytes: 300,
            imported: 0,
            downloadedAt: 102,
          ),
        ]);
        batch.insertAll(oldDb.playHistory, [
          history(
            sourceKey: 'local',
            songId: aLegacy,
            title: 'Song A',
            raw: jsonEncode(payload(aLegacy, aPath)),
            playedAt: 200,
          ),
          history(
            sourceKey: 'local',
            songId: orphanLegacy,
            title: 'Orphan',
            raw: '{}',
            playedAt: 201,
          ),
          history(
            sourceKey: 'wy',
            songId: 'wy-1',
            title: 'Online',
            raw: '{}',
            playedAt: 202,
          ),
        ]);
        batch.insertAll(oldDb.playTracks, [
          playTrack(
            id: 1,
            sourceKey: 'local',
            songId: aLegacy,
            title: 'Song A',
            payload: payload(aLegacy, aPath),
          ),
          playTrack(
            id: 2,
            sourceKey: 'local',
            songId: orphanLegacy,
            title: 'Orphan',
            payload: payload(orphanLegacy, orphanPath),
          ),
          playTrack(
            id: 3,
            sourceKey: 'wy',
            songId: 'wy-1',
            title: 'Online',
            payload: {'songId': 'wy-1'},
          ),
        ]);
        batch.insertAll(oldDb.playEvents, [
          const v2.PlayEventsData(
            id: 1,
            trackId: 1,
            startedAt: 300,
            listenedMs: 1000,
            maxPositionMs: 1000,
            syncKey: 'sync-a',
            originDeviceId: 'devA',
            versionPhysical: 1,
            versionCounter: 0,
          ),
        ]);
        batch.insertAll(oldDb.playbackSessionPayloads, [
          v2.PlaybackSessionPayloadsData(
            id: 1,
            json: sessionJson,
            updatedAt: 9000,
          ),
        ]);
        batch.insertAll(oldDb.playbackSessionCursors, [
          const v2.PlaybackSessionCursorsData(
            id: 1,
            cursorIndex: 1,
            positionMs: 42000,
            savedAt: 9000,
          ),
        ]);
        batch.insertAll(oldDb.syncTombstones, [
          const v2.SyncTombstonesData(
            category: 'history',
            key: 'local\u0001$aLegacy',
            versionPhysical: 6,
            versionCounter: 0,
            deviceId: 'devA',
            deletedAt: 0,
          ),
          const v2.SyncTombstonesData(
            category: 'history',
            key: 'wy\u0001wy-1',
            versionPhysical: 7,
            versionCounter: 0,
            deviceId: 'devA',
            deletedAt: 0,
          ),
          const v2.SyncTombstonesData(
            category: 'playlistTracks',
            key: 'sync-2\u0001local\u0001$orphanLegacy',
            versionPhysical: 8,
            versionCounter: 0,
            deviceId: 'devA',
            deletedAt: 0,
          ),
          const v2.SyncTombstonesData(
            category: 'covers',
            key: aLegacy,
            versionPhysical: 9,
            versionCounter: 0,
            deviceId: 'devA',
            deletedAt: 0,
          ),
        ]);
        batch.insertAll(oldDb.syncKnown, [
          const v2.SyncKnownData(
            category: 'history',
            key: 'local\u0001$aLegacy',
            versionPhysical: 6,
            versionCounter: 0,
            deviceId: 'devA',
          ),
          const v2.SyncKnownData(
            category: 'history',
            key: 'wy\u0001wy-1',
            versionPhysical: 7,
            versionCounter: 0,
            deviceId: 'devA',
          ),
        ]);
      },
      validateItems: (newDb) async {
        final downloads = await newDb
            .customSelect('SELECT * FROM downloads ORDER BY id')
            .get();
        final a = downloads[0].data;
        final b = downloads[1].data;
        final online = downloads[2].data;
        final aKey = a['localKey'] as String;
        final bKey = b['localKey'] as String;
        expect(isStableLocalKey(aKey), isTrue);
        expect(isStableLocalKey(bKey), isTrue);
        expect(aKey, isNot(bKey));
        expect(a['originSongId'], aKey);
        expect(b['originSongId'], bKey);
        expect(a['filePath'], aPath);
        expect(a['mtimeMs'], isNull);
        expect(a['missingAt'], isNull);
        // 下载副本不参与身份迁移。
        expect(online['originSongId'], 'wy-1');
        expect(online['localKey'], isNull);

        final tracks = await newDb
            .customSelect('SELECT * FROM playlist_tracks ORDER BY id')
            .get();
        expect(tracks[0].data['songId'], aKey);
        final trackRaw = jsonDecode(tracks[0].data['raw'] as String) as Map;
        expect(trackRaw['songId'], aKey);
        expect(trackRaw['path'], aPath);
        final orphanKey = tracks[1].data['songId'] as String;
        expect(isStableLocalKey(orphanKey), isTrue);
        expect(tracks[2].data['songId'], 'wy-1');
        expect(tracks[2].data['raw'], '{}');

        final history = await newDb
            .customSelect('SELECT * FROM play_history ORDER BY playedAt')
            .get();
        expect(history[0].data['songId'], aKey);
        expect(history[1].data['songId'], orphanKey);
        expect(history[2].data['songId'], 'wy-1');
        expect(history[2].data['raw'], '{}');

        final playTracks = await newDb
            .customSelect('SELECT * FROM play_tracks ORDER BY id')
            .get();
        expect(playTracks[0].data['songId'], aKey);
        expect(playTracks[1].data['songId'], orphanKey);
        expect(playTracks[2].data['songId'], 'wy-1');
        final statsPayload =
            jsonDecode(decodeStatsPayload(playTracks[0].data['raw'])) as Map;
        expect(statsPayload['songId'], aKey);
        expect(statsPayload['path'], aPath);

        final events = await newDb
            .customSelect('SELECT * FROM play_events')
            .get();
        expect(events.single.data['trackId'], 1);

        final session = await newDb
            .customSelect(
              'SELECT * FROM playback_session_payloads WHERE id = 1',
            )
            .getSingle();
        final sessionMap = jsonDecode(session.data['json'] as String) as Map;
        expect(sessionMap['index'], 1);
        expect(sessionMap['positionMs'], 42000);
        expect(sessionMap['savedAt'], 9000);
        final sessionTracks = sessionMap['tracks'] as List;
        expect((sessionTracks[0] as Map)['id'], aKey);
        expect(((sessionTracks[0] as Map)['payload'] as Map)['songId'], aKey);
        expect(((sessionTracks[0] as Map)['payload'] as Map)['path'], aPath);
        expect((sessionTracks[1] as Map)['id'], 'wy-1');
        final cursor = await newDb
            .customSelect('SELECT * FROM playback_session_cursors')
            .getSingle();
        expect(cursor.data['cursorIndex'], 1);
        expect(cursor.data['positionMs'], 42000);

        final tombstones = await newDb
            .customSelect('SELECT * FROM sync_tombstones ORDER BY key')
            .get();
        expect(tombstones.map((r) => r.data['key']), ['wy\u0001wy-1']);
        final known = await newDb
            .customSelect('SELECT * FROM sync_known ORDER BY key')
            .get();
        expect(known.map((r) => r.data['key']), ['wy\u0001wy-1']);

        final playlists = await newDb
            .customSelect('SELECT * FROM playlists ORDER BY id')
            .get();
        for (final row in playlists) {
          expect(row.data['description'], '');
          expect(row.data['coverKey'], isNull);
          expect(row.data['folder'], '');
        }
      },
    );
  });

  test('corrupt session JSON does not fail the migration', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    await verifier.testWithDataIntegrity(
      oldVersion: 2,
      newVersion: 3,
      createOld: v2.DatabaseAtV2.new,
      createNew: v3.DatabaseAtV3.new,
      openTestedDatabase: MoliaDatabase.new,
      createItems: (batch, oldDb) {
        batch.insertAll(oldDb.downloads, [
          download(
            id: 1,
            sourceKey: 'local',
            songId: aPath,
            title: 'Song A',
            filePath: aPath,
            sizeBytes: 100,
            imported: 1,
            downloadedAt: 100,
          ),
        ]);
        batch.insertAll(oldDb.playlistTracks, [
          playlistTrack(
            id: 1,
            playlistId: 1,
            sourceKey: 'local',
            songId: orphanLegacy,
            title: 'Orphan',
            raw: 'not-json',
          ),
        ]);
        batch.insertAll(oldDb.playbackSessionPayloads, [
          const v2.PlaybackSessionPayloadsData(
            id: 1,
            json: '{broken',
            updatedAt: 1,
          ),
        ]);
      },
      validateItems: (newDb) async {
        final session = await newDb
            .customSelect(
              'SELECT * FROM playback_session_payloads WHERE id = 1',
            )
            .getSingle();
        expect(session.data['json'], '{broken');
        final track = await newDb
            .customSelect('SELECT * FROM playlist_tracks WHERE id = 1')
            .getSingle();
        expect(isStableLocalKey(track.data['songId'] as String), isTrue);
        expect(track.data['raw'], 'not-json');
        final row = await newDb
            .customSelect('SELECT * FROM downloads WHERE id = 1')
            .getSingle();
        expect(isStableLocalKey(row.data['localKey'] as String), isTrue);
      },
    );
  });

  test('re-running the identity rewrite is idempotent', () async {
    final db = MoliaDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    const stable = 'file:11111111-1111-4111-8111-111111111111';
    await db.customStatement(
      'INSERT INTO downloads (originSourceKey, originSongId, title, filePath, '
      'sizeBytes, imported, localKey, downloadedAt) VALUES '
      "('local', ?, 'Song A', ?, 100, 1, ?, 100)",
      [stable, aPath, stable],
    );
    await db.customStatement(
      'INSERT INTO playlists (id, name, createdAt) VALUES (1, ?, 1)',
      ['列表'],
    );
    await db.customStatement(
      'INSERT INTO playlist_tracks (playlistId, sourceKey, songId, title, raw, '
      'addedAt, sortOrder, versionPhysical, versionCounter, deviceId) VALUES '
      "(1, 'local', ?, 'Song A', ?, 1, 0, 0, 0, '')",
      [
        stable,
        jsonEncode({'songId': stable, 'path': aPath}),
      ],
    );
    await db.customStatement(
      'INSERT INTO play_history (sourceKey, songId, title, raw, playedAt, '
      'versionPhysical, versionCounter, deviceId) VALUES '
      "('local', ?, 'Song A', ?, 1, 0, 0, '')",
      [
        stable,
        jsonEncode({'songId': stable}),
      ],
    );

    await LocalIdentityMigration.rewrite(db);
    await LocalIdentityMigration.rewrite(db);

    final download = await db
        .customSelect('SELECT * FROM downloads WHERE id = 1')
        .getSingle();
    expect(download.data['localKey'], stable);
    expect(download.data['originSongId'], stable);
    final count = await db
        .customSelect('SELECT COUNT(*) AS c FROM downloads')
        .getSingle();
    expect(count.data['c'], 1);
    final track = await db
        .customSelect('SELECT * FROM playlist_tracks WHERE id = 1')
        .getSingle();
    expect(track.data['songId'], stable);
    final history = await db
        .customSelect('SELECT * FROM play_history')
        .getSingle();
    expect(history.data['songId'], stable);
  });
}
