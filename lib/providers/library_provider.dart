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
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../app/perf/data_path_trace.dart';
import '../domain/ports/library_store.dart';
import '../data/library/favorite_fact.dart';
import '../data/library_read_model.dart';
import '../data/mapping/track_mapper.dart';
import '../domain/models/download.dart' show kLocalSourceKey;
import '../domain/models/library.dart';
import '../domain/models/playlist_cover_keys.dart';
import '../domain/models/track.dart';
import '../domain/models/play_mode.dart';
import '../sources/raw_track.dart';
import '../sources/source_track.dart';
import 'library_outcome.dart';
import 'library_read_projection.dart';
import 'playback_provider.dart';
import '../utils/snapshot_source.dart';

/// 资料库整表读取的意图：静默校准保持当前数据可见，显式读取可以翻 loading。
typedef _LoadMode = LibraryReadIntent;

/// 资料库对 UI 暴露的不可变快照。
///
/// 字段名沿用旧 `LibraryProvider` 的公开 getter：页面只 `ref.watch` 这里的值，
/// 命令（收藏 / 列表 CRUD / 加载）仍落在 [LibraryProvider] 上，经
/// `libraryControllerProvider` 取实例（ADR-0041「启动期状态对象：快照 + 控制器」）。
///
/// 列表 / 历史只在真值变化时换新引用；[favoriteKeys] 由收藏事实缓存，
/// 因此每次通知重建快照不会重新拷贝整表收藏键。
@immutable
class LibraryState {
  const LibraryState({
    required this.history,
    required this.playlists,
    required this.historyState,
    required this.playlistsState,
    required this.favoritesRevision,
    required this.playlistsRevision,
    required this.favoriteKeys,
  });

  /// 播放历史（最近播放倒序；浏览期间由会话控制冻结顺序）。
  final List<PlayHistoryEntry> history;

  /// 全部列表行（含默认收藏的内部保留行）。
  final List<PlaylistInfo> playlists;

  /// 历史 / 列表的读取阶段（含失败与重试）。
  final LibraryReadState historyState;
  final LibraryReadState playlistsState;

  /// 收藏状态版本（单调递增）。
  final int favoritesRevision;

  /// 列表集合 / 计数版本。
  final int playlistsRevision;

  /// 收藏键快照（`sourceKey:songId` 口径）。
  final Set<String> favoriteKeys;

  /// 自建列表（不含默认收藏的内部保留行）。
  List<PlaylistInfo> get customPlaylists => [
    for (final playlist in playlists)
      if (!playlist.isFavorites) playlist,
  ];

  bool get isHistoryLoading => historyState.isLoading;
  bool get isPlaylistsLoading => playlistsState.isLoading;

  /// 是否已收藏（键口径与仓库 `(sourceKey, songId)` 唯一约束一致）。
  bool isFavorite(String sourceKey, String songId) =>
      favoriteKeys.contains('$sourceKey:$songId');
}

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

class LibraryProvider implements SnapshotSource<LibraryState> {
  LibraryProvider({
    required this._repository,
    required PlaybackProvider playbackProvider,

    /// 资料库读取的超时上限（生产默认 10s；测试可注入更短的值）。
    ///
    /// 为什么需要：数据库连接被长时间占住（Windows 上实测出现过查询迟迟不
    /// 落地）时，收藏页会把「当前列表曲目在途」当成 loading，整页永远转圈。
    /// 超时把「挂住」收敛成可重试的失败态；查询本身没有取消语义，晚到的结果
    /// 不再采用，用户点「重试」即可重新读。
    this._readTimeout = const Duration(seconds: 10),
  }) : _playback = playbackProvider {
    _historyRead = ReadReconciliation(
      initialValue: const [],
      mergeQuiet: (current, fresh) =>
          LibraryHistoryOrder.merge(current: current, fresh: fresh),
      replayWrites: (current, pending) {
        var next = current;
        for (final entry in pending) {
          next = LibraryHistoryOrder.applyEntry(
            next,
            entry,
            limit: kHistoryLimit,
          );
        }
        return next;
      },
      failureState: (value, error) => value.isEmpty
          ? LibraryReadState.failed(error)
          : const LibraryReadState.ready(),
    );
    _playlistsRead = ReadReconciliation(
      initialValue: const [],
      mergeQuiet: (_, fresh) => fresh,
      replayWrites: (current, _) => current,
      failureState: (value, error) => value.isEmpty
          ? LibraryReadState.failed(error)
          : const LibraryReadState.ready(),
    );
    _favorites = FavoriteFact(
      repository: _repository,
      readTimeout: _readTimeout,
    )..changes.addListener(_onFavoriteFactChanged);
    _subscription = _repository.changes.listen(_onRepositoryChanged);
  }

  final LibraryStore _repository;
  final PlaybackProvider _playback;
  StreamSubscription<void>? _subscription;
  final Duration _readTimeout;
  final SnapshotSignal _changes = SnapshotSignal();

  /// 列表曲目浏览缓存最多保留的列表数。
  ///
  /// 4–6 个足够覆盖「切换列表 / 返回」的短路径；再多只是让列表的 raw
  /// payload（脚本取链参数）常驻内存。超过上限按最近访问淘汰。
  static const int kPlaylistTracksCacheLimit = 5;

  /// 播放历史 / 列表清单的读投影。
  ///
  /// 两者都是「整表单值」视图：读取可能被写入或另一次读取竞争，策略分别
  /// 由 merge / replay 参数表达，状态机本身只实现一次。
  late final ReadReconciliation<List<PlayHistoryEntry>, PlayHistoryEntry>
  _historyRead;
  late final ReadReconciliation<List<PlaylistInfo>, Never> _playlistsRead;

  /// 读投影的只读视图缓存：历史最多 500 行，不逐次复制；缓存到下次真值
  /// 换引用为止，保持合集 presenter 用来复用视图的列表身份稳定。
  List<PlayHistoryEntry>? _historyViewSource;
  List<PlayHistoryEntry> _historyView = const [];
  List<PlaylistInfo>? _playlistsViewSource;
  List<PlaylistInfo> _playlistsView = const [];

  /// 收藏事实（键 / 顺序行 / 计数 / 版本的唯一持有者）。
  late final FavoriteFact _favorites;

  /// 列表曲目缓存（LRU）：尾部是最近访问，超出上限时从头部淘汰。
  ///
  /// 每个列表各持一份读投影（值 + 阶段 + 在途 + 错误）；这里只保留 LRU
  /// 顺序。必须是插入有序 Map：每次读取 `remove` 后重新插入来「触碰」条目。
  final LinkedHashMap<int, ReadReconciliation<List<PlaylistTrack>?, Never>>
  _playlistTracksReads =
      LinkedHashMap<int, ReadReconciliation<List<PlaylistTrack>?, Never>>();

  /// 当前正在展示的列表 id：LRU 淘汰时跳过，避免后台写入把用户正看的
  /// 列表挤掉。`playlistTracksView` / `ensurePlaylistTracks` 会更新它。
  int? _activePlaylistId;

  bool _disposed = false;
  bool _favoriteNotifyScheduled = false;
  Future<void>? _pendingReload;

  @override
  Listenable get changes => _changes;

  @override
  LibraryState get state => LibraryState(
    history: history,
    playlists: playlists,
    historyState: _historyRead.state,
    playlistsState: _playlistsRead.state,
    favoritesRevision: _favorites.revision,
    playlistsRevision: _playlistsRevision,
    favoriteKeys: _favorites.keys,
  );

  /// 收藏状态版本（单调递增）：收藏相关订阅方（收藏按钮 / 发现页）据此做
  /// O(1) 的失效判定，不必对每次历史写入都重建。
  int get favoritesRevision => _favorites.revision;

  /// 列表集合 / 计数版本（`customPlaylists` 的失效判定）。
  int _playlistsRevision = 0;
  int get playlistsRevision => _playlistsRevision;

  /// 播放历史（大集合：只读视图复用底层列表，避免每次通知复制整表）。
  List<PlayHistoryEntry> get history {
    final value = _historyRead.value;
    if (!identical(value, _historyViewSource)) {
      _historyViewSource = value;
      _historyView = UnmodifiableListView(value);
    }
    return _historyView;
  }

  /// 列表清单（与 [history] 同口径的只读视图）。
  List<PlaylistInfo> get playlists {
    final value = _playlistsRead.value;
    if (!identical(value, _playlistsViewSource)) {
      _playlistsViewSource = value;
      _playlistsView = UnmodifiableListView(value);
    }
    return _playlistsView;
  }

  /// 自建列表（不含默认收藏的内部保留行）。
  List<PlaylistInfo> get customPlaylists => [
    for (final playlist in _playlistsRead.value)
      if (!playlist.isFavorites) playlist,
  ];

  /// 历史 / 列表的读取阶段（含失败与重试）。
  LibraryReadState get historyState => _historyRead.state;
  LibraryReadState get playlistsState => _playlistsRead.state;

  bool get isHistoryLoading => historyState.isLoading;
  bool get isPlaylistsLoading => playlistsState.isLoading;

  /// 列表曲目读取视图（含 failed 阶段）。
  ///
  /// 每次读取都算一次「最近访问」：合集页每帧都会对当前列表调用这里，
  /// 当前列表因此始终保持为 LRU 最新，不会被别的列表写入挤掉。
  PlaylistTracksView playlistTracksView(int playlistId) {
    _activePlaylistId = playlistId;
    final read = _playlistTracksReads[playlistId];
    final tracks = _touchPlaylistTracks(playlistId);
    final error = read?.error;
    final state = error != null && tracks == null
        ? LibraryReadState.failed(error)
        : (read?.explicitLoading ?? false) || (tracks == null && error == null)
        ? const LibraryReadState.loading()
        : const LibraryReadState.ready();
    return PlaylistTracksView(tracks: tracks, state: state);
  }

  /// 列表曲目的读投影（每个列表一份，值与读取阶段都在投影里）。
  ReadReconciliation<List<PlaylistTrack>?, Never> _playlistTracksRead(
    int playlistId,
  ) {
    return _playlistTracksReads.putIfAbsent(
      playlistId,
      () => ReadReconciliation(
        initialValue: null,
        mergeQuiet: (_, fresh) => fresh,
        replayWrites: (current, _) => current,
        failureState: (value, error) => value == null
            ? LibraryReadState.failed(error)
            : const LibraryReadState.ready(),
        canReadQuietly: (value) => value != null,
      ),
    );
  }

  /// 读取并标记最近使用（未缓存返回 null）。
  ///
  /// 收藏列表的值只来自收藏事实；LRU 只负责「这份列表有没有读过 / 在途 /
  /// 失败」。事实没有行时返回 null，不能退回 LRU 里的旧快照（那可能是
  /// toggle 之前读到的基线）。
  List<PlaylistTrack>? _touchPlaylistTracks(int playlistId) {
    final read = _playlistTracksReads[playlistId];
    if (read == null) return null;
    if (playlistId == _favoritesPlaylistId) {
      if (read.value == null) return null;
      _playlistTracksReads
        ..remove(playlistId)
        ..[playlistId] = read;
      return _favorites.rows;
    }
    if (read.value == null) return read.value;
    _playlistTracksReads
      ..remove(playlistId)
      ..[playlistId] = read;
    return read.value;
  }

  /// 写入缓存并按 LRU 淘汰超限条目。
  ///
  /// [favoriteRowsVersion] 是收藏行读取开始前捕获的事实版本：期间发生过
  /// 切换 / 释放时 [FavoriteFact.adoptRows] 会拒绝这份旧快照。
  void _storePlaylistTracks(
    int playlistId,
    List<PlaylistTrack> tracks, {
    int? favoriteRowsVersion,
  }) {
    final read = _playlistTracksRead(playlistId);
    if (playlistId == _favoritesPlaylistId) {
      _favorites.adoptRows(
        tracks,
        version: favoriteRowsVersion ?? _favorites.rowsVersion,
      );
      final favoriteRows = _favorites.rows;
      if (favoriteRows == null) {
        // 读取期间事实被释放：结果不能留在 LRU 里冒充缓存，页面恢复后
        // 还要能重新 ensure。
        read.invalidate(discardValue: true);
      } else {
        read.seed(favoriteRows);
      }
    } else {
      read.seed(tracks);
    }
    _playlistTracksReads
      ..remove(playlistId)
      ..[playlistId] = read;
    _evictOverflowPlaylistTracks();
  }

  /// 超出上限时从最久未访问开始淘汰；当前展示列表跳过。
  ///
  /// 只统计已有值的条目：失败 / 在途的投影不占 LRU 名额。跳过当前列表时
  /// 把它移到队尾再继续，最多多转一圈（条目数 ≤ 上限 + 1），不会死循环。
  void _evictOverflowPlaylistTracks() {
    while (_cachedPlaylistTracksCount > kPlaylistTracksCacheLimit) {
      int? oldest;
      for (final entry in _playlistTracksReads.entries) {
        if (entry.value.value != null) {
          oldest = entry.key;
          break;
        }
      }
      if (oldest == null) return;
      if (oldest == _activePlaylistId && _cachedPlaylistTracksCount > 1) {
        final read = _playlistTracksReads.remove(oldest)!;
        _playlistTracksReads[oldest] = read;
        continue;
      }
      _playlistTracksReads.remove(oldest);
      if (oldest == _favoritesPlaylistId) _favorites.releaseRows();
    }
  }

  int get _cachedPlaylistTracksCount =>
      _playlistTracksReads.values.where((read) => read.value != null).length;

  /// 列表曲目读取的唯一实现：读投影负责代际、在途与失败阶段，这里只做
  /// 缓存写入 / LRU / 通知。
  ///
  /// [mode] quiet 只重载已缓存列表、不翻转 loading；explicit 占 loading 并
  /// 在失败时返回旧缓存（没有则为空）。返回本次读到的曲目；过期结果只交给
  /// 显式等待方，不写回缓存。
  Future<List<PlaylistTrack>> _loadPlaylistTracks(
    int playlistId, {
    required _LoadMode mode,
    ReadReconciliation<List<PlaylistTrack>?, Never>? read,
  }) async {
    final projection = read ?? _playlistTracksRead(playlistId);
    final favoriteRowsVersion = playlistId == _favoritesPlaylistId
        ? _favorites.rowsVersion
        : null;
    final result = await projection.load(
      intent: mode,
      fetch: () =>
          _repository.listPlaylistTracks(playlistId).timeout(_readTimeout),
    );
    if (result.failed) {
      debugPrint('[Library] 加载列表曲目失败: ${result.error}');
    }
    final value = result.value;
    if (result.accepted && value != null) {
      _storePlaylistTracks(
        playlistId,
        value,
        favoriteRowsVersion: favoriteRowsVersion,
      );
    }
    if (mode == _LoadMode.explicit || result.accepted) {
      _notify();
    }
    // quiet 读取在「列表还没有缓存值」时会被读投影直接跳过（canReadQuietly），
    // 返回没有值也没有错误的结果；这里必须按「本次没有新数据」处理，不能
    // 假定成功就一定有 value。
    if (value != null) return value;
    return mode == _LoadMode.explicit
        ? _touchPlaylistTracks(playlistId) ?? const []
        : const [];
  }

  /// 请求加载列表曲目（未缓存且未在加载中时发起；可在 build 内调用）。
  ///
  /// [force] 由「加载失败后重试」使用：丢掉旧缓存重新查询。
  void ensurePlaylistTracks(int playlistId, {bool force = false}) {
    _activePlaylistId = playlistId;
    final read = _playlistTracksRead(playlistId);
    if (!force && read.value != null) {
      _touchPlaylistTracks(playlistId);
      return;
    }
    // 读失败后不自动重试：收藏页每次 build 都会调用这里，如果清掉错误再重读，
    // 一次失败就会变成「失败 → 清错 → loading → 再失败」的每帧死循环（页面
    // 永远转圈）。错误保留到显式重试（force）或仓库变更事件重载。
    if (!force && read.state.isFailed) return;
    // 已有显式请求在途：不并发；force 等它落地后由调用方再次重试。
    if (!read.markExplicitLoading()) return;
    if (force) read.invalidate(discardValue: true, discardPending: true);
    // build 期调用：同步标记 loading（本帧即可显示加载态），通知推迟到
    // 微任务，避免 setState during build。
    unawaited(
      Future<void>.microtask(() async {
        if (_disposed) return;
        _notify();
        await _loadPlaylistTracks(
          playlistId,
          mode: _LoadMode.explicit,
          read: read,
        );
      }),
    );
  }

  /// 释放浏览缓存（托盘隐藏 / 系统低内存时由内存守卫调用）：清列表曲目与读取错误。
  ///
  /// 保留收藏键、列表清单与历史：恢复后收藏图标 / 合集入口立即有正确依据，
  /// 页面重建时经 [ensurePlaylistTracks] 重新读列表曲目。投影代际自增，让
  /// 释放前的在途读取（以及紧随其后的静默重载）落地后作废，不会把旧列表
  /// 又塞回缓存；释放后新发起的读取则正常占位、正常写回。
  void releaseBrowseCaches() {
    for (final read in _playlistTracksReads.values) {
      read.invalidate(
        staleReads: true,
        discardValue: true,
        discardPending: true,
      );
    }
    _playlistTracksReads.clear();
    _activePlaylistId = null;
    _favorites.releaseRows();
    _notify();
  }

  bool isFavorite(String sourceKey, String songId) =>
      _favorites.contains(sourceKey, songId);

  void _onRepositoryChanged(LibraryChange change) {
    if (_disposed) return;
    switch (change) {
      case LibraryHistoryChange(:final entry):
        if (entry != null) {
          // 单条写入直接打补丁：播放 / 收藏都不必等待一次全表查询。
          _applyHistoryEntry(entry);
        } else {
          // 删除 / 清空 / 同步等无法增量表达：保持现有整表重载。
          _historyRead.invalidate();
          _pendingReload = _loadHistory(_LoadMode.quiet);
          unawaited(_pendingReload!);
        }
      case LibraryFavoritesChange(:final toggle):
        if (toggle != null) {
          // 单曲收藏切换：只改事实里的一行与计数，不闪列表、不重查。
          _favorites.applyChange(toggle);
        } else {
          // 批量 / 换源 / 同步 / 导入：收藏键与列表都按库校准。
          _pendingReload = _refreshFavoritesQuietly();
          unawaited(_pendingReload!);
        }
      case LibraryPlaylistTracksChange(:final playlistId):
        // 列表刚被写过：之前的读取失败不再代表当前数据，允许页面下一次重读
        //（否则错误会一直挡住 ensure，数据恢复后仍停在失败态）。
        final tracksRead = _playlistTracksReads[playlistId];
        tracksRead?.clearFailure();
        _pendingReload = Future.wait([
          if (tracksRead != null)
            _loadPlaylistTracks(
              playlistId,
              mode: _LoadMode.quiet,
              read: tracksRead,
            ),
          _loadPlaylists(_LoadMode.quiet),
        ]);
        unawaited(_pendingReload!);
      case LibraryPlaylistsChange():
        // 只改列表行（名称 / 描述 / 分组 / 封面 / 增删），曲目集合没变：
        // 不能按全量失效处理，否则正在浏览的列表会被丢掉曲目读投影、整页
        // 重新进入 loading（换封面后一直转圈）。
        _pendingReload = _reloadPlaylistMetadata();
        unawaited(_pendingReload!);
      case LibraryImportChange():
        _invalidateAll();
    }
  }

  /// 单条历史写入的内存补丁（不查库）。
  ///
  /// 与整表重载同一顺序口径（[LibraryHistoryOrder]）：已有条目原位替换内容
  /// （重播不打断浏览），新条目插到最前；超出上限时裁掉尾部最旧记录。
  void _applyHistoryEntry(PlayHistoryEntry entry) {
    // 查询进行中：结果可能还没包含这次写入，先缓冲，等查询落地后再合并。
    if (_historyRead.bufferWrite(entry)) return;
    // 历史尚未加载过：缓存本来就没有可补的基线，保持 dirty 等首次
    // refreshHistory。这里刻意不回查——首屏可能根本没打开历史页。
    if (!_historyRead.loaded) return;
    _historyRead.patch(
      (current) =>
          LibraryHistoryOrder.applyEntry(current, entry, limit: kHistoryLimit),
    );
    _notify();
  }

  /// 收藏事实变化：把计数投影回列表清单，并合并成一次通知。
  ///
  /// 一次用户切换会先后补键、补行（写入口与仓库事件各一次），两次都是
  /// 事实变化；同步转发会让 UI 在一帧里收到两次重建。通知推迟到微任务并
  /// 去重，保证一次用户动作只通知一次。
  ///
  /// 计数仍放在 `PlaylistInfo.trackCount`（列表行是 UI 模型）；事实是唯一
  /// 真值，这里只做同值跳过，不会反过来再写事实。
  void _onFavoriteFactChanged() {
    if (_disposed) return;
    _syncFavoriteCount();
    if (_favoriteNotifyScheduled) return;
    _favoriteNotifyScheduled = true;
    scheduleMicrotask(() {
      _favoriteNotifyScheduled = false;
      if (_disposed) return;
      _notify();
    });
  }

  void _syncFavoriteCount() {
    final favorites = _favoritesPlaylist;
    if (favorites == null) return;
    final count = _favorites.count;
    if (favorites.trackCount == count) return;
    _playlistsRead.patch(
      (current) => [
        for (final playlist in current)
          if (playlist.id == favorites.id)
            playlist.withTrackCount(count)
          else
            playlist,
      ],
    );
    _playlistsRevision++;
  }

  void _invalidateAll() {
    // 立即失效缓存并通知（同步），后台静默重载；不做事件去重——
    // 去重标志会在微任务未执行时吞掉后续变更，导致 UI 永久陈旧。
    // 静默重载不翻转 loading：后台校准不闪加载态（已有数据保持可见）。
    _historyRead.invalidate();
    _playlistsRead.invalidate();
    // 导入等变化可能新增收藏，旧键集合不再是全量：校准完成前不能再用它
    // 反推计数，也不能让一次 toggle 把它重新标成「已加载」。
    _favorites.invalidate();
    _playlistsRevision++;
    _invalidatePlaylistTracksReads();
    _notify();
    _pendingReload = Future.wait([
      _loadHistory(_LoadMode.quiet),
      _loadPlaylists(_LoadMode.quiet),
      _refreshFavoritesQuietly(),
    ]);
    unawaited(_pendingReload!);
  }

  /// 列表元数据（名称 / 描述 / 分组 / 封面 / 增删）变化：只刷列表清单。
  ///
  /// 这些写入不碰 `playlist_tracks`：照全量失效处理会把当前列表的曲目读
  /// 投影一起丢掉，收藏页随即按「列表曲目加载中」渲染整页 spinner（换封面
  /// 后一直转圈）。历史 / 收藏键也不受影响，不需要跟着重读。
  ///
  /// 被删掉的列表要作废它的曲目读投影：既释放 raw payload，也防止在途读取
  /// 落地后把已删除列表又写回缓存。
  Future<void> _reloadPlaylistMetadata() async {
    await _loadPlaylists(_LoadMode.quiet, notify: false);
    if (_disposed) return;
    // 读取失败且没有任何旧清单时不清理曲目缓存：此时「列表都不见了」是读取
    // 失败造成的假象，按空集合裁剪会把仍然有效的缓存全部丢掉。
    if (_playlistsRead.state.isReady) {
      _dropPlaylistTracksReadsForMissingPlaylists();
    }
    _notify();
  }

  void _dropPlaylistTracksReadsForMissingPlaylists() {
    final active = _activePlaylistId;
    final ids = {for (final playlist in _playlistsRead.value) playlist.id};
    if (active != null && !ids.contains(active)) _activePlaylistId = null;
    _playlistTracksReads.removeWhere((playlistId, read) {
      if (ids.contains(playlistId)) return false;
      // dispose 而不是只 invalidate：ensure 的微任务可能已经捕获了这份投影，
      // 只作废代际的话它会按新代际开一次读取并把结果写回（给已删除列表复活
      // 缓存）；dispose 让该投影上的读取一律不受理。
      read.dispose();
      return true;
    });
  }

  /// 全量失效时清掉列表曲目值，但保留仍在途的投影。
  ///
  /// 只在没有在途读取时直接丢掉条目：若只清值 / 错误、不动 loading 集合，
  /// 在途读取落地后仍会写回，新的 ensure 也不能绕过它重开。投影自己的代际
  /// 不动，让这些读取继续完成（下一次页面访问重新读）。
  void _invalidatePlaylistTracksReads() {
    _playlistTracksReads.removeWhere((_, read) {
      if (!read.reading && !read.explicitLoading) return true;
      read.invalidate(discardValue: true, discardPending: true);
      return false;
    });
    _activePlaylistId = null;
    _favorites.releaseRows();
  }

  /// 历史读取的唯一实现。
  ///
  /// [mode] 决定顺序与加载态：
  /// - quiet：历史变化的后台校准，保持当前列表可见、不翻转 loading；顺序用
  ///   [LibraryHistoryOrder.merge]（**已存在的条目保持当前顺序**，只换数据，
  ///   全新条目插到最前）。为什么冻结顺序：播放历史 / 本地歌曲列表在浏览期间
  ///   不该因重播而即时重排（刚点的歌跳到列表顶部会打断浏览）；要按最新播放
  ///   顺序刷新时，由收藏页在重新进入合集 / 页面重新可见时调用
  ///   [resortHistoryByRecency]。
  /// - explicit：首屏 / 导入后 / 失败重试，直接采用仓库顺序（最近播放倒序），
  ///   并先显示 loading。
  Future<void> _loadHistory(_LoadMode mode) {
    if (mode == _LoadMode.explicit) return _readHistory(mode);
    return DataPathTrace.async(
      'library.history.reload',
      () => _readHistory(mode),
      fields: () => {'rows': _historyRead.value.length},
    );
  }

  Future<void> _readHistory(_LoadMode mode) async {
    final quiet = mode == _LoadMode.quiet;
    // 新一次整表查询覆盖此前的本地写入（它们都已落库）：丢弃旧缓冲，
    // 避免查询后又把随后被删除的条目“复活”。查询期间的新写入会重新入队。
    final result = await _historyRead.load(
      intent: mode,
      fetch: () => _repository.listHistory().timeout(_readTimeout),
      discardPendingOnStart: true,
    );
    if (result.failed) {
      debugPrint('[Library] ${quiet ? '重载' : '加载'}播放历史失败: ${result.error}');
    }
    _notify();
  }

  /// 按最近播放（`playedAt` 倒序）重排内存历史；顺序真变了才通知。
  ///
  /// 由收藏页在重新进入播放历史 / 本地歌曲合集、或页面重新可见时调用：
  /// 停留期间列表顺序冻结（见 [_loadHistory]），只在这一刻刷新。
  void resortHistoryByRecency() {
    final history = _historyRead.value;
    if (history.length < 2) return;
    final ordered = LibraryHistoryOrder.resortByRecency(history);
    var changed = false;
    for (var i = 0; i < ordered.length; i++) {
      if (!identical(ordered[i], history[i])) {
        changed = true;
        break;
      }
    }
    if (!changed) return;
    _historyRead.patch((_) => ordered);
    _notify();
  }

  /// 收藏变化的后台校准：列表保持可见，不翻转 loading。
  ///
  /// 行只在「本来已加载」时校准：托盘释放 / 低内存后收藏页重新 ensure 即可，
  /// 不为一次同步把整表收藏曲目读回内存。
  Future<void> _refreshFavoritesQuietly() => DataPathTrace.async(
    'library.favorites.refresh',
    () async {
      // 本轮先把事实校准完（通知由最后统一发）：列表清单落地后计数才有
      // 新依据，中间通知会让 UI 先闪一帧旧计数。
      await _favorites.reload(readRows: _favorites.rows != null, notify: false);
      if (_disposed) return;
      await _loadPlaylists(_LoadMode.quiet, notify: false);
      _notify();
    },
    fields: () => {
      'favorites': _favorites.count,
      'tracks': _favorites.rows?.length ?? 0,
    },
  );

  /// 列表集合 / 计数读取的唯一实现。
  ///
  /// [mode] 决定加载态：quiet 保持当前列表可见、不翻转 loading（[notify] 为
  /// false 时由调用方在所有状态更新完后统一通知）；explicit 先显示 loading。
  Future<void> _loadPlaylists(_LoadMode mode, {bool notify = true}) async {
    _playlistsRevision++;
    final pending = _playlistsRead.load(
      intent: mode,
      fetch: () => _repository.listPlaylists().timeout(_readTimeout),
    );
    if (mode == _LoadMode.explicit) _notify();
    final result = await pending;
    if (result.failed) {
      debugPrint('[Library] 加载列表失败: ${result.error}');
    }
    // 列表清单是收藏列表 id 与 DB 计数的来源：一次绑定同时完成 id 与计数
    // 校准；都在同一轮通知前完成，避免 UI 闪一下旧计数。
    final favorites = _favoritesPlaylist;
    _favorites.bindPlaylist(
      favorites?.id,
      databaseCount: favorites?.trackCount ?? 0,
    );
    _syncFavoriteCount();
    // 永远给终态：读投影已按「有旧列表 ready / 空列表 failed」收口，
    // 不能因为「曾经成功过」留在 loading（空库导入后刷新失败会让收藏页
    // 永久转圈）。
    if (mode == _LoadMode.explicit || notify) _notify();
  }

  PlaylistInfo? get _favoritesPlaylist {
    for (final playlist in _playlistsRead.value) {
      if (playlist.isFavorites) return playlist;
    }
    return null;
  }

  int? get _favoritesPlaylistId => _favoritesPlaylist?.id;

  /// 仅供测试/调试：最近一次仓库变更触发的重载 Future（完成后为 null 不安全，
  /// 这里保留最近一次，供测试确定性等待）。
  @visibleForTesting
  Future<void>? get pendingReload => _pendingReload;

  /// 显式重载历史（首屏 / 导入后 / 失败重试）：直接采用仓库顺序（最近播放
  /// 倒序），不走停留期间的稳定合并。
  Future<void> refreshHistory({bool force = false}) async {
    if (_historyRead.loaded && !force) return;
    await _loadHistory(_LoadMode.explicit);
  }

  Future<void> refreshPlaylists({bool force = false}) async {
    if (_playlistsRead.loaded && !force) return;
    await _loadPlaylists(_LoadMode.explicit);
  }

  /// 收藏键整表读取（首屏 / 导入后 / 失败重试）。
  ///
  /// 与静默校准共用同一套读取代际与在途切换重放：读取期间用户点了收藏，
  /// 旧快照落地后不会被覆盖（否则数据库已收藏，播放页心形仍是空心）。
  Future<void> ensureFavoritesLoaded({bool force = false}) =>
      _favorites.ensureLoaded(force: force);

  /// 列表曲目：命中缓存直接返回，否则查询并缓存（可等待入口）。
  ///
  /// 失败返回旧缓存（或空列表）并记录 failed 阶段，不向调用方抛异常。
  Future<List<PlaylistTrack>> loadPlaylistTracks(
    int playlistId, {
    bool force = false,
  }) {
    if (!force) {
      final cached = _touchPlaylistTracks(playlistId);
      if (cached != null) return Future.value(cached);
    }
    final read = _playlistTracksRead(playlistId);
    final wasLoading = read.explicitLoading;
    final pending = _loadPlaylistTracks(
      playlistId,
      mode: _LoadMode.explicit,
      read: read,
    );
    if (!wasLoading) _notify();
    return pending;
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
    PlayHistoryEntry entry,
  ) async {
    // 乐观更新本地缓存（列表即时移除，不等待变更流回载）；写失败回滚。
    final previous = _historyRead.value;
    _historyRead.patch(
      (current) => [
        for (final item in current)
          if (!(item.sourceKey == entry.sourceKey &&
              item.songId == entry.songId))
            item,
      ],
    );
    _notify();
    try {
      await _repository.deleteHistoryEntry(entry.sourceKey, entry.songId);
      return const LibraryMutationOutcome.applied(1);
    } catch (e) {
      debugPrint('[Library] 删除历史记录失败: $e');
      if (!_disposed) {
        _historyRead.patch((_) => previous);
        _notify();
      }
      return LibraryMutationOutcome.failed(e);
    }
  }

  Future<LibraryMutationOutcome> clearHistory() async {
    // 乐观清空本地缓存（UI 立即显示空态，不等待变更流回载）；写失败回滚。
    final previous = _historyRead.value;
    final wasLoaded = _historyRead.loaded;
    _historyRead.patch((_) => const [], loaded: true);
    _notify();
    try {
      await _repository.clearHistory();
      return const LibraryMutationOutcome.applied();
    } catch (e) {
      debugPrint('[Library] 清空历史失败: $e');
      if (!_disposed) {
        _historyRead.patch((_) => previous, loaded: wasLoaded);
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
    final cached = _touchPlaylistTracks(playlistId);
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
  ///
  /// 新建列表时，写入返回的行就是本次导入的全量：先直接放进缓存，收藏页
  /// 切到新列表不再依赖一次读库（Windows 上出现过读连接被占住、页面一直
  /// loading 的情况）；真实数据仍由随后的变更加载原地校准。同名复用列表里
  /// 还有旧曲目，不能只拿本次导入的曲目当全量，仍走读库。
  Future<({int playlistId, int added, int total})> importTracksAsPlaylist({
    required String name,
    required List<PlaylistTrack> tracks,
  }) async {
    final result = await _repository.importTracks(name, tracks);
    if (result.playlistId > 0 && result.added > 0) {
      if (result.created) {
        _seedImportedPlaylist(result.playlistId, name, result.rows);
      }
      await refreshPlaylists(force: true);
      // 强制刷新可能失败，也可能被并发旧快照覆盖（列表 / 曲目缓存缺一块）：
      // 页面切过来之前补一次。两次都只填缺失项（见 _seedImportedPlaylist），
      // 第二次是幂等的；保留这个 workaround 是为了 Windows 上读连接被占住
      // 时新列表仍能立刻显示（文档见该方法注释）。
      if (result.created) {
        _seedImportedPlaylist(result.playlistId, name, result.rows);
      }
    }
    return (
      playlistId: result.playlistId,
      added: result.added,
      total: result.total,
    );
  }

  /// 补「本次导入新建的列表」的曲目缓存与列表头（幂等）。
  ///
  /// [rows] 是写路径实际落库的行：`playlistId` / `sortOrder` / `addedAt` 已由
  /// 导入写入分配好，这里只负责放进缓存，不再去重或重排。
  ///
  /// 已有真实数据时不覆盖：曲目缓存优先保留读库结果，列表头只在缺失或
  /// 计数比本次导入少（旧快照 / 刷新失败）时修正。因此重复调用是幂等的。
  void _seedImportedPlaylist(
    int playlistId,
    String name,
    List<PlaylistTrack> rows,
  ) {
    if (_playlistTracksReads[playlistId]?.value == null) {
      _storePlaylistTracks(playlistId, rows);
    }
    final playlists = _playlistsRead.value;
    var index = -1;
    for (var i = 0; i < playlists.length; i++) {
      if (playlists[i].id == playlistId) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      _playlistsRead.patch(
        (current) => [
          PlaylistInfo(
            id: playlistId,
            name: name,
            createdAt: DateTime.now().millisecondsSinceEpoch,
            trackCount: rows.length,
          ),
          ...current,
        ],
      );
      _playlistsRevision++;
    } else if (playlists[index].trackCount < rows.length) {
      _playlistsRead.patch(
        (current) => [
          for (final item in current)
            if (item.id == playlistId)
              item.withTrackCount(rows.length)
            else
              item,
        ],
      );
      _playlistsRevision++;
    }
    _notify();
  }

  /// 批量把列表曲目加入播放历史（最近播放置顶）。
  ///
  /// 只落库：批内 `playedAt` 与顺序由写入侧负责（见
  /// `LibraryWriteEngine.addHistoryTracks`）；内存顺序按停留期间冻结的口径
  /// 合并（新条目置前、已有条目不重排），播放历史列表下次进入时由
  /// [resortHistoryByRecency] 刷新到最新顺序。
  /// 写失败在边界收口成 failed，调用方据此提示而不是抛出。
  Future<LibraryMutationOutcome> addTracksToHistory(
    List<PlaylistTrack> tracks,
  ) async {
    if (tracks.isEmpty) return const LibraryMutationOutcome.unchanged();
    final int added;
    try {
      added = await _repository.addHistoryTracks(tracks);
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
    final cached = _touchPlaylistTracks(playlistId);
    if (cached != null && cached.length == ordered.length) {
      _storePlaylistTracks(playlistId, List.of(ordered));
      _notify();
    }
    return LibraryMutationOutcome.applied(ordered.length);
  }

  /// 批量收藏（跳过已收藏；返回新增数），收藏键缓存同步校准。
  Future<LibraryMutationOutcome> addTracksToFavorites(
    List<PlaylistTrack> tracks,
  ) async {
    final int added;
    try {
      added = await _favorites.addAll(tracks);
    } catch (e) {
      debugPrint('[Library] 批量收藏失败: $e');
      return LibraryMutationOutcome.failed(e);
    }
    return added > 0
        ? LibraryMutationOutcome.applied(added)
        : const LibraryMutationOutcome.unchanged();
  }

  /// 批量取消收藏（返回移除数），收藏键缓存同步校准。
  Future<LibraryMutationOutcome> removeTracksFromFavorites(
    List<TrackKey> keys,
  ) async {
    final int removed;
    try {
      removed = await _favorites.removeAll(keys);
    } catch (e) {
      debugPrint('[Library] 批量取消收藏失败: $e');
      return LibraryMutationOutcome.failed(e);
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
    final previous = _historyRead.value;
    final keys = {
      for (final entry in entries) '${entry.sourceKey}:${entry.songId}',
    };
    _historyRead.patch(
      (current) => [
        for (final item in current)
          if (!keys.contains('${item.sourceKey}:${item.songId}')) item,
      ],
    );
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
        _historyRead.patch((_) => previous);
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

  /// 列表详情（名称 / 描述 / 分组）一次写入；失败保留旧值并提示。
  Future<LibraryMutationOutcome> updatePlaylistDetails(
    int playlistId, {
    required String name,
    required String description,
    required String folder,
  }) async {
    try {
      await _repository.updatePlaylistDetails(
        playlistId,
        name: name,
        description: description,
        folder: folder,
      );
      return const LibraryMutationOutcome.applied();
    } catch (e) {
      debugPrint('[Library] 更新列表详情失败: $e');
      return LibraryMutationOutcome.failed(e);
    }
  }

  /// 列表封面键：先补齐 syncId，再返回稳定的 `playlist:<syncId>`。
  Future<String?> ensurePlaylistCoverKey(int playlistId) async {
    try {
      final syncId = await _repository.ensurePlaylistSyncId(playlistId);
      return playlistCoverKeyForSyncId(syncId);
    } catch (e) {
      debugPrint('[Library] 补齐列表 syncId 失败: $e');
      return null;
    }
  }

  /// 把列表封面指针写回列表行（设置 / 重置封面后调用）。
  Future<LibraryMutationOutcome> setPlaylistCoverKey(
    int playlistId,
    String? coverKey,
  ) async {
    try {
      await _repository.setPlaylistCoverKey(playlistId, coverKey);
      return const LibraryMutationOutcome.applied();
    } catch (e) {
      debugPrint('[Library] 写入列表封面指针失败: $e');
      return LibraryMutationOutcome.failed(e);
    }
  }

  /// 分组重命名扇出；返回受影响列表数。
  Future<int> renamePlaylistFolder(String from, String to) =>
      _repository.renamePlaylistFolder(from, to);

  /// 删除分组（只解除分组）；返回解除分组数。
  Future<int> deletePlaylistFolder(String folder) =>
      _repository.deletePlaylistFolder(folder);

  /// 按曲目键查找本机已知列表行（历史优先，其次库内列表）。
  ///
  /// 播放列表文件导入的 `#MOLIA` 解析唯一入口：只查已知记录，不搜索网络、
  /// 不拿标题猜曲目。
  Future<PlaylistTrack?> findTrackByKey(String sourceKey, String songId) async {
    for (final entry in history) {
      if (entry.sourceKey == sourceKey && entry.songId == songId) {
        return PlaylistTrack.fromHistoryEntry(
          entry,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        );
      }
    }
    return _repository.findPlaylistTrackByKey(sourceKey, songId);
  }

  /// 收藏/取消收藏（当前播放曲目 / 搜索结果 / 列表曲目通用入口）。
  ///
  /// 仓库写失败在边界收口成 failed（带回切换前状态）：调用方据此提示，
  /// 收藏键缓存与计数保持原样，图标不会因一次失败翻转。
  Future<FavoriteToggleOutcome> toggleFavorite({
    required String sourceKey,
    required String songId,
    required String title,
    String artist = '',
    String album = '',
    String? coverUrl,
    int? durationMs,
    Map<String, dynamic> raw = const {},
  }) {
    // 失败结果要带回切换前状态；成功后再更新，供埋点字段读取最终值。
    var favorite = isFavorite(sourceKey, songId);
    return DataPathTrace.async('library.favorite.toggle', () async {
      final bool next;
      try {
        next = await _favorites.toggle(
          sourceKey: sourceKey,
          songId: songId,
          title: title,
          artist: artist,
          album: album,
          coverUrl: coverUrl,
          durationMs: durationMs,
          raw: raw,
        );
      } catch (e) {
        debugPrint('[Library] 切换收藏失败: $e');
        return FavoriteToggleOutcome.failed(favorite, e);
      }
      favorite = next;
      return FavoriteToggleOutcome.success(favorite);
    }, fields: () => {'favorite': favorite ? 1 : 0});
  }

  /// 收藏/取消收藏领域曲目（播放页/UI 的收藏唯一入口）。
  ///
  /// raw 取链参数由 `Track.payload` 原样提供；UI 不读取 payload。
  Future<FavoriteToggleOutcome> toggleFavoriteTrack(Track track) =>
      toggleFavorite(
        sourceKey: track.id.sourceKey,
        songId: track.id.id,
        title: track.title,
        artist: track.artistLabel,
        album: track.album ?? '',
        coverUrl: track.artwork?.uri.toString(),
        durationMs: track.duration?.inMilliseconds,
        raw: Map<String, dynamic>.from(track.payload),
      );

  Future<FavoriteToggleOutcome> toggleFavoriteSourceTrack(SourceTrack track) =>
      toggleFavoriteTrack(trackFromSourceTrack(track));

  /// 把音源曲目加入指定列表（发现页/搜索等入口使用；重复加入返回 false）。
  Future<bool> addSourceTrackToPlaylist(int playlistId, SourceTrack track) {
    return _repository.addTrackToPlaylist(
      playlistId,
      playlistTrackOfSourceTrack(track, playlistId: playlistId),
    );
  }

  /// 音源曲目 → 列表项（加入列表 / 写入列表的唯一规范化处）。
  PlaylistTrack playlistTrackOfSourceTrack(
    SourceTrack track, {
    int playlistId = 0,
  }) => PlaylistTrack(
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
    if (!_disposed) _changes.notify();
  }

  /// 释放内部订阅与读投影；组合根持有实例直到进程退出，测试按需调用。
  void dispose() {
    _disposed = true;
    _historyRead.dispose();
    _playlistsRead.dispose();
    _favorites
      ..changes.removeListener(_onFavoriteFactChanged)
      ..dispose();
    for (final read in _playlistTracksReads.values) {
      read.dispose();
    }
    _playlistTracksReads.clear();
    _subscription?.cancel();
  }
}
