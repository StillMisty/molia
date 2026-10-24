import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/sources/source_track.dart';
import 'support/sync_test_support.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'support/memory_database.dart';

/// 计数仓库：增量路径的验收标准是「不查库」，所以直接观察查询次数。
class _CountingLibraryRepository extends LibraryRepository {
  _CountingLibraryRepository({
    required super.databaseProvider,
    required super.stamps,
  });

  int historyListCalls = 0;
  int favoriteKeysCalls = 0;
  int playlistsListCalls = 0;
  int playlistTracksListCalls = 0;

  /// 读取 / 写入失败开关：失败结果的验收标准（阶段 / outcome）用。
  bool failReads = false;
  bool failWrites = false;

  /// 一次性闸门：非空时该次查询返回测试控制的快照（用于制造旧快照）。
  Completer<List<PlayHistoryEntry>>? nextHistorySnapshot;
  Completer<Set<String>>? nextFavoriteKeysSnapshot;
  Completer<List<PlaylistInfo>>? nextPlaylistsSnapshot;
  Completer<List<PlaylistTrack>>? nextPlaylistTracksSnapshot;

  @override
  Future<List<PlayHistoryEntry>> listHistory({int limit = kHistoryLimit}) {
    if (failReads) return Future.error(StateError('history read failed'));
    historyListCalls++;
    final gate = nextHistorySnapshot;
    if (gate != null) {
      nextHistorySnapshot = null;
      return gate.future;
    }
    return super.listHistory(limit: limit);
  }

  @override
  Future<Set<String>> favoriteKeys() {
    if (failReads) return Future.error(StateError('favorites read failed'));
    favoriteKeysCalls++;
    final gate = nextFavoriteKeysSnapshot;
    if (gate != null) {
      nextFavoriteKeysSnapshot = null;
      return gate.future;
    }
    return super.favoriteKeys();
  }

  @override
  Future<List<PlaylistInfo>> listPlaylists() {
    if (failReads) return Future.error(StateError('playlists read failed'));
    playlistsListCalls++;
    final gate = nextPlaylistsSnapshot;
    if (gate != null) {
      nextPlaylistsSnapshot = null;
      return gate.future;
    }
    return super.listPlaylists();
  }

  @override
  Future<List<PlaylistTrack>> listPlaylistTracks(
    int playlistId, {
    int? limit,
  }) {
    if (failReads) return Future.error(StateError('tracks read failed'));
    playlistTracksListCalls++;
    final gate = nextPlaylistTracksSnapshot;
    if (gate != null) {
      nextPlaylistTracksSnapshot = null;
      return gate.future;
    }
    return super.listPlaylistTracks(playlistId, limit: limit);
  }

  @override
  Future<int> addFavorites(List<PlaylistTrack> tracks) {
    if (failWrites) return Future.error(StateError('favorites write failed'));
    return super.addFavorites(tracks);
  }

  @override
  Future<int> deleteHistoryEntries(List<TrackKey> keys) {
    if (failWrites) return Future.error(StateError('history write failed'));
    return super.deleteHistoryEntries(keys);
  }
}

/// LibraryProvider 测试：内存缓存 / 播放接线 / 收藏 / 导入。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MoliaDatabase db;
  late _CountingLibraryRepository repository;
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

  PlayHistoryEntry entry(String songId, {required int playedAt}) =>
      PlayHistoryEntry(
        sourceKey: 'wy',
        songId: songId,
        title: 'Song $songId',
        artist: 'Artist',
        album: 'Album $songId',
        durationMs: 1000,
        raw: {'songId': songId},
        playedAt: playedAt,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = openMemoryDatabase();
    repository = _CountingLibraryRepository(
      databaseProvider: () => db,
      stamps: testStampIssuer(),
    );
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

  test('历史重播不即时重排：停留期间顺序冻结，重进时才按最近播放刷新', () async {
    await repository.addHistoryEntry(entry('1', playedAt: 1));
    await repository.addHistoryEntry(entry('2', playedAt: 2));
    await repository.addHistoryEntry(entry('3', playedAt: 3));
    // 首屏显式重载：采用仓库顺序（最近播放倒序）。
    await provider.refreshHistory(force: true);
    expect([for (final item in provider.history) item.songId], ['3', '2', '1']);

    // 重播最旧一条：DB 里它已是最新，内存顺序不动、数据更新。
    await repository.addHistoryEntry(entry('1', playedAt: 100));
    await settle();
    expect([for (final item in provider.history) item.songId], ['3', '2', '1']);
    expect(provider.history.last.playedAt, 100, reason: '数据要更新，位置不动');

    // 重新进入播放历史 / 本地歌曲合集时刷新。
    provider.resortHistoryByRecency();
    expect([for (final item in provider.history) item.songId], ['1', '3', '2']);
  });

  test('历史合并：全新条目插到最前，已有条目相对顺序不动', () async {
    await repository.addHistoryEntry(entry('1', playedAt: 1));
    await repository.addHistoryEntry(entry('2', playedAt: 2));
    await provider.refreshHistory(force: true);
    expect([for (final item in provider.history) item.songId], ['2', '1']);

    // 全新条目：按最近优先插到最前。
    await repository.addHistoryEntry(entry('3', playedAt: 3));
    await settle();
    expect([for (final item in provider.history) item.songId], ['3', '2', '1']);

    // 新条目 + 重播旧条目同时发生：新条目在前、旧条目原位。
    await repository.addHistoryEntry(entry('4', playedAt: 4));
    await repository.addHistoryEntry(entry('2', playedAt: 50));
    await settle();
    expect([for (final item in provider.history) item.songId],
        ['4', '3', '2', '1']);

    // 「加入列表 → 播放历史」同样只落库：内存顺序等下次重进刷新。
    await provider.addTracksToHistory([
      PlaylistTrack(
        playlistId: 0,
        sourceKey: 'wy',
        songId: '2',
        title: 'Song 2',
        artist: 'Artist',
        album: 'Album 2',
        durationMs: 1000,
        raw: const {'songId': 2},
        addedAt: 0,
      ),
    ]);
    await settle();
    expect([for (final item in provider.history) item.songId],
        ['4', '3', '2', '1']);
    provider.resortHistoryByRecency();
    expect([for (final item in provider.history) item.songId],
        ['2', '4', '3', '1']);
  });

  test('历史增量：单条写入直接打补丁，不回查仓库', () async {
    await repository.addHistoryEntry(entry('1', playedAt: 1));
    await provider.refreshHistory(force: true);
    repository.historyListCalls = 0;

    // 全新条目：插到最前，不查库。
    await repository.addHistoryEntry(entry('2', playedAt: 2));
    await settle();
    expect(repository.historyListCalls, 0, reason: 'payload 变化不应 listHistory');
    expect([for (final item in provider.history) item.songId], ['2', '1']);

    // 重播已有条目：原位替换内容（order 不变），仍不查库。
    await repository.addHistoryEntry(entry('1', playedAt: 9));
    await settle();
    expect(repository.historyListCalls, 0);
    expect([for (final item in provider.history) item.songId], ['2', '1']);
    expect(provider.history.last.playedAt, 9);
  });

  test('历史整表变更（无载荷）仍回查；未加载时单条载荷只保持 dirty', () async {
    // 未加载：缓存没有基线，单条写入不回查、也不伪造内存历史。
    await repository.addHistoryEntry(entry('1', playedAt: 1));
    await settle();
    expect(repository.historyListCalls, 0);
    expect(provider.history, isEmpty);

    await provider.refreshHistory();
    expect(provider.history, hasLength(1));
    repository.historyListCalls = 0;

    // 批量写入没有单条载荷：保持整表重载。
    await repository.addHistoryEntries([entry('2', playedAt: 2)]);
    await settle();
    expect(repository.historyListCalls, 1);
    expect([for (final item in provider.history) item.songId], ['2', '1']);
  });

  test('历史增量：全量重载进行中到达的单条写入不会被旧快照覆盖', () async {
    await repository.addHistoryEntry(entry('1', playedAt: 1));
    await provider.refreshHistory(force: true);
    repository.historyListCalls = 0;

    final gate = Completer<List<PlayHistoryEntry>>();
    repository.nextHistorySnapshot = gate;

    // 批量写入（无载荷）触发全表重载；查询被闸门挂起。
    await repository.addHistoryEntries([entry('2', playedAt: 2)]);
    await Future<void>.delayed(Duration.zero);
    expect(repository.historyListCalls, 1);

    // 查询未完成时写入单条：只缓冲，不能再发起查询。
    await repository.addHistoryEntry(entry('3', playedAt: 3));
    await Future<void>.delayed(Duration.zero);
    expect(repository.historyListCalls, 1);

    // 旧快照（不含 3）落地后，缓冲条目必须补进来。
    gate.complete([entry('2', playedAt: 2), entry('1', playedAt: 1)]);
    await settle();

    expect(repository.historyListCalls, 1);
    expect([for (final item in provider.history) item.songId], ['3', '2', '1']);
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

  test('收藏增量：单曲切换补丁缓存与计数，不做整表校准', () async {
    await provider.toggleFavorite(
      sourceKey: 'wy',
      songId: '1',
      title: 'Song 1',
      raw: {'songId': 1},
    );
    await settle();
    await provider.refreshPlaylists(force: true);
    await provider.ensureFavoritesLoaded(force: true);
    final favorites = provider.playlists.singleWhere((p) => p.isFavorites);
    await provider.loadPlaylistTracks(favorites.id, force: true);
    expect(provider.playlists.single.trackCount, 1);

    repository.favoriteKeysCalls = 0;
    repository.playlistsListCalls = 0;
    repository.playlistTracksListCalls = 0;

    expect(
      await provider.toggleFavorite(
        sourceKey: 'wy',
        songId: '2',
        title: 'Song 2',
        raw: {'songId': 2},
      ),
      isTrue,
    );
    await settle();
    expect(provider.isFavorite('wy', '2'), isTrue);
    expect(repository.favoriteKeysCalls, 0, reason: '不应重查收藏键');
    expect(repository.playlistsListCalls, 0, reason: '不应重查列表计数');
    expect(repository.playlistTracksListCalls, 0, reason: '不应重查收藏列表');
    expect(provider.playlists.single.trackCount, 2);
    expect(
      provider.playlistTracksView(favorites.id).tracks!.map((t) => t.songId),
      ['1', '2'],
    );

    expect(
      await provider.toggleFavorite(
        sourceKey: 'wy',
        songId: '2',
        title: 'Song 2',
      ),
      isFalse,
    );
    await settle();
    expect(provider.isFavorite('wy', '2'), isFalse);
    expect(repository.favoriteKeysCalls, 0);
    expect(repository.playlistsListCalls, 0);
    expect(repository.playlistTracksListCalls, 0);
    expect(provider.playlists.single.trackCount, 1);
    expect(
      provider.playlistTracksView(favorites.id).tracks!.map((t) => t.songId),
      ['1'],
    );
  });

  test('收藏整表变更（无载荷）仍做全量校准', () async {
    await provider.toggleFavorite(
      sourceKey: 'wy',
      songId: '1',
      title: 'Song 1',
      raw: {'songId': 1},
    );
    await settle();
    await provider.refreshPlaylists(force: true);
    await provider.ensureFavoritesLoaded(force: true);
    final favorites = provider.playlists.singleWhere((p) => p.isFavorites);
    await provider.loadPlaylistTracks(favorites.id, force: true);

    repository.favoriteKeysCalls = 0;
    repository.playlistsListCalls = 0;
    repository.playlistTracksListCalls = 0;

    // 批量取消收藏：写入侧只能广播无载荷变化，走整表校准。
    expect(
      (await provider.removeTracksFromFavorites([
        (sourceKey: 'wy', songId: '1'),
      ]))
          .changed,
      1,
    );
    await settle();
    expect(provider.isFavorite('wy', '1'), isFalse);
    expect(repository.favoriteKeysCalls, 1);
    expect(repository.playlistTracksListCalls, 1);
    expect(repository.playlistsListCalls, 1);
    expect(provider.playlists.single.trackCount, 0);
    expect(provider.playlistTracksView(favorites.id).tracks, isEmpty);
  });

  test('收藏增量：全量校准进行中到达的 toggle 不会被旧快照覆盖', () async {
    await provider.toggleFavorite(
      sourceKey: 'wy',
      songId: '1',
      title: 'Song 1',
      raw: {'songId': 1},
    );
    await settle();
    await provider.refreshPlaylists(force: true);
    await provider.ensureFavoritesLoaded(force: true);
    final favorites = provider.playlists.singleWhere((p) => p.isFavorites);
    await provider.loadPlaylistTracks(favorites.id, force: true);

    // 另一个列表上的无载荷 favorites 事件（不改变收藏内容），只用来启动校准。
    final scratch = await repository.createPlaylist('scratch');
    await repository.addTrackToPlaylist(
      scratch,
      PlaylistTrack(
        playlistId: scratch,
        sourceKey: 'wy',
        songId: 'x',
        title: 'X',
        addedAt: 0,
      ),
    );
    await settle();
    // 列表集合变化会清空曲目缓存，重新加载默认收藏列表后再制造旧快照。
    await provider.loadPlaylistTracks(favorites.id, force: true);

    final staleKeys = await repository.favoriteKeys();
    final staleTracks = await repository.listPlaylistTracks(favorites.id);
    final stalePlaylists = await repository.listPlaylists();
    repository.favoriteKeysCalls = 0;
    repository.playlistsListCalls = 0;
    repository.playlistTracksListCalls = 0;

    final keysGate = Completer<Set<String>>();
    final tracksGate = Completer<List<PlaylistTrack>>();
    final playlistsGate = Completer<List<PlaylistInfo>>();
    repository.nextFavoriteKeysSnapshot = keysGate;
    repository.nextPlaylistTracksSnapshot = tracksGate;
    repository.nextPlaylistsSnapshot = playlistsGate;

    // 触发无载荷校准；三个查询都被闸门挂起。
    await repository.removeTracksFromPlaylist(
      scratch,
      [(sourceKey: 'wy', songId: 'x')],
      favoriteChange: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(repository.favoriteKeysCalls, 1);

    // 校准未完成时收藏新曲目：立即打补丁并进入重放队列。
    expect(
      await provider.toggleFavorite(
        sourceKey: 'wy',
        songId: '2',
        title: 'Song 2',
        raw: {'songId': 2},
      ),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);
    expect(repository.favoriteKeysCalls, 1, reason: '不能因 toggle 再查一次');

    // 旧快照（不含 2）落地：重放后键 / 行 / 计数都必须保留。
    keysGate.complete(staleKeys);
    tracksGate.complete(staleTracks);
    playlistsGate.complete(stalePlaylists);
    await settle();

    expect(repository.favoriteKeysCalls, 1);
    expect(repository.playlistTracksListCalls, 1);
    expect(repository.playlistsListCalls, 1);
    expect(provider.isFavorite('wy', '2'), isTrue);
    expect(
      provider.playlists.singleWhere((p) => p.isFavorites).trackCount,
      2,
    );
    expect(
      provider.playlistTracksView(favorites.id).tracks!.map((t) => t.songId),
      ['1', '2'],
    );
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
    var targetTracks = await provider.loadPlaylistTracks(target, force: true);
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
      (await provider.removeTracksFromPlaylist(target, [targetTracks.first]))
          .changed,
      1,
    );
    await settle();
    expect(provider.playlistTracksView(target).tracks?.map((t) => t.songId),
        ['1']);

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
    expect((await provider.deleteHistoryEntries(provider.history)).changed, 2);
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
      (await provider.addTracksToFavorites([
        for (final entry in provider.history)
          PlaylistTrack.fromHistoryEntry(entry, addedAt: 0),
      ]))
          .changed,
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
          .firstWhere((playlist) => playlist.isFavorites)
          .id,
    );
    expect(stored.single.songId, '1');
    expect(stored.single.raw['songId'], 1);
  });

  group('读取 / 写入结果', () {
    test('列表首次读取失败 → failed；重试成功 → ready 且有数据', () async {
      repository.failReads = true;
      await repository.createPlaylist('测试列表');
      await settle();
      expect(provider.playlistsState.isFailed, isTrue);

      repository.failReads = false;
      await provider.refreshPlaylists(force: true);
      expect(provider.playlistsState.isReady, isTrue);
      expect(provider.playlists.map((p) => p.name), ['测试列表']);
    });

    test('历史首次读取失败 → failed；重试成功 → ready', () async {
      repository.failReads = true;
      await provider.refreshHistory();
      expect(provider.historyState.isFailed, isTrue);

      repository.failReads = false;
      await provider.refreshHistory(force: true);
      expect(provider.historyState.isReady, isTrue);
    });

    test('列表曲目读取失败 → failed 视图；重试成功 → ready', () async {
      final playlistId = await repository.createPlaylist('测试列表');
      await repository.addTrackToPlaylist(
        playlistId,
        PlaylistTrack(
          playlistId: playlistId,
          sourceKey: 'wy',
          songId: '1',
          title: 'Song 1',
          addedAt: 0,
        ),
      );
      await provider.refreshPlaylists();
      repository.failReads = true;

      provider.ensurePlaylistTracks(playlistId);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      var view = provider.playlistTracksView(playlistId);
      expect(view.failed, isTrue, reason: '不能把失败伪装成空列表');
      expect(view.tracks, isNull);

      repository.failReads = false;
      provider.ensurePlaylistTracks(playlistId, force: true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      view = provider.playlistTracksView(playlistId);
      expect(view.ready, isTrue);
      expect(view.tracks!.single.songId, '1');
    });

    test('批量收藏失败 → failed 且不污染收藏缓存；重试成功 → applied', () async {
      await provider.toggleFavorite(
        sourceKey: 'wy',
        songId: 'seed',
        title: 'Seed',
        raw: {'songId': 'seed'},
      );
      await settle();

      final track = PlaylistTrack(
        playlistId: 0,
        sourceKey: 'wy',
        songId: '2',
        title: 'Song 2',
        addedAt: 0,
      );
      repository.failWrites = true;
      final failed = await provider.addTracksToFavorites([track]);
      expect(failed.isFailure, isTrue);
      expect(provider.isFavorite('wy', '2'), isFalse);

      repository.failWrites = false;
      final applied = await provider.addTracksToFavorites([track]);
      expect(applied.isSuccess, isTrue);
      expect(applied.changed, 1);
      expect(provider.isFavorite('wy', '2'), isTrue);
    });

    test('批量删历史失败 → failed 且回滚内存列表', () async {
      await repository.addHistoryEntry(entry('1', playedAt: 1));
      await provider.refreshHistory(force: true);
      expect(provider.history, hasLength(1));

      repository.failWrites = true;
      final outcome = await provider.deleteHistoryEntries(provider.history);
      expect(outcome.isFailure, isTrue);
      expect(provider.history, hasLength(1), reason: '失败后回滚乐观删除');
    });
  });
}
