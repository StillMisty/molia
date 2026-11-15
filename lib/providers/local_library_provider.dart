/// 曲库聚合读模型：专辑 / 歌手浏览索引、重复组与七个智能列表。
///
/// 输入来自资料库（收藏 + 全部列表）、下载记录、播放历史与统计；一次聚合
/// 读取后在内存里构建，输入 revision 变化防抖 150ms 重建，旧快照保持可见。
/// 只服务 UI，不写数据库、不进入同步。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

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
import 'local_songs_collection.dart';

/// 曲库浏览快照（只含 UI 需要的聚合索引）。
class LibraryBrowseSnapshot {
  const LibraryBrowseSnapshot({required this.index});

  final LibraryBrowseIndex index;
}

class LocalLibraryProvider extends ChangeNotifier {
  LocalLibraryProvider({
    required this.repository,
    required this.downloads,
    required this.library,
    required this.statistics,
    this.debounce = const Duration(milliseconds: 150),
  }) {
    _subscriptions = [
      repository.changes.listen(_onLibraryChange),
      statistics.changes.listen((_) => schedule(browse: false, stats: true)),
    ];
    downloads.addListener(_onDownloadsChanged);
    library.addListener(_onLibraryProviderChanged);
    schedule();
  }

  final LibraryRepository repository;
  final DownloadRecords downloads;
  final LibraryProvider library;
  final PlayStatisticsRepository statistics;
  final Duration debounce;

  SmartListMetric _mostPlayedMetric = SmartListMetric.playCount;

  SmartListMetric get mostPlayedMetric => _mostPlayedMetric;

  /// 「最常播放」指标：设备本地 UI 状态，切换后重建列表。
  void setMostPlayedMetric(SmartListMetric metric) {
    if (_mostPlayedMetric == metric) return;
    _mostPlayedMetric = metric;
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

  LibraryBrowseSnapshot? get snapshot => _snapshot;
  Map<String, List<CollectionRow>> get smartRows => _smartRows;

  /// 按失效范围标记输入并防抖重建；旧快照在完成前保持可见。
  ///
  /// [browse] 是整库浏览索引（收藏 + 全部列表 + 下载，需重读
  /// `playlist_tracks` 并解码 raw）；[stats] 是统计榜与已听曲目集合。
  /// 单条播放历史只影响智能列表行，两者都可以不传。
  void schedule({bool browse = true, bool stats = true}) {
    if (_disposed) return;
    if (browse) _browseDirty = true;
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
      case LibraryFavoritesChange():
      case LibraryPlaylistsChange():
      case LibraryPlaylistTracksChange():
        schedule(browse: true, stats: false);
    }
  }

  void _onDownloadsChanged() => schedule(browse: true, stats: false);

  /// 资料库 provider 的通知远多于真实数据变化：只有历史 / 列表清单的引用
  /// 换了才需要重新聚合（懒加载完成后的首次数据也靠这条兜底）。
  void _onLibraryProviderChanged() {
    if (_disposed) return;
    final history = library.history;
    final playlists = library.playlists;
    final playlistsChanged = !identical(playlists, _seenPlaylists);
    final historyChanged = !identical(history, _seenHistory);
    if (!playlistsChanged && !historyChanged) return;
    _seenHistory = history;
    _seenPlaylists = playlists;
    schedule(browse: playlistsChanged, stats: false);
  }

  Future<void> refresh() async {
    if (_disposed) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    var needBrowse = false;
    var needStats = false;
    var needRows = false;
    try {
      needBrowse = _browseDirty;
      needStats = _statsDirty;
      needRows = _rowsDirty;
      // 先清标记再读：读取期间到达的变化会重新置位，下一轮不会漏。
      _browseDirty = false;
      _statsDirty = false;
      _rowsDirty = false;
      if (needBrowse) await _reloadBrowse();
      if (needStats) await _reloadStats();
      if (needRows || needBrowse || needStats) _publish();
    } catch (e) {
      // 读取失败保留失效标记：下一次事件 / 定时器再试，不留「永久缺一块」
      // 的快照（旧快照仍继续展示）。
      _browseDirty = _browseDirty || needBrowse;
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
    final browseTracks = await repository.loadBrowseTracks();
    final downloadList = downloads.downloads;
    _browseIndex = buildBrowseIndex(
      BrowseSource(
        favorites: browseTracks.favorites,
        playlists: browseTracks.playlists,
        downloads: downloadList,
      ),
    );
  }

  Future<void> _reloadStats() async {
    try {
      final (stats, statsByTime, playedKeys) = await (
        statistics.topTracks(limit: 100),
        statistics.topTracks(limit: 100, byListening: true),
        statistics.playedTrackKeys(),
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
    if (_disposed || index == null) return;
    final downloadList = downloads.downloads;
    final sources = SmartListSources(
      downloads: downloadList,
      history: library.history,
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
    _seenHistory = library.history;
    _seenPlaylists = library.playlists;
    notifyListeners();
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
          PlaylistTrack(
            playlistId: 0,
            sourceKey: track.sourceKey,
            songId: track.songId,
            title: track.title,
            artist: track.artist,
            album: track.album,
            coverUrl: track.coverUrl,
            durationMs: track.durationMs,
            raw: track.raw,
            addedAt: track.addedAt,
          ),
        ),
    ];
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    downloads.removeListener(_onDownloadsChanged);
    library.removeListener(_onLibraryProviderChanged);
    super.dispose();
  }
}
