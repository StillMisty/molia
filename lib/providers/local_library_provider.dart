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
import 'library_browse_controller.dart';
import 'library_provider.dart';
import 'local_songs_collection.dart';

class LocalLibraryProvider extends ChangeNotifier {
  LocalLibraryProvider({
    required this.repository,
    required this.downloads,
    required this.library,
    required this.statistics,
    this.debounce = const Duration(milliseconds: 150),
  }) {
    repository.changes.listen((_) => schedule());
    downloads.addListener(schedule);
    library.addListener(schedule);
    statistics.changes.listen((_) => schedule());
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
    unawaited(refresh());
  }

  LibraryBrowseSnapshot? _snapshot;
  Map<String, List<CollectionRow>> _smartRows = const {};
  Timer? _timer;
  bool _running = false;
  bool _again = false;
  bool _disposed = false;

  LibraryBrowseSnapshot? get snapshot => _snapshot;
  Map<String, List<CollectionRow>> get smartRows => _smartRows;

  /// 输入变化后防抖重建；旧快照在完成前保持可见。
  void schedule() {
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(refresh()));
  }

  Future<void> refresh() async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      final browseTracks = await repository.loadBrowseTracks();
      final downloadList = downloads.downloads;
      final index = buildBrowseIndex(
        BrowseSource(
          favorites: browseTracks.favorites,
          playlists: browseTracks.playlists,
          downloads: downloadList,
        ),
      );
      final groups = groupDuplicates(index.tracks);
      List<PlayStatTrackEntry> stats = const [];
      try {
        stats = await statistics.topTracks(limit: 100000);
      } catch (e) {
        debugPrint('[Molia] 读取听歌统计失败（智能列表降级）: $e');
      }
      final sources = SmartListSources(
        downloads: downloadList,
        history: library.history,
        stats: stats,
        browse: index,
      );
      final smartRows = <String, List<CollectionRow>>{
        for (final id in SmartListIds.all)
          id: _rowsFor(id, sources, downloadList),
      };
      if (_disposed) return;
      _snapshot = LibraryBrowseSnapshot(
        index: index,
        duplicateGroups: groups,
        versionCounts: duplicateVersionCounts(groups),
      );
      _smartRows = smartRows;
      notifyListeners();
    } catch (e) {
      debugPrint('[Molia] 曲库聚合读取失败: $e');
    } finally {
      _running = false;
      if (_again && !_disposed) {
        _again = false;
        schedule();
      }
    }
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
    super.dispose();
  }
}
