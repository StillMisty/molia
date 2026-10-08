import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/database_helper.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/sources/source_track.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fakes.dart';

/// LibraryProvider 测试：内存缓存 / 播放接线 / 收藏 / 导入。
void main() {
  sqfliteFfiInit();
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late LibraryRepository repository;
  late FakePlaybackBackend backend;
  late PlaybackProvider playback;
  late LibraryProvider provider;

  Uint8List lxmcBytes(List<Map<String, dynamic>> list,
      {String name = 'list__name_test'}) {
    return Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode({
      'type': 'playListPart_v2',
      'data': {'id': 'x', 'name': name, 'list': list},
    }))));
  }

  Map<String, dynamic> track(int id) => {
        'id': 'wy_$id',
        'name': 'Song $id',
        'singer': 'Artist $id',
        'source': 'wy',
        'interval': '03:00',
        'meta': {
          'songId': id,
          'albumName': 'Album $id',
          'picUrl': 'https://img.example/$id.jpg',
          'qualitys': [
            {'type': '320k', 'size': '2 MiB'},
          ],
          '_qualitys': {
            'flac': {'size': '10 MiB', 'hash': 'h$id'},
          },
        },
      };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.dbVersion,
        onCreate: (database, version) => DatabaseHelper.createSchema(database),
      ),
    );
    repository = LibraryRepository(databaseProvider: () async => db);
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(
      backend: backend,
      libraryRepository: repository,
    );
    provider = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
  });

  tearDown(() async {
    provider.dispose();
    playback.dispose();
    await repository.dispose();
    await db.close();
  });

  Future<void> settle() async {
    // 先让 changes 事件送达 provider，再确定性等待其重载 Future 完成
    await Future<void>.delayed(Duration.zero);
    final pending = provider.pendingReload;
    if (pending != null) await pending;
  }

  test('历史写入后缓存自动失效并重载', () async {
    await provider.refreshHistory();
    expect(provider.history, isEmpty);

    await repository.addHistoryEntry(PlayHistoryEntry(
      sourceKey: 'wy',
      songId: '1',
      title: 'Song 1',
      artist: 'Artist',
      album: 'Album',
      durationMs: 1000,
      raw: {'songId': 1},
      playedAt: 1,
    ));
    await settle();

    expect(provider.history, hasLength(1));
    expect(provider.history.single.songId, '1');
  });

  test('playHistory：还原 SourceTrack（raw/qualities/时长）并委托播放', () async {
    await repository.addHistoryEntry(PlayHistoryEntry(
      sourceKey: 'wy',
      songId: '1',
      title: 'Song 1',
      artist: 'Artist',
      album: 'Album',
      coverUrl: 'https://img.example/1.jpg',
      durationMs: 1000,
      raw: {
        'songId': 1,
        'qualitys': [
          {'type': '320k', 'size': '2 MiB'},
        ],
        '_qualitys': {
          'flac': {'size': '10 MiB', 'hash': 'h1'},
        },
      },
      playedAt: 1,
    ));
    await settle();
    await provider.refreshHistory(force: true);

    await provider.playHistory(provider.history, 0, contextName: '最近播放');

    final request = backend.lastRequest;
    expect(request, isNotNull);
    expect(request!.tracks, hasLength(1));
    expect(request.startIndex, 0);
    expect(request.context?.name, '最近播放');
    final track = request.tracks.single;
    expect(track.id.sourceKey, 'wy');
    expect(track.id.id, '1');
    expect(track.title, 'Song 1');
    expect(track.payload['songId'], 1);
    // .lxmc 导入的 wy raw 只有 songId；播放前补齐脚本取链用的 songmid。
    expect(track.payload['songmid'], '1');
    expect(track.qualities.map((q) => q.type), containsAll(['320k', 'flac']));
    expect(track.qualities.firstWhere((q) => q.type == 'flac').hash, 'h1');
    expect(track.duration, const Duration(seconds: 1));
  });

  test('playPlaylistTracks：列表曲目委托播放', () async {
    final result = await provider.importLxmcBytes(
      lxmcBytes([track(1), track(2)]),
    );
    expect(result.imported, 2);

    final tracks =
        await provider.loadPlaylistTracks(result.playlistId, force: true);
    await provider.playPlaylistTracks(tracks, 1, contextName: 'test');

    final request = backend.lastRequest;
    expect(request!.tracks, hasLength(2));
    expect(request.startIndex, 1);
    expect(request.tracks[1].payload['songId'], 2);
    expect(request.tracks[1].payload['songmid'], '2');
  });

  test('raw 规范 id 补齐：只增不删，已有值不覆盖', () async {
    await repository.addHistoryEntry(PlayHistoryEntry(
      sourceKey: 'wy',
      songId: '1',
      title: 'T',
      raw: {'songId': 1, 'albumName': 'A'},
      playedAt: 1,
    ));
    await settle();
    await provider.refreshHistory(force: true);
    await provider.playHistory(provider.history, 0);

    final payload = backend.lastRequest!.tracks.single.payload;
    expect(payload['songmid'], '1');
    expect(payload['songId'], 1);
    expect(payload['albumName'], 'A');

    // 已有规范字段时保留原值（不覆盖）。
    await repository.addHistoryEntry(PlayHistoryEntry(
      sourceKey: 'wy',
      songId: '2',
      title: 'T2',
      raw: {'songId': 2, 'songmid': 'orig'},
      playedAt: 2,
    ));
    await settle();
    await provider.refreshHistory(force: true);
    await provider.playHistory(provider.history, 0);
    // 最近播放排前：第一条是 song 2（保留原始 songmid）。
    expect(backend.lastRequest!.tracks.first.payload['songmid'], 'orig');
  });

  test('收藏切换：状态缓存 + 默认收藏列表', () async {
    expect(provider.isFavorite('wy', '1'), isFalse);

    final added = await provider.toggleFavorite(
      sourceKey: 'wy',
      songId: '1',
      title: 'Song 1',
      raw: {'songId': 1},
    );
    expect(added, isTrue);
    expect(provider.isFavorite('wy', '1'), isTrue);
    expect(await repository.favoriteKeys(), {'wy:1'});

    final removed = await provider.toggleFavorite(
      sourceKey: 'wy',
      songId: '1',
      title: 'Song 1',
    );
    expect(removed, isFalse);
    expect(provider.isFavorite('wy', '1'), isFalse);
  });

  test('toggleFavoriteSearchItem：识别 _sourceTrack', () async {
    final item = {
      '_sourceTrack': SourceTrack(
        sourceKey: 'wy',
        origin: 'lx',
        title: 'T',
        artist: 'A',
        album: '',
        raw: {'songId': 7},
      ),
    };
    expect(provider.isFavoriteSearchItem(item), isFalse);
    expect(await provider.toggleFavoriteSearchItem(item), isTrue);
    expect(provider.isFavoriteSearchItem(item), isTrue);
    expect(await provider.toggleFavoriteSearchItem({'no': 'track'}), isNull);
  });

  test('导入后列表缓存刷新，重复导入幂等', () async {
    final first = await provider.importLxmcBytes(lxmcBytes([track(1)]));
    expect(first.imported, 1);
    expect(provider.playlists, hasLength(1));
    expect(provider.playlists.single.name, 'test');
    expect(provider.playlists.single.trackCount, 1);

    final again = await provider.importLxmcBytes(lxmcBytes([track(1)]));
    expect(again.imported, 0);
    expect(again.reusedPlaylist, isTrue);
    expect(provider.playlists.single.trackCount, 1);
  });

  test('removeTrackFromPlaylist / clearHistory 生效', () async {
    final result = await provider.importLxmcBytes(lxmcBytes([track(1)]));
    await provider.loadPlaylistTracks(result.playlistId, force: true);
    final tracks = provider.playlistTracksView(result.playlistId).tracks!;
    expect(await provider.removeTrackFromPlaylist(tracks.single), isTrue);
    await settle();
    expect(
      provider.playlistTracksView(result.playlistId).tracks ?? const [],
      isEmpty,
    );

    await repository.addHistoryEntry(PlayHistoryEntry(
      sourceKey: 'wy',
      songId: '2',
      title: 'T',
      raw: const {},
      playedAt: 1,
    ));
    await settle();
    expect(provider.history, isNotEmpty);
    await provider.clearHistory();
    await settle();
    expect(provider.history, isEmpty);
  });

  test('批量操作：新建 / 复制 / 重排 / 批量移除 / 批量删历史', () async {
    final target = await provider.createPlaylist('Target');
    final result = await provider.importLxmcBytes(
      lxmcBytes([track(1), track(2)]),
    );
    final sourceTracks =
        await provider.loadPlaylistTracks(result.playlistId, force: true);

    // 复制到 target；重复复制幂等。
    expect(await provider.addTracksToPlaylist(target, sourceTracks), 2);
    expect(await provider.addTracksToPlaylist(target, sourceTracks), 0);
    var targetTracks =
        await provider.loadPlaylistTracks(target, force: true);
    expect(targetTracks.map((t) => t.songId), ['1', '2']);

    // 重排：按传入顺序回写 sortOrder。
    await provider.reorderPlaylistTracks(
      target,
      [targetTracks[1], targetTracks[0]],
    );
    targetTracks = await provider.loadPlaylistTracks(target, force: true);
    expect(targetTracks.map((t) => t.songId), ['2', '1']);

    // 批量移除：缓存静默校准。
    expect(
      await provider.removeTracksFromPlaylist(target, [targetTracks.first]),
      1,
    );
    await settle();
    expect(provider.playlistTracksView(target).tracks?.map((t) => t.songId), ['1']);

    // 历史：复制到列表 + 批量删除（乐观更新）。
    await repository.addHistoryEntry(PlayHistoryEntry(
      sourceKey: 'wy',
      songId: '9',
      title: 'H9',
      raw: const {},
      playedAt: 2,
    ));
    await repository.addHistoryEntry(PlayHistoryEntry(
      sourceKey: 'wy',
      songId: '8',
      title: 'H8',
      raw: const {},
      playedAt: 1,
    ));
    await settle();
    expect(
      await provider.addTracksToPlaylist(target, [
        for (final entry in provider.history)
          PlaylistTrack.fromHistoryEntry(entry, addedAt: 0),
      ]),
      2,
    );
    expect(await provider.deleteHistoryEntries(provider.history), 2);
    expect(provider.history, isEmpty);
    await settle();
    expect(provider.history, isEmpty);
  });

  test('导入同名列表 / 曲目加入历史 / 历史收藏', () async {
    final source = await provider.importLxmcBytes(lxmcBytes([track(1)]));
    final tracks =
        await provider.loadPlaylistTracks(source.playlistId, force: true);

    // 导入同名列表：首次新增，重复导入幂等复用。
    final imported =
        await provider.importTracksAsPlaylist(name: '外部歌单', tracks: tracks);
    expect(imported.added, 1);
    expect(imported.total, 1);
    expect(
      provider.playlists.any(
        (playlist) => playlist.id == imported.playlistId,
      ),
      isTrue,
    );
    final again =
        await provider.importTracksAsPlaylist(name: '外部歌单', tracks: tracks);
    expect(again.playlistId, imported.playlistId);
    expect(again.added, 0);

    // 曲目加入播放历史。
    expect(await provider.addTracksToHistory(tracks), 1);
    await settle();
    expect(provider.history.single.songId, '1');

    // 历史条目收藏进默认收藏列表。
    expect(
      await provider.addTracksToFavorites([
        for (final entry in provider.history)
          PlaylistTrack.fromHistoryEntry(entry, addedAt: 0),
      ]),
      1,
    );
    expect(provider.isFavorite('wy', '1'), isTrue);

    // 历史条目再次加入历史 = 置顶（不产生重复行）。
    await provider.addTracksToHistory([
      for (final entry in provider.history)
        PlaylistTrack.fromHistoryEntry(entry, addedAt: 0),
    ]);
    await settle();
    expect(provider.history, hasLength(1));
    expect(provider.history.single.songId, '1');
  });

  test('toggleFavoriteTrack：领域 Track 是收藏的唯一写入口', () async {
    final domainTrack = Track(
      id: const TrackId('wy', '1'),
      title: 'Song 1',
      artists: const [Artist(name: 'Artist 1')],
      album: 'Album 1',
      duration: const Duration(seconds: 30),
      origin: TrackOrigin.lx,
      payload: const {'songId': 1},
    );

    expect(provider.isFavorite('wy', '1'), isFalse);
    expect(await provider.toggleFavoriteTrack(domainTrack), isTrue);
    expect(provider.isFavorite('wy', '1'), isTrue);

    final stored = await repository.listPlaylistTracks(
      (await repository.listPlaylists())
          .firstWhere((playlist) => playlist.name == kFavoritesPlaylistName)
          .id,
    );
    expect(stored.single.songId, '1');
    expect(stored.single.raw['songId'], 1);
  });
}
