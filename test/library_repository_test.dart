import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/database_helper.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/lxmc_decoder.dart';
import 'package:molia/domain/models/library.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 资料库仓库测试：sqflite FFI in-memory 库（schema 与生产一致，v3）。
void main() {
  sqfliteFfiInit();

  late Database db;
  late LibraryRepository repository;

  Uint8List lxmcBytes(Map<String, dynamic> payload) => Uint8List.fromList(
        gzip.encode(utf8.encode(jsonEncode(payload))),
      );

  Map<String, dynamic> lxmcPayload(
    List<Map<String, dynamic>> list, {
    String name = 'list__name_test',
  }) =>
      {
        'type': 'playListPart_v2',
        'data': {'id': 'x', 'name': name, 'list': list},
      };

  Map<String, dynamic> track(int id, {String source = 'wy'}) => {
        'id': '${source}_$id',
        'name': 'Song $id',
        'singer': 'Artist $id',
        'source': source,
        'interval': '03:00',
        'meta': {
          'songId': id,
          'albumName': 'Album $id',
          'picUrl': 'https://img.example/$id.jpg',
          'qualitys': [
            {'type': '128k', 'size': '1 MiB'},
          ],
          '_qualitys': {
            '320k': {'size': '2 MiB'},
          },
        },
      };

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.dbVersion,
        onCreate: (database, version) => DatabaseHelper.createSchema(database),
      ),
    );
    repository = LibraryRepository(databaseProvider: () async => db);
  });

  tearDown(() async {
    await repository.dispose();
    await db.close();
  });

  PlayHistoryEntry history(String songId, {int? playedAt}) => PlayHistoryEntry(
        sourceKey: 'wy',
        songId: songId,
        title: 'Song $songId',
        artist: 'Artist',
        album: 'Album',
        coverUrl: 'https://img.example/$songId.jpg',
        durationMs: 180000,
        raw: {
          'songId': songId,
          'qualitys': [
            {'type': '320k'},
          ],
        },
        playedAt: playedAt ?? DateTime.now().millisecondsSinceEpoch,
      );

  group('play_history', () {
    test('写入 + playedAt 倒序查询 + raw 往返保真', () async {
      await repository.addHistoryEntry(history('1', playedAt: 100));
      await repository.addHistoryEntry(history('2', playedAt: 200));

      final list = await repository.listHistory();
      expect(list.map((e) => e.songId).toList(), ['2', '1']);
      expect(list.first.raw['songId'], '2');
      expect(list.first.raw['qualitys'], isA<List>());
      expect(list.first.durationMs, 180000);
    });

    test('唯一键去重：重复播放只更新时间', () async {
      await repository.addHistoryEntry(history('1', playedAt: 100));
      await repository.addHistoryEntry(history('1', playedAt: 300));

      final list = await repository.listHistory();
      expect(list, hasLength(1));
      expect(list.single.playedAt, 300);
    });

    test('上限 500：超出删最旧', () async {
      for (var i = 0; i < 505; i++) {
        await repository.addHistoryEntry(history('$i', playedAt: i));
      }
      final list = await repository.listHistory();
      expect(list, hasLength(LibraryRepository.historyLimit));
      expect(list.first.songId, '504');
      // 最旧的 5 条（0..4）被裁剪
      expect(list.map((e) => e.songId).contains('4'), isFalse);
      expect(list.map((e) => e.songId).contains('5'), isTrue);
    });

    test('删除单条 / 清空', () async {
      await repository.addHistoryEntry(history('1'));
      await repository.addHistoryEntry(history('2'));

      await repository.deleteHistoryEntry('wy', '1');
      expect((await repository.listHistory()).map((e) => e.songId), ['2']);

      await repository.clearHistory();
      expect(await repository.listHistory(), isEmpty);
    });

    test('批量删除：返回实际删除数（不存在的键忽略）', () async {
      await repository.addHistoryEntry(history('1', playedAt: 1));
      await repository.addHistoryEntry(history('2', playedAt: 2));
      await repository.addHistoryEntry(history('3', playedAt: 3));

      final removed = await repository.deleteHistoryEntries([
        (sourceKey: 'wy', songId: '1'),
        (sourceKey: 'wy', songId: '3'),
        (sourceKey: 'wy', songId: '404'),
      ]);
      expect(removed, 2);
      expect((await repository.listHistory()).map((e) => e.songId), ['2']);
    });

    test('批量写入：upsert 置顶 + 单次广播', () async {
      final events = <void>[];
      final subscription = repository.changes.listen(events.add);
      addTearDown(subscription.cancel);

      await repository.addHistoryEntries([
        history('1', playedAt: 100),
        history('2', playedAt: 200),
      ]);
      expect((await repository.listHistory()).map((e) => e.songId), ['2', '1']);

      await repository.addHistoryEntries([history('1', playedAt: 300)]);
      expect((await repository.listHistory()).map((e) => e.songId), ['1', '2']);

      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(2)); // 每次批量写入只广播一次
    });
  });

  group('playlists / playlist_tracks', () {
    test('创建 / 查询（带曲目数）/ 重命名 / 删除级联', () async {
      final id = await repository.createPlaylist('My List');
      await repository.addTrackToPlaylist(
        id,
        PlaylistTrack(
          playlistId: id,
          sourceKey: 'wy',
          songId: '1',
          title: 'A',
          addedAt: 1,
        ),
      );

      var infos = await repository.listPlaylists();
      expect(infos, hasLength(1));
      expect(infos.single.name, 'My List');
      expect(infos.single.trackCount, 1);

      await repository.renamePlaylist(id, 'Renamed');
      expect((await repository.playlistById(id))!.name, 'Renamed');

      await repository.deletePlaylist(id);
      expect(await repository.listPlaylists(), isEmpty);
      expect(await repository.listPlaylistTracks(id), isEmpty);
    });

    test('重复加入幂等（唯一约束）', () async {
      final id = await repository.createPlaylist('L');
      final track = PlaylistTrack(
        playlistId: id,
        sourceKey: 'wy',
        songId: '9',
        title: 'T',
        addedAt: 1,
      );
      expect(await repository.addTrackToPlaylist(id, track), isTrue);
      expect(await repository.addTrackToPlaylist(id, track), isFalse);
      expect(await repository.listPlaylistTracks(id), hasLength(1));
    });

    test('移除曲目', () async {
      final id = await repository.createPlaylist('L');
      await repository.addTrackToPlaylist(
        id,
        PlaylistTrack(
          playlistId: id,
          sourceKey: 'wy',
          songId: '9',
          title: 'T',
          addedAt: 1,
        ),
      );
      expect(await repository.removeTrackFromPlaylist(id, 'wy', '9'), 1);
      expect(await repository.listPlaylistTracks(id), isEmpty);
    });

    test('批量加入（跳过重复）/ 重排 / 批量移除', () async {
      final source = await repository.createPlaylist('Source');
      final target = await repository.createPlaylist('Target');
      PlaylistTrack track(String songId) => PlaylistTrack(
            playlistId: source,
            sourceKey: 'wy',
            songId: songId,
            title: 'T$songId',
            raw: {'songId': songId},
            addedAt: 1,
          );

      for (final songId in ['1', '2', '3']) {
        await repository.addTrackToPlaylist(source, track(songId));
      }
      // 目标列表已有 '2'：批量复制只新增 '1'、'3'。
      await repository.addTrackToPlaylist(target, track('2'));
      final added = await repository.addTracksToPlaylist(
        target,
        [track('1'), track('2'), track('3')],
      );
      expect(added, 2);
      expect(
        (await repository.listPlaylistTracks(target)).map((e) => e.songId),
        ['2', '1', '3'],
      );
      // 复制曲目归属目标列表，且 raw 原样保留。
      final copied = (await repository.listPlaylistTracks(target)).last;
      expect(copied.playlistId, target);
      expect(copied.raw['songId'], '3');

      await repository.reorderPlaylistTracks(target, [
        (sourceKey: 'wy', songId: '3'),
        (sourceKey: 'wy', songId: '2'),
        (sourceKey: 'wy', songId: '1'),
      ]);
      expect(
        (await repository.listPlaylistTracks(target)).map((e) => e.songId),
        ['3', '2', '1'],
      );

      final removed = await repository.removeTracksFromPlaylist(target, [
        (sourceKey: 'wy', songId: '2'),
        (sourceKey: 'wy', songId: '404'),
      ]);
      expect(removed, 1);
      expect(
        (await repository.listPlaylistTracks(target)).map((e) => e.songId),
        ['3', '1'],
      );
    });

    test('导入同名列表：创建 / 复用幂等 / 空导入不落库', () async {
      PlaylistTrack imported(String songId) => PlaylistTrack(
            playlistId: 0,
            sourceKey: 'wy',
            songId: songId,
            title: 'T$songId',
            raw: {'songId': songId},
            addedAt: 1,
          );
      final first = await repository.importTracks(
        '外部歌单',
        [imported('1'), imported('2')],
      );
      expect(first.added, 2);
      expect(first.total, 2);
      expect(first.playlistId, greaterThan(0));

      final again = await repository.importTracks(
        '外部歌单',
        [imported('1'), imported('2')],
      );
      expect(again.playlistId, first.playlistId);
      expect(again.added, 0);
      expect(await repository.listPlaylistTracks(first.playlistId),
          hasLength(2));

      final empty = await repository.importTracks('空歌单', const []);
      expect(empty.playlistId, -1);
      expect(empty.total, 0);
      expect(await repository.findPlaylistByName('空歌单'), isNull);
    });
  });

  group('收藏（默认列表）', () {
    test('切换收藏 + favoriteKeys', () async {
      expect(await repository.favoriteKeys(), isEmpty);

      final added = await repository.toggleFavorite(
        sourceKey: 'wy',
        songId: '1',
        title: 'A',
        artist: 'B',
        album: 'C',
        coverUrl: 'https://img.example/1.jpg',
        durationMs: 1000,
        raw: {'songId': 1},
      );
      expect(added, isTrue);
      expect(await repository.favoriteKeys(), {'wy:1'});

      final favorites = await repository.listPlaylists();
      expect(favorites.single.name, kFavoritesPlaylistName);
      expect(favorites.single.trackCount, 1);

      final removed = await repository.toggleFavorite(
        sourceKey: 'wy',
        songId: '1',
        title: 'A',
      );
      expect(removed, isFalse);
      expect(await repository.favoriteKeys(), isEmpty);
    });
  });

  group('.lxmc 导入', () {
    test('真实夹具导入 1018 首 + 重复导入幂等', () async {
      final bytes =
          File('test/fixtures/lx_list_love.lxmc').readAsBytesSync();

      final result = await repository.importLxmcBytes(
        Uint8List.fromList(bytes),
        fileName: 'lx_list_love.lxmc',
      );
      expect(result.playlistName, 'love');
      expect(result.total, 1018);
      expect(result.imported, 1018);
      expect(result.reusedPlaylist, isFalse);

      final tracks = await repository.listPlaylistTracks(result.playlistId);
      expect(tracks, hasLength(1018));
      expect(tracks.first.sourceKey, 'wy');
      expect(tracks.first.songId, '1888818113');
      expect(tracks.first.raw['qualitys'], isA<List>());

      // 重复导入：同名列表复用，唯一约束保证 0 新增
      final again = await repository.importLxmcBytes(
        Uint8List.fromList(bytes),
        fileName: 'lx_list_love.lxmc',
      );
      expect(again.playlistId, result.playlistId);
      expect(again.reusedPlaylist, isTrue);
      expect(again.imported, 0);
      expect(await repository.listPlaylistTracks(result.playlistId),
          hasLength(1018));
      expect(await repository.listPlaylists(), hasLength(1));
    });

    test('合成夹具：跳过非法条目并保持顺序', () async {
      final result = await repository.importLxmcBytes(
        lxmcBytes(lxmcPayload([
          track(1),
          {'id': 'wy_2', 'name': 'No source', 'meta': {'songId': 2}},
          track(3),
        ])),
      );
      expect(result.total, 2);
      expect(result.imported, 2);
      expect(result.skipped, 1);
      final tracks = await repository.listPlaylistTracks(result.playlistId);
      expect(tracks.map((t) => t.songId), ['1', '3']);
    });

    test('无可导入曲目 → LxmcDecodeException(no_tracks)', () async {
      expect(
        () => repository.importLxmcBytes(lxmcBytes(lxmcPayload(const []))),
        throwsA(isA<LxmcDecodeException>()
            .having((e) => e.reason, 'reason', 'no_tracks')),
      );
    });
  });

  test('changes 流在写操作后广播', () async {
    final events = <void>[];
    final subscription = repository.changes.listen(events.add);
    addTearDown(subscription.cancel);

    await repository.addHistoryEntry(history('1'));
    await repository.createPlaylist('L');

    // 广播是同步投递，等待微任务队列清空
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(2));
  });
}
