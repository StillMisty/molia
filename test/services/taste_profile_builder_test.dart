import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/ports/library_store.dart';
import 'package:molia/services/ai/taste_profile_builder.dart';

import '../support/memory_database.dart';
import '../support/sync_test_support.dart';

/// 记录读取参数并可控并发开始的资料库假实现。
///
/// 自建歌单读取会在 [release] 前挂起，用来观察 [TasteProfileBuilder] 是否
/// 真的并行发起读取；收藏读取不受闸门影响（它先于歌单串行发生）。
class _RecordingLibraryStore implements LibraryStore {
  _RecordingLibraryStore({
    required this.favoritesId,
    required this.customPlaylists,
    required this.tracks,
    this.holdCustomReads = true,
    this.failingPlaylistIds = const {},
  });

  final int favoritesId;
  final List<PlaylistInfo> customPlaylists;
  final Map<int, List<PlaylistTrack>> tracks;
  final bool holdCustomReads;
  final Set<int> failingPlaylistIds;

  /// 每次曲目读取的 `(playlistId, limit)`，按调用顺序记录。
  final List<({int playlistId, int? limit})> trackReads = [];

  final Completer<void> _release = Completer<void>();
  int _customInFlight = 0;
  int maxConcurrentCustomReads = 0;

  @override
  Future<List<PlaylistInfo>> listPlaylists() async => [
        PlaylistInfo(
          id: favoritesId,
          name: '__favorites__',
          createdAt: 0,
          trackCount: tracks[favoritesId]?.length ?? 0,
          isFavorites: true,
        ),
        ...customPlaylists,
      ];

  @override
  Future<List<PlaylistTrack>> listPlaylistTracks(
    int playlistId, {
    int? limit,
  }) async {
    trackReads.add((playlistId: playlistId, limit: limit));
    if (playlistId != favoritesId) {
      if (holdCustomReads) {
        _customInFlight++;
        if (_customInFlight > maxConcurrentCustomReads) {
          maxConcurrentCustomReads = _customInFlight;
        }
        try {
          await _release.future;
        } finally {
          _customInFlight--;
        }
      }
    }
    if (failingPlaylistIds.contains(playlistId)) {
      throw StateError('playlist $playlistId unavailable');
    }
    final all = tracks[playlistId] ?? const <PlaylistTrack>[];
    return List.of(limit == null ? all : all.take(limit));
  }

  void release() => _release.complete();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<PlaylistTrack> _tracksFor(int playlistId, int count) => [
      for (var i = 0; i < count; i++)
        PlaylistTrack(
          playlistId: playlistId,
          sourceKey: 'wy',
          songId: '$playlistId-$i',
          title: '歌$playlistId-$i',
          artist: '歌手$playlistId',
          addedAt: i,
          sortOrder: i,
        ),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MoliaDatabase db;
  late PlayStatisticsRepository statistics;

  /// 只勾选收藏与自建歌单：不触碰统计查询，专心验证资料库读取路径。
  const preferences = AiPreferences(
    sections: {
      AiUpstreamSection.favorites,
      AiUpstreamSection.playlists,
    },
  );

  setUp(() {
    db = openMemoryDatabase();
    statistics = PlayStatisticsRepository(
      databaseProvider: () => db,
      statisticsSync: testStatisticsSyncStore(() => db),
    );
  });

  tearDown(() async {
    await statistics.dispose();
    await db.close();
  });

  test('收藏 / 歌单按 limit 有界读取；歌单并发且聚合顺序与总量不变', () async {
    const favoritesId = 1;
    final custom = [
      for (var i = 0; i < 10; i++)
        PlaylistInfo(
          id: 100 + i,
          name: '歌单$i',
          createdAt: i,
          trackCount: 25,
        ),
    ];
    final store = _RecordingLibraryStore(
      favoritesId: favoritesId,
      customPlaylists: custom,
      tracks: {
        favoritesId: _tracksFor(favoritesId, 150),
        for (final playlist in custom) playlist.id: _tracksFor(playlist.id, 25),
      },
    );
    final builder = TasteProfileBuilder(
      repository: statistics,
      libraryStore: store,
    );

    final future = builder.build(preferences: preferences);
    // 等微任务把并发读取全部启动：串行实现这时只会启动第一个。
    await Future<void>.delayed(Duration.zero);
    final startedTogether = store.maxConcurrentCustomReads;
    final reads = List.of(store.trackReads);
    store.release();
    final profile = await future;

    final favoritesReads =
        reads.where((read) => read.playlistId == favoritesId).toList();
    final customReads =
        reads.where((read) => read.playlistId != favoritesId).toList();
    expect(favoritesReads, hasLength(1));
    expect(favoritesReads.single.limit, TasteProfileBuilder.favoritesLimit);
    expect(customReads, hasLength(10), reason: '最多读 10 个自建歌单');
    expect(
      customReads.map((read) => read.limit),
      everyElement(TasteProfileBuilder.playlistTrackLimit),
    );
    expect(startedTogether, 10, reason: '10 个歌单读取应同时开始');

    expect(profile.favorites, hasLength(TasteProfileBuilder.favoritesLimit));
    expect(profile.favorites.first.title, '歌$favoritesId-0');
    expect(profile.favorites.last.title, '歌$favoritesId-99');

    // 每单读 20 首，总预算 100 → 顺序保留前 5 个歌单。
    expect(
      profile.playlists.map((playlist) => playlist.name),
      ['歌单0', '歌单1', '歌单2', '歌单3', '歌单4'],
    );
    expect(
      profile.playlists.expand((playlist) => playlist.tracks),
      hasLength(TasteProfileBuilder.playlistTotalTrackLimit),
    );
    expect(profile.playlists.first.tracks.first.title, '歌100-0');
  });

  test('单个歌单读取失败：该段降级为空，其余歌单照常进入画像', () async {
    const favoritesId = 1;
    final custom = [
      for (var i = 0; i < 3; i++)
        PlaylistInfo(
          id: 200 + i,
          name: '歌单${String.fromCharCode(65 + i)}',
          createdAt: i,
          trackCount: 2,
        ),
    ];
    final store = _RecordingLibraryStore(
      favoritesId: favoritesId,
      customPlaylists: custom,
      tracks: {
        favoritesId: _tracksFor(favoritesId, 1),
        for (final playlist in custom) playlist.id: _tracksFor(playlist.id, 2),
      },
      holdCustomReads: false,
      failingPlaylistIds: {201},
    );
    final builder = TasteProfileBuilder(
      repository: statistics,
      libraryStore: store,
    );

    final profile = await builder.build(preferences: preferences);

    expect(
      profile.playlists.map((playlist) => playlist.name),
      ['歌单A', '歌单C'],
    );
    expect(profile.favorites, hasLength(1));
  });
}
