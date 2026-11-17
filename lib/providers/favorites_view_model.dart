/// 收藏页 ViewModel：合集会话、滚动簿记、设备服务订阅与页面级状态的唯一
/// 持有者（ADR-0031 的 providers 层）。
///
/// 为什么单独一层：收藏页在壳层里常驻挂载，缓存 / 下载记录 / 缓存索引 /
/// 跨页请求都会触发重建；这些订阅与「智能列表展开 / 定位 / 弹层条目」不应
/// 和 UI 控件混在一个 State 里。ViewModel 不持有 BuildContext：文案由调用方
/// 传入 `AppLocalizations`，滚动控制器由页面注入。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../domain/models/download.dart' show DownloadedTrack;
import '../domain/models/library.dart';
import '../domain/models/library_browse.dart';
import '../domain/models/playlist_folders.dart';
import '../domain/models/smart_lists.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../services/cache_service.dart';
import '../services/download/download_records.dart';
import '../services/library/playlist_folder_prefs.dart';
import '../services/local_cache_index_store.dart';
import '../services/track_local_data_service.dart';
import '../utils/collection_row_query.dart';
import '../widgets/scroll_to_top.dart';
import 'smart_list_rows.dart';
import '../widgets/collection_picker.dart';
import '../widgets/collection_scroll_bookkeeping.dart';
import 'collection_io_commands.dart';
import 'collection_presenter.dart';
import 'collection_session.dart';
import 'library_collections.dart';
import 'library_collection_request.dart';
import 'library_outcome.dart';

/// 智能列表展示名（弹层与合集标题共用）。
Map<String, String> smartListNames(AppLocalizations l10n) => {
  SmartListIds.recentlyAdded: l10n.smartRecentlyAdded,
  SmartListIds.recentlyPlayed: l10n.smartRecentlyPlayed,
  SmartListIds.mostPlayed: l10n.smartMostPlayed,
  SmartListIds.neverPlayed: l10n.smartNeverPlayed,
  SmartListIds.localOnly: l10n.smartLocalOnly,
  SmartListIds.downloaded: l10n.smartDownloaded,
  SmartListIds.missingFiles: l10n.smartMissingFiles,
};

IconData smartListIcon(String id) => switch (id) {
  SmartListIds.recentlyAdded => Icons.new_releases_rounded,
  SmartListIds.recentlyPlayed => Icons.history_rounded,
  SmartListIds.mostPlayed => Icons.trending_up_rounded,
  SmartListIds.neverPlayed => Icons.music_off_rounded,
  SmartListIds.localOnly => Icons.folder_special_rounded,
  SmartListIds.downloaded => Icons.download_done_rounded,
  _ => Icons.report_gmailerrorred_rounded,
};

/// 一次「定位当前播放曲目」的解析结果。
enum FavoritesLocateKind { reveal, missing, noTrack }

class FavoritesLocateResult {
  const FavoritesLocateResult(this.kind, {this.index = 0});

  final FavoritesLocateKind kind;

  /// [FavoritesLocateKind.reveal] 时的可见行下标。
  final int index;
}

/// 导入结果映射：页面只负责弹底栏 / 切换合集，文案与目标列表由这里给。
class FavoritesImportResult {
  const FavoritesImportResult({this.playlistId, this.message});

  /// 导入成功后的新列表 id（失败 / 空 / 取消为 null）。
  final int? playlistId;

  /// 已本地化的提示文案；null = 不提示（取消）。
  final String? message;
}

/// 收藏页 ViewModel。
class FavoritesViewModel extends ChangeNotifier {
  FavoritesViewModel({
    required ScrollController Function(String collectionKey) controllerOf,
    PlaylistFolderCollapseController? folderCollapse,
  }) {
    _folderCollapse = folderCollapse ?? PlaylistFolderCollapseController();
    _session = CollectionSession(
      scroll: _ScrollPort(
        restoreOffsetsCallback: (offsets) =>
            _bookkeeping.restoreOffsets(offsets),
        activateCallback: (key) => _bookkeeping.activate(key),
        restoreCallback: () => _bookkeeping.scheduleRestore(),
        flushCallback: () => _bookkeeping.flush(),
      ),
      loadCachedAudioTrackIds: _loadCachedAudioTrackIds,
    );
    _bookkeeping = CollectionScrollBookkeeping(
      controllerOf: controllerOf,
      persist: _session.persistScrollOffsets,
    );
    _session.addListener(_forwardChange);
    _folderCollapse.addListener(_forwardChange);
    unawaited(_session.start());
    unawaited(_folderCollapse.load());
  }

  late final CollectionSession _session;
  late final CollectionScrollBookkeeping _bookkeeping;
  late final PlaylistFolderCollapseController _folderCollapse;

  CacheService? _cacheService;
  TrackLocalDataService? _localDataService;
  LibraryCollectionRequest? _collectionRequest;
  DownloadRecords? _downloadRecords;
  LocalCacheIndexStore? _cacheIndex;

  bool _pageVisible = true;
  bool _locatePending = false;
  bool _disposed = false;

  final Set<String> _expandedSmartVersions = {};
  Map<String, int> _smartVersionCounts = const {};
  String _smartVersionSignature = '';

  CollectionSession get session => _session;
  PlaylistFolderCollapseController get folderCollapse => _folderCollapse;

  bool get selecting => _session.selecting;
  int get selectedCount => _session.selectedCount;
  bool get searching => _session.searching;
  CollectionTrackSort get sort => _session.sort;
  int get selectedId => _session.selectedId;
  List<String> get collectionOrder => _session.collectionOrder;
  int get localSongsCount => _session.localSongsCount;
  bool get locatePending => _locatePending;
  Map<String, int> get smartVersionCounts => _smartVersionCounts;

  /// 本帧的缓存索引快照（本地歌曲合集的输入）。
  CollectionCacheIndex get cacheIndexSnapshot {
    final index = _cacheIndex;
    if (index == null) {
      // 未注册 = 无索引能力：按空且已就绪处理，不阻塞下载 / 导入行。
      return const CollectionCacheIndex();
    }
    return CollectionCacheIndex(
      entries: index.entries,
      initialized: index.initialized,
      revision: index.revision,
    );
  }

  /// 本帧的下载能力快照（本地歌曲合集的输入）。
  CollectionDownloads get downloadsSnapshot {
    final records = _downloadRecords;
    return CollectionDownloads(
      records: records?.downloads ?? const <DownloadedTrack>[],
      supported: records?.supported ?? false,
      // 未注册下载记录 = 能力不可用但已「就绪」：不能永远卡住合集校准。
      initialized: records?.initialized ?? true,
      recordsRevision: records?.revision ?? 0,
    );
  }

  int get cacheRevision => _cacheService?.revision.value ?? -1;

  TrackLocalDataService? get localDataService => _localDataService;

  /// 页面把当前 context 下读到的服务交给 ViewModel：只换引用，订阅在这里。
  void attachServices({
    required CacheService? cacheService,
    required TrackLocalDataService? localDataService,
    required LibraryCollectionRequest? collectionRequest,
    required DownloadRecords? downloadRecords,
    required LocalCacheIndexStore? cacheIndex,
  }) {
    if (_disposed) return;
    _localDataService = localDataService;
    if (!identical(cacheService, _cacheService)) {
      _cacheService?.revision.removeListener(_onServiceChanged);
      _cacheService = cacheService;
      cacheService?.revision.addListener(_onServiceChanged);
    }
    if (!identical(collectionRequest, _collectionRequest)) {
      _collectionRequest?.removeListener(_onCollectionRequest);
      _collectionRequest = collectionRequest;
      collectionRequest?.addListener(_onCollectionRequest);
      _onCollectionRequest();
    }
    if (!identical(downloadRecords, _downloadRecords)) {
      _downloadRecords?.removeListener(_onServiceChanged);
      _downloadRecords = downloadRecords;
      downloadRecords?.addListener(_onServiceChanged);
    }
    if (!identical(cacheIndex, _cacheIndex)) {
      _cacheIndex?.removeListener(_onServiceChanged);
      _cacheIndex = cacheIndex;
      cacheIndex?.addListener(_onServiceChanged);
    }
  }

  /// 壳层页面可见性：重新可见 = 重新进入收藏页，刷新播放历史顺序。
  void setPageVisible(bool visible) {
    if (_disposed) return;
    if (visible && !_pageVisible) _session.onPageVisible();
    _pageVisible = visible;
  }

  CollectionSessionView sync(CollectionSessionInput input) =>
      _session.sync(input);

  void clearSelection() => _session.clearSelection();
  void selectAllVisible(CollectionView view) => _session.selectAllVisible(view);
  void selectRangeTo(CollectionView view, String key) =>
      _session.selectRangeTo(view, key);
  String? get selectionAnchorKey => _session.selectionAnchorKey;
  bool isSelected(String key) => _session.isSelected(key);
  bool? allSelected(CollectionView view) => _session.allSelected(view);
  List<CollectionRow> selectedRows(CollectionView view) =>
      _session.selectedRows(view);
  bool handleRowTap(
    String key,
    CollectionView view, {
    bool ctrl = false,
    bool shift = false,
  }) => _session.handleRowTap(key, view, ctrl: ctrl, shift: shift);
  void selectRow(String key) => _session.selectRow(key);
  void setSort(CollectionTrackSort sort) => _session.setSort(sort);
  void openSearch() => _session.openSearch();
  void exitSearch() => _session.exitSearch();
  void onQueryChanged() => _session.onQueryChanged();
  void enterReorder() => _session.enterReorder();
  void exitReorder() => _session.exitReorder();
  bool selectCollection(int id) => _session.selectCollection(id);
  void reorderCollections(List<String> keys) =>
      _session.reorderCollections(keys);
  List<CollectionRowActionSpec> rowActionsFor(
    CollectionRow row,
    CollectionView view,
  ) => _session.rowActionsFor(row, view);
  Future<LibraryMutationOutcome> applySelection(
    CollectionView view,
    Future<LibraryMutationOutcome> Function(List<CollectionRow> rows) write,
  ) => _session.applySelection(view, write);

  /// 滚动：页面把三个列表控制器都挂到同一个落盘回调上。
  void saveFromScroll() => _bookkeeping.saveFromScroll();

  /// 壳层重复点击「收藏」目的地：当前合集的列表回到顶部。
  void handleReselect() {
    final controller = _bookkeeping.activeController;
    if (controller == null) return;
    animateScrollToTop(controller);
  }

  ScrollController? get activeScrollController => _bookkeeping.activeController;
  Future<void> flushScrollOffsets() async => _bookkeeping.flush();
  Future<void> restoreScrollOffsets(Map<String, double> offsets) async =>
      _bookkeeping.restoreOffsets(offsets);

  /// 智能列表的展示行：重复组只展开一次代表行，版本行按需插入。
  List<CollectionRow> displayRows({
    required CollectionView view,
    required String query,
  }) {
    final signature =
        '${view.identity.smartListId}|$query|${_session.sort.name}';
    if (_smartVersionSignature != signature) {
      _smartVersionSignature = signature;
      _expandedSmartVersions.clear();
    }
    final result = buildSmartListDisplayRows(
      view.visibleRows,
      _expandedSmartVersions,
    );
    _smartVersionCounts = result.versionCounts;
    return result.rows;
  }

  void toggleSmartVersions(CollectionRow row) {
    if (_disposed) return;
    if (!_expandedSmartVersions.remove(row.key)) {
      _expandedSmartVersions.add(row.key);
    }
    notifyListeners();
  }

  /// 壳层长按：挂起一次定位请求（等数据 / 布局就绪后消费）。
  void requestLocate() {
    if (_disposed) return;
    _locatePending = true;
    notifyListeners();
  }

  void clearLocate() => _locatePending = false;

  /// 消费一次定位请求：只在当前可见行里找正在播放的曲目。
  ///
  /// 行身份与 `TrackRow` 的当前曲目判定同源（`TrackId` ↔ `favoriteKey`）。
  FavoritesLocateResult? resolveLocate({
    required List<CollectionRow> rows,
    required TrackId? trackId,
  }) {
    if (!_locatePending) return null;
    _locatePending = false;
    if (trackId == null) {
      return const FavoritesLocateResult(FavoritesLocateKind.noTrack);
    }
    final index = rows.indexWhere(
      (row) =>
          row.favoriteKey.sourceKey == trackId.sourceKey &&
          row.favoriteKey.songId == trackId.id,
    );
    if (index < 0) {
      return const FavoritesLocateResult(FavoritesLocateKind.missing);
    }
    return FavoritesLocateResult(FavoritesLocateKind.reveal, index: index);
  }

  /// 合集条目：收藏 / 历史 / 本地歌曲 / 曲库 / 各列表（顺序 / 选中态）。
  List<CollectionPickerEntry> collectionEntries({
    required AppLocalizations l10n,
    required List<PlaylistInfo> playlists,
    required int? favoritesId,
    required int selected,
    required int historyCount,
    required bool localSongsSupported,
    required LibraryBrowseIndex? browseIndex,
  }) {
    var favoritesCount = 0;
    for (final playlist in playlists) {
      if (playlist.id == favoritesId) {
        favoritesCount = playlist.trackCount;
        break;
      }
    }
    // 固定入口顺序恒定，不参与拖动排序：收藏 → 历史 → 本地歌曲 → 曲库。
    final pinned = <CollectionPickerEntry>[
      CollectionPickerEntry(
        key: LibraryCollections.favoritesOrderKey,
        id: LibraryCollections.favoritesSentinel,
        name: l10n.favoritesPlaylistName,
        icon: Icons.favorite_rounded,
        trackCount: favoritesCount,
        selected: selected == LibraryCollections.favoritesSentinel,
        pinned: true,
      ),
      CollectionPickerEntry(
        key: LibraryCollections.historyOrderKey,
        id: LibraryCollections.historySentinel,
        name: l10n.libraryHistory,
        icon: Icons.history_rounded,
        trackCount: historyCount,
        selected: selected == LibraryCollections.historySentinel,
        pinned: true,
      ),
      if (localSongsSupported)
        CollectionPickerEntry(
          key: LibraryCollections.downloadsOrderKey,
          id: LibraryCollections.downloadsSentinel,
          name: l10n.libraryLocalSongs,
          icon: Icons.library_music_rounded,
          // 计数与列表行数同源：下载 / 导入记录 + 缓存完成索引里命中缓存的
          // 行（弹层打开前会先把缓存行重算到当前输入）。
          trackCount: localSongsCount,
          selected: selected == LibraryCollections.downloadsSentinel,
          pinned: true,
        ),
      CollectionPickerEntry(
        key: LibraryCollections.libraryBrowseOrderKey,
        id: LibraryCollections.libraryBrowseSentinel,
        name: l10n.libraryBrowseTitle,
        icon: Icons.library_books_rounded,
        trackCount: 0,
        selected: selected == LibraryCollections.libraryBrowseSentinel,
        pinned: true,
        supportingText: _browseSummary(l10n, browseIndex),
      ),
    ];

    // 自建列表：只有这一段参与拖动排序；分组投影保持命名分组在前、
    // 未分组在后，组内沿用设备本地顺序。
    final natural = <String>[
      for (final playlist in playlists)
        if (playlist.id != favoritesId) 'playlist:${playlist.id}',
    ];
    final orderedKeys = LibraryCollections.applyOrder(natural, collectionOrder);
    final byKey = <String, CollectionPickerEntry>{
      for (final playlist in playlists)
        if (playlist.id != favoritesId)
          'playlist:${playlist.id}': CollectionPickerEntry(
            key: 'playlist:${playlist.id}',
            id: playlist.id,
            name: playlist.name,
            icon: Icons.queue_music_rounded,
            trackCount: playlist.trackCount,
            selected: selected == playlist.id,
            playlistId: playlist.id,
            folder: normalizePlaylistFolderName(playlist.folder),
          ),
    };
    final playlistEntries = <CollectionPickerEntry>[
      for (final key in orderedKeys)
        if (byKey[key] != null) byKey[key]!,
    ];
    if (!hasNamedPlaylistFolders(playlists)) {
      return [...pinned, ...playlistEntries];
    }
    final groups = groupPlaylistsByFolder(
      [
        for (final entry in playlistEntries)
          playlists.firstWhere((item) => item.id == entry.id),
      ],
      excludePlaylistIds: {?favoritesId},
    );
    return [
      ...pinned,
      for (final group in groups)
        if (group.isUngrouped) ...[
          for (final playlist in group.playlists)
            if (byKey['playlist:${playlist.id}'] != null)
              byKey['playlist:${playlist.id}']!,
        ] else ...[
          CollectionPickerEntry(
            key: 'folder:${group.folder}',
            id: LibraryCollections.unset,
            name: group.folder,
            icon: Icons.folder_rounded,
            trackCount: 0,
            selected: false,
            folder: group.folder,
            isFolderHeader: true,
            folderCollapsed: _folderCollapse.isCollapsed(group.folder),
          ),
          for (final playlist in group.playlists)
            if (byKey['playlist:${playlist.id}'] != null)
              byKey['playlist:${playlist.id}']!,
        ],
    ];
  }

  /// 智能列表条目：分组标题 + 各智能列表（计数来自设备本地投影）。
  List<CollectionPickerEntry> smartPickerEntries({
    required AppLocalizations l10n,
    required int selected,
    required Map<String, List<CollectionRow>> smartRows,
  }) {
    final names = smartListNames(l10n);
    return [
      CollectionPickerEntry(
        key: 'smart:header',
        id: LibraryCollections.unset,
        name: l10n.smartListsSection,
        icon: Icons.auto_awesome_rounded,
        trackCount: 0,
        selected: false,
        isHeader: true,
        isCollapsibleHeader: true,
      ),
      for (final id in SmartListIds.all)
        CollectionPickerEntry(
          key: id,
          id: LibraryCollections.smartSentinelFor(id),
          name: names[id] ?? id,
          icon: smartListIcon(id),
          trackCount: smartRows[id]?.length ?? 0,
          selected: selected == LibraryCollections.smartSentinelFor(id),
          isSmart: true,
        ),
    ];
  }

  /// M3U / M3U8 / PLS 导入结果 → 新列表 + 提示。
  FavoritesImportResult? mapPlaylistImportOutcome(
    CollectionPlaylistImportOutcome outcome,
    AppLocalizations l10n,
  ) => switch (outcome) {
    CollectionPlaylistImportDone(
      :final playlistId,
      :final added,
      :final skipped,
    ) =>
      FavoritesImportResult(
        playlistId: playlistId,
        message: l10n.playlistImportDone(added, skipped),
      ),
    CollectionPlaylistImportEmpty() => FavoritesImportResult(
      message: l10n.playlistImportEmpty,
    ),
    CollectionPlaylistImportFailed() => FavoritesImportResult(
      message: l10n.playlistImportFailed,
    ),
    CollectionPlaylistImportCancelled() => null,
  };

  /// 平台歌单 / 收藏夹链接导入结果 → 新列表 + 提示。
  FavoritesImportResult? mapLinkImportOutcome(
    CollectionLinkImportOutcome outcome,
    AppLocalizations l10n,
  ) => switch (outcome) {
    CollectionLinkImportDone(:final playlistId, :final added) =>
      FavoritesImportResult(
        playlistId: playlistId,
        message: l10n.libraryImportSuccess(added),
      ),
    CollectionLinkImportEmpty() => FavoritesImportResult(
      message: l10n.playlistImportEmpty,
    ),
    CollectionLinkImportAlreadyContains() => FavoritesImportResult(
      message: l10n.playlistAlreadyContains,
    ),
    CollectionLinkImportFailed() => FavoritesImportResult(
      message: l10n.discoverLoadFailed,
    ),
  };

  Future<Set<TrackId>> _loadCachedAudioTrackIds(List<Track> tracks) {
    final service = _localDataService;
    if (service == null) return Future.value(const <TrackId>{});
    return service.cachedAudioTrackIds(tracks);
  }

  void _onCollectionRequest() {
    final id = _collectionRequest?.take();
    if (id == null || _disposed) return;
    selectCollection(LibraryCollections.smartSentinelFor(id));
  }

  void _onServiceChanged() {
    if (!_disposed) notifyListeners();
  }

  void _forwardChange() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cacheService?.revision.removeListener(_onServiceChanged);
    _downloadRecords?.removeListener(_onServiceChanged);
    _cacheIndex?.removeListener(_onServiceChanged);
    _collectionRequest?.removeListener(_onCollectionRequest);
    _folderCollapse
      ..removeListener(_forwardChange)
      ..dispose();
    _session.removeListener(_forwardChange);
    _bookkeeping.dispose();
    _session.dispose();
    super.dispose();
  }
}

String? _browseSummary(AppLocalizations l10n, LibraryBrowseIndex? index) {
  if (index == null || (index.albums.isEmpty && index.artists.isEmpty)) {
    return null;
  }
  return l10n.libraryBrowseSummary(index.albums.length, index.artists.length);
}

/// 会话 → 滚动簿记的适配：控制器与防抖落盘都留在页面，会话只决定合集键
/// 和恢复时机（见 [CollectionScrollPort]）。
class _ScrollPort implements CollectionScrollPort {
  const _ScrollPort({
    required this.restoreOffsetsCallback,
    required this.activateCallback,
    required this.restoreCallback,
    required this.flushCallback,
  });

  final void Function(Map<String, double> offsets) restoreOffsetsCallback;
  final void Function(String collectionKey) activateCallback;
  final VoidCallback restoreCallback;
  final VoidCallback flushCallback;

  @override
  void restoreOffsets(Map<String, double> offsets) =>
      restoreOffsetsCallback(offsets);

  @override
  void activate(String collectionKey) => activateCallback(collectionKey);

  @override
  void restore() => restoreCallback();

  @override
  void flush() => flushCallback();
}
