/// 资料库状态：播放历史 / 我的列表 / 收藏 / `.lxmc` 导入 + 播放接线。
///
/// 职责：
/// - 内存缓存 history / playlists / 列表曲目 / 收藏键，仓库变更（[LibraryStore.changes]）
///   时失效并重载；
/// - 把 [PlayHistoryEntry] / [PlaylistTrack] 还原为 [SourceTrack]（raw 原样带上）
///   并委托 [PlaybackProvider.playSourceTracks] 播放——播放时按需重新取链，
///   不持久化直链；
/// - 收藏切换（默认收藏列表）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app/perf/data_path_trace.dart';
import '../domain/ports/library_store.dart';
import '../data/mapping/track_mapper.dart';
import '../domain/models/download.dart' show kLocalSourceKey;
import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../models/play_mode.dart';
import '../sources/raw_track.dart';
import '../sources/source_track.dart';
import 'library_outcome.dart';
import 'playback_provider.dart';

/// 列表曲目读取视图：页面只读读取阶段，不探测缓存内部。
class PlaylistTracksView {
  const PlaylistTracksView({required this.tracks, required this.state});

  /// null = 尚未加载成功过（首次加载 / 加载失败且无旧缓存）。
  final List<PlaylistTrack>? tracks;

  /// loading / ready / failed（failed 时 [tracks] 为空才表示没有可显示数据）。
  final LibraryReadState state;

  bool get loading => state.isLoading;
  bool get failed => state.isFailed;
  bool get ready => state.isReady;
}

class LibraryProvider extends ChangeNotifier {
  LibraryProvider({
    required LibraryStore repository,
    required PlaybackProvider playbackProvider,
  })  : _repository = repository,
        _playback = playbackProvider {
    _subscription = _repository.changes.listen(_onRepositoryChanged);
  }

  final LibraryStore _repository;
  final PlaybackProvider _playback;
  StreamSubscription<void>? _subscription;

  List<PlayHistoryEntry> _history = const [];
  List<PlaylistInfo> _playlists = const [];
  final Map<int, List<PlaylistTrack>> _tracksByPlaylist = {};
  final Set<int> _loadingPlaylistIds = {};
  Set<String> _favoriteKeys = const {};

  bool _historyLoaded = false;
  bool _playlistsLoaded = false;
  bool _favoritesLoaded = false;

  /// 合集读取阶段：页面据此区分空库与加载失败（failed 可重试）。
  LibraryReadState _playlistsState = const LibraryReadState.loading();
  LibraryReadState _historyState = const LibraryReadState.loading();

  /// 各列表曲目最近一次读取失败（有旧缓存时视图仍按 ready 展示旧值）。
  final Map<int, Object> _playlistTracksErrors = {};

  /// `_favoriteKeys` 是否来自仓库整表（而非只有一次乐观 toggle）。
  /// 只有整表可信时才能用它的长度校准收藏计数。
  bool _favoriteKeysAuthoritative = false;

  /// 历史查询进行中的数量（静默重载与显式刷新共用）。
  ///
  /// 查询期间到达的单条写入不能直接丢掉：快照可能取自写入之前。这里只记录
  /// 进行中数量，等最后一个查询落地后再把缓冲条目补进去。
  int _historyLoadsInFlight = 0;

  /// 查询期间到达、尚未合并进内存的单条历史写入（按到达顺序）。
  List<PlayHistoryEntry> _pendingHistoryEntries = const [];

  /// 收藏全量校准进行中的数量。
  ///
  /// 校准的 `favoriteKeys` / 列表 / 计数来自多个 await，期间的本地 toggle
  /// 可能落在旧快照之外。计数器归零后重放队列，保证最终状态包含本地写入。
  int _favoritesCalibrationsInFlight = 0;

  /// 校准期间到达的收藏切换（立即打补丁，同时排队等待重放）。
  final List<FavoriteToggle> _pendingFavoriteToggles = [];

  bool _disposed = false;
  Future<void>? _pendingReload;

  /// 收藏状态版本（单调递增）：收藏相关订阅方（收藏按钮 / 发现页）据此做
  /// O(1) 的失效判定，不必对每次历史写入都重建。
  int _favoritesRevision = 0;
  int get favoritesRevision => _favoritesRevision;

  /// 列表集合 / 计数版本（`customPlaylists` 的失效判定）。
  int _playlistsRevision = 0;
  int get playlistsRevision => _playlistsRevision;

  List<PlayHistoryEntry> get history => _history;
  List<PlaylistInfo> get playlists => _playlists;

  /// 自建列表（不含默认收藏的内部保留行）。
  List<PlaylistInfo> get customPlaylists => [
        for (final playlist in _playlists)
          if (!playlist.isFavorites) playlist,
      ];

  /// 历史 / 列表的读取阶段（含失败与重试）。
  LibraryReadState get historyState => _historyState;
  LibraryReadState get playlistsState => _playlistsState;

  bool get isHistoryLoading => _historyState.isLoading;
  bool get isPlaylistsLoading => _playlistsState.isLoading;

  /// 列表曲目读取视图（含 failed 阶段）。
  PlaylistTracksView playlistTracksView(int playlistId) {
    final tracks = _tracksByPlaylist[playlistId];
    final error = _playlistTracksErrors[playlistId];
    final state = error != null && tracks == null
        ? LibraryReadState.failed(error)
        : _loadingPlaylistIds.contains(playlistId) ||
                (tracks == null && error == null)
            ? const LibraryReadState.loading()
            : const LibraryReadState.ready();
    return PlaylistTracksView(tracks: tracks, state: state);
  }

  /// 请求加载列表曲目（未缓存且未在加载中时发起；可在 build 内调用）。
  ///
  /// [force] 由「加载失败后重试」使用：丢掉旧缓存重新查询。
  void ensurePlaylistTracks(int playlistId, {bool force = false}) {
    if (!force && _tracksByPlaylist.containsKey(playlistId)) return;
    // 已有请求在途：不并发；force 等它落地后由调用方再次重试。
    if (!_loadingPlaylistIds.add(playlistId)) return;
    if (force) _tracksByPlaylist.remove(playlistId);
    _playlistTracksErrors.remove(playlistId);
    // build 期调用：同步标记 loading（本帧即可显示加载态），通知推迟到
    // 微任务，避免 setState during build。
    unawaited(Future<void>.microtask(() async {
      if (_disposed) return;
      _notify();
      try {
        final tracks = await _repository.listPlaylistTracks(playlistId);
        if (_disposed) return;
        _tracksByPlaylist[playlistId] = tracks;
        _playlistTracksErrors.remove(playlistId);
      } catch (e) {
        debugPrint('[Library] 加载列表曲目失败: $e');
        if (_disposed) return;
        _playlistTracksErrors[playlistId] = e;
      } finally {
        _loadingPlaylistIds.remove(playlistId);
        _notify();
      }
    }));
  }

  bool isFavorite(String sourceKey, String songId) =>
      _favoriteKeys.contains('$sourceKey:$songId');

  void _onRepositoryChanged(LibraryChange change) {
    if (_disposed) return;
    switch (change) {
      case LibraryHistoryChange(:final entry):
        if (entry != null) {
          // 单条写入直接打补丁：播放 / 收藏都不必等待一次全表查询。
          _applyHistoryEntry(entry);
        } else {
          // 删除 / 清空 / 同步等无法增量表达：保持现有整表重载。
          _historyLoaded = false;
          _pendingReload = _reloadHistoryQuietly();
          unawaited(_pendingReload!);
        }
      case LibraryFavoritesChange(:final toggle):
        if (toggle != null) {
          // 单曲收藏切换：只改缓存里的一行与计数，不闪列表、不重查。
          _applyFavoriteToggle(toggle);
        } else {
          // 批量 / 换源 / 同步 / 导入：收藏键与列表都按库校准。
          _pendingReload = _refreshFavoritesQuietly();
          unawaited(_pendingReload!);
        }
      case LibraryPlaylistTracksChange(:final playlistId):
        _pendingReload = Future.wait([
          _reloadPlaylistTracksQuietly(playlistId),
          _refreshPlaylistsQuietly(),
        ]);
        unawaited(_pendingReload!);
      case LibraryPlaylistsChange():
      case LibraryImportChange():
        _invalidateAll();
    }
  }

  /// 单条历史写入的内存补丁（不查库）。
  ///
  /// 与 [_mergeHistoryOrder] 同一顺序口径：已有条目原位替换内容（重播不打断
  /// 浏览），新条目插到最前；超出上限时裁掉尾部最旧记录。
  void _applyHistoryEntry(PlayHistoryEntry entry) {
    // 查询进行中：结果可能还没包含这次写入，先缓冲，等查询落地后再合并。
    if (_historyLoadsInFlight > 0) {
      _pendingHistoryEntries = [..._pendingHistoryEntries, entry];
      return;
    }
    // 历史尚未加载过：缓存本来就没有可补的基线，保持 dirty 等首次
    // refreshHistory。这里刻意不回查——首屏可能根本没打开历史页。
    if (!_historyLoaded) return;
    _mergeHistoryEntry(entry);
    _notify();
  }

  /// 把 [entry] 合并进当前历史（不通知）；调用方负责一次性通知。
  void _mergeHistoryEntry(PlayHistoryEntry entry) {
    final key = _historyKey(entry);
    final index = _history.indexWhere((item) => _historyKey(item) == key);
    final next = List<PlayHistoryEntry>.of(_history);
    if (index >= 0) {
      next[index] = entry;
    } else {
      next.insert(0, entry);
    }
    if (next.length > kHistoryLimit) {
      next.removeRange(kHistoryLimit, next.length);
    }
    _history = next;
  }

  /// 查询结束时补入期间缓冲的单条写入。
  ///
  /// 只有最后一个查询落地、且已有可合并的基线时才消费缓冲；失败且从未
  /// 加载成功时保留缓冲，等下一次 refreshHistory 再合并（DB 也有这次写入，
  /// 不会永久丢失）。
  void _drainPendingHistoryEntries() {
    if (_historyLoadsInFlight > 0 || _pendingHistoryEntries.isEmpty) return;
    if (!_historyLoaded) return;
    for (final entry in _pendingHistoryEntries) {
      _mergeHistoryEntry(entry);
    }
    _pendingHistoryEntries = const [];
  }

  /// 一个历史查询结束：递减进行中计数，最后一个查询负责补入缓冲。
  void _finishHistoryLoad({required bool success}) {
    if (_historyLoadsInFlight > 0) _historyLoadsInFlight--;
    if (_historyLoadsInFlight > 0) return;
    // 失败但旧缓存仍在：把缓冲合并进旧缓存；失败且从未加载成功则留到下次。
    if (success || _historyLoaded) _drainPendingHistoryEntries();
  }

  /// 单曲收藏切换的内存补丁（不查库）。
  ///
  /// [toggle] 来自写入侧，必定对应一次真实落库。校准进行中时先排队：校准的
  /// 多个快照可能早于这次写入，立即打补丁后仍会被旧结果覆盖；等最后一个校准
  /// 结束再重放一次同样的幂等补丁。重放期间计数不再排队（计数器已归零）。
  void _applyFavoriteToggle(FavoriteToggle toggle) {
    if (_favoritesCalibrationsInFlight > 0) {
      _pendingFavoriteToggles.add(toggle);
    }
    _patchFavoriteToggle(toggle);
    _notify();
  }

  /// 收藏补丁的实际实现（不通知）：立即应用与校准后重放共用，必须幂等。
  void _patchFavoriteToggle(FavoriteToggle toggle) {
    final hadKey = _favoriteKeys.contains(toggle.key);
    final keys = Set<String>.from(_favoriteKeys);
    if (toggle.favorite) {
      keys.add(toggle.key);
    } else {
      keys.remove(toggle.key);
    }
    _favoriteKeys = keys;
    // 只有全量键集合可信时才标记「已加载」；否则一次 toggle 会把部分集合
    // 当成全量，后续 ensureFavoritesLoaded 不再补查其它曲目的收藏状态。
    if (_favoriteKeysAuthoritative) _favoritesLoaded = true;
    if (hadKey != toggle.favorite) _favoritesRevision++;

    final favoritesId = _favoritesPlaylistId;
    if (favoritesId == null) return;
    final cached = _tracksByPlaylist[favoritesId];
    if (cached != null) {
      final hasRow = cached.any((track) =>
          track.sourceKey == toggle.sourceKey && track.songId == toggle.songId);
      if (toggle.favorite && !hasRow) {
        final track = toggle.track;
        if (track != null) {
          final next = List<PlaylistTrack>.of(cached);
          final index =
              next.indexWhere((item) => item.sortOrder > track.sortOrder);
          next.insert(index < 0 ? next.length : index, track);
          _tracksByPlaylist[favoritesId] = next;
        }
      } else if (!toggle.favorite && hasRow) {
        _tracksByPlaylist[favoritesId] = [
          for (final track in cached)
            if (!(track.sourceKey == toggle.sourceKey &&
                track.songId == toggle.songId))
              track,
        ];
      }
    }

    PlaylistInfo? favorites;
    for (final playlist in _playlists) {
      if (playlist.id == favoritesId) {
        favorites = playlist;
        break;
      }
    }
    if (favorites == null) return;
    // 计数优先级：整表收藏键 > 已加载列表长度 > ±1。
    // 前两者都是权威快照，重放时不会把校准已包含的 toggle 再算一次。
    final favoriteTracks = _tracksByPlaylist[favoritesId];
    final trackCount = _favoriteKeysAuthoritative
        ? _favoriteKeys.length
        : favoriteTracks != null
            ? favoriteTracks.length
            : _adjustTrackCount(
                favorites.trackCount,
                toggle.favorite ? 1 : -1,
              );
    if (trackCount == favorites.trackCount) return;
    _playlists = [
      for (final playlist in _playlists)
        if (playlist.id == favoritesId)
          PlaylistInfo(
            id: playlist.id,
            name: playlist.name,
            createdAt: playlist.createdAt,
            trackCount: trackCount,
            isFavorites: playlist.isFavorites,
          )
        else
          playlist,
    ];
    _playlistsRevision++;
  }

  /// 校准结束时重放期间排队的 toggle；只在最后一个校准落地后调用。
  void _finishFavoritesCalibration() {
    if (_favoritesCalibrationsInFlight > 0) _favoritesCalibrationsInFlight--;
    if (_favoritesCalibrationsInFlight > 0) return;
    if (_pendingFavoriteToggles.isEmpty) return;
    final queued = List<FavoriteToggle>.of(_pendingFavoriteToggles);
    _pendingFavoriteToggles.clear();
    // 重放走补丁本体而不是 _applyFavoriteToggle：不会再次入队。
    for (final toggle in queued) {
      _patchFavoriteToggle(toggle);
    }
  }

  static int _adjustTrackCount(int count, int delta) {
    if (delta > 0) return count + 1;
    if (delta < 0) return _dec(count);
    return count;
  }

  static int _dec(int value) => value > 0 ? value - 1 : 0;

  void _invalidateAll() {
    // 立即失效缓存并通知（同步），后台静默重载；不做事件去重——
    // 去重标志会在微任务未执行时吞掉后续变更，导致 UI 永久陈旧。
    // 静默重载不翻转 loading：后台校准不闪加载态（已有数据保持可见）。
    _historyLoaded = false;
    _playlistsLoaded = false;
    _favoritesLoaded = false;
    // 导入等变化可能新增收藏，旧键集合不再是全量：校准完成前不能再用它
    // 反推计数，也不能让一次 toggle 把它重新标成「已加载」。
    _favoriteKeysAuthoritative = false;
    _favoritesRevision++;
    _playlistsRevision++;
    _tracksByPlaylist.clear();
    _notify();
    _pendingReload = Future.wait([
      _reloadHistoryQuietly(),
      _refreshPlaylistsQuietly(),
      _refreshFavoritesQuietly(),
    ]);
    unawaited(_pendingReload!);
  }

  /// 历史变化的后台校准：保持当前列表可见，不翻转 loading。
  ///
  /// 顺序策略：**已存在的条目保持当前顺序**（只换数据），全新条目插到最前。
  /// 为什么：播放历史 / 本地歌曲列表在浏览期间不该因重播而即时重排（刚点的
  /// 歌跳到列表顶部会打断浏览）；要按最新播放顺序刷新时，由收藏页在重新进入
  /// 合集 / 页面重新可见时调用 [resortHistoryByRecency]。
  Future<void> _reloadHistoryQuietly() => DataPathTrace.async(
        'library.history.reload',
        () async {
          // 新一次整表查询覆盖此前的本地写入（它们都已落库）：丢弃旧缓冲，
          // 避免查询后又把随后被删除的条目“复活”。查询期间的新写入会重新入队。
          _pendingHistoryEntries = const [];
          _historyLoadsInFlight++;
          var success = false;
          try {
            final fresh = await _repository.listHistory();
            _history = _mergeHistoryOrder(current: _history, fresh: fresh);
            _historyLoaded = true;
            _historyState = const LibraryReadState.ready();
            success = true;
          } catch (e) {
            debugPrint('[Library] 重载播放历史失败: $e');
            // 有旧缓存就继续展示旧值；从未加载成功才是 failed（可重试）。
            if (!_historyLoaded) _historyState = LibraryReadState.failed(e);
          } finally {
            _finishHistoryLoad(success: success);
          }
          _notify();
        },
        fields: () => {'rows': _history.length},
      );

  /// 稳定合并：已存在条目保持 [current] 的相对顺序（内容用最新值），全新条目
  /// 按最近优先插到最前（[fresh] 本身即最近优先）。
  static List<PlayHistoryEntry> _mergeHistoryOrder({
    required List<PlayHistoryEntry> current,
    required List<PlayHistoryEntry> fresh,
  }) {
    final freshByKey = {for (final entry in fresh) _historyKey(entry): entry};
    final ordered = <PlayHistoryEntry>[];
    for (final entry in current) {
      final updated = freshByKey.remove(_historyKey(entry));
      if (updated != null) ordered.add(updated);
    }
    if (freshByKey.isEmpty) return ordered;
    return [
      for (final entry in fresh)
        if (freshByKey.containsKey(_historyKey(entry))) entry,
      ...ordered,
    ];
  }

  static String _historyKey(PlayHistoryEntry entry) =>
      '${entry.sourceKey}:${entry.songId}';

  /// 按最近播放（`playedAt` 倒序）重排内存历史；顺序真变了才通知。
  ///
  /// 由收藏页在重新进入播放历史 / 本地歌曲合集、或页面重新可见时调用：
  /// 停留期间列表顺序冻结（见 [_reloadHistoryQuietly]），只在这一刻刷新。
  /// 时间相同的条目保持当前相对顺序（内存侧不读 DB rowid）。
  void resortHistoryByRecency() {
    if (_history.length < 2) return;
    final decorated = [
      for (var i = 0; i < _history.length; i++) (entry: _history[i], index: i),
    ]..sort((a, b) {
        final byTime = b.entry.playedAt.compareTo(a.entry.playedAt);
        return byTime != 0 ? byTime : a.index.compareTo(b.index);
      });
    var changed = false;
    for (var i = 0; i < decorated.length; i++) {
      if (!identical(decorated[i].entry, _history[i])) {
        changed = true;
        break;
      }
    }
    if (!changed) return;
    _history = [for (final item in decorated) item.entry];
    _notify();
  }

  /// 收藏变化的后台校准：列表保持可见，不翻转 loading。
  Future<void> _refreshFavoritesQuietly() => DataPathTrace.async(
        'library.favorites.refresh',
        () async {
          _favoritesRevision++;
          // 新一次整表校准覆盖此前的本地 toggle（都已落库）：旧队列丢弃，
          // 避免校准后重放已被后续删除的 toggle。校准期间的新 toggle 会重新入队。
          _pendingFavoriteToggles.clear();
          _favoritesCalibrationsInFlight++;
          try {
            try {
              _favoriteKeys = await _repository.favoriteKeys();
              _favoriteKeysAuthoritative = true;
              _favoritesLoaded = true;
            } catch (e) {
              debugPrint('[Library] 刷新收藏状态失败: $e');
            }
            final favoritesId = _favoritesPlaylistId;
            if (favoritesId != null &&
                _tracksByPlaylist.containsKey(favoritesId)) {
              try {
                _tracksByPlaylist[favoritesId] =
                    await _repository.listPlaylistTracks(favoritesId);
              } catch (e) {
                debugPrint('[Library] 刷新收藏列表失败: $e');
              }
            }
            // 通知推迟到 finally：重放完校准期间的本地 toggle 后只通知一次。
            await _refreshPlaylistsQuietly(notify: false);
          } finally {
            _finishFavoritesCalibration();
            _notify();
          }
        },
        fields: () {
          final favoritesId = _favoritesPlaylistId;
          return {
            'favorites': _favoriteKeys.length,
            'tracks': favoritesId == null
                ? 0
                : (_tracksByPlaylist[favoritesId]?.length ?? 0),
          };
        },
      );

  /// 列表集合/计数后台刷新（不清曲目缓存、不闪 loading）。
  ///
  /// [notify] 为 false 时由调用方在所有状态（含排队重放）更新完后统一通知。
  Future<void> _refreshPlaylistsQuietly({bool notify = true}) async {
    _playlistsRevision++;
    try {
      _playlists = await _repository.listPlaylists();
      _playlistsLoaded = true;
      _playlistsState = const LibraryReadState.ready();
    } catch (e) {
      debugPrint('[Library] 刷新列表失败: $e');
      if (!_playlistsLoaded) _playlistsState = LibraryReadState.failed(e);
    }
    if (notify) _notify();
  }

  /// 单个列表曲目的后台重载：已缓存时原地替换（滚动位置/列表实例稳定）。
  Future<void> _reloadPlaylistTracksQuietly(int playlistId) async {
    if (!_tracksByPlaylist.containsKey(playlistId)) return;
    try {
      _tracksByPlaylist[playlistId] =
          await _repository.listPlaylistTracks(playlistId);
      _playlistTracksErrors.remove(playlistId);
      _notify();
    } catch (e) {
      debugPrint('[Library] 重载列表曲目失败: $e');
      // 有旧缓存时保持 ready；错误留到显式重试时再清。
      _playlistTracksErrors[playlistId] = e;
    }
  }

  int? get _favoritesPlaylistId {
    for (final playlist in _playlists) {
      if (playlist.isFavorites) return playlist.id;
    }
    return null;
  }

  /// 仅供测试/调试：最近一次仓库变更触发的重载 Future（完成后为 null 不安全，
  /// 这里保留最近一次，供测试确定性等待）。
  @visibleForTesting
  Future<void>? get pendingReload => _pendingReload;

  /// 显式重载历史（首屏 / 导入后 / 失败重试）：直接采用仓库顺序（最近播放
  /// 倒序），不走停留期间的稳定合并。
  Future<void> refreshHistory({bool force = false}) async {
    if (_historyLoaded && !force) return;
    // 整表查询会包含此前的本地写入，旧缓冲不再需要（见 _reloadHistoryQuietly）。
    _pendingHistoryEntries = const [];
    _historyLoadsInFlight++;
    _historyState = const LibraryReadState.loading();
    _notify();
    var success = false;
    try {
      _history = await _repository.listHistory();
      _historyLoaded = true;
      _historyState = const LibraryReadState.ready();
      success = true;
    } catch (e) {
      // 查询失败保持旧缓存（首次为空列表），并把失败阶段交给页面重试。
      debugPrint('[Library] 加载播放历史失败: $e');
      if (!_historyLoaded) _historyState = LibraryReadState.failed(e);
    } finally {
      _finishHistoryLoad(success: success);
      _notify();
    }
  }

  Future<void> refreshPlaylists({bool force = false}) async {
    if (_playlistsLoaded && !force) return;
    _playlistsRevision++;
    _playlistsState = const LibraryReadState.loading();
    _notify();
    try {
      _playlists = await _repository.listPlaylists();
      _playlistsLoaded = true;
      _playlistsState = const LibraryReadState.ready();
    } catch (e) {
      debugPrint('[Library] 加载列表失败: $e');
      if (!_playlistsLoaded) _playlistsState = LibraryReadState.failed(e);
    } finally {
      _notify();
    }
  }

  Future<void> ensureFavoritesLoaded({bool force = false}) async {
    if (_favoritesLoaded && !force) return;
    _favoritesRevision++;
    try {
      _favoriteKeys = await _repository.favoriteKeys();
      _favoriteKeysAuthoritative = true;
      _favoritesLoaded = true;
      _notify();
    } catch (e) {
      debugPrint('[Library] 加载收藏状态失败: $e');
    }
  }

  /// 列表曲目：命中缓存直接返回，否则查询并缓存（可等待入口）。
  ///
  /// 失败返回旧缓存（或空列表）并记录 failed 阶段，不向调用方抛异常。
  Future<List<PlaylistTrack>> loadPlaylistTracks(
    int playlistId, {
    bool force = false,
  }) async {
    if (!force) {
      final cached = _tracksByPlaylist[playlistId];
      if (cached != null) return cached;
    }
    if (_loadingPlaylistIds.add(playlistId)) _notify();
    try {
      final tracks = await _repository.listPlaylistTracks(playlistId);
      _tracksByPlaylist[playlistId] = tracks;
      _playlistTracksErrors.remove(playlistId);
      return tracks;
    } catch (e) {
      debugPrint('[Library] 加载列表曲目失败: $e');
      _playlistTracksErrors[playlistId] = e;
      return _tracksByPlaylist[playlistId] ?? const [];
    } finally {
      _loadingPlaylistIds.remove(playlistId);
      _notify();
    }
  }

  // 播放接线（raw 原样 → SourceTrack → PlaybackProvider；按需重新取链）

  /// 播放音乐历史（[entries] 的可见顺序即播放队列顺序；[index] 为起始下标）。
  ///
  /// [mode] 非空时先切换播放模式（「随机播放」→随机）；不传时尊重当前模式。
  Future<void> playHistory(
    List<PlayHistoryEntry> entries,
    int index, {
    String? contextName,
    PlayMode? mode,
  }) async {
    if (entries.isEmpty) return;
    if (mode != null) {
      await _playback.setPlayMode(mode);
    }
    final tracks = [for (final entry in entries) _fromHistory(entry)];
    await _playback.playSourceTracks(
      tracks,
      index.clamp(0, tracks.length - 1),
      contextName: contextName,
    );
  }

  /// 按给定曲目顺序播放（收藏页搜索/排序后的可见顺序即播放队列顺序）。
  ///
  /// [mode] 非空时先切换播放模式（「随机播放」→随机），保证按钮语义与后续
  /// 自动切歌行为一致；「播放全部」与单曲点击不传 [mode]，尊重用户当前模式。
  Future<void> playPlaylistTracks(
    List<PlaylistTrack> tracks,
    int index, {
    String? contextName,
    PlayMode? mode,
  }) async {
    if (tracks.isEmpty) return;
    if (mode != null) {
      await _playback.setPlayMode(mode);
    }
    await _playback.playSourceTracks(
      [for (final track in tracks) _fromPlaylistTrack(track)],
      index.clamp(0, tracks.length - 1),
      contextName: contextName,
    );
  }

  // 变更操作（仓库写 → changes 流触发缓存失效）

  Future<LibraryMutationOutcome> deleteHistoryEntry(
      PlayHistoryEntry entry) async {
    // 乐观更新本地缓存（列表即时移除，不等待变更流回载）；写失败回滚。
    final previous = _history;
    _history = [
      for (final item in _history)
        if (!(item.sourceKey == entry.sourceKey && item.songId == entry.songId))
          item,
    ];
    _notify();
    try {
      await _repository.deleteHistoryEntry(entry.sourceKey, entry.songId);
      return const LibraryMutationOutcome.applied(1);
    } catch (e) {
      debugPrint('[Library] 删除历史记录失败: $e');
      if (!_disposed) {
        _history = previous;
        _notify();
      }
      return LibraryMutationOutcome.failed(e);
    }
  }

  Future<LibraryMutationOutcome> clearHistory() async {
    // 乐观清空本地缓存（UI 立即显示空态，不等待变更流回载）；写失败回滚。
    final previous = _history;
    final wasLoaded = _historyLoaded;
    _history = const [];
    _historyLoaded = true;
    _notify();
    try {
      await _repository.clearHistory();
      return const LibraryMutationOutcome.applied();
    } catch (e) {
      debugPrint('[Library] 清空历史失败: $e');
      if (!_disposed) {
        _history = previous;
        _historyLoaded = wasLoaded;
        _notify();
      }
      return LibraryMutationOutcome.failed(e);
    }
  }

  Future<bool> removeTrackFromPlaylist(PlaylistTrack track) async {
    final removed = await _repository.removeTrackFromPlaylist(
      track.playlistId,
      track.sourceKey,
      track.songId,
    );
    return removed > 0;
  }

  /// 换源：列表内原位替换（收藏列表自动走 favorites 变更类型）。
  ///
  /// 位置 / `sortOrder` / `addedAt` 由仓库保留；变更经 [changes] 流
  /// 自动刷新缓存，不在此手动改内存。
  Future<bool> replacePlaylistTrack(
    int playlistId,
    TrackKey oldKey,
    PlaylistTrack replacement,
  ) async {
    final playlist = await _repository.playlistById(playlistId);
    return _repository.replacePlaylistTrack(
      playlistId,
      oldKey,
      replacement,
      favoriteChange: playlist?.isFavorites ?? false,
    );
  }

  /// 换源：播放历史原位替换（仓库保留旧行 `playedAt`）。
  Future<bool> replaceHistoryEntry(
    TrackKey oldKey,
    PlayHistoryEntry replacement,
  ) {
    return _repository.replaceHistoryEntry(oldKey, replacement);
  }

  /// 目标列表是否已包含某曲目（换源重复确认用；缓存优先）。
  ///
  /// 缓存可能略旧：确认放行与否只影响是否弹一次确认框，最终去重由
  /// [replacePlaylistTrack] 的事务兜底。
  Future<bool> playlistContains(int playlistId, TrackKey key) async {
    final cached = _tracksByPlaylist[playlistId];
    final tracks = cached ?? await loadPlaylistTracks(playlistId);
    return tracks.any(
      (track) => track.sourceKey == key.sourceKey && track.songId == key.songId,
    );
  }

  /// 批量移除列表曲目（返回实际移除数）。
  Future<LibraryMutationOutcome> removeTracksFromPlaylist(
    int playlistId,
    List<PlaylistTrack> tracks,
  ) async {
    try {
      final removed = await _repository.removeTracksFromPlaylist(playlistId, [
        for (final track in tracks)
          (sourceKey: track.sourceKey, songId: track.songId),
      ]);
      return removed > 0
          ? LibraryMutationOutcome.applied(removed)
          : const LibraryMutationOutcome.unchanged();
    } catch (e) {
      debugPrint('[Library] 从列表移除曲目失败: $e');
      return LibraryMutationOutcome.failed(e);
    }
  }

  /// 批量复制曲目到目标列表（跳过重复）。
  ///
  /// 写失败在边界收口成 failed：调用方据此提示，不再让异常逃进
  /// `unawaited`；成功时 `changed` 是实际新增数。
  Future<LibraryMutationOutcome> addTracksToPlaylist(
    int playlistId,
    List<PlaylistTrack> tracks,
  ) async {
    if (tracks.isEmpty) return const LibraryMutationOutcome.unchanged();
    final int added;
    try {
      added = await _repository.addTracksToPlaylist(playlistId, tracks);
    } catch (e) {
      debugPrint('[Library] 批量加入列表失败: $e');
      return LibraryMutationOutcome.failed(e);
    }
    return added > 0
        ? LibraryMutationOutcome.applied(added)
        : const LibraryMutationOutcome.unchanged();
  }

  /// 新建列表（收藏页合集弹层 / 「加入列表」弹层使用）。
  Future<int> createPlaylist(String name) => _repository.createPlaylist(name);

  /// 把外部曲目导入同名本地列表（重复导入幂等）。
  ///
  /// 返回 `(playlistId, 本次新增数, 曲目总数)`；曲目为空时不落库。
  Future<({int playlistId, int added, int total})> importTracksAsPlaylist({
    required String name,
    required List<PlaylistTrack> tracks,
  }) async {
    final result = await _repository.importTracks(name, tracks);
    if (result.playlistId > 0 && result.added > 0) {
      await refreshPlaylists(force: true);
    }
    return result;
  }

  /// 批量把列表曲目加入播放历史（最近播放置顶）。
  ///
  /// 只落库：内存顺序按停留期间冻结的口径合并（新条目置前、已有条目不重排），
  /// 播放历史列表下次进入时由 [resortHistoryByRecency] 刷新到最新顺序。
  /// 写失败在边界收口成 failed，调用方据此提示而不是抛出。
  Future<LibraryMutationOutcome> addTracksToHistory(
    List<PlaylistTrack> tracks,
  ) async {
    if (tracks.isEmpty) return const LibraryMutationOutcome.unchanged();
    final now = DateTime.now().millisecondsSinceEpoch;
    var offset = 0;
    final int added;
    try {
      added = await _repository.addHistoryEntries([
        for (final track in tracks)
          PlayHistoryEntry(
            sourceKey: track.sourceKey,
            songId: track.songId,
            title: track.title,
            artist: track.artist,
            album: track.album,
            coverUrl: track.coverUrl,
            durationMs: track.durationMs,
            raw: track.raw,
            playedAt: now + offset++,
          ),
      ]);
    } catch (e) {
      debugPrint('[Library] 批量加入播放历史失败: $e');
      return LibraryMutationOutcome.failed(e);
    }
    return added > 0
        ? LibraryMutationOutcome.applied(added)
        : const LibraryMutationOutcome.unchanged();
  }

  /// 按给定顺序重排列表曲目（`sortOrder` 事务重写）。
  ///
  /// 写失败返回 failed，本地缓存保持原顺序（页面据结果提示，不闪回）。
  Future<LibraryMutationOutcome> reorderPlaylistTracks(
    int playlistId,
    List<PlaylistTrack> ordered,
  ) async {
    try {
      await _repository.reorderPlaylistTracks(playlistId, [
        for (final track in ordered)
          (sourceKey: track.sourceKey, songId: track.songId),
      ]);
    } catch (e) {
      debugPrint('[Library] 重排列表曲目失败: $e');
      return LibraryMutationOutcome.failed(e);
    }
    // 本地缓存按同一顺序立即回写：重排落位后列表不闪回旧序；
    // changes 流的静默重载随后用数据库真实顺序二次校准。
    final cached = _tracksByPlaylist[playlistId];
    if (cached != null && cached.length == ordered.length) {
      _tracksByPlaylist[playlistId] = List.of(ordered);
      _notify();
    }
    return LibraryMutationOutcome.applied(ordered.length);
  }

  /// 批量收藏（跳过已收藏；返回新增数），收藏键缓存同步校准。
  Future<LibraryMutationOutcome> addTracksToFavorites(
      List<PlaylistTrack> tracks) async {
    final int added;
    try {
      added = await _repository.addFavorites(tracks);
    } catch (e) {
      debugPrint('[Library] 批量收藏失败: $e');
      return LibraryMutationOutcome.failed(e);
    }
    if (added > 0) {
      final keys = Set<String>.from(_favoriteKeys);
      for (final track in tracks) {
        keys.add('${track.sourceKey}:${track.songId}');
      }
      _favoriteKeys = keys;
      if (_favoriteKeysAuthoritative) _favoritesLoaded = true;
      _favoritesRevision++;
      _notify();
    }
    return added > 0
        ? LibraryMutationOutcome.applied(added)
        : const LibraryMutationOutcome.unchanged();
  }

  /// 批量取消收藏（返回移除数），收藏键缓存同步校准。
  Future<LibraryMutationOutcome> removeTracksFromFavorites(
      List<TrackKey> keys) async {
    final int removed;
    try {
      removed = await _repository.removeFavorites(keys);
    } catch (e) {
      debugPrint('[Library] 批量取消收藏失败: $e');
      return LibraryMutationOutcome.failed(e);
    }
    if (removed > 0) {
      final dropped = {
        for (final key in keys) '${key.sourceKey}:${key.songId}',
      };
      _favoriteKeys = {
        for (final key in _favoriteKeys)
          if (!dropped.contains(key)) key,
      };
      if (_favoriteKeysAuthoritative) _favoritesLoaded = true;
      _favoritesRevision++;
      _notify();
    }
    return removed > 0
        ? LibraryMutationOutcome.applied(removed)
        : const LibraryMutationOutcome.unchanged();
  }

  /// 批量删除历史记录（乐观更新本地缓存；写失败回滚并返回 failed）。
  Future<LibraryMutationOutcome> deleteHistoryEntries(
    List<PlayHistoryEntry> entries,
  ) async {
    if (entries.isEmpty) return const LibraryMutationOutcome.unchanged();
    final previous = _history;
    final keys = {
      for (final entry in entries) '${entry.sourceKey}:${entry.songId}',
    };
    _history = [
      for (final item in _history)
        if (!keys.contains('${item.sourceKey}:${item.songId}')) item,
    ];
    _notify();
    final int removed;
    try {
      removed = await _repository.deleteHistoryEntries([
        for (final entry in entries)
          (sourceKey: entry.sourceKey, songId: entry.songId),
      ]);
    } catch (e) {
      debugPrint('[Library] 批量删除历史失败: $e');
      if (!_disposed) {
        _history = previous;
        _notify();
      }
      return LibraryMutationOutcome.failed(e);
    }
    return removed > 0
        ? LibraryMutationOutcome.applied(removed)
        : const LibraryMutationOutcome.unchanged();
  }

  /// 删除列表；写失败收口成 failed（合集弹层保留该行并提示）。
  Future<LibraryMutationOutcome> deletePlaylist(int playlistId) async {
    try {
      await _repository.deletePlaylist(playlistId);
      return const LibraryMutationOutcome.applied();
    } catch (e) {
      debugPrint('[Library] 删除列表失败: $e');
      return LibraryMutationOutcome.failed(e);
    }
  }

  /// 重命名列表；写失败收口成 failed（合集弹层保留旧名并提示）。
  Future<LibraryMutationOutcome> renamePlaylist(
    int playlistId,
    String name,
  ) async {
    try {
      await _repository.renamePlaylist(playlistId, name);
      return const LibraryMutationOutcome.applied();
    } catch (e) {
      debugPrint('[Library] 重命名列表失败: $e');
      return LibraryMutationOutcome.failed(e);
    }
  }

  /// 收藏/取消收藏（当前播放曲目 / 搜索结果 / 列表曲目通用入口）。
  Future<bool> toggleFavorite({
    required String sourceKey,
    required String songId,
    required String title,
    String artist = '',
    String album = '',
    String? coverUrl,
    int? durationMs,
    Map<String, dynamic> raw = const {},
  }) {
    var favorite = false;
    return DataPathTrace.async(
      'library.favorite.toggle',
      () async {
        favorite = await _repository.toggleFavorite(
          sourceKey: sourceKey,
          songId: songId,
          title: title,
          artist: artist,
          album: album,
          coverUrl: coverUrl,
          durationMs: durationMs,
          raw: raw,
        );
        // 立即更新本地键集合，UI 无需等待 changes 流的下一次重载。
        final keys = Set<String>.from(_favoriteKeys);
        final key = '$sourceKey:$songId';
        if (favorite) {
          keys.add(key);
        } else {
          keys.remove(key);
        }
        _favoriteKeys = keys;
        if (_favoriteKeysAuthoritative) _favoritesLoaded = true;
        _favoritesRevision++;
        _notify();
        return favorite;
      },
      fields: () => {'favorite': favorite ? 1 : 0},
    );
  }

  /// 收藏/取消收藏领域曲目（播放页/UI 的收藏唯一入口）。
  ///
  /// raw 取链参数由 `Track.payload` 原样提供；UI 不读取 payload。
  Future<bool> toggleFavoriteTrack(Track track) => toggleFavorite(
        sourceKey: track.id.sourceKey,
        songId: track.id.id,
        title: track.title,
        artist: track.artistLabel,
        album: track.album ?? '',
        coverUrl: track.artwork?.uri.toString(),
        durationMs: track.duration?.inMilliseconds,
        raw: Map<String, dynamic>.from(track.payload),
      );

  Future<bool> toggleFavoriteSourceTrack(SourceTrack track) =>
      toggleFavoriteTrack(trackFromSourceTrack(track));

  /// 把音源曲目加入指定列表（发现页/搜索等入口使用；重复加入返回 false）。
  Future<bool> addSourceTrackToPlaylist(int playlistId, SourceTrack track) {
    return _repository.addTrackToPlaylist(
      playlistId,
      playlistTrackOfSourceTrack(track, playlistId: playlistId),
    );
  }

  /// 音源曲目 → 列表项（加入列表 / 写入列表的唯一规范化处）。
  ///
  /// UI 层拿不到 `SourceTrack` 类型（分层约束禁止 widgets import `lib/sources/**`），
  /// 搜索结果等入口经 [playlistTrackFromSearchItem] 走同一实现。
  PlaylistTrack playlistTrackOfSourceTrack(
    SourceTrack track, {
    int playlistId = 0,
  }) =>
      PlaylistTrack(
        playlistId: playlistId,
        sourceKey: track.sourceKey,
        songId: _songIdOfSourceTrack(track),
        title: track.title,
        artist: track.artist,
        album: track.album,
        coverUrl: track.coverUrl,
        durationMs: track.duration?.inMilliseconds,
        raw: track.raw,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      );

  /// 搜索结果项 → 列表项（`_sourceTrack` 无法识别时返回 null，调用方忽略）。
  PlaylistTrack? playlistTrackFromSearchItem(Map<String, dynamic> item) {
    final sourceTrack = item['_sourceTrack'];
    if (sourceTrack is! SourceTrack) return null;
    return playlistTrackOfSourceTrack(sourceTrack);
  }

  /// 搜索结果项收藏切换（item map 由 SearchProvider 生成，含 `_sourceTrack`）。
  /// 无法识别来源曲目时返回 null（调用方忽略）。
  Future<bool?> toggleFavoriteSearchItem(Map<String, dynamic> item) async {
    final sourceTrack = item['_sourceTrack'];
    if (sourceTrack is! SourceTrack) return null;
    return toggleFavoriteSourceTrack(sourceTrack);
  }

  /// 搜索结果项是否已收藏。
  bool isFavoriteSearchItem(Map<String, dynamic> item) {
    final sourceTrack = item['_sourceTrack'];
    if (sourceTrack is! SourceTrack) return false;
    return isFavorite(sourceTrack.sourceKey, _songIdOfSourceTrack(sourceTrack));
  }

  /// 导入 `.lxmc` 收藏夹；失败抛 [LxmcDecodeException]（由 UI 转 l10n 提示）。
  Future<LxmcImportResult> importLxmcBytes(
    Uint8List bytes, {
    String? fileName,
  }) async {
    final result = await _repository.importLxmcBytes(bytes, fileName: fileName);
    await Future.wait([
      refreshHistory(force: true),
      refreshPlaylists(force: true),
      ensureFavoritesLoaded(force: true),
    ]);
    return result;
  }

  SourceTrack _fromHistory(PlayHistoryEntry entry) => sourceTrackFromRaw(
        sourceKey: entry.sourceKey,
        title: entry.title,
        artist: entry.artist,
        album: entry.album,
        coverUrl: entry.coverUrl,
        durationMs: entry.durationMs,
        raw: entry.raw,
      );

  SourceTrack _fromPlaylistTrack(PlaylistTrack track) => sourceTrackFromRaw(
        sourceKey: track.sourceKey,
        title: track.title,
        artist: track.artist,
        album: track.album,
        coverUrl: track.coverUrl,
        durationMs: track.durationMs,
        raw: track.raw,
      );

  /// 把「库内形状」的曲目（sourceKey + 元数据 + raw payload）还原为
  /// [SourceTrack]；播放时按需重新取链。
  ///
  /// 与历史 / 列表共用同一转换（raw 原样 + [withCanonicalId] 补齐规范 id），
  /// 听歌统计页的 Top 曲目 / 当日曲目也走这里。
  ///
  /// `local`（本地下载副本）映射为 `localFile` 来源：自动换源显式跳过该
  /// 来源，且本地条目不提供「换源」入口（UI 按来源过滤）。
  SourceTrack sourceTrackFromRaw({
    required String sourceKey,
    required String title,
    required String artist,
    required String album,
    required String? coverUrl,
    required int? durationMs,
    required Map<String, dynamic> raw,
  }) {
    return SourceTrack(
      sourceKey: sourceKey,
      origin: sourceKey == kLocalSourceKey ? 'localFile' : 'lx',
      title: title,
      artist: artist,
      album: album,
      coverUrl: (coverUrl?.isNotEmpty ?? false) ? coverUrl : null,
      duration: (durationMs != null && durationMs > 0)
          ? Duration(milliseconds: durationMs)
          : null,
      qualities: qualitiesFromRaw(raw),
      // raw 原样（含 qualitys/_qualitys），取链时脚本依赖平台字段；
      // 仅补齐平台规范 id 别名（见 [withCanonicalId]）。
      raw: withCanonicalId(sourceKey: sourceKey, raw: raw),
    );
  }

  /// 与 `SourceTrack.id` / `TrackId.id` 一致的平台 id 提取规则（兜底标题-歌手）。
  static String _songIdOfSourceTrack(SourceTrack track) {
    final key = rawIdOf(track.raw);
    return key.isNotEmpty ? key : '${track.title}-${track.artist}';
  }

  /// 库内条目 → 领域曲目（换源入口用）：raw 原样还原 + 规范 id 补齐，
  /// 供换源弹层做跨源搜索种子；UI 不直接读 raw。
  Track trackFromPlaylistTrack(PlaylistTrack track) => trackFromSourceTrack(
        sourceTrackFromRaw(
          sourceKey: track.sourceKey,
          title: track.title,
          artist: track.artist,
          album: track.album,
          coverUrl: track.coverUrl,
          durationMs: track.durationMs,
          raw: track.raw,
        ),
      );

  /// 播放历史条目 → 领域曲目（同上）。
  Track trackFromHistoryEntry(PlayHistoryEntry entry) => trackFromSourceTrack(
        sourceTrackFromRaw(
          sourceKey: entry.sourceKey,
          title: entry.title,
          artist: entry.artist,
          album: entry.album,
          coverUrl: entry.coverUrl,
          durationMs: entry.durationMs,
          raw: entry.raw,
        ),
      );

  /// dispose 后不再向已销毁的监听器发通知（仓库变更流是异步的，存在竞态）。
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    super.dispose();
  }
}
