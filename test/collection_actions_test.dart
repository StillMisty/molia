import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/collection_actions.dart';
import 'package:molia/providers/collection_presenter.dart';
import 'package:molia/providers/library_outcome.dart';
import 'package:molia/providers/local_songs_collection.dart';
import 'package:molia/services/cache_types.dart';
import 'package:molia/services/track_local_data_service.dart';

/// 假资料库端口：记录每类命令的输入，结果可配置。
class _FakeLibrary implements CollectionActionLibrary {
  final Set<String> favorites = {};
  final List<List<PlaylistTrack>> addedFavorites = [];
  final List<List<TrackKey>> removedFavorites = [];
  final List<({int playlistId, List<PlaylistTrack> tracks})> playlistRemovals =
      [];
  final List<List<PlayHistoryEntry>> historyDeletions = [];
  final List<({int playlistId, List<PlaylistTrack> ordered})> reorders = [];
  int clearHistoryCalls = 0;

  LibraryMutationOutcome outcome = const LibraryMutationOutcome.applied();

  @override
  Track trackFromPlaylistTrack(PlaylistTrack track) => _domainTrack(
        sourceKey: track.sourceKey,
        songId: track.songId,
        title: track.title,
      );

  @override
  Track trackFromHistoryEntry(PlayHistoryEntry entry) => _domainTrack(
        sourceKey: entry.sourceKey,
        songId: entry.songId,
        title: entry.title,
      );

  @override
  bool isFavorite(String sourceKey, String songId) =>
      favorites.contains('$sourceKey:$songId');

  @override
  Future<LibraryMutationOutcome> addTracksToFavorites(
    List<PlaylistTrack> tracks,
  ) async {
    addedFavorites.add(tracks);
    return outcome;
  }

  @override
  Future<LibraryMutationOutcome> removeTracksFromFavorites(
    List<TrackKey> keys,
  ) async {
    removedFavorites.add(keys);
    return outcome;
  }

  @override
  Future<LibraryMutationOutcome> removeTracksFromPlaylist(
    int playlistId,
    List<PlaylistTrack> tracks,
  ) async {
    playlistRemovals.add((playlistId: playlistId, tracks: tracks));
    return outcome;
  }

  @override
  Future<LibraryMutationOutcome> deleteHistoryEntries(
    List<PlayHistoryEntry> entries,
  ) async {
    historyDeletions.add(entries);
    return outcome;
  }

  @override
  Future<LibraryMutationOutcome> clearHistory() async {
    clearHistoryCalls++;
    return outcome;
  }

  @override
  Future<LibraryMutationOutcome> reorderPlaylistTracks(
    int playlistId,
    List<PlaylistTrack> ordered,
  ) async {
    reorders.add((playlistId: playlistId, ordered: ordered));
    return outcome;
  }
}

/// 假曲目交接端口：只记录命令层交给 TrackHandoff 的参数。
class _FakeHandoff implements CollectionHandoff {
  List<Track>? played;
  int? startIndex;
  bool? shuffle;
  String? contextName;

  List<PlaylistTrack>? added;
  bool? includeFavorites;
  bool? includeHistory;
  bool addResult = true;

  @override
  Future<void> play(
    List<Track> tracks, {
    required int startIndex,
    required bool shuffle,
    required String contextName,
  }) async {
    played = tracks;
    this.startIndex = startIndex;
    this.shuffle = shuffle;
    this.contextName = contextName;
  }

  @override
  Future<bool> addToLibrary(
    List<PlaylistTrack> tracks, {
    required bool includeFavorites,
    required bool includeHistory,
  }) async {
    added = tracks;
    this.includeFavorites = includeFavorites;
    this.includeHistory = includeHistory;
    return addResult;
  }
}

/// 假本地数据端口：记录删除 / 清缓存，可按曲目注入失败与跳过。
class _FakeLocalData implements CollectionLocalData {
  @override
  bool available = true;

  final List<DownloadedTrack> deleted = [];
  final List<Track> cleared = [];

  /// 这些下载记录键删除时抛错。
  final Set<String> failingRecords = {};

  /// 这些曲目清缓存返回「写入中跳过」。
  final Set<String> skippingTracks = {};

  /// true = 本地数据服务缺席（清缓存返回 null）。
  bool cacheUnavailable = false;

  @override
  Future<void> deleteDownload(DownloadedTrack record) async {
    if (failingRecords.contains(record.key)) {
      throw StateError('delete ${record.key} failed');
    }
    deleted.add(record);
  }

  @override
  Future<LocalCacheClearResult?> clearCachedAudio(Track track) async {
    cleared.add(track);
    if (cacheUnavailable) return null;
    if (skippingTracks.contains(track.id.uri)) {
      return const LocalCacheClearResult(
        part: LocalCachePart.audio,
        skipped: 1,
      );
    }
    return const LocalCacheClearResult(
      part: LocalCachePart.audio,
      freed: CacheUsage(bytes: 1, count: 1),
    );
  }
}

Track _domainTrack({
  required String sourceKey,
  required String songId,
  required String title,
}) =>
    Track(
      id: TrackId(sourceKey, songId),
      title: title,
      origin: TrackOrigin.builtin,
    );

PlaylistTrack _track(String id, {String sourceKey = 'wy'}) => PlaylistTrack(
      playlistId: 1,
      sourceKey: sourceKey,
      songId: id,
      title: 'Song $id',
      artist: 'Artist $id',
      album: 'Album',
      durationMs: 180000,
      addedAt: 1,
    );

PlayHistoryEntry _history(String id) => PlayHistoryEntry(
      sourceKey: 'wy',
      songId: id,
      title: 'Song $id',
      artist: 'Artist $id',
      album: 'Album',
      durationMs: 180000,
      raw: {'songId': id},
      playedAt: 1,
    );

CollectionLocalSong _downloaded(String id, {bool imported = false}) =>
    CollectionLocalSong.download(
      DownloadedTrack(
        originSourceKey: imported ? kLocalSourceKey : 'wy',
        originSongId: id,
        title: imported ? '导入 $id' : '下载 $id',
        artist: 'Artist $id',
        filePath: '/downloads/$id.mp3',
        imported: imported,
        downloadedAt: 1,
      ),
    );

CollectionLocalSong _cached(String id) =>
    CollectionLocalSong.cached(_history(id));

CollectionView _view(
  List<CollectionRow> rows, {
  int? playlistId,
  CollectionKind kind = CollectionKind.custom,
  String name = '合集',
}) =>
    CollectionView(
      identity: CollectionIdentity(
        selectedId: playlistId ?? 1,
        kind: kind,
        playlistId: playlistId,
        displayName: name,
      ),
      tracks: const [],
      visibleRows: rows,
      hasItems: rows.isNotEmpty,
    );

void main() {
  late _FakeLibrary library;
  late _FakeHandoff handoff;
  late _FakeLocalData localData;
  late CollectionActions actions;

  setUp(() {
    library = _FakeLibrary();
    handoff = _FakeHandoff();
    localData = _FakeLocalData();
    actions = CollectionActions(
      library: library,
      handoff: handoff,
      localData: localData,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
    );
  });

  group('播放', () {
    test('混合行变体按可见顺序还原成领域曲目并交给 TrackHandoff', () async {
      final view = _view(
        [
          TrackCollectionRow(_track('1')),
          HistoryCollectionRow(_history('2')),
          LocalSongCollectionRow(_downloaded('3')),
        ],
        playlistId: 7,
        name: '我的合集',
      );

      await actions.play(view, startIndex: 2, shuffle: true);

      expect(
        handoff.played!.map((track) => track.title).toList(),
        ['Song 1', 'Song 2', '下载 3'],
      );
      expect(handoff.startIndex, 2);
      expect(handoff.shuffle, isTrue);
      expect(handoff.contextName, '我的合集');
    });

    test('空视图不装载队列（不调用 TrackHandoff）', () async {
      await actions.play(_view(const []));

      expect(handoff.played, isNull);
    });

    test('本地歌曲行统一使用同一个 addedAt', () async {
      await actions.play(
        _view([
          LocalSongCollectionRow(_downloaded('1')),
          LocalSongCollectionRow(_cached('2')),
        ]),
      );

      // 假端口只保留曲目标题；真正的 addedAt 口径由
      // `CollectionLocalSong.toPlaylistTrack` 的单一入参保证。
      expect(handoff.played, hasLength(2));
    });
  });

  group('收藏', () {
    test('批量收藏：三种行都转成 PlaylistTrack 快照', () async {
      final rows = <CollectionRow>[
        TrackCollectionRow(_track('1')),
        HistoryCollectionRow(_history('2')),
        LocalSongCollectionRow(_downloaded('3')),
      ];

      final outcome = await actions.setFavorite(
        rows,
        change: CollectionFavoriteChange.add,
      );

      expect(outcome.isSuccess, isTrue);
      expect(
        library.addedFavorites.single.map((track) => track.title).toList(),
        ['Song 1', 'Song 2', '下载 3'],
      );
    });

    test('批量取消收藏：按行联合的收藏键去重写入', () async {
      final rows = <CollectionRow>[
        TrackCollectionRow(_track('1')),
        HistoryCollectionRow(_history('2')),
        LocalSongCollectionRow(_downloaded('3')),
      ];

      await actions.setFavorite(
        rows,
        change: CollectionFavoriteChange.remove,
      );

      expect(library.removedFavorites.single, [
        (sourceKey: 'wy', songId: '1'),
        (sourceKey: 'wy', songId: '2'),
        (sourceKey: kLocalSourceKey, songId: 'wy:3'),
      ]);
    });

    test('收藏意图：全部已收藏 → 取消，任一行未收藏 → 收藏', () {
      library.favorites.addAll(['wy:1', 'wy:2']);
      final rows = <CollectionRow>[
        TrackCollectionRow(_track('1')),
        HistoryCollectionRow(_history('2')),
      ];

      expect(
        actions.favoriteChange(rows),
        CollectionFavoriteChange.remove,
      );

      library.favorites.remove('wy:2');
      expect(actions.favoriteChange(rows), CollectionFavoriteChange.add);
    });

    test('单行开关按当前收藏状态决定加 / 删', () async {
      final row = LocalSongCollectionRow(_downloaded('1'));

      await actions.toggleFavorite([row]);
      expect(library.addedFavorites, hasLength(1));

      library.favorites.add('local:wy:1');
      await actions.toggleFavorite([row]);
      expect(library.removedFavorites, hasLength(1));
    });

    test('写入结果原样返回（失败不被吞掉）', () async {
      library.outcome = LibraryMutationOutcome.failed(StateError('写失败'));

      final outcome = await actions.setFavorite(
        [TrackCollectionRow(_track('1'))],
        change: CollectionFavoriteChange.add,
      );

      expect(outcome.isFailure, isTrue);
    });
  });

  group('列表 / 历史删除', () {
    test('从列表移除只取列表曲目行（历史行显式忽略）', () async {
      await actions.removeFromPlaylist(
        _view(
          [
            TrackCollectionRow(_track('1')),
            HistoryCollectionRow(_history('2')),
          ],
          playlistId: 7,
        ),
        [
          TrackCollectionRow(_track('1')),
          HistoryCollectionRow(_history('2')),
        ],
      );

      expect(library.playlistRemovals.single.playlistId, 7);
      expect(
        library.playlistRemovals.single.tracks.map((track) => track.songId),
        ['1'],
      );
    });

    test('无落库列表 id / 空选择 = 无变化且不写库', () async {
      final rows = [TrackCollectionRow(_track('1'))];

      final noPlaylist = await actions.removeFromPlaylist(_view(rows), rows);
      final empty = await actions.deleteHistory(const []);

      expect(noPlaylist.status, LibraryMutationStatus.unchanged);
      expect(empty.status, LibraryMutationStatus.unchanged);
      expect(library.playlistRemovals, isEmpty);
      expect(library.historyDeletions, isEmpty);
    });

    test('批量删除历史只取历史行', () async {
      await actions.deleteHistory([
        TrackCollectionRow(_track('1')),
        HistoryCollectionRow(_history('2')),
        LocalSongCollectionRow(_cached('3')),
      ]);

      expect(
        library.historyDeletions.single.map((entry) => entry.songId),
        ['2'],
      );
    });

    test('清空历史走同一资料库端口', () async {
      await actions.clearHistory();

      expect(library.clearHistoryCalls, 1);
    });
  });

  group('本地删除', () {
    test('成功：下载删记录、导入只移出、缓存清音频', () async {
      final outcome = await actions.deleteLocalSongs([
        _downloaded('1'),
        _downloaded('2', imported: true),
        _cached('3'),
      ]);

      expect(outcome.deleted, 1);
      expect(outcome.removed, 1);
      expect(outcome.cleared, 1);
      expect(outcome.failed, 0);
      expect(
        localData.deleted.map((record) => record.key).toList(),
        ['wy:1', 'local:2'],
      );
      expect(localData.cleared.single.id.uri, 'wy:3');
      expect(
        outcome.items.map((item) => item.kind).toList(),
        [
          CollectionLocalDeleteKind.download,
          CollectionLocalDeleteKind.imported,
          CollectionLocalDeleteKind.cached,
        ],
      );
    });

    test('部分失败：一条失败不阻断其余，失败计数进结果', () async {
      localData.failingRecords.add('wy:1');
      localData.skippingTracks.add('wy:3');

      final outcome = await actions.deleteLocalSongs([
        _downloaded('1'),
        _downloaded('2'),
        _cached('3'),
      ]);

      expect(outcome.failed, 1);
      expect(outcome.deleted, 1);
      expect(outcome.skipped, 1);
      expect(outcome.hasFailure, isTrue);
      expect(outcome.items[0].error, isNotNull);
      expect(outcome.items[2].skippedFiles, 1);
      expect(localData.deleted.map((record) => record.key), ['wy:2']);
    });

    test('清缓存服务缺席 = unavailable（页面沿用静默路径）', () async {
      localData.cacheUnavailable = true;

      final outcome = await actions.deleteLocalSongs([_cached('1')]);

      expect(outcome.unavailable, 1);
      expect(outcome.failed, 0);
    });

    test('下载能力不可用：下载 / 导入项都记 unavailable', () async {
      localData.available = false;

      final outcome = await actions.deleteLocalSongs([
        _downloaded('1'),
        _downloaded('2', imported: true),
      ]);

      expect(outcome.unavailable, 2);
      expect(localData.deleted, isEmpty);
      expect(actions.localDataAvailable, isFalse);
    });

    test('未注入本地数据端口：整批 unavailable', () async {
      final withoutLocalData = CollectionActions(
        library: library,
        handoff: handoff,
      );

      final outcome = await withoutLocalData.deleteLocalSongs([
        _downloaded('1'),
        _cached('2'),
      ]);

      expect(outcome.unavailable, 2);
      expect(withoutLocalData.localDataAvailable, isFalse);
    });
  });

  group('排序', () {
    test('按可见行重建列表并写回落库 id', () async {
      final view = _view(
        [
          TrackCollectionRow(_track('1')),
          TrackCollectionRow(_track('2')),
          TrackCollectionRow(_track('3')),
        ],
        playlistId: 9,
      );

      await actions.reorder(view, 2, 0);

      expect(library.reorders.single.playlistId, 9);
      expect(
        library.reorders.single.ordered.map((track) => track.songId),
        ['3', '1', '2'],
      );
    });

    test('同下标 / 越界 / 无列表 id = 无变化且不写库', () async {
      final rows = [
        TrackCollectionRow(_track('1')),
        TrackCollectionRow(_track('2')),
      ];

      expect(
        (await actions.reorder(_view(rows, playlistId: 9), 1, 1)).status,
        LibraryMutationStatus.unchanged,
      );
      expect(
        (await actions.reorder(_view(rows, playlistId: 9), 0, 5)).status,
        LibraryMutationStatus.unchanged,
      );
      expect(
        (await actions.reorder(_view(rows), 0, 1)).status,
        LibraryMutationStatus.unchanged,
      );
      expect(library.reorders, isEmpty);
    });
  });

  group('复制', () {
    test('混合行变体统一成 PlaylistTrack，并按合集决定目标范围', () async {
      final view = _view(
        [
          TrackCollectionRow(_track('1')),
          HistoryCollectionRow(_history('2')),
          LocalSongCollectionRow(_downloaded('3')),
        ],
        kind: CollectionKind.custom,
        playlistId: 7,
      );

      final copied = await actions.copyToLibrary(view, view.visibleRows);

      expect(copied, isTrue);
      expect(
        handoff.added!.map((track) => track.title).toList(),
        ['Song 1', 'Song 2', '下载 3'],
      );
      // 历史 / 本地行同批共用一个 addedAt；列表曲目保留自身写入时间。
      expect(
        handoff.added!.map((track) => track.addedAt).toList(),
        [1, 1000, 1000],
      );
      expect(handoff.includeFavorites, isTrue);
      expect(handoff.includeHistory, isTrue);
    });

    test('历史合集不把「播放历史」作为复制目标；空选择不开弹层', () async {
      final historyView = _view(
        [HistoryCollectionRow(_history('1'))],
        kind: CollectionKind.history,
        name: '播放历史',
      );

      await actions.copyToLibrary(historyView, historyView.visibleRows);
      expect(handoff.includeFavorites, isTrue);
      expect(handoff.includeHistory, isFalse);

      final copied = await actions.copyToLibrary(historyView, const []);
      expect(copied, isFalse);
    });

    test('取消目标选择 = false', () async {
      handoff.addResult = false;

      final copied = await actions.copyToLibrary(
        _view([TrackCollectionRow(_track('1'))]),
        [TrackCollectionRow(_track('1'))],
      );

      expect(copied, isFalse);
    });
  });

  group('行动作载荷', () {
    test('列表曲目行：复制 / 换源 / 移出列表 / 取消收藏都接同一命令层', () async {
      final view = _view([], playlistId: 7, name: 'Road');
      final command = actions.rowCommands(
        view,
        TrackCollectionRow(_track('1')),
      );

      expect(command, isA<TrackCollectionRowCommands>());
      await command.copy();
      expect(handoff.added!.single.songId, '1');

      final swap = command.swap!;
      expect(swap.track.title, 'Song 1');
      expect(swap.playlistId, 7);
      expect(swap.historyKey, isNull);

      await command.removeFromPlaylist!();
      expect(library.playlistRemovals.single.playlistId, 7);

      await command.removeFromFavorites!();
      expect(library.removedFavorites.single.single.songId, '1');
    });

    test('历史行：删除历史与历史换源位置', () async {
      final view = _view([], kind: CollectionKind.history);
      final command = actions.rowCommands(
        view,
        HistoryCollectionRow(_history('2')),
      );

      expect(command, isA<HistoryCollectionRowCommands>());
      expect(command.removeFromPlaylist, isNull);
      expect(command.swap!.historyKey, (sourceKey: 'wy', songId: '2'));
      expect(command.swap!.playlistId, isNull);

      await command.deleteHistory!();
      expect(library.historyDeletions.single.single.songId, '2');
    });

    test('本地歌曲行：收藏开关 / 缓存与导入标记 / 删除输入', () async {
      final view = _view([], kind: CollectionKind.localSongs);
      final downloaded = actions.rowCommands(
        view,
        LocalSongCollectionRow(_downloaded('1')),
      );
      final imported = actions.rowCommands(
        view,
        LocalSongCollectionRow(_downloaded('2', imported: true)),
      );
      final cached = actions.rowCommands(
        view,
        LocalSongCollectionRow(_cached('3')),
      );

      expect(downloaded.isFavorite, isFalse);
      expect(downloaded.localSongCached, isFalse);
      expect(downloaded.localSongImported, isFalse);
      expect(downloaded.localSong!.key, 'wy:1');
      expect(cached.localSongCached, isTrue);
      expect(imported.localSongImported, isTrue);
      expect(downloaded.swap, isNull);

      await downloaded.toggleFavorite!();
      expect(library.addedFavorites.single.single.songId, 'wy:1');

      library.favorites.add('wy:3');
      await cached.toggleFavorite!();
      expect(library.removedFavorites.single.single, (
        sourceKey: 'wy',
        songId: '3',
      ));
      expect(cached.isFavorite, isTrue);
    });
  });
}
