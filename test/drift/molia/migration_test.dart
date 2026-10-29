// dart format width=80
// ignore_for_file: unused_local_variable, unused_import
import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';

import 'generated/schema.dart';

import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v2.dart' as v2;

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
}
