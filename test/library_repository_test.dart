import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/library_read_model.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/lxmc_decoder.dart';
import 'package:molia/data/lxmc_decoder_io.dart'
    show lxmcDecodeIsolateThreshold, shouldDecodeLxmcBytesOffThread;
import 'package:molia/data/molia_database.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/library.dart';
import 'support/sync_test_support.dart';

import 'support/memory_database.dart';

/// 资料库仓库测试：drift in-memory 库（schema 与生产一致）。
void main() {
  late MoliaDatabase db;
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

  /// 超过 isolate 阈值的错误输入：确保仓库导入走异步解码路径。
  Uint8List largeInvalidJson() {
    final random = Random(7);
    final noise = List<int>.generate(
      lxmcDecodeIsolateThreshold + 1024,
      (_) => random.nextInt(256),
    );
    return Uint8List.fromList(gzip.encode(noise));
  }

  Uint8List largeWrongRoot() => lxmcBytes({
        'type': 'playList_v2',
        'data': {
          'id': 'x',
          'name': 'x',
          'list': [for (var i = 0; i < 4000; i++) track(i)],
        },
      });

  setUp(() async {
    db = openMemoryDatabase();
    repository = LibraryRepository(
      databaseProvider: () => db,
      stamps: testStampIssuer(),
    );
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
      final events = <LibraryChange>[];
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

    test('批量加入历史：写路径盖批内时间戳，listHistory 按批次倒序', () async {
      final fixed = LibraryRepository(
        databaseProvider: () => db,
        clock: () => 1000,
        stamps: testStampIssuer(),
      );
      addTearDown(fixed.dispose);
      PlaylistTrack track(String songId) => PlaylistTrack(
            playlistId: 0,
            sourceKey: 'wy',
            songId: songId,
            title: 'Song $songId',
            addedAt: 1,
          );

      expect(
        await fixed.addHistoryTracks([track('1'), track('2'), track('3')]),
        3,
      );
      final list = await fixed.listHistory();
      // 后写入的 playedAt 更大 + rowid 更大：整批在历史顶部倒序。
      expect(list.map((entry) => entry.songId), ['3', '2', '1']);
      expect(list.map((entry) => entry.playedAt), [1002, 1001, 1000]);

      // 显式基准：调用方只给批内起点，偏移仍由写路径负责。
      await fixed.addHistoryTracks([track('4'), track('5')], playedAt: 2000);
      expect(
        (await fixed.listHistory()).map((entry) => entry.songId),
        ['5', '4', '3', '2', '1'],
      );
    });

    test('DB 顺序与 LibraryHistoryOrder.resortByRecency 等价', () async {
      for (final (index, playedAt)
          in [(0, 100), (1, 400), (2, 300), (3, 200)]) {
        await repository.addHistoryEntry(
          history('${index + 1}', playedAt: playedAt),
        );
      }
      final fresh = await repository.listHistory();
      expect(fresh.map((entry) => entry.songId), ['2', '3', '4', '1']);

      // 内存侧只保证 playedAt 倒序；不同时刻的条目顺序必须与 DB 完全一致。
      final current = fresh.reversed.toList();
      final resorted = LibraryHistoryOrder.resortByRecency(current);
      expect(
        resorted.map((entry) => entry.songId),
        fresh.map((entry) => entry.songId),
        reason: '内存排序口径必须能复现仓库 ORDER BY playedAt DESC',
      );
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

    test('limit 只取既有顺序的前 N 首（下推到查询）', () async {
      final id = await repository.createPlaylist('L');
      for (var i = 1; i <= 5; i++) {
        await repository.addTrackToPlaylist(
          id,
          PlaylistTrack(
            playlistId: id,
            sourceKey: 'wy',
            songId: '$i',
            title: 'T$i',
            addedAt: 1,
          ),
        );
      }

      final all = await repository.listPlaylistTracks(id);
      final limited = await repository.listPlaylistTracks(id, limit: 2);

      expect(all, hasLength(5));
      expect(limited, hasLength(2));
      expect(
        limited.map((track) => track.songId),
        all.take(2).map((track) => track.songId),
        reason: 'limit 不改变排序，只截断尾部',
      );
      expect(await repository.listPlaylistTracks(id, limit: 99), hasLength(5));
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
      expect(first.created, isTrue, reason: '新建列表要能告诉调用方可以预置缓存');
      // rows 是写路径实际落库行：位置字段已分配，消费方不必再去重 / 重排。
      expect(first.rows.map((track) => track.songId), ['1', '2']);
      expect(
        first.rows.map((track) => track.playlistId),
        everyElement(first.playlistId),
      );
      expect(first.rows.map((track) => track.sortOrder), [0, 1]);
      expect(first.rows.map((track) => track.addedAt), everyElement(1));

      final again = await repository.importTracks(
        '外部歌单',
        [imported('1'), imported('2')],
      );
      expect(again.playlistId, first.playlistId);
      expect(again.added, 0);
      expect(again.created, isFalse);
      expect(again.rows, isEmpty);
      expect(await repository.listPlaylistTracks(first.playlistId),
          hasLength(2));

      final empty = await repository.importTracks('空歌单', const []);
      expect(empty.playlistId, -1);
      expect(empty.total, 0);
      expect(empty.created, isFalse);
      expect(empty.rows, isEmpty);
      expect(await repository.findPlaylistByName('空歌单'), isNull);
    });
  });

  group('换源（原位替换）', () {
    PlaylistTrack track(String songId, {String source = 'wy'}) => PlaylistTrack(
          playlistId: 0,
          sourceKey: source,
          songId: songId,
          title: 'T$songId',
          artist: 'A$songId',
          album: 'B$songId',
          raw: {'songId': songId, 'origin': source},
          addedAt: 1,
        );

    test('列表：保留位置与 sortOrder/addedAt，元数据与 raw 替换', () async {
      final id = await repository.createPlaylist('L');
      for (final songId in ['1', '2', '3']) {
        await repository.addTrackToPlaylist(id, track(songId));
      }
      final before = await repository.listPlaylistTracks(id);

      final ok = await repository.replacePlaylistTrack(
        id,
        (sourceKey: 'wy', songId: '2'),
        PlaylistTrack(
          playlistId: id,
          sourceKey: 'kg',
          songId: '900',
          title: 'T2 kg',
          artist: 'A2',
          album: 'B2',
          coverUrl: 'https://img.example/900.jpg',
          durationMs: 222000,
          raw: {'hash': 'h900'},
          addedAt: 999,
        ),
      );
      expect(ok, isTrue);

      final after = await repository.listPlaylistTracks(id);
      expect(after.map((t) => t.songId), ['1', '900', '3']);
      final swapped = after[1];
      expect(swapped.sourceKey, 'kg');
      expect(swapped.title, 'T2 kg');
      expect(swapped.artist, 'A2');
      expect(swapped.raw['hash'], 'h900');
      // 原位：位置/sortOrder/addedAt 沿用旧行（忽略 replacement 传入值）。
      expect(swapped.sortOrder, before[1].sortOrder);
      expect(swapped.addedAt, before[1].addedAt);
    });

    test('列表：目标键已存在时去重，旧行落在原位置', () async {
      final id = await repository.createPlaylist('L');
      await repository.addTrackToPlaylist(id, track('1'));
      await repository.addTrackToPlaylist(id, track('2'));
      await repository.addTrackToPlaylist(id, track('900', source: 'kg'));

      final ok = await repository.replacePlaylistTrack(
        id,
        (sourceKey: 'wy', songId: '1'),
        track('900', source: 'kg'),
      );
      expect(ok, isTrue);

      final after = await repository.listPlaylistTracks(id);
      expect(
        after.map((t) => '${t.sourceKey}:${t.songId}'),
        ['kg:900', 'wy:2'],
      );
    });

    test('列表：旧键不存在返回 false 且不广播', () async {
      final id = await repository.createPlaylist('L');
      final events = <LibraryChange>[];
      final subscription = repository.changes.listen(events.add);
      addTearDown(subscription.cancel);

      final ok = await repository.replacePlaylistTrack(
        id,
        (sourceKey: 'wy', songId: '404'),
        track('900', source: 'kg'),
      );
      expect(ok, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
    });

    test('收藏列表换源：变更事件为 favorites', () async {
      final events = <LibraryChange>[];
      final subscription = repository.changes.listen(events.add);
      addTearDown(subscription.cancel);

      await repository.toggleFavorite(
        sourceKey: 'wy',
        songId: '1',
        title: 'T1',
      );
      // 保留行名是存储层细节，这里按字面量钉住（既有用户数据的契约）。
      final favorites = await repository.findPlaylistByName('__favorites__');

      final ok = await repository.replacePlaylistTrack(
        favorites!.id,
        (sourceKey: 'wy', songId: '1'),
        track('900', source: 'kg'),
        favoriteChange: true,
      );
      expect(ok, isTrue);
      expect(events.last, isA<LibraryFavoritesChange>());
      expect(
        (await repository.listPlaylistTracks(favorites.id))
            .map((t) => '${t.sourceKey}:${t.songId}'),
        ['kg:900'],
      );
    });

    test('历史：保留 playedAt；目标键已存在时合并去重', () async {
      await repository.addHistoryEntry(history('1', playedAt: 100));
      await repository.addHistoryEntry(history('2', playedAt: 200));

      final ok = await repository.replaceHistoryEntry(
        (sourceKey: 'wy', songId: '1'),
        PlayHistoryEntry(
          sourceKey: 'kg',
          songId: '900',
          title: 'T900',
          artist: 'A',
          raw: {'hash': 'h900'},
          playedAt: 999,
        ),
      );
      expect(ok, isTrue);

      var list = await repository.listHistory();
      expect(list.map((e) => e.songId), ['2', '900']);
      expect(list.last.sourceKey, 'kg');
      expect(list.last.raw['hash'], 'h900');
      // 换源不改「何时听的」：沿用旧行 playedAt（忽略 replacement 传入值）。
      expect(list.last.playedAt, 100);

      // 目标键（wy:2）已存在：删重复行后原位替换，仍保旧 playedAt。
      final ok2 = await repository.replaceHistoryEntry(
        (sourceKey: 'kg', songId: '900'),
        history('2', playedAt: 888),
      );
      expect(ok2, isTrue);
      list = await repository.listHistory();
      expect(list.map((e) => '${e.sourceKey}:${e.songId}'), ['wy:2']);
      expect(list.single.playedAt, 100);
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
      expect(favorites.single.name, '__favorites__');
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
      final bytes = Uint8List.fromList(
          File('test/fixtures/lx_list_love.lxmc').readAsBytesSync());
      // 夹具压缩后 >64KB：走异步解码，与同步结果对齐后再落库。
      expect(bytes.length, greaterThan(lxmcDecodeIsolateThreshold));
      expect(shouldDecodeLxmcBytesOffThread(bytes), isTrue);
      final decoded = decodeLxmcBytes(bytes, fileName: 'lx_list_love.lxmc');

      final result = await repository.importLxmcBytes(
        bytes,
        fileName: 'lx_list_love.lxmc',
      );
      expect(result.playlistName, decoded.name);
      expect(result.total, decoded.tracks.length);
      expect(result.skipped, decoded.skipped);
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
        bytes,
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

    test('大文件错误原因经仓库导入保持', () async {
      final cases = <(Uint8List, String)>[
        (Uint8List(lxmcDecodeIsolateThreshold), 'not_gzip'),
        (largeInvalidJson(), 'invalid_json'),
        (largeWrongRoot(), 'not_play_list'),
      ];
      for (final (bytes, reason) in cases) {
        expect(shouldDecodeLxmcBytesOffThread(bytes), isTrue);
        await expectLater(
          repository.importLxmcBytes(bytes),
          throwsA(isA<LxmcDecodeException>()
              .having((e) => e.reason, 'reason', reason)),
        );
      }
    });
  });

  test('changes 流在写操作后广播', () async {
    final events = <LibraryChange>[];
    final subscription = repository.changes.listen(events.add);
    addTearDown(subscription.cancel);

    await repository.addHistoryEntry(history('1'));
    await repository.createPlaylist('L');

    // 广播是同步投递，等待微任务队列清空
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(2));
  });

  test('同步指纹：写入推进指纹，syncId 补齐后指纹变化', () async {
    final categories = [
      SyncCategory.playlists,
      SyncCategory.playlistTracks,
      SyncCategory.history,
    ];
    final empty = await repository.syncFingerprints(categories);
    expect(empty.keys, containsAll(categories));

    await repository.createPlaylist('L');
    final afterCreate = await repository.syncFingerprints(categories);
    expect(afterCreate[SyncCategory.playlists],
        isNot(empty[SyncCategory.playlists]));

    await repository.addHistoryEntry(history('1'));
    final afterHistory = await repository.syncFingerprints(categories);
    expect(afterHistory[SyncCategory.history],
        isNot(afterCreate[SyncCategory.history]));

    // 缺 syncId 的行计入指纹：导出补齐后指纹随之变化（不会被缓存跳过）。
    await db.into(db.playlists).insert(
          PlaylistsCompanion.insert(name: '无 syncId', createdAt: 1),
        );
    final withNull = await repository.syncFingerprints(categories);
    expect(withNull[SyncCategory.playlists],
        isNot(afterHistory[SyncCategory.playlists]));
    await repository.syncExportPlaylists();
    final backfilled = await repository.syncFingerprints(categories);
    expect(backfilled[SyncCategory.playlists],
        isNot(withNull[SyncCategory.playlists]));
  });

  test('同步指纹：同一物理值内 counter 变化也算变化', () async {
    // 固定时钟：两次写入共享物理分量，只有 versionCounter 推进。
    final fixed = LibraryRepository(
      databaseProvider: () => db,
      clock: () => 1000,
      stamps: testStampIssuer(clock: () => 1000, deviceId: 'devA'),
    );
    addTearDown(fixed.dispose);
    final playlistId = await fixed.createPlaylist('L');
    final first =
        (await fixed.syncFingerprints([SyncCategory.playlists]))[
            SyncCategory.playlists];
    await fixed.renamePlaylist(playlistId, 'L2');
    final second =
        (await fixed.syncFingerprints([SyncCategory.playlists]))[
            SyncCategory.playlists];
    expect(second, isNot(first));
  });
}
