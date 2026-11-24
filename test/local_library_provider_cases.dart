import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/library_browse.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'package:molia/domain/models/smart_lists.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/local_library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/download/download_records.dart';

import 'support/fakes.dart';
import 'support/provider_test_scope.dart';
import 'support/memory_database.dart';
import 'support/sync_test_support.dart';

/// 聚合读取次数：本轮优化的验收标准是「历史写入不再重读整库 / 统计」。
class _CountingLibraryRepository extends LibraryRepository {
  _CountingLibraryRepository({required super.databaseProvider})
    : super(stamps: testStampIssuer());

  int browseCalls = 0;

  @override
  Future<({List<BrowseTrack> favorites, List<BrowsePlaylist> playlists})>
  loadBrowseTracks() {
    browseCalls++;
    return super.loadBrowseTracks();
  }
}

class _CountingStatisticsRepository extends PlayStatisticsRepository {
  _CountingStatisticsRepository({
    required MoliaDatabase Function() databaseProvider,
  }) : super(
         databaseProvider: databaseProvider,
         statisticsSync: testStatisticsSyncStore(databaseProvider),
       );

  int topTracksCalls = 0;
  int playedKeysCalls = 0;

  @override
  Future<List<PlayStatTrackEntry>> topTracks({
    int? since,
    int? until,
    int limit = 10,
    bool byListening = false,
  }) {
    topTracksCalls++;
    return super.topTracks(
      since: since,
      until: until,
      limit: limit,
      byListening: byListening,
    );
  }

  @override
  Future<Set<String>> playedTrackKeys() {
    playedKeysCalls++;
    return super.playedTrackKeys();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // PlaybackProvider 构造期会碰偏好读取（会话清理等），给测试一个空存储。
  SharedPreferences.setMockInitialValues(const {});

  late MoliaDatabase db;
  late _CountingLibraryRepository repository;
  late _CountingStatisticsRepository statistics;
  late DownloadRecords downloads;
  late PlaybackProvider playback;
  late LibraryProvider library;
  late LocalLibraryProvider provider;

  LocalLibraryProvider buildLocalLibrary({
    Duration debounce = const Duration(days: 1),
    int threshold = 2000,
  }) {
    final scope = ProviderTestScope(
      overrides: [
        localLibraryDebounceProvider.overrideWithValue(debounce),
        localLibraryIsolateThresholdProvider.overrideWithValue(threshold),
      ],
    );
    scope.put<LibraryRepository>(repository);
    scope.put<PlayStatisticsRepository>(statistics);
    scope.put<DownloadRecords>(downloads);
    scope.put<LibraryProvider>(library);
    return scope.container.read(localLibraryProvider.notifier);
  }

  setUp(() async {
    db = openMemoryDatabase();
    repository = _CountingLibraryRepository(databaseProvider: () => db);
    statistics = _CountingStatisticsRepository(databaseProvider: () => db);
    downloads = DownloadRecords(initialized: true, supported: false);
    playback = buildTestPlaybackProvider();
    library = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
    provider = buildLocalLibrary();
  });

  tearDown(() async {
    library.dispose();
    playback.dispose();
    await statistics.dispose();
    await db.close();
  });

  /// 让构造 / 事件流里的异步任务落地，再手动处理失效标记。
  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await provider.refresh();
  }

  test('首次 refresh 读取浏览索引 + 统计，并发布快照', () async {
    await provider.refresh();
    expect(repository.browseCalls, 1);
    expect(statistics.topTracksCalls, 2, reason: '播放次数 / 收听时长两榜');
    expect(statistics.playedKeysCalls, 1);
    expect(provider.snapshot, isNotNull);
    expect(provider.smartRows.keys, containsAll(SmartListIds.all));
  });

  test('单条播放历史只重建智能列表：不重读整库、不重读统计', () async {
    await library.refreshHistory(force: true);
    await provider.refresh();
    repository.browseCalls = 0;
    statistics.topTracksCalls = 0;
    statistics.playedKeysCalls = 0;

    await repository.addHistoryEntry(
      PlayHistoryEntry(
        sourceKey: 'wy',
        songId: 'h1',
        title: '刚播过',
        playedAt: 1700000000000,
      ),
    );
    await settle();

    expect(repository.browseCalls, 0, reason: '历史不改变专辑 / 歌手索引');
    expect(statistics.topTracksCalls, 0, reason: '统计榜由统计变更单独驱动');
    expect(statistics.playedKeysCalls, 0);
    final recent = provider.smartRows[SmartListIds.recentlyPlayed] ?? const [];
    expect(recent, isNotEmpty, reason: '新增历史行要出现在「最近播放」里');
  });

  test('单曲收藏新增 / 移除只重建索引，不重读整库、不重读统计', () async {
    // 先建收藏列表并让 LibraryProvider 的列表清单落地：首次收藏若顺手创建
    // 收藏列表会发 LibraryPlaylistsChange，那是列表集合变化而非单曲切换。
    await repository.createPlaylist('__favorites__');
    await library.refreshPlaylists(force: true);
    await provider.refresh();
    repository.browseCalls = 0;
    statistics.topTracksCalls = 0;

    await repository.toggleFavorite(sourceKey: 'wy', songId: 'f1', title: '收藏');
    await settle();

    expect(repository.browseCalls, 0, reason: '新增收藏走缓存增量');
    expect(
      provider.snapshot!.index.tracks.map((track) => track.key),
      contains('wy:f1'),
    );
    expect(statistics.topTracksCalls, 0);

    await repository.toggleFavorite(sourceKey: 'wy', songId: 'f1', title: '收藏');
    await settle();

    expect(repository.browseCalls, 0, reason: '取消收藏走缓存增量');
    expect(
      provider.snapshot!.index.tracks.map((track) => track.key),
      isNot(contains('wy:f1')),
    );
  });

  test('取消收藏但曲目仍在用户列表 / 下载里：重建索引仍保留该曲', () async {
    final favoritesId = await repository.createPlaylist('__favorites__');
    final playlistId = await repository.createPlaylist('用户列表');
    PlaylistTrack localRow(int target) => PlaylistTrack(
      playlistId: target,
      sourceKey: kLocalSourceKey,
      songId: 'file:1',
      title: '本地一首',
      artist: '歌手',
      album: '专辑',
      raw: const {'path': '/music/a.mp3'},
      addedAt: 1,
    );
    await repository.addTrackToPlaylist(
      favoritesId,
      localRow(favoritesId),
      favoriteChange: true,
    );
    await repository.addTrackToPlaylist(playlistId, localRow(playlistId));
    downloads.put(
      DownloadedTrack(
        originSourceKey: kLocalSourceKey,
        originSongId: 'file:1',
        title: '本地一首',
        artist: '歌手',
        album: '专辑',
        durationMs: 200000,
        filePath: '/music/a.mp3',
        imported: true,
        localKey: 'file:1',
        downloadedAt: 5,
      ),
    );

    await library.refreshPlaylists(force: true);
    await provider.refresh();
    repository.browseCalls = 0;

    await repository.removeTrackFromPlaylist(
      favoritesId,
      kLocalSourceKey,
      'file:1',
      favoriteChange: true,
    );
    await settle();

    expect(repository.browseCalls, 0, reason: '单曲取消收藏不重读整库');
    expect(
      provider.snapshot!.index.tracks.map((track) => track.key),
      contains('local:file:1'),
      reason: '下载 / 自建列表仍持有该曲，合并优先级要把它补回来',
    );
  });

  test('批量收藏变化（toggle == null）仍然整库重读', () async {
    await provider.refresh();
    repository.browseCalls = 0;

    await repository.addFavorites([
      PlaylistTrack(
        playlistId: 0,
        sourceKey: 'wy',
        songId: 'batch',
        title: '批量收藏',
        addedAt: 1,
      ),
    ]);
    await settle();

    expect(repository.browseCalls, 1, reason: '批量变化无法用单行表达');
    expect(
      provider.snapshot!.index.tracks.map((track) => track.key),
      contains('wy:batch'),
    );
  });

  test('超过阈值时 isolate 构建结果与主线程同步构建一致', () async {
    final favoritesId = await repository.createPlaylist('__favorites__');
    final playlistId = await repository.createPlaylist('列表');
    PlaylistTrack row(
      int target,
      String id, {
      required String title,
      required String artist,
      required String album,
      int sortOrder = 0,
    }) => PlaylistTrack(
      playlistId: target,
      sourceKey: 'wy',
      songId: id,
      title: title,
      artist: artist,
      album: album,
      addedAt: 1,
      sortOrder: sortOrder,
    );
    await repository.addTracksToPlaylist(favoritesId, [
      row(favoritesId, '1', title: '一', artist: 'A', album: '专辑一'),
      row(favoritesId, '2', title: '二', artist: 'B', album: '专辑二'),
    ]);
    await repository.addTracksToPlaylist(playlistId, [
      row(playlistId, '2', title: '二（列表）', artist: '', album: ''),
      row(playlistId, '3', title: '三', artist: 'A, C', album: '专辑一'),
    ]);

    final isolated = buildLocalLibrary(threshold: 1);
    await isolated.refresh();
    expect(isolated.snapshot, isNotNull);

    final data = await repository.loadBrowseTracks();
    final direct = buildBrowseIndex(
      BrowseSource(
        favorites: data.favorites,
        playlists: data.playlists,
        downloads: downloads.downloads,
      ),
    );
    final actual = isolated.snapshot!.index;
    expect(actual.tracks.map((track) => track.key), [
      for (final track in direct.tracks) track.key,
    ]);
    expect(
      actual.albums.map(
        (group) =>
            '${group.sortKey}|${group.tracks.map((t) => t.key).join(',')}',
      ),
      [
        for (final group in direct.albums)
          '${group.sortKey}|${group.tracks.map((t) => t.key).join(',')}',
      ],
    );
    expect(
      actual.artists.map(
        (group) =>
            '${group.sortKey}|${group.tracks.map((t) => t.key).join(',')}',
      ),
      [
        for (final group in direct.artists)
          '${group.sortKey}|${group.tracks.map((t) => t.key).join(',')}',
      ],
    );
  });

  test('publish 智能列表后，DB 来源的浏览行仍然没有解码 raw', () async {
    final playlistId = await repository.createPlaylist('列表');
    await repository.addTracksToPlaylist(playlistId, [
      PlaylistTrack(
        playlistId: playlistId,
        sourceKey: 'wy',
        songId: 'lazy',
        title: '惰性 raw',
        raw: const {'songmid': 'lazy'},
        addedAt: 1,
      ),
    ]);
    await library.refreshPlaylists(force: true);

    await provider.refresh();

    final dbTracks = provider.snapshot!.index.tracks
        .where((track) => track.rawJson != null)
        .toList();
    expect(dbTracks, isNotEmpty);
    expect(
      dbTracks.where((track) => track.debugRawDecoded),
      isEmpty,
      reason: 'neverPlayed 等智能列表构造行时只应透传惰性壳',
    );
    expect(provider.smartRows[SmartListIds.neverPlayed], isNotEmpty);
  });

  test('isolate 直接发送对象时保留 imported 下载字段，缺文件记录被排除', () async {
    const localKey = 'file:imp';
    final available = DownloadedTrack(
      originSourceKey: kLocalSourceKey,
      originSongId: localKey,
      title: '导入曲目',
      artist: '歌手',
      album: '专辑',
      durationMs: 180000,
      filePath: '/music/imp.flac',
      lyricPath: '/music/imp.lrc',
      coverPath: '/music/imp.jpg',
      imported: true,
      localKey: localKey,
      downloadedAt: 10,
    );
    final missing = DownloadedTrack(
      originSourceKey: kLocalSourceKey,
      originSongId: 'file:missing',
      title: '缺文件',
      filePath: '/music/missing.flac',
      imported: true,
      localKey: 'file:missing',
      missingAt: 20,
      downloadedAt: 20,
    );
    downloads.replaceAll([available, missing]);

    final isolated = buildLocalLibrary(threshold: 1);
    await isolated.refresh();

    final index = isolated.snapshot!.index;
    expect(index.tracks.map((track) => track.key), contains('local:$localKey'));
    expect(
      index.tracks.map((track) => track.key),
      isNot(contains('local:file:missing')),
      reason: '缺文件记录不进入浏览索引',
    );

    final browse = index.tracks.singleWhere(
      (track) => track.key == 'local:$localKey',
    );
    final expected = available.toPlaylistTrack(addedAt: available.downloadedAt);
    final actual = browse.toPlaylistTrack(addedAt: available.downloadedAt);
    expect(actual.raw['path'], expected.raw['path']);
    expect(actual.raw['songId'], expected.raw['songId']);
    expect(actual.raw['lyricPath'], expected.raw['lyricPath']);
    expect(actual.raw['coverPath'], expected.raw['coverPath']);
    expect(actual.raw, expected.raw);
  });

  test('切换最常播放指标只重建行，不触发数据库读取', () async {
    await provider.refresh();
    repository.browseCalls = 0;
    statistics.topTracksCalls = 0;

    provider.setMostPlayedMetric(SmartListMetric.listeningTime);
    await Future<void>.delayed(Duration.zero);

    expect(repository.browseCalls, 0);
    expect(statistics.topTracksCalls, 0);
  });
}
