/// 曲库聚合读模型：专辑 / 歌手浏览索引、重复组与七个智能列表。
///
/// 输入来自资料库（收藏 + 全部列表）、下载记录、播放历史与统计；一次聚合
/// 读取后在内存里构建，输入 revision 变化防抖 150ms 重建，旧快照保持可见。
/// 只服务 UI，不写数据库、不进入同步。
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../app/perf/data_path_trace.dart';
import '../data/library/favorite_fact.dart';
import '../data/library_repository.dart';
import '../data/play_statistics_repository.dart';
import '../domain/models/download.dart';
import '../domain/models/library.dart';
import '../domain/models/library_browse.dart';
import '../domain/models/play_statistics.dart';
import '../domain/models/smart_lists.dart';
import '../services/download/download_records.dart';
import 'collection_presenter.dart';
import 'library_provider.dart';
import '../app/bootstrap/runtime_providers.dart';
import 'app_providers.dart';
import 'local_songs_collection.dart';

part 'local_library_provider.g.dart';

/// 曲库浏览快照（只含 UI 需要的聚合索引）。
class LibraryBrowseSnapshot {
  const LibraryBrowseSnapshot({required this.index});

  final LibraryBrowseIndex index;
}

/// 曲库聚合读模型对 UI 暴露的不可变快照。
@immutable
class LocalLibraryState {
  const LocalLibraryState({
    required this.snapshot,
    required this.smartRows,
    required this.mostPlayedMetric,
  });

  static const LocalLibraryState empty = LocalLibraryState(
    snapshot: null,
    smartRows: {},
    mostPlayedMetric: SmartListMetric.playCount,
  );

  final LibraryBrowseSnapshot? snapshot;
  final Map<String, List<CollectionRow>> smartRows;
  final SmartListMetric mostPlayedMetric;

  LocalLibraryState copyWith({
    LibraryBrowseSnapshot? snapshot,
    Map<String, List<CollectionRow>>? smartRows,
    SmartListMetric? mostPlayedMetric,
  }) => LocalLibraryState(
    snapshot: snapshot ?? this.snapshot,
    smartRows: smartRows ?? this.smartRows,
    mostPlayedMetric: mostPlayedMetric ?? this.mostPlayedMetric,
  );
}

@Riverpod(keepAlive: true, name: 'localLibraryDebounceProvider')
Duration localLibraryDebounce(Ref ref) => const Duration(milliseconds: 150);

/// 曲库聚合读取的「资料库」输入；测试 / 性能场景可替换为真实内存库。
@Riverpod(keepAlive: true, name: 'localLibraryLibraryProvider')
LibraryProvider localLibraryLibrary(Ref ref) => ref.read(libraryProvider);

@Riverpod(keepAlive: true, name: 'localLibraryIsolateThresholdProvider')
int localLibraryIsolateThreshold(Ref ref) => 2000;

@Riverpod(keepAlive: true, name: 'localLibraryProvider')
class LocalLibraryProvider extends _$LocalLibraryProvider {
  LibraryRepository? repository;
  DownloadRecords? downloads;
  LibraryProvider? library;
  PlayStatisticsRepository? statistics;
  late final Duration debounce;

  /// 浏览索引超过该行数时搬到 isolate 构建（测试注入小值）。
  late final int isolateThreshold;

  @override
  LocalLibraryState build() {
    repository = ref.read(appRuntimeProvider).maybe<LibraryRepository>();
    downloads = ref.read(downloadRecordsProvider);
    library = ref.read(localLibraryLibraryProvider);
    statistics = ref.read(appRuntimeProvider).maybe<PlayStatisticsRepository>();
    debounce = ref.watch(localLibraryDebounceProvider);
    isolateThreshold = ref.watch(localLibraryIsolateThresholdProvider);
    final repo = repository;
    final stats = statistics;
    final lib = library;
    final dl = downloads;
    if (repo == null || stats == null || lib == null || dl == null) {
      return LocalLibraryState.empty;
    }
    _subscriptions = [
      repo.changes.listen(_onLibraryChange),
      stats.changes.listen((_) => schedule(browse: false, stats: true)),
    ];
    dl.addListener(_onDownloadsChanged);
    lib.addListener(_onLibraryProviderChanged);
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
      for (final subscription in _subscriptions) {
        unawaited(subscription.cancel());
      }
      dl.removeListener(_onDownloadsChanged);
      lib.removeListener(_onLibraryProviderChanged);
    });
    schedule();
    return LocalLibraryState.empty;
  }

  LibraryBrowseSnapshot? get snapshot => state.snapshot;
  Map<String, List<CollectionRow>> get smartRows => state.smartRows;
  SmartListMetric get mostPlayedMetric => _mostPlayedMetric;

  SmartListMetric _mostPlayedMetric = SmartListMetric.playCount;

  /// 「最常播放」指标：设备本地 UI 状态，切换后重建列表。
  void setMostPlayedMetric(SmartListMetric metric) {
    if (_mostPlayedMetric == metric) return;
    _mostPlayedMetric = metric;
    state = state.copyWith(mostPlayedMetric: metric);
    _rowsDirty = true;
    unawaited(refresh());
  }

  LibraryBrowseSnapshot? _snapshot;
  Map<String, List<CollectionRow>> _smartRows = const {};
  Timer? _timer;
  bool _running = false;
  bool _again = false;
  bool _disposed = false;

  /// 已读入的输入：只有对应部分失效时才重读，其余直接复用。
  LibraryBrowseIndex? _browseIndex;

  /// 上一次构建索引用的输入。单曲收藏切换只改这里的一行后重建，
  /// 不重读 `playlist_tracks`；常驻 ~1 万个小对象，raw 仍是 DB 原串。
  BrowseSource? _browseSource;

  /// 下次 refresh 必须整库重读（批量 / 换源 / 同步 / 导入 / 下载变化）。
  bool _browseNeedsFullReload = true;

  List<PlayStatTrackEntry> _stats = const [];
  List<PlayStatTrackEntry> _statsByTime = const [];
  Set<String>? _playedKeys;

  /// 上一次聚合时看到的列表清单 / 历史引用，用来过滤资料库 provider 的
  /// 无关通知（加载态、收藏补丁、缓存释放都会 notify，但数据引用没变）。
  List<PlayHistoryEntry>? _seenHistory;
  List<PlaylistInfo>? _seenPlaylists;

  bool _browseDirty = true;
  bool _statsDirty = true;
  bool _rowsDirty = true;

  List<StreamSubscription<Object?>> _subscriptions = const [];

  /// 按失效范围标记输入并防抖重建；旧快照在完成前保持可见。
  ///
  /// [browse] 是整库浏览索引输入（收藏 + 全部列表 + 下载，需要重读
  /// `playlist_tracks`）；单曲收藏切换走缓存增量，不经过本方法。[stats] 是
  /// 统计榜与已听曲目集合。单条播放历史只影响智能列表行，两者都可以不传。
  void schedule({bool browse = true, bool stats = true}) {
    if (_disposed || repository == null || statistics == null) return;
    if (browse) {
      _browseDirty = true;
      _browseNeedsFullReload = true;
    }
    if (stats) _statsDirty = true;
    _rowsDirty = true;
    _armTimer();
  }

  void _armTimer() {
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(refresh()));
  }

  void _onLibraryChange(LibraryChange change) {
    switch (change) {
      case LibraryHistoryChange():
        // 每一次曲目切换都会写一条历史。浏览索引与统计都不受影响，重读整库
        // 只会把 raw 解码和两次统计榜塞进起播链路，收益为零。
        schedule(browse: false, stats: false);
      case LibraryImportChange():
        schedule();
      case LibraryFavoritesChange(:final toggle):
        if (toggle != null) {
          _applyFavoriteToggle(toggle);
        } else {
          // 批量 / 换源 / 同步 / 导入：无法用单行表达，整库校准。
          schedule(browse: true, stats: false);
        }
      case LibraryPlaylistsChange():
      case LibraryPlaylistTracksChange():
        schedule(browse: true, stats: false);
    }
  }

  /// 单曲收藏切换：只改缓存的 [BrowseSource] 一行再重建索引，不重读整表。
  ///
  /// 行投影的增删 / 位置交给收藏事实的纯函数：浏览行保留惰性 raw，不能直接
  /// 换成事实里的 `PlaylistTrack`，但排序口径必须与收藏列表完全一致。
  /// 取消收藏只删 favorites 里的键；该曲若仍在下载 / 用户列表里，
  /// 重建时的合并优先级（收藏 → 下载 / 导入 → 自建列表）会把它补回来。
  /// 批量 / 换源 / 同步不带 toggle，仍走整库重读；已有整库重读在排队或进行
  /// 中时不能拿旧缓存增量，否则会丢掉那次重读要校准的数据。
  void _applyFavoriteToggle(FavoriteToggle toggle) {
    final source = _browseSource;
    if (source == null || _browseNeedsFullReload || _running) {
      schedule(browse: true, stats: false);
      return;
    }
    if (toggle.favorite && toggle.track == null) {
      schedule(browse: true, stats: false);
      return;
    }
    final favorites = applyFavoriteToggleToProjection(
      rows: source.favorites,
      toggle: toggle,
      wrap: BrowseTrack.fromPlaylistTrack,
    );
    if (identical(favorites, source.favorites)) return;
    _browseSource = BrowseSource(
      favorites: favorites,
      playlists: source.playlists,
      downloads: source.downloads,
    );
    // 只重建索引，不置整库重读标记。
    _browseDirty = true;
    _rowsDirty = true;
    _armTimer();
  }

  void _onDownloadsChanged() => schedule(browse: true, stats: false);

  /// 资料库 provider 的通知远多于真实数据变化：只有历史引用或列表 id 集合
  /// 变了才需要重新聚合（懒加载完成后的首次数据也靠这条兜底）。收藏计数
  /// 补丁会生成新的 `playlists` 列表引用，但 id 集合不变，不应触发整库重读。
  void _onLibraryProviderChanged() {
    if (_disposed) return;
    final history = library!.history;
    final playlists = library!.playlists;
    final playlistsChanged = _playlistIdsChanged(playlists, _seenPlaylists);
    final historyChanged = !identical(history, _seenHistory);
    if (!playlistsChanged && !historyChanged) return;
    _seenHistory = history;
    _seenPlaylists = playlists;
    schedule(browse: playlistsChanged, stats: false);
  }

  static bool _playlistIdsChanged(
    List<PlaylistInfo> current,
    List<PlaylistInfo>? previous,
  ) {
    if (previous == null || current.length != previous.length) return true;
    for (var i = 0; i < current.length; i++) {
      if (current[i].id != previous[i].id) return true;
    }
    return false;
  }

  Future<void> refresh() async {
    if (_disposed || repository == null || statistics == null) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    var needBrowse = false;
    var needBrowseFull = false;
    var needStats = false;
    var needRows = false;
    try {
      needBrowse = _browseDirty;
      needBrowseFull = _browseNeedsFullReload;
      needStats = _statsDirty;
      needRows = _rowsDirty;
      // 先清标记再读：读取期间到达的变化会重新置位，下一轮不会漏。
      _browseDirty = false;
      _browseNeedsFullReload = false;
      _statsDirty = false;
      _rowsDirty = false;
      if (needBrowse) {
        if (needBrowseFull || _browseSource == null) {
          await _reloadBrowse();
        } else {
          await _rebuildBrowseFromSource();
        }
      }
      if (needStats) await _reloadStats();
      if (needRows || needBrowse || needStats) _publish();
    } catch (e) {
      // 读取失败保留失效标记：下一次事件 / 定时器再试，不留「永久缺一块」
      // 的快照（旧快照仍继续展示）。
      _browseDirty = _browseDirty || needBrowse;
      _browseNeedsFullReload = _browseNeedsFullReload || needBrowseFull;
      _statsDirty = _statsDirty || needStats;
      _rowsDirty = _rowsDirty || needRows;
      debugPrint('[Molia] 曲库聚合读取失败: $e');
    } finally {
      _running = false;
      if (_again && !_disposed) {
        _again = false;
        _armTimer();
      }
    }
  }

  Future<void> _reloadBrowse() async {
    final browseTracks = await repository!.loadBrowseTracks();
    _browseSource = BrowseSource(
      favorites: browseTracks.favorites,
      playlists: browseTracks.playlists,
      downloads: downloads!.downloads,
    );
    await _rebuildBrowseFromSource(sourcePath: 'sql');
  }

  /// 只用缓存输入重建索引（单曲收藏切换路径，不查库）。
  Future<void> _rebuildBrowseFromSource({
    String sourcePath = 'incremental',
  }) async {
    final source = _browseSource;
    if (source == null) return;
    _browseIndex = await _buildBrowseIndex(source, sourcePath: sourcePath);
  }

  /// 大库把去重 / 分组 / 排序移到 isolate；小库直接同步构建。
  ///
  /// 直接把 [BrowseSource] 送进 isolate：`BrowseTrack` / `DownloadedTrack` 与
  /// 惰性 raw 壳都只含 String / Map 等纯数据，Dart 直接复制对象即可；额外
  /// 构造一层 wire map 反而会在 UI isolate 上多付一次全量分配。若以后这些
  /// 类型里出现不可发送字段（平台对象、闭包等），`Isolate.run` 会抛错并走
  /// 下面的主线程回退，结果仍然可用。
  Future<LibraryBrowseIndex> _buildBrowseIndex(
    BrowseSource source, {
    required String sourcePath,
  }) {
    final rows = _rowCountOf(source);
    final useIsolate = rows > isolateThreshold;
    // path 只看「这一轮实际走哪条」：isolate 优先于 sql / incremental 来源。
    final path = useIsolate ? 'isolate' : sourcePath;
    return DataPathTrace.async('browse.build', () async {
      if (!useIsolate) return buildBrowseIndex(source);
      try {
        return await Isolate.run(() => buildBrowseIndex(source));
      } catch (e) {
        debugPrint('[Molia] 浏览索引 isolate 构建失败，回退主线程: $e');
        return buildBrowseIndex(source);
      }
    }, fields: () => {'rows': rows, 'path': path});
  }

  static int _rowCountOf(BrowseSource source) {
    var count = source.favorites.length + source.downloads.length;
    for (final playlist in source.playlists) {
      count += playlist.tracks.length;
    }
    return count;
  }

  Future<void> _reloadStats() async {
    try {
      final (stats, statsByTime, playedKeys) = await (
        statistics!.topTracks(limit: 100),
        statistics!.topTracks(limit: 100, byListening: true),
        statistics!.playedTrackKeys(),
      ).wait;
      _stats = stats;
      _statsByTime = statsByTime;
      _playedKeys = playedKeys;
    } catch (e) {
      debugPrint('[Molia] 读取听歌统计失败（智能列表降级）: $e');
      _stats = const [];
      _statsByTime = const [];
      _playedKeys = null;
    }
  }

  void _publish() {
    final index = _browseIndex;
    if (_disposed || index == null || downloads == null || library == null) {
      return;
    }
    DataPathTrace.sync(
      'browse.publish',
      () {
        final downloadList = downloads!.downloads;
        final sources = SmartListSources(
          downloads: downloadList,
          history: library!.history,
          stats: _mostPlayedMetric == SmartListMetric.listeningTime
              ? _statsByTime
              : _stats,
          browse: index,
          playedKeys: _playedKeys,
        );
        _smartRows = <String, List<CollectionRow>>{
          for (final id in SmartListIds.all)
            id: _rowsFor(id, sources, downloadList),
        };
        _snapshot = LibraryBrowseSnapshot(index: index);
        _seenHistory = library!.history;
        _seenPlaylists = library!.playlists;
        state = LocalLibraryState(
          snapshot: _snapshot,
          smartRows: _smartRows,
          mostPlayedMetric: _mostPlayedMetric,
        );
      },
      fields: () => {
        'smart_rows': _smartRows.values.fold<int>(
          0,
          (sum, rows) => sum + rows.length,
        ),
        'index_tracks': index.tracks.length,
      },
    );
  }

  List<CollectionRow> _rowsFor(
    String id,
    SmartListSources sources,
    List<DownloadedTrack> downloads,
  ) {
    if (id == SmartListIds.missingFiles) {
      final missing = [
        for (final record in downloads)
          if (record.hasAudio && record.isMissing) record,
      ]..sort((a, b) => (b.missingAt ?? 0).compareTo(a.missingAt ?? 0));
      return [
        for (final record in missing)
          LocalSongCollectionRow(CollectionLocalSong.download(record)),
      ];
    }
    return [
      for (final track in buildSmartList(
        id,
        sources,
        metric: _mostPlayedMetric,
      ))
        TrackCollectionRow(
          track.toPlaylistTrack(playlistId: 0, addedAt: track.addedAt),
        ),
    ];
  }
}
