import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/database_helper.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/sync/adapters/playlist_sync_adapter.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/library.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 歌单 / 收藏适配器测试：两库互导、LWW、删除墓碑、收藏固定 syncId。
void main() {
  sqfliteFfiInit();

  late Directory tempDir;
  late Database dbA;
  late Database dbB;
  late LibraryRepository repoA;
  late LibraryRepository repoB;
  late PlaylistSyncAdapter adapterA;
  late PlaylistSyncAdapter adapterB;
  var clock = 1000;

  Future<Database> openDb(String name) => databaseFactoryFfi.openDatabase(
        '${tempDir.path}/$name.db',
        options: OpenDatabaseOptions(
          version: DatabaseHelper.dbVersion,
          onCreate: (database, version) => DatabaseHelper.createSchema(database),
        ),
      );

  PlaylistTrack track(String id, {String source = 'wy', int sortOrder = 0}) =>
      PlaylistTrack(
        playlistId: 0,
        sourceKey: source,
        songId: id,
        title: 'Song $id',
        artist: 'Artist',
        album: 'Album',
        raw: {'songId': id},
        addedAt: 500,
        sortOrder: sortOrder,
      );

  setUp(() async {
    clock = 1000;
    tempDir = Directory.systemTemp.createTempSync('molia_sync_library');
    dbA = await openDb('a');
    dbB = await openDb('b');
    repoA = LibraryRepository(
      databaseProvider: () async => dbA,
      deviceIdProvider: () => 'devA',
      clock: () => clock,
    );
    repoB = LibraryRepository(
      databaseProvider: () async => dbB,
      deviceIdProvider: () => 'devB',
      clock: () => clock,
    );
    adapterA = PlaylistSyncAdapter(repository: repoA);
    adapterB = PlaylistSyncAdapter(repository: repoB);
  });

  tearDown(() async {
    await repoA.dispose();
    await repoB.dispose();
    await dbA.close();
    await dbB.close();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // 清理失败不影响测试结果。
    }
  });

  test('A → B：列表、曲目与收藏整体同步', () async {
    await repoA.toggleFavorite(
      sourceKey: 'wy',
      songId: 'fav-1',
      title: 'Favorite',
    );
    final playlistId = await repoA.createPlaylist('通勤歌单');
    await repoA.addTrackToPlaylist(playlistId, track('t1'));
    await repoA.addTrackToPlaylist(playlistId, track('t2'));

    final collected = await adapterA.collect();
    final result = await adapterB.apply(collected);
    expect(result.applied, 5); // 2 列表（收藏 + 歌单）+ 3 曲目（收藏 1 + 歌单 2）

    final playlistsB = await repoB.listPlaylists();
    expect(playlistsB.map((p) => p.name), containsAll(['通勤歌单']));
    expect(await repoB.favoriteKeys(), contains('wy:fav-1'));

    final playlistB = await repoB.findPlaylistByName('通勤歌单');
    final tracksB = await repoB.listPlaylistTracks(playlistB!.id);
    expect(tracksB.map((t) => t.songId), ['t1', 't2']);

    // 再应用一次：全部跳过（幂等）。
    final again = await adapterB.apply(await adapterA.collect());
    expect(again.applied, 0);
  });

  test('收藏列表使用固定 syncId', () async {
    await repoA.toggleFavorite(
      sourceKey: 'kw',
      songId: 'x',
      title: 'X',
    );
    final playlists = await repoA.syncExportPlaylists();
    // 同步记录不带收藏概念（合并键是固定 syncId），按保留行名取。
    final favorites = playlists.firstWhere((p) => p.name == '__favorites__');
    expect(favorites.syncId, SyncRecordKeys.favoritesPlaylistSyncId);
  });

  test('B 修改后 A 应用：远端更新者胜出（LWW）', () async {
    final playlistId = await repoA.createPlaylist('歌单');
    await repoA.addTrackToPlaylist(playlistId, track('t1'));
    await adapterB.apply(await adapterA.collect());

    clock = 2000;
    await repoB.renamePlaylist(
      (await repoB.findPlaylistByName('歌单'))!.id,
      '改名歌单',
    );
    final result = await adapterA.apply(await adapterB.collect());
    expect(result.applied, 1);
    expect(
      (await repoA.findPlaylistByName('改名歌单')),
      isNotNull,
    );

    clock = 3000;
    final currentRow = (await repoA.syncExportPlaylists())
        .firstWhere((p) => p.name == '改名歌单');
    final stale = SyncEnvelope(
      deviceId: 'devC',
      producedAt: 1,
      records: {
        SyncCategory.playlists: [
          SyncRecord(
            key: currentRow.syncId,
            updatedAt: 1,
            updatedBy: 'devC',
            data: PlaylistSyncRecord(
              syncId: currentRow.syncId,
              name: '旧名字',
              createdAt: 1,
              updatedAt: 1,
              updatedBy: 'devC',
            ).toJson(),
          ),
        ],
      },
    );
    final staleResult = await adapterA.apply(stale.records);
    expect(staleResult.applied, 0);
    expect(await repoA.findPlaylistByName('改名歌单'), isNotNull);
    expect(await repoA.findPlaylistByName('旧名字'), isNull);
  });

  test('删除经墓碑传播：B 删曲目、A 删列表', () async {
    final playlistId = await repoA.createPlaylist('歌单');
    await repoA.addTrackToPlaylist(playlistId, track('t1'));
    await repoA.addTrackToPlaylist(playlistId, track('t2'));
    await adapterB.apply(await adapterA.collect());

    // B 删除一条曲目 → A 应用后曲目消失。
    clock = 2000;
    final playlistB = await repoB.findPlaylistByName('歌单');
    await repoB.removeTrackFromPlaylist(playlistB!.id, 'wy', 't1');
    await adapterA.apply(await adapterB.collect());
    final tracksA = await repoA.listPlaylistTracks(playlistId);
    expect(tracksA.map((t) => t.songId), ['t2']);

    // A 删除整个列表 → B 应用后列表消失。
    clock = 3000;
    await repoA.deletePlaylist(playlistId);
    await adapterB.apply(await adapterA.collect());
    expect(await repoB.findPlaylistByName('歌单'), isNull);
    expect(await repoB.listPlaylists(), isEmpty);
  });

  test('远端新列表落地后可在本地继续编辑', () async {
    final playlistId = await repoA.createPlaylist('来源列表');
    await repoA.addTrackToPlaylist(playlistId, track('remote-1'));
    await adapterB.apply(await adapterA.collect());

    clock = 4000;
    final remoteInB = await repoB.findPlaylistByName('来源列表');
    await repoB.addTrackToPlaylist(remoteInB!.id, track('local-added'));
    await adapterA.apply(await adapterB.collect());

    final tracksA = await repoA.listPlaylistTracks(playlistId);
    expect(tracksA.map((t) => t.songId), containsAll(['remote-1', 'local-added']));
  });
}
