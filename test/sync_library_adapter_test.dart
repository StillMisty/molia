import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/data/library_repository.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/sync/sync_backup.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/data/sync/adapters/change_detecting_adapter.dart';
import 'package:molia/data/sync/adapters/playlist_sync_adapter.dart';
import 'package:molia/data/sync/sync_adapter.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/playlist_folders.dart';

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

    final collected = await adapterA.exportRecords();
    final result = await adapterB.apply(collected);
    expect(result.applied, 5); // 2 列表（收藏 + 歌单）+ 3 曲目（收藏 1 + 歌单 2）

    final playlistsB = await repoB.listPlaylists();
    expect(playlistsB.map((p) => p.name), containsAll(['通勤歌单']));
    expect(await repoB.favoriteKeys(), contains('wy:fav-1'));

    final playlistB = await repoB.findPlaylistByName('通勤歌单');
    final tracksB = await repoB.listPlaylistTracks(playlistB!.id);
    expect(tracksB.map((t) => t.songId), ['t1', 't2']);

    // 再应用一次：全部跳过（幂等）。
    final again = await adapterB.apply(await adapterA.exportRecords());
    expect(again.applied, 0);
  });

  test('releaseCaches：清空记录缓存，下一次 collect 重新导出', () async {
    await repoA.toggleFavorite(
      sourceKey: 'wy',
      songId: 'fav-1',
      title: 'Favorite',
    );
    final adapter = _detectingAdapter(repoA);
    final first = await adapter.collect();
    final cached = await adapter.collect();
    expect(identical(cached, first), isTrue, reason: '指纹未变复用缓存');

    adapter
      ..releaseCaches()
      ..releaseCaches();
    final rebuilt = await adapter.collect();
    expect(identical(rebuilt, first), isFalse, reason: '释放后重新读取');
    expect(
      rebuilt[SyncCategory.playlists]!.map((record) => record.key),
      first[SyncCategory.playlists]!.map((record) => record.key),
    );
  });

  test('收藏列表使用固定 syncId', () async {
    await repoA.toggleFavorite(sourceKey: 'kw', songId: 'x', title: 'X');
    final playlists = await repoA.syncExportPlaylists();
    // 同步记录不带收藏概念（合并键是固定 syncId），按保留行名取。
    final favorites = playlists.firstWhere((p) => p.name == '__favorites__');
    expect(favorites.syncId, SyncRecordKeys.favoritesPlaylistSyncId);
  });

  test('B 修改后 A 应用：远端更新者胜出（LWW）', () async {
    final playlistId = await repoA.createPlaylist('歌单');
    await repoA.addTrackToPlaylist(playlistId, track('t1'));
    await adapterB.apply(await adapterA.exportRecords());

    clock = 2000;
    await repoB.renamePlaylist(
      (await repoB.findPlaylistByName('歌单'))!.id,
      '改名歌单',
    );
    final result = await adapterA.apply(await adapterB.exportRecords());
    expect(result.applied, 1);
    expect((await repoA.findPlaylistByName('改名歌单')), isNotNull);

    clock = 3000;
    final currentRow = (await repoA.syncExportPlaylists()).firstWhere(
      (p) => p.name == '改名歌单',
    );
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
    await adapterB.apply(await adapterA.exportRecords());

    // B 删除一条曲目 → A 应用后曲目消失。
    clock = 2000;
    final playlistB = await repoB.findPlaylistByName('歌单');
    await repoB.removeTrackFromPlaylist(playlistB!.id, 'wy', 't1');
    await adapterA.apply(await adapterB.exportRecords());
    final tracksA = await repoA.listPlaylistTracks(playlistId);
    expect(tracksA.map((t) => t.songId), ['t2']);

    // A 删除整个列表 → B 应用后列表消失。
    clock = 3000;
    await repoA.deletePlaylist(playlistId);
    await adapterB.apply(await adapterA.exportRecords());
    expect(await repoB.findPlaylistByName('歌单'), isNull);
    expect(await repoB.listPlaylists(), isEmpty);
  });

  test('远端新列表落地后可在本地继续编辑', () async {
    final playlistId = await repoA.createPlaylist('来源列表');
    await repoA.addTrackToPlaylist(playlistId, track('remote-1'));
    await adapterB.apply(await adapterA.exportRecords());

    clock = 4000;
    final remoteInB = await repoB.findPlaylistByName('来源列表');
    await repoB.addTrackToPlaylist(remoteInB!.id, track('local-added'));
    await adapterA.apply(await adapterB.exportRecords());

    final tracksA = await repoA.listPlaylistTracks(playlistId);
    expect(
      tracksA.map((t) => t.songId),
      containsAll(['remote-1', 'local-added']),
    );
  });

  test('换源更新版本：列表替换后的曲目可同步到对端', () async {
    final playlistId = await repoA.createPlaylist('歌单');
    await repoA.addTrackToPlaylist(playlistId, track('t1'));
    final before = (await repoA.syncExportPlaylistTracks()).single.version;

    clock = 2000;
    await repoA.replacePlaylistTrack(playlistId, (
      sourceKey: 'wy',
      songId: 't1',
    ), track('t1', source: 'kw'));
    final after = (await repoA.syncExportPlaylistTracks()).single.version;
    expect(after.isNewerThan(before), isTrue, reason: '换源是本地修改：版本必须前进（否则永不传播）');

    final result = await adapterB.apply(await adapterA.exportRecords());
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

    final collected = await adapterA.exportRecords();
    final trackRecords = collected[SyncCategory.playlistTracks]!;
    expect(
      trackRecords
          .where((record) => !record.deleted)
          .map((record) => record.data!['sourceKey']),
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
    final adapter = ChangeDetectingAdapter(
      source: PlaylistSyncAdapter(repository: counting),
      fingerprint: () async => syncFingerprintKey(
        await counting.syncFingerprints(const {
          SyncCategory.playlists,
          SyncCategory.playlistTracks,
        }),
      ),
    );
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
    expect(
      third[SyncCategory.playlists]!.length,
      greaterThan(first[SyncCategory.playlists]!.length),
    );
  });

  test('列表详情 A→B / B→A 往返保留描述、分组与封面键', () async {
    final id = await repoA.createPlaylist('通勤');
    await repoA.updatePlaylistDetails(
      id,
      name: '通勤',
      description: '早上的歌',
      folder: 'Work',
    );
    final syncId = (await repoA.playlistById(id))!.syncId!;
    await repoA.setPlaylistCoverKey(id, 'playlist:$syncId');

    await adapterB.apply(await adapterA.exportRecords());
    var infoB = await repoB.findPlaylistByName('通勤');
    expect(infoB!.description, '早上的歌');
    expect(infoB.folder, 'Work');
    expect(infoB.coverKey, 'playlist:$syncId');

    clock = 2000;
    await repoB.updatePlaylistDetails(
      infoB.id,
      name: '通勤',
      description: 'B 端描述',
      folder: 'Commute',
    );
    await adapterA.apply(await adapterB.exportRecords());
    final infoA = await repoA.findPlaylistByName('通勤');
    expect(infoA!.description, 'B 端描述');
    expect(infoA.folder, 'Commute');
  });

  test('旧形状记录（缺新字段）解析为无描述 / 未分组 / 无封面', () async {
    await repoA.createPlaylist('旧记录');
    final row = (await repoA.syncExportPlaylists()).firstWhere(
      (item) => item.name == '旧记录',
    );
    final legacy = SyncRecord(
      key: row.syncId,
      version: const SyncVersion(physical: 99, deviceId: 'old'),
      data: {
        'syncId': row.syncId,
        'name': '旧记录',
        'createdAt': 1,
        'version': const SyncVersion(physical: 99, deviceId: 'old').toJson(),
      },
    );
    final result = await adapterB.apply({
      SyncCategory.playlists: [legacy],
    });
    expect(result.applied, 1);
    final info = await repoB.findPlaylistByName('旧记录');
    expect(info!.description, '');
    expect(info.folder, '');
    expect(info.coverKey, isNull);
  });

  test('脏类型的新字段按空值解析，不抛异常', () {
    final record = PlaylistSyncRecord.fromJson({
      'syncId': 123,
      'name': false,
      'createdAt': 'x',
      'description': 7,
      'folder': ['Work'],
      'coverKey': 9,
    });
    expect(record.syncId, '');
    expect(record.name, '');
    expect(record.createdAt, 0);
    expect(record.description, '');
    expect(record.folder, '');
    expect(record.coverKey, isNull);
  });

  test('同步带来的 " Work " 归一为 Work，并可重命名 / 删除', () async {
    await repoA.createPlaylist('通勤');
    final row = (await repoA.syncExportPlaylists()).single;
    await adapterB.apply({
      SyncCategory.playlists: [
        SyncRecord(
          key: row.syncId,
          version: const SyncVersion(physical: 5000, deviceId: 'devA'),
          data: PlaylistSyncRecord(
            syncId: row.syncId,
            name: '通勤',
            createdAt: row.createdAt,
            folder: ' Work ',
            version: const SyncVersion(physical: 5000, deviceId: 'devA'),
          ).toJson(),
        ),
      ],
    });
    var info = await repoB.findPlaylistByName('通勤');
    expect(info!.folder, 'Work');
    expect(
      groupPlaylistsByFolder(await repoB.listPlaylists()).single.folder,
      'Work',
    );
    expect(await repoB.renamePlaylistFolder('Work', 'Gym'), 1);
    info = await repoB.findPlaylistByName('通勤');
    expect(info!.folder, 'Gym');
    expect(await repoB.deletePlaylistFolder('Gym'), 1);
    expect((await repoB.findPlaylistByName('通勤'))!.folder, '');
  });

  test('分组重命名扇出抵达对端并收敛', () async {
    final a = await repoA.createPlaylist('A');
    final b = await repoA.createPlaylist('B');
    for (final id in [a, b]) {
      await repoA.updatePlaylistDetails(
        id,
        name: id == a ? 'A' : 'B',
        description: '',
        folder: 'Work',
      );
    }
    await adapterB.apply(await adapterA.exportRecords());
    clock = 2000;
    await repoA.renamePlaylistFolder('Work', 'Gym');
    await adapterB.apply(await adapterA.exportRecords());
    final rowsB = await repoB.listPlaylists();
    expect(
      {for (final row in rowsB) row.name: row.folder},
      {'A': 'Gym', 'B': 'Gym'},
    );
  });

  test('收藏行描述与封面在固定收藏键下往返', () async {
    await repoA.toggleFavorite(sourceKey: 'wy', songId: 'f1', title: 'F');
    final favorites = await repoA.findPlaylistByName('__favorites__');
    await repoA.updatePlaylistDetails(
      favorites!.id,
      name: '__favorites__',
      description: '收藏说明',
      folder: '',
    );
    await repoA.setPlaylistCoverKey(favorites.id, 'playlist:__favorites__');
    await adapterB.apply(await adapterA.exportRecords());
    final favoritesB = await repoB.findPlaylistByName('__favorites__');
    expect(favoritesB!.description, '收藏说明');
    expect(favoritesB.coverKey, 'playlist:__favorites__');
  });

  test('.molia.json：只含目标列表与曲目，导入按 syncId 合并不重复', () async {
    SharedPreferences.setMockInitialValues({});
    final target = await repoA.createPlaylist('目标');
    final other = await repoA.createPlaylist('别的');
    await repoA.updatePlaylistDetails(
      target,
      name: '目标',
      description: '说明',
      folder: 'Work',
    );
    await repoA.addTrackToPlaylist(target, track('t1'));
    await repoA.addTrackToPlaylist(other, track('other'));
    final targetRow = (await repoA.syncExportPlaylists()).firstWhere(
      (row) => row.name == '目标',
    );

    final stateA = SyncStateStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySyncSecretStore(),
      clock: () => clock,
      deviceId: 'devA',
    );
    await stateA.init();
    final backupA = SyncBackup(
      state: stateA,
      pipeline: testRecordPipeline(
        adapters: [_detectingAdapter(repoA)],
        deviceId: 'devA',
      ),
      stamps: stateA.stampIssuer,
    );
    final json = await backupA.exportPlaylistJson(
      playlistSyncId: targetRow.syncId,
      coverKey: 'playlist:${targetRow.syncId}',
    );
    expect(json, contains('目标'));
    expect(json, contains('"description": "说明"'));
    expect(json, isNot(contains('别的')));
    expect(json, isNot(contains('"settings"')));

    final stateB = SyncStateStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySyncSecretStore(),
      clock: () => clock,
      deviceId: 'devB',
    );
    await stateB.init();
    final backupB = SyncBackup(
      state: stateB,
      pipeline: testRecordPipeline(
        adapters: [_detectingAdapter(repoB)],
        deviceId: 'devB',
      ),
      stamps: stateB.stampIssuer,
    );
    await backupB.importBackupJson(json);
    final imported = await repoB.findPlaylistByName('目标');
    expect(imported, isNotNull);
    final tracksB = await repoB.listPlaylistTracks(imported!.id);
    expect(tracksB.map((item) => item.songId), ['t1']);
    expect(await repoB.findPlaylistByName('别的'), isNull);

    await backupB.importBackupJson(json);
    expect(
      (await repoB.listPlaylists()).where((row) => row.name == '目标').length,
      1,
      reason: '重复导入按 syncId LWW 合并，不造第二个列表',
    );
  });
}

/// 生产接线：行表适配器只导出 / 应用，缓存与 fresh 在装饰器里。
ChangeDetectingAdapter _detectingAdapter(LibraryRepository repository) =>
    ChangeDetectingAdapter(
      source: PlaylistSyncAdapter(repository: repository),
      fingerprint: () async => syncFingerprintKey(
        await repository.syncFingerprints(const {
          SyncCategory.playlists,
          SyncCategory.playlistTracks,
        }),
      ),
    );
