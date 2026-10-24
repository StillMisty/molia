import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/collection_session.dart';
import 'package:molia/providers/library_collections.dart';
import 'package:molia/providers/library_outcome.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/utils/collection_row_query.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假资料库：会话只需要读快照 / 触发加载 / 重排历史，写入全部由页面负责。
class _FakeLibrary implements CollectionLibrary {
  _FakeLibrary({
    this.playlists = const [],
    this.history = const [],
    Map<int, List<PlaylistTrack>>? tracks,
  }) : tracks = tracks ?? {};

  @override
  List<PlaylistInfo> playlists;
  @override
  List<PlayHistoryEntry> history;
  final Map<int, List<PlaylistTrack>> tracks;
  final Set<int> loadingTracks = {};
  final Set<int> failedTracks = {};
  bool playlistsLoading = false;
  bool historyLoading = false;
  @override
  LibraryReadState playlistsState = const LibraryReadState.ready();
  @override
  LibraryReadState historyState = const LibraryReadState.ready();

  int refreshPlaylistsCalls = 0;
  int ensureFavoritesCalls = 0;
  int refreshHistoryCalls = 0;
  int resortCalls = 0;
  final List<int> ensureTrackCalls = [];

  @override
  bool get isPlaylistsLoading => playlistsLoading;

  @override
  bool get isHistoryLoading => historyLoading;

  @override
  PlaylistTracksView playlistTracks(int playlistId) => PlaylistTracksView(
        tracks: tracks[playlistId],
        state: failedTracks.contains(playlistId)
            ? LibraryReadState.failed(StateError('tracks read failed'))
            : loadingTracks.contains(playlistId) ||
                    !tracks.containsKey(playlistId)
                ? const LibraryReadState.loading()
                : const LibraryReadState.ready(),
      );

  @override
  void ensurePlaylistTracks(int playlistId, {bool force = false}) =>
      ensureTrackCalls.add(playlistId);

  @override
  void refreshPlaylists({bool force = false}) => refreshPlaylistsCalls++;

  @override
  void ensureFavoritesLoaded({bool force = false}) => ensureFavoritesCalls++;

  @override
  void refreshHistory({bool force = false}) => refreshHistoryCalls++;

  @override
  void resortHistoryByRecency() => resortCalls++;

  @override
  Track trackFromHistoryEntry(PlayHistoryEntry entry) => Track(
        id: TrackId(entry.sourceKey, entry.songId),
        title: entry.title,
        origin: TrackOrigin.builtin,
        payload: entry.raw,
      );
}

/// 假滚动端口：只记录会话发出的意图。
class _FakeScroll implements CollectionScrollPort {
  final List<Map<String, double>> offsets = [];
  final List<String> activated = [];
  final List<String> restores = [];
  int flushes = 0;

  @override
  void restoreOffsets(Map<String, double> value) => offsets.add(value);

  @override
  void activate(String collectionKey) => activated.add(collectionKey);

  @override
  void restore() => restores.add(activated.isEmpty ? '' : activated.last);

  @override
  void flush() => flushes++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  PlaylistInfo favorites({int trackCount = 0}) => PlaylistInfo(
        id: 1,
        name: '我的收藏',
        createdAt: 0,
        trackCount: trackCount,
        isFavorites: true,
      );

  PlaylistInfo playlist(int id, {int trackCount = 0}) => PlaylistInfo(
        id: id,
        name: '列表 $id',
        createdAt: 0,
        trackCount: trackCount,
      );

  PlaylistTrack track(String id) => PlaylistTrack(
        playlistId: 1,
        sourceKey: 'wy',
        songId: id,
        title: 'Song $id',
        artist: 'Artist $id',
        album: 'Album',
        durationMs: 180000,
        addedAt: 1,
      );

  PlayHistoryEntry history(String id, {int playedAt = 1}) => PlayHistoryEntry(
        sourceKey: 'wy',
        songId: id,
        title: 'Song $id',
        artist: 'Artist $id',
        album: 'Album',
        durationMs: 180000,
        raw: {'songId': id},
        playedAt: playedAt,
      );

  CollectionSessionInput inputFor(
    _FakeLibrary library, {
    String query = '',
    CollectionDownloads downloads = const CollectionDownloads.unavailable(),
  }) =>
      CollectionSessionInput(
        library: library,
        names: const CollectionNames(
          favorites: '我的收藏',
          history: '播放历史',
          localSongs: '本地歌曲',
        ),
        query: query,
        downloads: downloads,
        cacheRevision: 0,
      );

  CollectionSession buildSession({_FakeScroll? scroll}) => CollectionSession(
        scroll: scroll,
        loadCachedAudioTrackIds: (tracks) async => const <TrackId>{},
      );

  group('恢复与校准', () {
    test('恢复上次选集；已删除的列表回退一次并落盘', () async {
      SharedPreferences.setMockInitialValues({
        LibraryCollections.selectionKey: 99,
      });
      final library = _FakeLibrary(playlists: [
        favorites(),
        playlist(2, trackCount: 1),
      ]);
      final session = buildSession();
      addTearDown(session.dispose);

      await session.start();
      var view = session.sync(inputFor(library));

      expect(view.view.selectedId, 2);
      expect(view.view.collectionKey, LibraryCollections.playlistOrderKey(2));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(LibraryCollections.selectionKey), 2);

      // 只校准一次：99 之后变成合法列表也不会把用户拉回去。
      library.playlists = [...library.playlists, playlist(99, trackCount: 1)];
      view = session.sync(inputFor(library));
      expect(view.view.selectedId, 2);
    });

    test('未选择：首次解析固定默认合集并落盘，后续新增列表不跳走', () async {
      final library = _FakeLibrary(playlists: [favorites(trackCount: 2)]);
      final session = buildSession();
      addTearDown(session.dispose);

      await session.start();
      var view = session.sync(inputFor(library));
      expect(view.view.selectedId, LibraryCollections.favoritesSentinel);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt(LibraryCollections.selectionKey),
        LibraryCollections.favoritesSentinel,
      );

      library.playlists = [...library.playlists, playlist(2, trackCount: 3)];
      view = session.sync(inputFor(library));
      expect(view.view.selectedId, LibraryCollections.favoritesSentinel);
      expect(view.view.collectionKey, LibraryCollections.favoritesOrderKey);
    });

    test('恢复滚动偏移只注入一次，选集恢复后不覆盖', () async {
      SharedPreferences.setMockInitialValues({
        LibraryCollections.selectionKey: LibraryCollections.historySentinel,
        LibraryCollections.scrollOffsetsKey: '{"history": 120.0}',
      });
      final queue = _FakeScroll();
      final library = _FakeLibrary(
        playlists: [favorites()],
        history: [history('1')],
      );
      final session = buildSession(scroll: queue);
      addTearDown(session.dispose);

      await session.start();
      await session.start();
      final view = session.sync(inputFor(library));

      expect(view.view.isHistory, isTrue);
      expect(queue.offsets, [
        {'history': 120.0},
      ]);
    });
  });

  group('选择按行 key', () {
    test('历史在浏览期间前插：选中行不漂移', () async {
      final library = _FakeLibrary(
        playlists: [favorites()],
        history: [history('a'), history('b')],
      );
      final session = buildSession();
      addTearDown(session.dispose);
      await session.start();

      session.sync(inputFor(library));
      session.selectCollection(LibraryCollections.historySentinel);
      var view = session.sync(inputFor(library));
      expect(view.view.visibleCount, 2);

      session.selection.select('h:wy:b');
      view = session.sync(inputFor(library));
      expect(
        session.selectedRows(view.view).map((row) => row.key),
        ['h:wy:b'],
      );

      // 后台写入在列表前部插入新行（历史最近优先）。
      library.history = [
        history('new', playedAt: 9),
        history('a', playedAt: 2),
        history('b', playedAt: 1),
      ];
      view = session.sync(inputFor(library));
      expect(
        view.view.visibleRows.map((row) => row.key),
        ['h:wy:new', 'h:wy:a', 'h:wy:b'],
      );
      expect(
        session.selectedRows(view.view).map((row) => row.key),
        ['h:wy:b'],
        reason: '选择跟行身份，不跟下标',
      );
      expect(session.selection.selectedCount, 1);
    });

    test('行被删除 / 被过滤：选择集收缩，计数不虚高', () async {
      final library = _FakeLibrary(
        playlists: [favorites(trackCount: 2)],
        tracks: {
          1: [track('a'), track('b')],
        },
      );
      final session = buildSession();
      addTearDown(session.dispose);
      await session.start();

      session.sync(inputFor(library));
      session.selection.selectAll(['wy:a', 'wy:b']);
      expect(session.selection.selectedCount, 2);

      library.tracks[1] = [track('a')];
      var view = session.sync(inputFor(library));
      expect(session.selection.selectedCount, 1);
      expect(session.selectedRows(view.view).single.key, 'wy:a');

      // 搜索过滤掉唯一选中行：视图落定时选择集为空。
      view = session.sync(inputFor(library, query: 'nothing'));
      expect(view.view.visibleCount, 0);
      expect(session.selection.isSelecting, isFalse);
    });

    test('Ctrl / Shift 语义走会话，返回是否接管点播', () async {
      final library = _FakeLibrary(
        playlists: [favorites(trackCount: 3)],
        tracks: {
          1: [track('a'), track('b'), track('c')],
        },
      );
      final session = buildSession();
      addTearDown(session.dispose);
      await session.start();
      final view = session.sync(inputFor(library)).view;

      expect(
        session.handleRowTap('wy:b', view, ctrl: true),
        isTrue,
      );
      expect(session.selection.selectedKeys, {'wy:b'});

      expect(
        session.handleRowTap('wy:c', view, shift: true),
        isTrue,
      );
      expect(session.selection.selectedKeys, {'wy:b', 'wy:c'});

      // 已有多选下普通点击 = 切换，不点播。
      expect(session.handleRowTap('wy:a', view), isTrue);
      expect(session.selection.selectedKeys, {'wy:b', 'wy:c', 'wy:a'});

      // 非选择模式普通点击 = 交给页面点播。
      session.selection.clear();
      expect(session.handleRowTap('wy:a', view), isFalse);
    });
  });

  group('模式', () {
    test('搜索 / 排序 / 调整顺序的进入与退出', () async {
      final library = _FakeLibrary(
        playlists: [favorites(trackCount: 2)],
        tracks: {
          1: [track('a'), track('b')],
        },
      );
      final session = buildSession();
      addTearDown(session.dispose);
      await session.start();
      session.sync(inputFor(library));

      session.selection.select('wy:a');
      session.openSearch();
      expect(session.searching, isTrue);
      expect(session.selecting, isTrue);

      session.setSort(CollectionTrackSort.title);
      expect(session.sort, CollectionTrackSort.title);

      session.enterReorder();
      expect(session.searching, isFalse);
      expect(session.reordering, isTrue);
      expect(session.sort, CollectionTrackSort.added);
      expect(session.selecting, isFalse, reason: '排序整体重排，选择清空');

      session.exitReorder();
      expect(session.reordering, isFalse);

      session.openSearch();
      session.exitSearch();
      expect(session.searching, isFalse);
    });

    test('sort / query 变化让 Shift 锚点失效', () async {
      final session = buildSession();
      addTearDown(session.dispose);

      // 用可见 key 直接驱动选择：先普通点击落锚，再 Shift 成区间。
      session.selection.applyModifiers(
        'b',
        visibleKeys: const ['a', 'b', 'c'],
        ctrl: false,
        shift: false,
      );
      session.selection.applyModifiers(
        'c',
        visibleKeys: const ['a', 'b', 'c'],
        ctrl: false,
        shift: true,
      );
      expect(session.selection.selectedKeys, {'b', 'c'});

      session.setSort(CollectionTrackSort.artist);
      session.selection.applyModifiers(
        'a',
        visibleKeys: const ['a', 'b', 'c'],
        ctrl: false,
        shift: true,
      );
      expect(session.selection.selectedKeys, {'a'}, reason: '锚点已失效');
    });

    test('切换合集退出搜索 / 调整顺序并清空多选', () async {
      final library = _FakeLibrary(
        playlists: [favorites(trackCount: 1), playlist(2, trackCount: 1)],
        tracks: {
          1: [track('a')],
          2: [track('b')],
        },
      );
      final session = buildSession();
      addTearDown(session.dispose);
      await session.start();
      session.sync(inputFor(library));

      session.selection.select('wy:a');
      session.openSearch();
      session.enterReorder();
      session.selection.select('wy:a');

      expect(session.selectCollection(2), isTrue);
      expect(session.searching, isFalse);
      expect(session.reordering, isFalse);
      expect(session.selecting, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(LibraryCollections.selectionKey), 2);

      // 同一合集不重复切换。
      expect(session.selectCollection(2), isFalse);
    });
  });

  group('加载组合', () {
    test('首帧列表 / 列表曲目 / 历史首载 / 本地歌曲各自合成 loading', () async {
      final library = _FakeLibrary();
      final session = buildSession();
      addTearDown(session.dispose);
      await session.start();

      library.playlistsLoading = true;
      var view = session.sync(inputFor(library));
      expect(view.phase, CollectionViewPhase.loading);

      library
        ..playlistsLoading = false
        ..playlists = [favorites(trackCount: 1)]
        ..tracks[1] = [track('a')]
        ..loadingTracks.add(1);
      view = session.sync(inputFor(library));
      expect(view.phase, CollectionViewPhase.loading, reason: '列表曲目在途');

      library.loadingTracks.remove(1);
      view = session.sync(inputFor(library));
      expect(view.phase, CollectionViewPhase.ready);

      // 历史首载且为空 → loading。
      library
        ..historyLoading = true
        ..history = const [];
      session.selectCollection(LibraryCollections.historySentinel);
      view = session.sync(inputFor(library));
      expect(view.phase, CollectionViewPhase.loading);

      library.historyLoading = false;
      view = session.sync(inputFor(library));
      expect(view.phase, CollectionViewPhase.ready);
    });

    test('本地歌曲：弹层计数可按最新下载快照重算', () async {
      final library = _FakeLibrary(playlists: [favorites()]);
      final session = buildSession();
      addTearDown(session.dispose);
      await session.start();
      session.sync(inputFor(library));
      expect(session.localSongsCount, 0);

      final downloads = CollectionDownloads(
        records: [
          DownloadedTrack(
            originSourceKey: 'wy',
            originSongId: '1',
            title: '下载 1',
            filePath: '/downloads/1.mp3',
            downloadedAt: 1,
          ),
        ],
        supported: true,
        initialized: true,
      );
      await session.ensureLocalSongsReady(downloads: downloads);
      expect(session.localSongsCount, 1);
    });

    test('本地歌曲：能力未初始化 / 缓存联结在途时 loading，落定后 ready', () async {
      final library = _FakeLibrary(playlists: [favorites()]);
      final session = buildSession();
      addTearDown(session.dispose);
      await session.start();
      session.sync(inputFor(library));

      final downloads = CollectionDownloads(
        records: const [],
        supported: true,
        initialized: false,
      );
      session.selectCollection(LibraryCollections.downloadsSentinel);
      var view = session.sync(inputFor(library, downloads: downloads));
      expect(view.phase, CollectionViewPhase.loading);
      expect(view.view.isLocalSongs, isTrue);

      final ready = CollectionDownloads(
        records: const [],
        supported: true,
        initialized: true,
      );
      view = session.sync(inputFor(library, downloads: ready));
      await session.ensureLocalSongsReady();
      view = session.sync(inputFor(library, downloads: ready));
      expect(view.phase, CollectionViewPhase.ready);
      expect(view.view.hasItems, isFalse);
    });
  });

  group('滚动激活', () {
    test('同一合集只激活一次，内容就绪后只恢复一次', () async {
      final queue = _FakeScroll();
      final library = _FakeLibrary(
        playlists: [favorites(trackCount: 1)],
        tracks: {
          1: [track('a')],
        },
      );
      final session = buildSession(scroll: queue);
      addTearDown(session.dispose);
      await session.start();

      session.sync(inputFor(library));
      session.sync(inputFor(library));
      expect(queue.activated, [LibraryCollections.favoritesOrderKey]);
      expect(queue.restores, [LibraryCollections.favoritesOrderKey]);
    });

    test('加载中不恢复；内容就绪后再恢复', () async {
      final queue = _FakeScroll();
      final library = _FakeLibrary(
        playlists: [favorites(trackCount: 1)],
        tracks: {
          1: [track('a')],
        },
      )..loadingTracks.add(1);
      final session = buildSession(scroll: queue);
      addTearDown(session.dispose);
      await session.start();

      session.sync(inputFor(library));
      expect(queue.activated, [LibraryCollections.favoritesOrderKey]);
      expect(queue.restores, isEmpty);

      library.loadingTracks.remove(1);
      session.sync(inputFor(library));
      expect(queue.restores, [LibraryCollections.favoritesOrderKey]);
    });

    test('切换合集先落盘旧偏移，再激活新键', () async {
      final queue = _FakeScroll();
      final library = _FakeLibrary(
        playlists: [favorites(trackCount: 1), playlist(2, trackCount: 1)],
        tracks: {
          1: [track('a')],
          2: [track('b')],
        },
      );
      final session = buildSession(scroll: queue);
      addTearDown(session.dispose);
      await session.start();

      session.sync(inputFor(library));
      session.selectCollection(2);
      session.sync(inputFor(library));

      expect(queue.flushes, 1);
      expect(queue.activated, [
        LibraryCollections.favoritesOrderKey,
        LibraryCollections.playlistOrderKey(2),
      ]);
      expect(queue.restores.last, LibraryCollections.playlistOrderKey(2));
    });
  });

  group('读取失败与重试', () {
    test('列表清单读取失败 → failed；重试成功后 ready 且沿用原选集', () async {
      SharedPreferences.setMockInitialValues({
        LibraryCollections.selectionKey: 2,
      });
      final library = _FakeLibrary(
        playlists: const [],
        tracks: {},
      )..playlistsState = LibraryReadState.failed(StateError('read'));
      final session = buildSession();
      addTearDown(session.dispose);
      await session.start();

      var view = session.sync(inputFor(library));
      expect(view.phase, CollectionViewPhase.failed);
      expect(view.error, isNotNull);
      expect(
        view.view.selectedId,
        LibraryCollections.favoritesSentinel,
        reason: '读不到列表时不把恢复的选集覆盖成默认值',
      );

      // 重试成功：列表到位，恢复的选集仍指向 2。
      library
        ..playlistsState = const LibraryReadState.ready()
        ..playlists = [favorites(), playlist(2, trackCount: 1)]
        ..tracks[2] = [track('b')];
      session.retry();
      view = session.sync(inputFor(library));
      expect(view.phase, CollectionViewPhase.ready);
      expect(view.view.selectedId, 2);
      expect(view.view.visibleRows.single.key, 'wy:b');
    });

    test('列表曲目读取失败 → failed；force 重试后 ready', () async {
      final library = _FakeLibrary(
        playlists: [favorites(trackCount: 1)],
        tracks: {
          1: [track('a')],
        },
      )..failedTracks.add(1);
      final session = buildSession();
      addTearDown(session.dispose);
      await session.start();

      var view = session.sync(inputFor(library));
      expect(view.phase, CollectionViewPhase.failed);

      library.failedTracks.remove(1);
      session.retry();
      view = session.sync(inputFor(library));
      expect(view.phase, CollectionViewPhase.ready);
      expect(view.view.visibleRows.single.key, 'wy:a');
    });

    test('历史读取失败且无缓存 → failed；重试后 ready', () async {
      final library = _FakeLibrary(
        playlists: [favorites()],
      )..historyState = LibraryReadState.failed(StateError('read'));
      final session = buildSession();
      addTearDown(session.dispose);
      await session.start();
      session.sync(inputFor(library));
      session.selectCollection(LibraryCollections.historySentinel);

      var view = session.sync(inputFor(library));
      expect(view.phase, CollectionViewPhase.failed);

      library
        ..historyState = const LibraryReadState.ready()
        ..history = [history('1')];
      session.retry();
      view = session.sync(inputFor(library));
      expect(view.phase, CollectionViewPhase.ready);
      expect(view.view.visibleCount, 1);
    });
  });

  group('批量写入结果', () {
    test('失败保留选择，成功才清空', () async {
      final library = _FakeLibrary(
        playlists: [favorites(trackCount: 2)],
        tracks: {
          1: [track('a'), track('b')],
        },
      );
      final session = buildSession();
      addTearDown(session.dispose);
      await session.start();
      final view = session.sync(inputFor(library)).view;
      session.selection.selectAll(['wy:a', 'wy:b']);

      var received = const <String>[];
      final failed = await session.applySelection(view, (rows) async {
        received = [for (final row in rows) row.key];
        return LibraryMutationOutcome.failed(StateError('write'));
      });
      expect(failed.isFailure, isTrue);
      expect(received, ['wy:a', 'wy:b']);
      expect(session.selection.selectedCount, 2, reason: '写失败不能清选择');

      final applied = await session.applySelection(
        view,
        (rows) async => LibraryMutationOutcome.applied(rows.length),
      );
      expect(applied.isSuccess, isTrue);
      expect(applied.changed, 2);
      expect(session.selection.isSelecting, isFalse);
    });

    test('空选择不触发写入', () async {
      final library = _FakeLibrary(
        playlists: [favorites(trackCount: 1)],
        tracks: {
          1: [track('a')],
        },
      );
      final session = buildSession();
      addTearDown(session.dispose);
      await session.start();
      final view = session.sync(inputFor(library)).view;

      var called = false;
      final outcome = await session.applySelection(view, (rows) async {
        called = true;
        return LibraryMutationOutcome.applied(rows.length);
      });
      expect(outcome.status, LibraryMutationStatus.unchanged);
      expect(called, isFalse);
    });
  });

  test('合集顺序落位即持久化', () async {
    final session = buildSession();
    addTearDown(session.dispose);

    session.reorderCollections(['history', 'favorites', 'playlist:2']);
    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(LibraryCollections.orderKey), [
      'history',
      'favorites',
      'playlist:2',
    ]);
  });
}
