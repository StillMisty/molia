import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/library.dart';
import '../l10n/app_localizations.dart';
import '../models/play_mode.dart';
import '../providers/discover_provider.dart';
import '../providers/library_collections.dart';
import '../providers/library_provider.dart';
import '../utils/responsive.dart';
import '../widgets/add_to_library.dart';
import '../widgets/add_to_playlist_sheet.dart' show showPlaylistNameDialog;
import '../widgets/app_search_bar.dart';
import '../widgets/lxmc_import.dart' show importLxmcFavoritesFlow;
import '../widgets/swipe_reveal_row.dart';
import '../widgets/track_row.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本页而不注册 delegate，
/// 此时回退到简体中文（与 lxmc_import / 其他页面同一约定）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 「收藏」页：默认收藏（♥）与已导入/自建列表、播放历史的统一管理入口。
///
/// - 标题行即合集切换器（弹层内可新建/重命名/删除列表、拖动排序合集，
///   并提供「导入收藏」：.lxmc 文件 / 五平台歌单链接）；
///   默认落在有曲目的收藏，收藏为空时回退到第一个非空列表；
/// - 曲目行：点击播放；行尾显示歌曲时长；左滑「加入列表 / 移除类操作」
///   （「加入列表」含我的收藏 / 播放历史 / 自建列表）；长按进入多选；
/// - 标题右侧提供播放全部（顺序）/ 随机播放两个图标；搜索按钮展开搜索栏
///   （日常不占用行高），排序与「调整顺序」收在搜索栏的 ⋮ 菜单里；
/// - 自建列表支持「调整顺序」模式：长按拖动曲目落位即持久化；
/// - 播放历史支持单条删除（左滑）与批量删除（多选）。
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key, this.shuffleRandom});

  /// 随机播放起点随机源（测试注入种子；默认系统随机源）。
  final math.Random? shuffleRandom;

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

enum _CollectionSort { added, title, artist }

class _FavoritesPageState extends State<FavoritesPage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// 曲目列表滚动控制器（配合常显滚动条，支持直接拖动定位）。
  final ScrollController _listController = ScrollController();

  /// 多选控制器（索引以当前合集的可见列表为准）。
  final M3ESelectionController _selection = M3ESelectionController();

  int _selectedId = LibraryCollections.unset;
  _CollectionSort _sort = _CollectionSort.added;

  /// 搜索栏是否展开（不展开时完全不占行高）。
  bool _searching = false;

  /// 自建列表的「调整顺序」模式。
  bool _reordering = false;

  /// 合集自定义顺序（持久化键 `favorites` / `history` / `playlist:<id>`）；
  /// 未记录的新列表按自然顺序追加在末尾。
  List<String> _collectionOrder = const [];
  final LibraryCollections _collections = LibraryCollections();

  /// 随机播放起点随机源（测试可注入种子）。
  late final math.Random _shuffleRandom =
      widget.shuffleRandom ?? math.Random();

  /// 播放历史列表滚动控制器（常显滚动条，支持手拖定位）。
  final ScrollController _historyScrollController = ScrollController();

  bool get _selecting => _selection.isSelectionMode;

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelectionChanged);
    unawaited(_loadCollectionOrder());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<LibraryProvider>();
      provider.refreshPlaylists();
      provider.ensureFavoritesLoaded();
      provider.refreshHistory();
    });
  }

  @override
  void dispose() {
    _selection.removeListener(_onSelectionChanged);
    _selection.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _listController.dispose();
    _historyScrollController.dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  // 搜索 / 多选 / 排序模式切换

  void _openSearch() {
    HapticFeedback.lightImpact();
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _exitSearch() {
    _searchFocus.unfocus();
    _searchController.clear();
    if (!_searching) return;
    setState(() {
      _searching = false;
    });
  }

  void _enterSelection(int index) {
    HapticFeedback.lightImpact();
    _selection.select(index);
  }

  void _enterReorder() {
    HapticFeedback.lightImpact();
    _selection.clear();
    _searchFocus.unfocus();
    _searchController.clear();
    setState(() {
      _searching = false;
      _sort = _CollectionSort.added;
      _reordering = true;
    });
  }

  void _exitReorder() {
    if (!_reordering) return;
    setState(() => _reordering = false);
  }

  // 合集解析

  String _displayName(
    AppLocalizations l10n,
    List<PlaylistInfo> playlists,
    int? favoritesId,
    int selected,
  ) {
    if (selected == LibraryCollections.historySentinel) return l10n.libraryHistory;
    if (selected == LibraryCollections.favoritesSentinel) return l10n.favoritesPlaylistName;
    for (final playlist in playlists) {
      if (playlist.id == selected) return playlist.name;
    }
    return l10n.favoritesPlaylistName;
  }

  // 合集顺序与切换弹层

  /// 合集弹层条目：收藏 / 播放历史 / 各列表。按持久化顺序排列，
  /// 未记录的新列表按自然顺序（收藏 → 历史 → 列表）追加在末尾；
  /// 已删除列表的持久化键自动忽略。
  List<_CollectionEntry> _collectionEntries(
    AppLocalizations l10n,
    LibraryProvider provider,
    List<PlaylistInfo> playlists,
    int? favoritesId,
    int selected,
  ) {
    var favoritesCount = 0;
    for (final playlist in playlists) {
      if (playlist.id == favoritesId) {
        favoritesCount = playlist.trackCount;
        break;
      }
    }
    final available = <String, _CollectionEntry>{
      LibraryCollections.favoritesOrderKey: _CollectionEntry(
        key: LibraryCollections.favoritesOrderKey,
        id: LibraryCollections.favoritesSentinel,
        name: l10n.favoritesPlaylistName,
        icon: Icons.favorite_rounded,
        trackCount: favoritesCount,
        selected: selected == LibraryCollections.favoritesSentinel,
      ),
      LibraryCollections.historyOrderKey: _CollectionEntry(
        key: LibraryCollections.historyOrderKey,
        id: LibraryCollections.historySentinel,
        name: l10n.libraryHistory,
        icon: Icons.history_rounded,
        trackCount: provider.history.length,
        selected: selected == LibraryCollections.historySentinel,
      ),
      for (final playlist in playlists)
        if (playlist.id != favoritesId)
          'playlist:${playlist.id}': _CollectionEntry(
            key: 'playlist:${playlist.id}',
            id: playlist.id,
            name: playlist.name,
            icon: Icons.queue_music_rounded,
            trackCount: playlist.trackCount,
            selected: selected == playlist.id,
            playlistId: playlist.id,
          ),
    };
    final natural = <String>[
      LibraryCollections.favoritesOrderKey,
      LibraryCollections.historyOrderKey,
      for (final playlist in playlists)
        if (playlist.id != favoritesId) 'playlist:${playlist.id}',
    ];
    final ordered = <_CollectionEntry>[];
    // 持久化顺序优先，其次自然顺序；模块只返回自然顺序中存在的键
    //（已删除列表的持久化键自动忽略）。
    for (final key in LibraryCollections.applyOrder(natural, _collectionOrder)) {
      final entry = available.remove(key);
      if (entry != null) ordered.add(entry);
    }
    return ordered;
  }

  /// 打开合集切换弹层：点行切换、新建/重命名/删除、导入收藏、
  /// 行尾把手拖动排序。
  Future<void> _showCollectionPicker(
    AppLocalizations l10n,
    List<PlaylistInfo> playlists,
    int? favoritesId,
    int selected,
  ) async {
    final provider = context.read<LibraryProvider>();
    final outcome = await M3EBottomSheet.show<_PickerOutcome>(
      context,
      builder: (_) => _CollectionPickerSheet(
        title: l10n.favoritesSwitchTitle,
        entries: _collectionEntries(
          l10n,
          provider,
          playlists,
          favoritesId,
          selected,
        ),
        onOrderChanged: _onCollectionOrderChanged,
        onDelete: provider.deletePlaylist,
        onCreate: provider.createPlaylist,
        onRename: provider.renamePlaylist,
      ),
    );
    if (outcome == null || !mounted) return;
    if (outcome.importRequested) {
      await _importCollection();
      return;
    }
    final picked = outcome.selectedId;
    if (picked == null) return;
    setState(() {
      _selectedId = picked;
      // 切换合集回到常规浏览态：退出搜索/排序编辑，避免空态困惑。
      _searching = false;
      _reordering = false;
      _searchController.clear();
    });
    _selection.clear();
  }

  void _onCollectionOrderChanged(List<String> keys) {
    if (!mounted) return;
    setState(() => _collectionOrder = List.of(keys));
    unawaited(_collections.saveOrder(keys));
  }

  Future<void> _loadCollectionOrder() async {
    final stored = await _collections.loadOrder();
    if (stored.isEmpty || !mounted) return;
    setState(() => _collectionOrder = stored);
  }

  // 播放操作

  Future<void> _playAll(List<PlaylistTrack> tracks, String name) {
    HapticFeedback.lightImpact();
    return context.read<LibraryProvider>().playPlaylistTracks(
          tracks,
          0,
          contextName: name,
          mode: PlayMode.sequential,
        );
  }

  Future<void> _playShuffled(List<PlaylistTrack> tracks, String name) {
    HapticFeedback.lightImpact();
    return context.read<LibraryProvider>().playPlaylistTracks(
          tracks,
          _randomStart(tracks.length),
          contextName: name,
          mode: PlayMode.shuffle,
        );
  }

  /// 随机播放起点：在可见列表内随机取一首（不再固定第一首）。
  int _randomStart(int count) =>
      count <= 0 ? 0 : _shuffleRandom.nextInt(count);

  Future<void> _playFrom(List<PlaylistTrack> tracks, int index, String name) {
    HapticFeedback.lightImpact();
    return context.read<LibraryProvider>().playPlaylistTracks(
          tracks,
          index,
          contextName: name,
        );
  }

  /// 播放历史（可见顺序即播放队列；[mode] 用于「播放全部/随机」）。
  Future<void> _playHistoryFrom(
    List<PlayHistoryEntry> entries,
    int index,
    String name, {
    PlayMode? mode,
  }) {
    HapticFeedback.lightImpact();
    return context.read<LibraryProvider>().playHistory(
          entries,
          index,
          contextName: name,
          mode: mode,
        );
  }

  /// 历史搜索过滤（title/artist 子串，与列表曲目同一语义）。
  List<PlayHistoryEntry> _filterHistory(List<PlayHistoryEntry> history) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return history;
    return [
      for (final entry in history)
        if (entry.title.toLowerCase().contains(query) ||
            entry.artist.toLowerCase().contains(query))
          entry,
    ];
  }

  /// 拖动排序落位：M3E 宿主给的是「直接移动」语义（曲目落在目标下标）。
  Future<void> _reorderTracks(_CollectionView view, int from, int to) async {
    final playlistId = view.playlistId;
    final tracks = view.visible;
    if (playlistId == null ||
        from == to ||
        from < 0 ||
        to < 0 ||
        from >= tracks.length ||
        to >= tracks.length) {
      return;
    }
    final reordered = List<PlaylistTrack>.of(tracks);
    final moved = reordered.removeAt(from);
    reordered.insert(to, moved);
    HapticFeedback.lightImpact();
    await context
        .read<LibraryProvider>()
        .reorderPlaylistTracks(playlistId, reordered);
  }

  // 单曲管理（左滑 / 多选共用）

  /// 复制曲目/历史到所选目标（我的收藏 / 播放历史 / 自建列表）。
  ///
  /// 历史条目先规范化为 [PlaylistTrack]；选择/写入/反馈统一走
  /// [addTracksToLibraryTarget]（与发现页同一实现）。返回是否真正选择了
  /// 目标（取消为 false）。
  Future<bool> _copyToPlaylist({
    List<PlaylistTrack>? tracks,
    List<PlayHistoryEntry>? entries,
    bool includeFavorites = true,
    bool includeHistory = true,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final normalized = tracks ??
        [
          for (final entry in entries ?? const <PlayHistoryEntry>[])
            PlaylistTrack.fromHistoryEntry(entry, addedAt: now),
        ];
    return addTracksToLibraryTarget(
      context,
      provider: context.read<LibraryProvider>(),
      tracks: normalized,
      includeFavorites: includeFavorites,
      includeHistory: includeHistory,
    );
  }

  /// 合集弹层的「导入收藏」：.lxmc 文件 或 五平台歌单链接。
  Future<void> _importCollection() async {
    final l10n = _l10n(context);
    final discover = context.read<DiscoverProvider?>();
    final choices = <({String value, IconData icon, String label})>[
      (
        value: 'file',
        icon: Icons.folder_open_rounded,
        label: l10n.playlistImportFromFile,
      ),
      if (discover != null)
        (
          value: 'link',
          icon: Icons.link_rounded,
          label: l10n.playlistImportFromLink,
        ),
    ];
    final choice = await M3EBottomSheet.show<String>(
      context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
              child: Text(
                l10n.libraryImportFavorites,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final item in choices)
              M3EListItem(
                leading: Icon(item.icon),
                headline: item.label,
                onTap: () => Navigator.of(sheetContext).pop(item.value),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'file') {
      await importLxmcFavoritesFlow(context);
      return;
    }
    if (discover != null) await _importFromLink(discover);
  }

  /// 五平台歌单链接导入：选平台 + 粘贴链接/ID → 拉取并存入本地列表。
  Future<void> _importFromLink(DiscoverProvider discover) async {
    final l10n = _l10n(context);
    final channels = [
      for (final key in discover.sourceKeys)
        (key: key, name: discover.sourceDisplayName(key)),
    ];
    final input = await M3EDialog.show<_LinkImportInput>(
      context,
      dialog: _LinkImportDialog(channels: channels),
    );
    if (input == null || !mounted) return;
    try {
      final result = await discover.importPlaylistFromLink(
        input.sourceKey,
        input.rawId,
        fallbackName: l10n.playlistImportedName,
      );
      if (!mounted) return;
      if (result.total == 0) {
        M3ESnackbar.show(context, message: l10n.playlistImportEmpty);
        return;
      }
      if (result.added == 0) {
        M3ESnackbar.show(context, message: l10n.playlistAlreadyContains);
        return;
      }
      setState(() => _selectedId = result.playlistId);
      M3ESnackbar.show(
        context,
        message: l10n.libraryImportSuccess(result.added),
      );
    } on DiscoverFailure {
      if (!mounted) return;
      M3ESnackbar.show(context, message: l10n.discoverLoadFailed);
    } catch (_) {
      if (!mounted) return;
      M3ESnackbar.show(context, message: l10n.discoverLoadFailed);
    }
  }

  Future<void> _confirmClearHistory(
    LibraryProvider provider,
    AppLocalizations l10n,
  ) async {
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.historyClear,
        content: Text(l10n.historyClearConfirm),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.historyClear),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await provider.clearHistory();
    }
  }

  // 多选批量操作

  List<PlaylistTrack> _selectedTracks(_CollectionView view) => [
        for (final index in _selection.selectedIndices)
          if (index >= 0 && index < view.visible.length) view.visible[index],
      ];

  List<PlayHistoryEntry> _selectedHistory(_CollectionView view) => [
        for (final index in _selection.selectedIndices)
          if (index >= 0 && index < view.visibleHistory.length)
            view.visibleHistory[index],
      ];

  Future<void> _favoriteSelected(_CollectionView view) async {
    final selected = _selectedTracks(view);
    _selection.clear();
    if (selected.isEmpty) return;
    await context.read<LibraryProvider>().addTracksToFavorites(selected);
  }

  Future<void> _unfavoriteSelectedTracks(_CollectionView view) async {
    final selected = _selectedTracks(view);
    _selection.clear();
    if (selected.isEmpty) return;
    await context.read<LibraryProvider>().removeTracksFromFavorites([
      for (final track in selected)
        (sourceKey: track.sourceKey, songId: track.songId),
    ]);
  }

  Future<void> _removeSelectedFromPlaylist(_CollectionView view) async {
    final playlistId = view.playlistId;
    final selected = _selectedTracks(view);
    _selection.clear();
    if (playlistId == null || selected.isEmpty) return;
    await context
        .read<LibraryProvider>()
        .removeTracksFromPlaylist(playlistId, selected);
  }

  Future<void> _favoriteSelectedHistory(_CollectionView view) async {
    final selected = _selectedHistory(view);
    _selection.clear();
    if (selected.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await context.read<LibraryProvider>().addTracksToFavorites([
      for (final entry in selected)
        PlaylistTrack.fromHistoryEntry(entry, addedAt: now),
    ]);
  }

  Future<void> _unfavoriteSelectedHistory(_CollectionView view) async {
    final selected = _selectedHistory(view);
    _selection.clear();
    if (selected.isEmpty) return;
    await context.read<LibraryProvider>().removeTracksFromFavorites([
      for (final entry in selected)
        (sourceKey: entry.sourceKey, songId: entry.songId),
    ]);
  }

  Future<void> _deleteSelectedHistory(_CollectionView view) async {
    final selected = _selectedHistory(view);
    _selection.clear();
    if (selected.isEmpty) return;
    await context.read<LibraryProvider>().deleteHistoryEntries(selected);
  }

  Future<void> _copySelectionToPlaylist(_CollectionView view) async {
    final tracks = view.isHistory ? null : _selectedTracks(view);
    final entries = view.isHistory ? _selectedHistory(view) : null;
    final copied = await _copyToPlaylist(
      tracks: tracks,
      entries: entries,
      includeFavorites: !view.isFavorites,
      includeHistory: !view.isHistory,
    );
    if (copied && mounted) _selection.clear();
  }

  // 构建

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<LibraryProvider>();
    final l10n = _l10n(context);
    final playlists = provider.playlists;
    final favoritesId = LibraryCollections.favoritesPlaylistId(playlists);
    final selected = LibraryCollections.resolveSelection(
      selected: _selectedId,
      playlists: playlists,
      favoritesId: favoritesId,
    );
    final isHistory = selected == LibraryCollections.historySentinel;
    final isFavorites = selected == LibraryCollections.favoritesSentinel;
    final isCustom = !isHistory && !isFavorites;
    final selectedPlaylistId =
        (isFavorites || isHistory) ? favoritesId : selected;
    final displayName = _displayName(l10n, playlists, favoritesId, selected);

    // 选中合集的曲目视图：未缓存时 ensurePlaylistTracks 触发加载
    // （provider 统一管理 loading），页面不再探测缓存内部。
    if (!isHistory && selectedPlaylistId != null) {
      provider.ensurePlaylistTracks(selectedPlaylistId);
    }
    final tracksView = (isHistory || selectedPlaylistId == null)
        ? null
        : provider.playlistTracksView(selectedPlaylistId);
    final tracks = tracksView?.tracks ?? const <PlaylistTrack>[];
    final visible =
        isHistory ? const <PlaylistTrack>[] : _filterAndSort(tracks);
    final history = provider.history;
    final visibleHistory =
        isHistory ? _filterHistory(history) : const <PlayHistoryEntry>[];
    final hasItems = isHistory ? history.isNotEmpty : tracks.isNotEmpty;
    final isLoading = !isHistory &&
        selectedPlaylistId != null &&
        (tracksView?.loading ?? false);
    // 历史为空且正在加载时补一个加载态，其余情况沿用组合集加载态。
    final isHistoryLoading =
        isHistory && history.isEmpty && provider.isHistoryLoading;
    // 首帧合集列表尚未加载完成：显示加载态，避免空态闪烁。
    final isInitialLoading = playlists.isEmpty && provider.isPlaylistsLoading;

    final view = _CollectionView(
      isHistory: isHistory,
      isFavorites: isFavorites,
      isCustom: isCustom,
      playlistId: isHistory ? null : selectedPlaylistId,
      displayName: displayName,
      tracks: tracks,
      visible: visible,
      visibleHistory: visibleHistory,
      hasItems: hasItems,
    );
    final reorderActive =
        _reordering && view.isCustom && !_searching && view.visible.length >= 2;

    // 首次解析完成后固定合集选择：避免「我的收藏」从无到有时自动跳出
    // 当前正在浏览的列表（例如在自建列表里收藏后跳到收藏）。
    if (_selectedId == LibraryCollections.unset && !isInitialLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _selectedId != LibraryCollections.unset) return;
        setState(() => _selectedId = selected);
      });
    }

    return PopScope(
      canPop: !_selecting && !_searching && !reorderActive,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          _selection.clear();
          return;
        }
        if (reorderActive) {
          _exitReorder();
          return;
        }
        if (_searching) _exitSearch();
      },
      child: ResponsivePageContainer(
        pageType: ResponsivePageType.browse,
        alignment: Alignment.topCenter,
        child: Column(
          children: [
            _selecting
                ? _buildSelectionBar(context, l10n, provider, view)
                : _buildIdleHeader(
                    context,
                    l10n,
                    provider,
                    playlists,
                    favoritesId,
                    selected,
                    view,
                    reorderActive: reorderActive,
                  ),
            Expanded(
              child: isInitialLoading || isLoading || isHistoryLoading
                  ? const Center(child: M3ELoadingIndicator())
                  : _buildBody(
                      context,
                      l10n,
                      provider,
                      view,
                      reorderActive: reorderActive,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<PlaylistTrack> _filterAndSort(List<PlaylistTrack> tracks) {
    final query = _searchController.text.trim().toLowerCase();
    final result = query.isEmpty
        ? List<PlaylistTrack>.of(tracks)
        : tracks
            .where((track) =>
                track.title.toLowerCase().contains(query) ||
                track.artist.toLowerCase().contains(query))
            .toList();
    switch (_sort) {
      case _CollectionSort.added:
        break;
      case _CollectionSort.title:
        result.sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case _CollectionSort.artist:
        result.sort((a, b) {
          final byArtist =
              a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
          if (byArtist != 0) return byArtist;
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });
    }
    return result;
  }

  // 头部（常驻 / 搜索 / 排序模式）

  Widget _buildIdleHeader(
    BuildContext context,
    AppLocalizations l10n,
    LibraryProvider provider,
    List<PlaylistInfo> playlists,
    int? favoritesId,
    int selected,
    _CollectionView view, {
    required bool reorderActive,
  }) {
    if (reorderActive) return _buildReorderHeader(context, l10n, view);
    if (_searching) return _buildSearchHeader(context, l10n, view);
    return _buildTitleRow(
      context,
      l10n,
      playlists,
      favoritesId,
      selected,
      view,
    );
  }

  /// 常驻标题行：合集切换器 + 播放全部 / 随机 + 搜索按钮。
  Widget _buildTitleRow(
    BuildContext context,
    AppLocalizations l10n,
    List<PlaylistInfo> playlists,
    int? favoritesId,
    int selected,
    _CollectionView view,
  ) {
    final theme = Theme.of(context);
    final horizontalPadding =
        context.layoutType(ResponsivePageType.browse).horizontalPadding;
    final canPlay = view.isHistory
        ? view.visibleHistory.isNotEmpty
        : view.visible.isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, 12, horizontalPadding, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                HapticFeedback.lightImpact();
                _showCollectionPicker(l10n, playlists, favoritesId, selected);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Container(
                      width: 5,
                      height: 38,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        view.displayName,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.expand_more_rounded,
                      size: 22,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          M3EIconButton(
            variant: M3EIconButtonVariant.filled,
            tooltip: l10n.playAll,
            icon: const Icon(Icons.play_arrow_rounded),
            onPressed: canPlay ? () => _playAllFor(view) : null,
          ),
          const SizedBox(width: 4),
          M3EIconButton(
            variant: M3EIconButtonVariant.tonal,
            tooltip: l10n.shufflePlay,
            icon: const Icon(Icons.shuffle_rounded),
            onPressed: canPlay ? () => _playShuffledFor(view) : null,
          ),
          const SizedBox(width: 4),
          M3EIconButton(
            variant: M3EIconButtonVariant.standard,
            tooltip: l10n.libraryTabSearch,
            icon: const Icon(Icons.search_rounded),
            onPressed: _openSearch,
          ),
        ],
      ),
    );
  }

  Future<void> _playAllFor(_CollectionView view) => view.isHistory
      ? _playHistoryFrom(
          view.visibleHistory,
          0,
          view.displayName,
          mode: PlayMode.sequential,
        )
      : _playAll(view.visible, view.displayName);

  Future<void> _playShuffledFor(_CollectionView view) => view.isHistory
      ? _playHistoryFrom(
          view.visibleHistory,
          _randomStart(view.visibleHistory.length),
          view.displayName,
          mode: PlayMode.shuffle,
        )
      : _playShuffled(view.visible, view.displayName);

  /// 搜索行：单胶囊布局——返回键、输入框/清除键与 ⋮（排序 / 调整顺序 /
  /// 清空历史）都收在搜索栏内，日常不展开搜索时不占行高。
  Widget _buildSearchHeader(
    BuildContext context,
    AppLocalizations l10n,
    _CollectionView view,
  ) {
    final horizontalPadding =
        context.layoutType(ResponsivePageType.browse).horizontalPadding;
    return Padding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, 12, horizontalPadding, 8),
      child: AppSearchBar(
        controller: _searchController,
        focusNode: _searchFocus,
        hintText: l10n.favoritesSearchHint,
        leading: M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          tooltip: l10n.cancel,
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: _exitSearch,
        ),
        trailing: [
          if (view.hasItems) _buildOverflowMenu(context, l10n, view),
        ],
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  /// 排序模式行：标题 + 提示 + 完成。
  Widget _buildReorderHeader(
    BuildContext context,
    AppLocalizations l10n,
    _CollectionView view,
  ) {
    final theme = Theme.of(context);
    final horizontalPadding =
        context.layoutType(ResponsivePageType.browse).horizontalPadding;
    return Padding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, 12, horizontalPadding, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Container(
                      width: 5,
                      height: 38,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        view.displayName,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              M3EIconButton(
                variant: M3EIconButtonVariant.filled,
                tooltip: l10n.playlistReorderDone,
                icon: const Icon(Icons.done_rounded),
                onPressed: _exitReorder,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 17),
            child: Text(
              l10n.playlistReorderHint,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 搜索行尾菜单：曲目合集为排序（+ 自建列表调整顺序），历史为清空。
  Widget _buildOverflowMenu(
    BuildContext context,
    AppLocalizations l10n,
    _CollectionView view,
  ) {
    return M3EMenu.entries(
      position: M3EMenuAnchorPosition.bottomEnd,
      anchorBuilder: (context, open) => M3EIconButton(
        variant: M3EIconButtonVariant.standard,
        icon: const Icon(Icons.more_vert_rounded),
        tooltip: view.isHistory ? l10n.historyClear : l10n.sortTooltip,
        onPressed: open,
      ),
      onSelected: (value) {
        if (value is _CollectionSort) {
          setState(() => _sort = value);
        } else if (value == 'reorder') {
          _enterReorder();
        } else if (value == 'clearHistory') {
          _confirmClearHistory(context.read<LibraryProvider>(), l10n);
        }
      },
      entries: [
        if (view.isHistory)
          M3EMenuEntry(
            label: l10n.historyClear,
            value: 'clearHistory',
            isDestructive: true,
          )
        else ...[
          for (final sort in _CollectionSort.values)
            M3EMenuEntry(
              label: switch (sort) {
                _CollectionSort.added => l10n.sortDefaultOrder,
                _CollectionSort.title => l10n.sortByTitle,
                _CollectionSort.artist => l10n.sortByArtist,
              },
              value: sort,
              leading: _sort == sort
                  ? const Icon(Icons.check_rounded, size: 20)
                  : null,
            ),
          if (view.isCustom && view.tracks.length >= 2)
            M3EMenuEntry(
              label: l10n.playlistReorder,
              value: 'reorder',
              leading: const Icon(Icons.drag_handle_rounded, size: 20),
            ),
        ],
      ],
    );
  }

  // 多选上下文操作

  List<Widget> _buildSelectionActions(
    BuildContext context,
    AppLocalizations l10n,
    LibraryProvider provider,
    _CollectionView view,
  ) {
    final selected =
        view.isHistory ? _selectedHistory(view) : _selectedTracks(view);
    if (selected.isEmpty) return const [];
    final allFavorited = selected.every((item) => switch (item) {
          PlaylistTrack track =>
            provider.isFavorite(track.sourceKey, track.songId),
          PlayHistoryEntry entry =>
            provider.isFavorite(entry.sourceKey, entry.songId),
          _ => false,
        });
    return [
      M3EIconButton(
        variant: M3EIconButtonVariant.standard,
        icon: const Icon(Icons.playlist_add_rounded),
        tooltip: l10n.addToPlaylist,
        onPressed: () => unawaited(_copySelectionToPlaylist(view)),
      ),
      M3EIconButton(
        variant: M3EIconButtonVariant.standard,
        icon: Icon(
          allFavorited
              ? Icons.heart_broken_rounded
              : Icons.favorite_border_rounded,
        ),
        tooltip: allFavorited ? l10n.favoriteRemove : l10n.favoriteAdd,
        onPressed: () {
          if (allFavorited) {
            unawaited(view.isHistory
                ? _unfavoriteSelectedHistory(view)
                : _unfavoriteSelectedTracks(view));
          } else {
            unawaited(view.isHistory
                ? _favoriteSelectedHistory(view)
                : _favoriteSelected(view));
          }
        },
      ),
      if (view.isCustom)
        M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          icon: const Icon(Icons.playlist_remove_rounded),
          tooltip: l10n.playlistRemoveTrack,
          onPressed: () => unawaited(_removeSelectedFromPlaylist(view)),
        ),
      if (view.isHistory)
        M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          icon: const Icon(Icons.delete_outline_rounded),
          tooltip: l10n.historyDeleteEntry,
          onPressed: () => unawaited(_deleteSelectedHistory(view)),
        ),
    ];
  }

  /// 多选上下文栏（单行紧凑版）：关闭 / 已选计数 / 全选 / 批量操作。
  ///
  /// 自绘而非 M3ESelectionAppBar：后者在页面内会叠加状态栏安全区，且
  /// 「全选」独占一行导致顶栏过高（收藏页顶部已有应用栏，不需要再留安全区）。
  Widget _buildSelectionBar(
    BuildContext context,
    AppLocalizations l10n,
    LibraryProvider provider,
    _CollectionView view,
  ) {
    final m3e = M3ETheme.of(context);
    final selectionTheme = m3e.selectionTheme;
    final foreground = selectionTheme.contextualForeground(m3e.colorScheme);
    final itemCount =
        view.isHistory ? view.visibleHistory.length : view.visible.length;
    final allSelected = _selection.allSelectedFor(itemCount) == true;
    return ColoredBox(
      color: selectionTheme.contextualBackground(m3e.colorScheme),
      child: IconTheme.merge(
        data: IconThemeData(color: foreground),
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              const SizedBox(width: 4),
              M3EIconButton(
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(Icons.close_rounded),
                tooltip: l10n.cancel,
                onPressed: _selection.clear,
              ),
              Expanded(
                child: Text(
                  '${_selection.selectedCount}',
                  style: m3e.typeScale.titleLarge.copyWith(color: foreground),
                ),
              ),
              M3EIconButton(
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(Icons.select_all_rounded),
                tooltip: allSelected ? l10n.deselectAll : l10n.selectAllItems,
                onPressed: () {
                  if (allSelected) {
                    _selection.clear();
                  } else {
                    _selection.selectAll(itemCount);
                  }
                },
              ),
              ..._buildSelectionActions(context, l10n, provider, view),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }

  // 列表

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    LibraryProvider provider,
    _CollectionView view, {
    required bool reorderActive,
  }) {
    if (view.isHistory) {
      return _buildHistoryBody(context, l10n, provider, view);
    }
    if (view.tracks.isEmpty) {
      return _buildEmptyState(context, l10n, view);
    }
    if (view.visible.isEmpty) {
      return Center(
        child: Text(
          l10n.favoritesSearchEmpty,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }
    // 排序模式：ReorderableListView 固定 extent，长按行内任意位置拖动。
    if (reorderActive) {
      return Scrollbar(
        controller: _listController,
        thumbVisibility: true,
        interactive: true,
        child: ReorderableListView.builder(
          scrollController: _listController,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemExtent: TrackRow.extent,
          buildDefaultDragHandles: false,
          itemCount: view.visible.length,
          onReorderItem: (from, to) =>
              unawaited(_reorderTracks(view, from, to)),
          itemBuilder: (context, index) {
            final track = view.visible[index];
            return ReorderableDelayedDragStartListener(
              // 稳定 key：收藏切换后列表原地刷新，不整段重建/丢滚动位置。
              key: ValueKey<String>('${track.sourceKey}:${track.songId}'),
              index: index,
              child: _buildTrackRow(
                context,
                l10n,
                view,
                index,
                reorderActive: true,
              ),
            );
          },
        ),
      );
    }
    return Scrollbar(
      controller: _listController,
      thumbVisibility: true,
      interactive: true,
      child: ListView.builder(
        controller: _listController,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemExtent: TrackRow.extent,
        itemCount: view.visible.length,
        itemBuilder: (context, index) => _buildTrackRow(
          context,
          l10n,
          view,
          index,
          reorderActive: false,
        ),
      ),
    );
  }

  Widget _buildTrackRow(
    BuildContext context,
    AppLocalizations l10n,
    _CollectionView view,
    int index, {
    required bool reorderActive,
  }) {
    final track = view.visible[index];
    final row = TrackRow(
      // 稳定 key：收藏切换后列表原地刷新，不整段重建/丢滚动位置。
      key: ValueKey<String>('${track.sourceKey}:${track.songId}'),
      title: track.title,
      artist: track.artist,
      coverUrl: track.coverUrl,
      trailingText: _durationText(track.durationMs),
      selected: _selection.isSelected(index),
      trailing: reorderActive
          ? Icon(
              Icons.drag_handle_rounded,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            )
          : null,
      onTap: reorderActive
          ? null
          : () {
              if (_selecting) {
                _selection.toggle(index);
              } else {
                _playFrom(view.visible, index, view.displayName);
              }
            },
      onLongPress: reorderActive ? null : () => _enterSelection(index),
    );
    if (reorderActive || _selecting) return row;
    return SwipeRevealRow(
      actions: _trackSwipeActions(context, l10n, view, track),
      child: row,
    );
  }

  /// 毫秒 → `m:ss`；未知/非法时长返回 null（不占行尾）。
  String? _durationText(int? milliseconds) {
    if (milliseconds == null || milliseconds <= 0) return null;
    final duration = Duration(milliseconds: milliseconds);
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '${duration.inMinutes}:$seconds';
  }

  /// 曲目左滑操作：加入列表 + 移除类（按合集取语义）。
  List<M3EListSwipeAction> _trackSwipeActions(
    BuildContext context,
    AppLocalizations l10n,
    _CollectionView view,
    PlaylistTrack track,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return [
      M3EListSwipeAction(
        icon: const Icon(Icons.playlist_add_rounded),
        backgroundColor: scheme.secondaryContainer,
        foregroundColor: scheme.onSecondaryContainer,
        onPressed: () => unawaited(
          _copyToPlaylist(
            tracks: [track],
            includeFavorites: !view.isFavorites,
            includeHistory: !view.isHistory,
          ),
        ),
      ),
      if (view.isCustom && view.playlistId != null)
        M3EListSwipeAction(
          icon: const Icon(Icons.playlist_remove_rounded),
          backgroundColor: scheme.errorContainer,
          foregroundColor: scheme.onErrorContainer,
          onPressed: () => unawaited(
            context.read<LibraryProvider>().removeTracksFromPlaylist(
              view.playlistId!,
              [track],
            ),
          ),
        )
      else if (view.isFavorites)
        M3EListSwipeAction(
          icon: const Icon(Icons.heart_broken_rounded),
          backgroundColor: scheme.errorContainer,
          foregroundColor: scheme.onErrorContainer,
          onPressed: () => unawaited(
            context.read<LibraryProvider>().removeTracksFromFavorites([
              (sourceKey: track.sourceKey, songId: track.songId),
            ]),
          ),
        ),
    ];
  }

  Widget _buildHistoryBody(
    BuildContext context,
    AppLocalizations l10n,
    LibraryProvider provider,
    _CollectionView view,
  ) {
    if (view.visibleHistory.isEmpty) {
      if (provider.history.isNotEmpty) {
        return Center(
          child: Text(
            l10n.favoritesSearchEmpty,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        );
      }
      return _buildEmptyState(context, l10n, view);
    }
    final scheme = Theme.of(context).colorScheme;
    return Scrollbar(
      controller: _historyScrollController,
      thumbVisibility: true,
      interactive: true,
      child: ListView.builder(
        controller: _historyScrollController,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemExtent: TrackRow.extent,
        itemCount: view.visibleHistory.length,
        itemBuilder: (context, index) {
          final entry = view.visibleHistory[index];
          final row = TrackRow(
            // 稳定 key：收藏切换后列表原地刷新，不整段重建/丢滚动位置。
            key: ValueKey<String>('h:${entry.sourceKey}:${entry.songId}'),
            title: entry.title,
            artist: entry.artist,
            coverUrl: entry.coverUrl,
            trailingText: _durationText(entry.durationMs),
            selected: _selection.isSelected(index),
            onTap: () {
              if (_selecting) {
                _selection.toggle(index);
              } else {
                _playHistoryFrom(
                  view.visibleHistory,
                  index,
                  view.displayName,
                );
              }
            },
            onLongPress: () => _enterSelection(index),
          );
          if (_selecting) return row;
          return SwipeRevealRow(
            actions: [
              M3EListSwipeAction(
                icon: const Icon(Icons.playlist_add_rounded),
                backgroundColor: scheme.secondaryContainer,
                foregroundColor: scheme.onSecondaryContainer,
                onPressed: () => unawaited(
                  _copyToPlaylist(
                    entries: [entry],
                    includeHistory: false,
                  ),
                ),
              ),
              M3EListSwipeAction(
                icon: const Icon(Icons.delete_outline_rounded),
                backgroundColor: scheme.errorContainer,
                foregroundColor: scheme.onErrorContainer,
                onPressed: () => unawaited(
                  provider.deleteHistoryEntry(entry),
                ),
              ),
            ],
            child: row,
          );
        },
      ),
    );
  }

  Widget _buildEmptyState(
    BuildContext context,
    AppLocalizations l10n,
    _CollectionView view,
  ) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              view.isHistory
                  ? Icons.history_rounded
                  : view.isFavorites
                      ? Icons.favorite_border_rounded
                      : Icons.queue_music_rounded,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              view.isHistory
                  ? l10n.historyEmpty
                  : view.isFavorites
                      ? l10n.favoritesEmpty
                      : l10n.playlistTracksEmpty,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 当前合集的只读视图（build 计算一次，头部 / 列表 / 多选共用）。
class _CollectionView {
  const _CollectionView({
    required this.isHistory,
    required this.isFavorites,
    required this.isCustom,
    required this.playlistId,
    required this.displayName,
    required this.tracks,
    required this.visible,
    required this.visibleHistory,
    required this.hasItems,
  });

  final bool isHistory;
  final bool isFavorites;
  final bool isCustom;

  /// 实际落库的列表 id（收藏集合为收藏列表 id；历史为 null）。
  final int? playlistId;
  final String displayName;

  /// 全量曲目（历史集合为空）。
  final List<PlaylistTrack> tracks;

  /// 搜索 + 排序后的可见曲目（可见顺序即播放队列顺序）。
  final List<PlaylistTrack> visible;

  /// 搜索过滤后的历史条目。
  final List<PlayHistoryEntry> visibleHistory;

  final bool hasItems;
}

/// 合集弹层条目：收藏 / 播放历史（哨兵）或一个自建列表。
class _CollectionEntry {
  const _CollectionEntry({
    required this.key,
    required this.id,
    required this.name,
    required this.icon,
    required this.trackCount,
    required this.selected,
    this.playlistId,
  });

  /// 顺序持久化键：`favorites` / `history` / `playlist:<id>`。
  final String key;

  /// 弹层选择结果：哨兵值或列表 id。
  final int id;
  final String name;
  final IconData icon;
  final int trackCount;
  final bool selected;

  /// 非空表示自建列表（可重命名/删除）。
  final int? playlistId;

  _CollectionEntry copyWithName(String name) => _CollectionEntry(
        key: key,
        id: id,
        name: name,
        icon: icon,
        trackCount: trackCount,
        selected: selected,
        playlistId: playlistId,
      );
}

/// 合集弹层结果：切换到某合集 / 请求导入收藏。
class _PickerOutcome {
  const _PickerOutcome.select(this.selectedId) : importRequested = false;

  const _PickerOutcome.importRequested()
      : selectedId = null,
        importRequested = true;

  final int? selectedId;
  final bool importRequested;
}

/// 合集切换弹层：点行切换；「新建列表」；「导入收藏」；自建列表行支持
/// 重命名/删除；行尾把手拖动排序（落位即持久化）。
class _CollectionPickerSheet extends StatefulWidget {
  const _CollectionPickerSheet({
    required this.title,
    required this.entries,
    required this.onOrderChanged,
    required this.onDelete,
    required this.onCreate,
    required this.onRename,
  });

  final String title;
  final List<_CollectionEntry> entries;
  final ValueChanged<List<String>> onOrderChanged;
  final Future<void> Function(int playlistId) onDelete;
  final Future<int> Function(String name) onCreate;
  final Future<void> Function(int playlistId, String name) onRename;

  @override
  State<_CollectionPickerSheet> createState() => _CollectionPickerSheetState();
}

class _CollectionPickerSheetState extends State<_CollectionPickerSheet> {
  late final List<_CollectionEntry> _entries = List.of(widget.entries);

  List<String> get _existingNames => [
        for (final entry in _entries)
          if (entry.playlistId != null) entry.name,
      ];

  void _onReorder(int oldIndex, int newIndex) {
    // onReorderItem 已按移除后位置调整 newIndex，直接插入即可。
    setState(() {
      final moved = _entries.removeAt(oldIndex);
      _entries.insert(newIndex, moved);
    });
    widget.onOrderChanged([for (final entry in _entries) entry.key]);
  }

  Future<void> _createPlaylist() async {
    final l10n = _l10n(context);
    final name = await showPlaylistNameDialog(
      context,
      title: l10n.playlistCreate,
      confirmLabel: l10n.playlistCreateConfirm,
      existingNames: _existingNames,
    );
    if (name == null || !mounted) return;
    final id = await widget.onCreate(name);
    if (!mounted) return;
    // 新建后直接切换到新列表，便于立即添加曲目。
    Navigator.of(context).pop(_PickerOutcome.select(id));
  }

  Future<void> _rename(_CollectionEntry entry) async {
    final l10n = _l10n(context);
    final name = await showPlaylistNameDialog(
      context,
      title: l10n.playlistRename,
      confirmLabel: l10n.saveChanges,
      existingNames: _existingNames,
      initialValue: entry.name,
    );
    if (name == null || !mounted || name == entry.name) return;
    await widget.onRename(entry.playlistId!, name);
    if (!mounted) return;
    setState(() {
      final index = _entries.indexWhere((item) => item.key == entry.key);
      if (index >= 0) _entries[index] = _entries[index].copyWithName(name);
    });
  }

  Future<void> _confirmDelete(
    BuildContext context,
    _CollectionEntry entry,
  ) async {
    final l10n = _l10n(context);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.playlistDelete,
        content: Text(l10n.playlistDeleteConfirm(entry.name)),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    HapticFeedback.lightImpact();
    await widget.onDelete(entry.playlistId!);
    if (!mounted) return;
    setState(() => _entries.removeWhere((item) => item.key == entry.key));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            child: Text(widget.title, style: theme.textTheme.titleMedium),
          ),
          M3EListItem(
            leading: const Icon(Icons.add_rounded),
            headline: l10n.playlistCreate,
            onTap: _createPlaylist,
          ),
          M3EListItem(
            leading: const Icon(Icons.download_rounded),
            headline: l10n.libraryImportFavorites,
            onTap: () => Navigator.of(context).pop(
              const _PickerOutcome.importRequested(),
            ),
          ),
          Flexible(
            child: ReorderableListView.builder(
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              onReorderItem: _onReorder,
              itemCount: _entries.length,
              itemBuilder: (context, index) {
                final entry = _entries[index];
                return M3EListItem(
                  key: ValueKey<String>(entry.key),
                  leading: Icon(entry.icon),
                  headline: entry.name,
                  onTap: () =>
                      Navigator.of(context).pop(_PickerOutcome.select(entry.id)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.playlistTrackCount(entry.trackCount),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (entry.selected) ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.check_rounded,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                      ],
                      if (entry.playlistId != null)
                        M3EMenu.entries(
                          position: M3EMenuAnchorPosition.bottomEnd,
                          anchorBuilder: (context, open) => M3EIconButton(
                            variant: M3EIconButtonVariant.standard,
                            icon: const Icon(Icons.more_vert_rounded),
                            tooltip: l10n.playlistRename,
                            onPressed: open,
                          ),
                          onSelected: (value) {
                            if (value == 'rename') {
                              _rename(entry);
                            } else if (value == 'delete') {
                              _confirmDelete(context, entry);
                            }
                          },
                          entries: [
                            M3EMenuEntry(
                              label: l10n.playlistRename,
                              value: 'rename',
                              leading: const Icon(Icons.edit_rounded, size: 20),
                            ),
                            M3EMenuEntry(
                              label: l10n.playlistDelete,
                              value: 'delete',
                              isDestructive: true,
                              leading: const Icon(
                                Icons.delete_outline_rounded,
                                size: 20,
                              ),
                            ),
                          ],
                        ),
                      ReorderableDragStartListener(
                        index: index,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Icon(
                            Icons.drag_handle_rounded,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// 链接导入输入（平台 + 链接/ID）。
class _LinkImportInput {
  const _LinkImportInput(this.sourceKey, this.rawId);

  final String sourceKey;
  final String rawId;
}

/// 五平台歌单链接导入对话框：选择平台并粘贴链接/ID。
class _LinkImportDialog extends StatefulWidget {
  const _LinkImportDialog({required this.channels});

  /// 平台列表（key + 展示名，顺序与发现页一致）。
  final List<({String key, String name})> channels;

  @override
  State<_LinkImportDialog> createState() => _LinkImportDialogState();
}

class _LinkImportDialogState extends State<_LinkImportDialog> {
  late String _sourceKey = widget.channels.first.key;
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = _l10n(context);
    final rawId = _controller.text.trim();
    if (rawId.isEmpty) {
      setState(() => _error = l10n.discoverOpenPlaylistHint);
      return;
    }
    Navigator.of(context).pop(_LinkImportInput(_sourceKey, rawId));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return M3EDialog(
      title: l10n.playlistImportFromLink,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3EDropdownMenu<String>(
            items: [
              for (final channel in widget.channels)
                M3EDropdownItem<String>(
                  label: channel.name,
                  value: channel.key,
                  selected: channel.key == _sourceKey,
                ),
            ],
            singleSelect: true,
            showChipAnimation: false,
            fieldStyle: M3EDropdownFieldStyle(
              hintText: l10n.playlistImportChannel,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onSelectionChanged: (items) {
              if (items.isEmpty) return;
              setState(() => _sourceKey = items.first.value);
            },
          ),
          const SizedBox(height: 12),
          M3ETextField(
            controller: _controller,
            placeholder: l10n.discoverOpenPlaylistHint,
            autofocus: true,
            // 弹窗表单与音源配置等其它弹窗一致用 outlined（这不是搜索框）。
            variant: M3ETextFieldVariant.outlined,
            errorText: _error,
            textInputAction: TextInputAction.done,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        M3EButton.text(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        M3EButton.filled(
          onPressed: _submit,
          child: Text(l10n.discoverOpen),
        ),
      ],
    );
  }
}
