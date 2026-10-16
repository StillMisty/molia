import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/sync/adapters/playlist_sync_adapter.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/library.dart';
import 'support/sync_test_support.dart';

import 'support/memory_database.dart';

/// 歌单 / 收藏适配器测试：两库互导、LWW、删除墓碑、收藏固定 syncId。
void main() {
  late MoliaDatabase dbA;
  late MoliaDatabase dbB;
  late LibraryRepository repoA;
  late LibraryRepository repoB;
  late PlaylistSyncAdapter adapterA;
  late PlaylistSyncAdapter adapterB;
  var clock = 1000;

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
    dbA = openMemoryDatabase();
    dbB = openMemoryDatabase();
    repoA = LibraryRepository(
      databaseProvider: () => dbA,
      clock: () => clock,
      stamps: testStampIssuer(clock: () => clock, deviceId: 'devA'),
    );
    repoB = LibraryRepository(
      databaseProvider: () => dbB,
      clock: () => clock,
      stamps: testStampIssuer(clock: () => clock, deviceId: 'devB'),
    );
    adapterA = PlaylistSyncAdapter(repository: repoA);
    adapterB = PlaylistSyncAdapter(repository: repoB);
  });

  tearDown(() async {
    await repoA.dispose();
    await repoB.dispose();
    await dbA.close();
    await dbB.close();
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
            version: const SyncVersion(physical: 1, deviceId: 'devC'),
            data: PlaylistSyncRecord(
              syncId: currentRow.syncId,
              name: '旧名字',
              createdAt: 1,
              version: const SyncVersion(physical: 1, deviceId: 'devC'),
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

  test('换源更新版本：列表替换后的曲目可同步到对端', () async {
    final playlistId = await repoA.createPlaylist('歌单');
    await repoA.addTrackToPlaylist(playlistId, track('t1'));
    final before = (await repoA.syncExportPlaylistTracks()).single.version;

    clock = 2000;
    await repoA.replacePlaylistTrack(
      playlistId,
      (sourceKey: 'wy', songId: 't1'),
      track('t1', source: 'kw'),
    );
    final after = (await repoA.syncExportPlaylistTracks()).single.version;
    expect(
      after.isNewerThan(before),
      isTrue,
      reason: '换源是本地修改：版本必须前进（否则永不传播）',
    );

    final result = await adapterB.apply(await adapterA.collect());
    expect(result.applied, greaterThanOrEqualTo(1));
    final inB = await repoB.findPlaylistByName('歌单');
    final tracksB = await repoB.listPlaylistTracks(inB!.id);
    expect(tracksB.single.sourceKey, 'kw');
  });

  test('本地下载曲目（local）不同步：曲目与墓碑都过滤', () async {
    final playlistId = await repoA.createPlaylist('混合');
    await repoA.addTrackToPlaylist(playlistId, track('t1'));
    await repoA.addTrackToPlaylist(playlistId, track('wy:9', source: 'local'));
    // 加一条本地曲目再移除：产生 local 墓碑。
    await repoA.addTrackToPlaylist(playlistId, track('wy:8', source: 'local'));
    await repoA.removeTrackFromPlaylist(playlistId, 'local', 'wy:8');

    final collected = await adapterA.collect();
    final trackRecords = collected[SyncCategory.playlistTracks]!;
    expect(
      trackRecords.where((record) => !record.deleted).map(
            (record) => record.data!['sourceKey'],
          ),
      ['wy'],
    );
    expect(trackRecords.where((record) => record.deleted), isEmpty);

    // 对端收到 local 曲目也忽略（防御：异常或外来数据）。
    final result = await adapterB.apply({
      SyncCategory.playlistTracks: [
        SyncRecord(
          key: SyncRecordKeys.playlistTrack('sync-1', 'local', 'wy:9'),
          version: const SyncVersion(physical: 3000, deviceId: 'devA'),
          data: const {
            'playlistSyncId': 'sync-1',
            'sourceKey': 'local',
            'songId': 'wy:9',
            'title': '本地下载',
          },
        ),
      ],
    });
    expect(result.applied, 0);
    expect(await repoB.findPlaylistByName('混合'), isNull);
  });

  test('collect 门控：指纹未变复用上轮记录，不读行', () async {
    final counting = CountingLibrarySyncStore(repoA);
    final adapter = PlaylistSyncAdapter(repository: counting);
    await repoA.toggleFavorite(sourceKey: 'wy', songId: 'fav-1', title: 'F');

    final first = await adapter.collect();
    expect(first[SyncCategory.playlists], isNotEmpty);
    expect(counting.exportCalls, greaterThan(0));
    final readsAfterFirst = counting.exportCalls;

    // 无写入：指纹未变，第二次 collect 直接复用缓存（不读行）。
    final second = await adapter.collect();
    expect(identical(first, second), isTrue);
    expect(counting.exportCalls, readsAfterFirst);
    expect(counting.fingerprintCalls, 2);

    // 本地写入推进版本 → 指纹变化 → 重新读行。
    clock = 5000;
    await repoA.createPlaylist('新列表');
    final third = await adapter.collect();
    expect(counting.exportCalls, greaterThan(readsAfterFirst));
    expect(third[SyncCategory.playlists]!.length,
        greaterThan(first[SyncCategory.playlists]!.length));
  });
}
