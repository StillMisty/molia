/// 收藏页合集会话：当前合集的身份 / 模式 / 多选 / 加载组合 / 滚动激活的
/// 唯一实现。
///
/// 为什么单独一层：这些状态原先散在 `FavoritesPage` 的 build 里——恢复校准
/// 用 post-frame setState、`ensure*` / `sync` 的调用顺序就是正确性、四个
/// loading 布尔值各自判断、多选按可见行下标保存（播放历史在浏览期间前插会
/// 让选择漂移到别的曲目）。会话把「当前合集」收成一个可单测的值：页面每帧
/// 只交一份输入快照、消费一个 [CollectionSessionView]；恢复一次、校准一次、
/// 合集切换、选择失效与滚动键激活都在这里完成。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/models/download.dart' show DownloadedTrack;
import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../utils/collection_row_query.dart';
import '../utils/collection_selection.dart';
import 'collection_presenter.dart';
import 'library_collections.dart';
import 'library_outcome.dart';
import 'library_provider.dart';
import 'local_songs_collection.dart';

/// 资料库的一帧读取快照。
///
/// 会话只消费值：列表清单、播放历史、两者的读取阶段，以及（给定当前选集时）
/// 该列表的曲目视图。provider 的其余成员不再逐个映射成语义等价的 getter——
/// 接口宽度停在「页面当前帧要显示什么」，而不是「provider 暴露什么」。
class CollectionLibrarySnapshot {
  const CollectionLibrarySnapshot({
    this.playlists = const <PlaylistInfo>[],
    this.history = const <PlayHistoryEntry>[],
    this.playlistsState = const LibraryReadState.loading(),
    this.historyState = const LibraryReadState.loading(),
    this.playlistTracks,
  });

  final List<PlaylistInfo> playlists;
  final List<PlayHistoryEntry> history;

  /// 列表清单 / 历史的读取阶段（failed 时页面给重试态）。
  final LibraryReadState playlistsState;
  final LibraryReadState historyState;

  /// 当前选集列表的曲目视图；未选列表时为 null。
  ///
  /// 加载阶段也在这个值里（未加载成功 = `state.loading`），页面不需要再问
  /// provider「这个 id 到底在不在加载」。
  final PlaylistTracksView? playlistTracks;
}

/// 资料库加载意图：会话只说「要什么」，具体并发 / 去重 / 通知时机留在
/// [LibraryProvider]。
enum CollectionLibraryLoadKind {
  /// 首帧三件事：列表清单、收藏状态、播放历史。
  startup,

  /// 当前选集的列表曲目。
  playlistTracks,

  /// 读取失败后的整页重试（三件事 + 当前列表曲目，全部 force）。
  retry,

  /// 重新进入播放历史 / 本地歌曲：按最近播放重排。
  resortHistory,
}

/// 一条加载意图。
///
/// [force] 只用于失败重试；[playlistId] 只在需要列表曲目的意图上出现。
class CollectionLibraryLoad {
  const CollectionLibraryLoad.startup()
      : kind = CollectionLibraryLoadKind.startup,
        playlistId = null,
        force = false;

  const CollectionLibraryLoad.playlistTracks(int this.playlistId)
      : kind = CollectionLibraryLoadKind.playlistTracks,
        force = false;

  const CollectionLibraryLoad.retry({this.playlistId})
      : kind = CollectionLibraryLoadKind.retry,
        force = true;

  const CollectionLibraryLoad.resortHistory()
      : kind = CollectionLibraryLoadKind.resortHistory,
        playlistId = null,
        force = false;

  final CollectionLibraryLoadKind kind;

  /// 需要读取曲目的列表 id（列表清单类意图为 null）。
  final int? playlistId;

  /// 是否丢弃旧缓存重查（失败重试）。
  final bool force;
}

/// 合集会话读取 / 加载资料库的窄端口。
///
/// 只有两件事加一个转换助手：读一帧快照、发一条加载意图、把历史条目还原成
/// 领域曲目（本地歌曲合集的缓存行判定要用）。`LibraryProvider` 的写入口
/// （收藏 / 列表 CRUD / 播放）不从这里过；测试直接用假实现，不必构造真实
/// provider 与播放器。
abstract interface class CollectionLibrary {
  /// 读取一帧快照。[playlistId] 非空时同时带上该列表的曲目视图。
  CollectionLibrarySnapshot snapshot({int? playlistId});

  /// 请求加载 / 刷新；可在 build 内调用（provider 内部把通知推迟到微任务）。
  void load(CollectionLibraryLoad request);

  /// 历史条目 → 领域曲目。
  Track trackFromHistoryEntry(PlayHistoryEntry entry);
}

/// [CollectionLibrary] 的生产实现：把快照 / 意图映射到 [LibraryProvider]。
class LibraryCollectionReader implements CollectionLibrary {
  LibraryCollectionReader(this._provider);

  final LibraryProvider _provider;

  @override
  CollectionLibrarySnapshot snapshot({int? playlistId}) {
    return CollectionLibrarySnapshot(
      playlists: _provider.playlists,
      history: _provider.history,
      playlistsState: _provider.playlistsState,
      historyState: _provider.historyState,
      playlistTracks:
          playlistId == null ? null : _provider.playlistTracksView(playlistId),
    );
  }

  @override
  void load(CollectionLibraryLoad request) {
    switch (request.kind) {
      case CollectionLibraryLoadKind.startup:
      case CollectionLibraryLoadKind.retry:
        _provider.refreshPlaylists(force: request.force);
        _provider.ensureFavoritesLoaded(force: request.force);
        _provider.refreshHistory(force: request.force);
      case CollectionLibraryLoadKind.playlistTracks:
        break;
      case CollectionLibraryLoadKind.resortHistory:
        _provider.resortHistoryByRecency();
    }
    final playlistId = request.playlistId;
    if (playlistId != null) {
      _provider.ensurePlaylistTracks(playlistId, force: request.force);
    }
  }

  @override
  Track trackFromHistoryEntry(PlayHistoryEntry entry) =>
      _provider.trackFromHistoryEntry(entry);
}

/// 下载能力的一帧快照（本地歌曲合集的输入）。
///
/// 用快照而不是 `DownloadService`：会话与单测都不感知下载服务的实现。
class CollectionDownloads {
  const CollectionDownloads({
    required this.records,
    required this.supported,
    required this.initialized,
  });

  /// 下载 / 导入能力不可用（合集不出现，也不产生缓存行）。
  const CollectionDownloads.unavailable()
      : records = const <DownloadedTrack>[],
        supported = false,
        initialized = true;

  final List<DownloadedTrack> records;
  final bool supported;
  final bool initialized;
}

/// 合集展示名（l10n 由页面传入；会话不依赖 BuildContext）。
class CollectionNames {
  const CollectionNames({
    required this.favorites,
    required this.history,
    required this.localSongs,
  });

  final String favorites;
  final String history;
  final String localSongs;
}

/// 滚动簿记端口：页面持有 ScrollController 与簿记，会话只发意图。
abstract interface class CollectionScrollPort {
  /// 冷启动注入各合集偏移（只覆盖内存值）。
  void restoreOffsets(Map<String, double> offsets);

  /// 落定当前合集键（保存 / 恢复都只作用于它）。
  void activate(String collectionKey);

  /// 内容就绪后调度一次偏移恢复（帧后执行）。
  void restore();

  /// 切换合集前立即落盘当前偏移。
  void flush();
}

/// 一帧的合集输入快照：页面只读一次 provider / 下载 / 缓存版本。
class CollectionSessionInput {
  const CollectionSessionInput({
    required this.library,
    required this.names,
    required this.query,
    this.downloads = const CollectionDownloads.unavailable(),
    this.cacheRevision = -1,
  });

  final CollectionLibrary library;
  final CollectionNames names;

  /// 当前搜索词（由页面输入框持有）。
  final String query;

  final CollectionDownloads downloads;

  /// 音频缓存 revision（清缓存 / LRU 淘汰后变化）。
  final int cacheRevision;
}

/// 合集视图的加载阶段。
enum CollectionViewPhase { loading, ready, failed }

/// 会话每帧交给页面的一个值：视图 + 加载态 + 排序态。
class CollectionSessionView {
  const CollectionSessionView({
    required this.view,
    required this.phase,
    required this.reorderActive,
    required this.searchOpen,
    this.error,
  });

  final CollectionView view;
  final CollectionViewPhase phase;
  final bool reorderActive;
  final bool searchOpen;

  /// 读取失败的原始异常（只用于诊断；UI 展示 l10n 文案 + 重试）。
  final Object? error;

  bool get isLoading => phase == CollectionViewPhase.loading;
  bool get hasFailed => phase == CollectionViewPhase.failed;
}

/// 把「当前合集」的状态机从页面里拿出来：恢复 / 校准 / 模式 / 选择 / 加载
/// 组合 / 滚动激活只在这里发生。
class CollectionSession extends ChangeNotifier {
  CollectionSession({
    LibraryCollections? collections,
    CollectionPresenter? presenter,
    this._scroll,
    CachedAudioTrackIdsLookup? loadCachedAudioTrackIds,
  })  : _collections = collections ?? LibraryCollections(),
        _presenter = presenter ?? CollectionPresenter(),
        _localSongs = LocalSongsCollection(
          loadCachedAudioTrackIds:
              loadCachedAudioTrackIds ?? _noCachedAudioTracks,
        ) {
    _selection.addListener(_forwardChange);
    _localSongs.addListener(_forwardChange);
  }

  final LibraryCollections _collections;
  final CollectionPresenter _presenter;
  final CollectionScrollPort? _scroll;
  final LocalSongsCollection _localSongs;

  /// 多选状态机（选择按行 key 保存，见 [CollectionSelection]）。
  final CollectionSelection _selection = CollectionSelection();

  int _selectedId = LibraryCollections.unset;
  List<String> _collectionOrder = const <String>[];
  CollectionTrackSort _sort = CollectionTrackSort.added;
  bool _searching = false;
  bool _reordering = false;

  /// 冷启动持久化恢复是否已完成（完成前不跑默认合集校准）。
  bool _restored = false;
  bool _restoreStarted = false;

  /// 恢复的选集是否已按首次加载的合集列表校准过（失效选集只回退一次）。
  bool _calibrated = false;

  /// 首帧加载是否已请求（playlists / favorites / history 只自动触发一次）。
  bool _startupRequested = false;

  bool _disposed = false;

  /// 最近一次 sync 的资料库端口：事件意图（切换合集 / 重新可见 / 重试）用它。
  CollectionLibrary? _library;

  /// 最近一次 sync 消费的资料库快照：弹层计数与重试按它重算本地歌曲，
  /// 不需要调用方再交一遍 provider 状态。
  CollectionLibrarySnapshot? _lastSnapshot;

  /// 最近一帧的下载 / 缓存输入（`ensureLocalSongsReady` 未显式给值时的兜底）。
  CollectionDownloads _lastDownloads = const CollectionDownloads.unavailable();
  int _lastCacheRevision = -1;

  /// 当前滚动键与是否已为它调度过恢复（同一合集只恢复一次）。
  String? _scrollKey;
  bool _scrollReady = false;

  /// 最近一次 sync 解析出的列表 id（失败重试用）。
  int? _lastPlaylistId;

  Future<void>? _restoreFuture;

  /// 多选状态机（页面读选中态 / 计数，写操作走本类意图方法）。
  CollectionSelection get selection => _selection;

  bool get selecting => _selection.isSelecting;
  bool get searching => _searching;
  bool get reordering => _reordering;
  CollectionTrackSort get sort => _sort;

  /// 合集自定义顺序（持久化键 `favorites` / `history` / `downloads` /
  /// `playlist:<id>`）。
  List<String> get collectionOrder => _collectionOrder;

  /// 本地歌曲合集当前行数（合集弹层计数与列表行数同源）。
  int get localSongsCount => _localSongs.count;

  /// 冷启动恢复：合集顺序 + 上次选中的合集 + 各合集滚动位置。
  ///
  /// 三者就绪前 [_restored] 为 false，默认合集回退与失效校准都不会执行——
  /// 否则恢复的选集会被默认解析覆盖。幂等；页面在 initState 调一次即可。
  Future<void> start() => _restoreFuture ??= _restore();

  Future<void> _restore() async {
    _restoreStarted = true;
    final order = await _collections.loadOrder();
    final selection = await _collections.loadSelection();
    final offsets = await _collections.loadScrollOffsets();
    if (_disposed) return;
    _collectionOrder = order;
    if (selection != null) _selectedId = selection;
    _scroll?.restoreOffsets(offsets);
    _restored = true;
    _notify();
  }

  /// 每帧调用一次：解析身份、触发加载、组合加载态并投影可见行。
  ///
  /// 可在 build 内调用：内部触发的 provider 通知都推迟到微任务
  /// （`ensurePlaylistTracks` 自带微任务；启动加载也走微任务）。
  CollectionSessionView sync(CollectionSessionInput input) {
    final library = input.library;
    _library = library;
    _lastDownloads = input.downloads;
    _lastCacheRevision = input.cacheRevision;
    _ensureStartupLoads(library);
    if (!_restoreStarted) unawaited(start());

    // 先读不带曲目的一帧：选集身份要由列表清单解析，解析完才知道该读哪个
    // 列表的曲目。两次读取都是同一个同步值，不存在等前一帧的顺序依赖。
    final base = library.snapshot();
    final playlists = base.playlists;
    final favoritesId = LibraryCollections.favoritesPlaylistId(playlists);
    final identity = _identityFor(input, playlists, favoritesId);
    _calibrate(input, identity, base);

    final selectedPlaylistId = identity.playlistId;
    var snapshot = base;
    PlaylistTracksView? tracksView;
    if (selectedPlaylistId != null) {
      library.load(CollectionLibraryLoad.playlistTracks(selectedPlaylistId));
      snapshot = library.snapshot(playlistId: selectedPlaylistId);
      tracksView = snapshot.playlistTracks;
    }
    _lastSnapshot = snapshot;
    _lastPlaylistId = selectedPlaylistId;

    if (identity.isLocalSongs) {
      unawaited(
        _localSongs.sync(
          _localSongsInput(
            snapshot,
            downloads: input.downloads,
            cacheRevision: input.cacheRevision,
          ),
        ),
      );
    }
    final localSongs = identity.isLocalSongs
        ? _localSongs.rows
        : const <CollectionLocalSong>[];
    final tracks = tracksView?.tracks ?? const <PlaylistTrack>[];
    final view = _presenter.viewFor(
      identity: identity,
      tracks: tracks,
      history: snapshot.history,
      localSongs: localSongs,
      query: input.query,
      sort: _sort,
    );

    // 视图落定即校准选择集：被删除 / 被过滤掉的行不再计数，仍在可见列表
    // 里的行（例如历史前插后的旧行）保持选中。
    _selection.retainKeys([for (final row in view.visibleRows) row.key]);

    // 加载组合：首帧列表 / 当前列表曲目 / 历史首载 / 本地歌曲联结，
    // 四个来源合成一个阶段，页面只判断 loading 与否。
    final initialLoading =
        snapshot.playlists.isEmpty && snapshot.playlistsState.isLoading;
    final tracksLoading = !identity.isHistory &&
        !identity.isLocalSongs &&
        selectedPlaylistId != null &&
        (tracksView?.loading ?? false);
    final historyLoading = identity.isHistory &&
        snapshot.history.isEmpty &&
        snapshot.historyState.isLoading;
    final localSongsLoading = identity.isLocalSongs && _localSongs.loading;
    final loading =
        initialLoading || tracksLoading || historyLoading || localSongsLoading;
    final failure = loading
        ? null
        : _readFailure(
            snapshot: snapshot,
            identity: identity,
            selectedPlaylistId: selectedPlaylistId,
            tracksView: tracksView,
          );
    final phase = loading
        ? CollectionViewPhase.loading
        : failure != null
            ? CollectionViewPhase.failed
            : CollectionViewPhase.ready;
    final reorderActive =
        _reordering && view.isCustom && !_searching && view.visibleCount >= 2;

    // 恢复完成前不调度滚动：持久化偏移可能还没到，先恢复会错过它。
    _activateScroll(
      view.collectionKey,
      contentReady: phase == CollectionViewPhase.ready && _restored,
    );

    return CollectionSessionView(
      view: view,
      phase: phase,
      reorderActive: reorderActive,
      searchOpen: _searching,
      error: failure,
    );
  }

  /// 当前合集「没有可显示数据」的读取失败；有旧缓存时仍按 ready 展示
  /// 旧值（provider 的读取阶段已按此口径收口）。
  Object? _readFailure({
    required CollectionLibrarySnapshot snapshot,
    required CollectionIdentity identity,
    required int? selectedPlaylistId,
    required PlaylistTracksView? tracksView,
  }) {
    if (identity.isHistory) {
      return snapshot.history.isEmpty && snapshot.historyState.isFailed
          ? snapshot.historyState.error
          : null;
    }
    if (identity.isLocalSongs) {
      // 本地歌曲以下载 / 导入记录为准，历史缓存行失败不影响列表可用。
      return null;
    }
    // 收藏 / 自建列表都要落库 id 才读得到曲目：取不到说明列表清单本身
    // 没加载成功（或选中的列表已不存在）。
    if (selectedPlaylistId == null) {
      return snapshot.playlistsState.isFailed
          ? snapshot.playlistsState.error
          : null;
    }
    if (tracksView != null && tracksView.failed) return tracksView.state.error;
    if (snapshot.playlists.isEmpty && snapshot.playlistsState.isFailed) {
      return snapshot.playlistsState.error;
    }
    return null;
  }

  /// 合集弹层打开前把缓存行重算到当前输入（计数与列表行数同源）。
  ///
  /// [downloads] / [cacheRevision] 可传当前帧之外的最新快照：弹层从别的合集
  /// 打开时页面不一定因下载记录变化重建，计数仍要按最新记录算。
  ///
  /// 读取来源是会话自己持有的最近一帧快照（[sync] 落下的那份），调用方
  /// 不需要先交一次输入；[downloads] / [cacheRevision] 不给时用同一帧的值。
  Future<void> ensureLocalSongsReady({
    CollectionDownloads? downloads,
    int? cacheRevision,
  }) {
    final library = _library;
    final snapshot = _lastSnapshot;
    if (library == null || snapshot == null) return Future<void>.value();
    return _localSongs.sync(
      _localSongsInput(
        snapshot,
        downloads: downloads ?? _lastDownloads,
        cacheRevision: cacheRevision ?? _lastCacheRevision,
      ),
    );
  }

  /// 读取失败后的重试：合集清单 / 历史 / 当前列表曲目全部按 force 重查，
  /// 本地歌曲联结也按最近一帧快照重跑。成功路径由 provider / local songs 的
  /// 通知驱动页面重建，这里不额外改状态。
  ///
  /// 重试意图只需要端口与上一帧解析出的列表 id；没有快照时本地歌曲联结
  /// 跳过（此时页面也还没渲染过失败态，不构成正确性条件）。
  void retry() {
    final library = _library;
    if (_disposed || library == null) return;
    library.load(CollectionLibraryLoad.retry(playlistId: _lastPlaylistId));
    final snapshot = _lastSnapshot;
    if (snapshot != null) {
      unawaited(
        _localSongs.sync(
          _localSongsInput(
            snapshot,
            downloads: _lastDownloads,
            cacheRevision: _lastCacheRevision,
          ),
        ),
      );
    }
  }

  /// 多选批量写入：成功（含无变化）才清空选择；失败保留选择，交给页面
  /// 提示并把结果原样返回。
  Future<LibraryMutationOutcome> applySelection(
    CollectionView view,
    Future<LibraryMutationOutcome> Function(List<CollectionRow> rows) write,
  ) async {
    final rows = selectedRows(view);
    if (rows.isEmpty) return const LibraryMutationOutcome.unchanged();
    final outcome = await write(rows);
    if (outcome.isSuccess) _selection.clear();
    return outcome;
  }

  /// 切换到指定合集：落盘旧合集滚动位置 → 选集 → 退出搜索/排序编辑态 →
  /// 持久化选择 → 清空多选。返回是否真的切换了（同一合集为 false）。
  bool selectCollection(int id) {
    if (_disposed || _selectedId == id) return false;
    // 切换前先落盘当前合集的滚动位置（控制器即将换内容）。
    _scroll?.flush();
    _selectedId = id;
    _searching = false;
    _reordering = false;
    _selection.clear();
    unawaited(_collections.saveSelection(id));
    // 重新进入播放历史 / 本地歌曲：顺序按最近播放刷新（停留期间冻结，
    // 见 LibraryProvider 的历史合并策略）。
    if (id == LibraryCollections.historySentinel ||
        id == LibraryCollections.downloadsSentinel) {
      _library?.load(const CollectionLibraryLoad.resortHistory());
    }
    _notify();
    return true;
  }

  /// 合集弹层拖动排序落位。
  void reorderCollections(List<String> keys) {
    _collectionOrder = List<String>.of(keys);
    unawaited(_collections.saveOrder(keys));
    _notify();
  }

  /// 滚动偏移落盘（簿记的持久化回调）：与会话共用同一份合集存储。
  Future<void> persistScrollOffsets(Map<String, double> offsets) =>
      _collections.saveScrollOffsets(offsets);

  void openSearch() {
    if (_disposed || _searching) return;
    _searching = true;
    _notify();
  }

  /// 退出搜索：过滤条件清空后可见列表回到全量，区间锚点失效。
  void exitSearch() {
    if (!_searching) return;
    _searching = false;
    _selection.clearAnchor();
    _notify();
  }

  /// 搜索词变化：可见列表改变，锚点失效（选择保留，由 [sync] 校准）。
  void onQueryChanged() => _selection.clearAnchor();

  /// 排序改变可见顺序：锚点失效。
  void setSort(CollectionTrackSort sort) {
    final changed = _sort != sort;
    _sort = sort;
    _selection.clearAnchor();
    if (changed) _notify();
  }

  /// 进入「调整顺序」：退出搜索、回到自然顺序、清空多选。
  void enterReorder() {
    if (_disposed || _reordering) return;
    _searching = false;
    _sort = CollectionTrackSort.added;
    _reordering = true;
    _selection.clear();
    _notify();
  }

  void exitReorder() {
    if (!_reordering) return;
    _reordering = false;
    _notify();
  }

  /// 页面重新可见（壳层切回本页）：刷新历史顺序。
  void onPageVisible() =>
      _library?.load(const CollectionLibraryLoad.resortHistory());

  /// 长按进入多选。
  void selectRow(String key) => _selection.select(key);

  /// 行点击的选择语义：返回 true = 已被多选接管（调用方不点播）。
  bool handleRowTap(
    String key,
    CollectionView view, {
    bool ctrl = false,
    bool shift = false,
  }) {
    if (_selection.applyModifiers(
      key,
      visibleKeys: [for (final row in view.visibleRows) row.key],
      ctrl: ctrl,
      shift: shift,
    )) {
      return true;
    }
    if (_selection.isSelecting) {
      _selection.toggle(key);
      return true;
    }
    return false;
  }

  /// 当前视图内的选中行（可见顺序）。
  List<CollectionRow> selectedRows(CollectionView view) =>
      _selection.selectedFrom(view.visibleRows, keyOf: (row) => row.key);

  /// 全部可见行是否都已选中（表头三态用）。
  bool? allSelected(CollectionView view) =>
      _selection.allSelectedFor([for (final row in view.visibleRows) row.key]);

  /// 一行应有哪些行动作（页面只负责把种类接成具体流程）。
  List<CollectionRowActionSpec> rowActionsFor(
    CollectionRow row,
    CollectionView view,
  ) =>
      _presenter.rowActionsFor(row, view.identity);

  CollectionIdentity _identityFor(
    CollectionSessionInput input,
    List<PlaylistInfo> playlists,
    int? favoritesId,
  ) =>
      _presenter.identityFor(
        selectedId: _selectedId,
        playlists: playlists,
        favoritesId: favoritesId,
        favoritesName: input.names.favorites,
        historyName: input.names.history,
        localSongsName: input.names.localSongs,
      );

  /// 恢复的选集校准：首次合集列表加载完成后，若持久化选集已不存在
  /// （列表被删 / 下载能力不可用）或尚未选择，则采用默认解析结果并落盘。
  ///
  /// 只校准一次——链接导入后新列表尚未进 `playlists` 时不能被误判为失效，
  /// 也不能因为后续列表增删把用户已经切走的选集拉回去。下载能力要等服务
  /// init 完成再判（首帧 supported 恒为 false）。
  void _calibrate(
    CollectionSessionInput input,
    CollectionIdentity identity,
    CollectionLibrarySnapshot snapshot,
  ) {
    if (_calibrated || !_restored) return;
    final playlists = snapshot.playlists;
    if (playlists.isEmpty && snapshot.playlistsState.isLoading) return;
    // 列表清单都没读成功：此时「选中列表不存在」是失败造成的假象，
    // 不能把恢复的选集覆盖成默认值（重试成功后还要按原选集恢复）。
    if (snapshot.playlistsState.isFailed) return;
    if (!input.downloads.initialized) return;
    _calibrated = true;

    final previous = _selectedId;
    final valid = previous == LibraryCollections.unset ||
        previous == LibraryCollections.favoritesSentinel ||
        previous == LibraryCollections.historySentinel ||
        (previous == LibraryCollections.downloadsSentinel &&
            input.downloads.supported) ||
        playlists.any((playlist) => playlist.id == previous);
    if (!valid || previous == LibraryCollections.unset) {
      // identity 已按默认策略解析：本帧就用它，不需要再来一次 post-frame
      // setState（那会让页面先闪一帧错误的合集）。
      _selectedId = identity.selectedId;
      unawaited(_collections.saveSelection(identity.selectedId));
    }
  }

  void _ensureStartupLoads(CollectionLibrary library) {
    if (_startupRequested) return;
    _startupRequested = true;
    // 首次刷新会同步 notify：推迟到微任务，避免在 build 期通知 provider
    // 的监听者（provider 的 refresh* 在第一个 await 前就通知）。
    unawaited(Future<void>.microtask(() {
      if (_disposed) return;
      library.load(const CollectionLibraryLoad.startup());
    }));
  }

  LocalSongsInput _localSongsInput(
    CollectionLibrarySnapshot snapshot, {
    required CollectionDownloads downloads,
    required int cacheRevision,
  }) {
    final history = snapshot.history;
    return LocalSongsInput(
      history: history,
      // 惰性转换：签名只读历史键；真正列举缓存时才需要领域曲目。
      historyTracks: () => [
        for (final entry in history) _library!.trackFromHistoryEntry(entry),
      ],
      downloads: downloads.records,
      supported: downloads.supported,
      initialized: downloads.initialized,
      cacheRevision: cacheRevision,
    );
  }

  /// 合集键 / 恢复时机由会话决定；簿记只负责实际保存与恢复。
  void _activateScroll(String key, {required bool contentReady}) {
    if (_scrollKey != key) {
      _scrollKey = key;
      _scrollReady = false;
      _scroll?.activate(key);
    }
    if (contentReady && !_scrollReady) {
      _scrollReady = true;
      _scroll?.restore();
    }
  }

  void _forwardChange() => _notify();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static Future<Set<TrackId>> _noCachedAudioTracks(List<Track> tracks) async =>
      const <TrackId>{};

  @override
  void dispose() {
    _disposed = true;
    _selection.removeListener(_forwardChange);
    _localSongs.removeListener(_forwardChange);
    _selection.dispose();
    _localSongs.dispose();
    super.dispose();
  }
}
