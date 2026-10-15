import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/download.dart' show DownloadedTrack, kLocalSourceKey;
import '../domain/models/library.dart';
import '../l10n/app_localizations.dart';
import '../models/play_mode.dart';
import '../providers/discover_provider.dart';
import '../providers/library_collections.dart';
import '../providers/library_provider.dart';
import '../providers/lyrics_provider.dart';
import '../pages/source_swap_page.dart';
import '../services/cache_service.dart';
import '../services/download/download_service.dart';
import '../services/notification_service.dart';
import '../utils/duration_text.dart';
import '../utils/responsive.dart';
import '../widgets/add_to_library.dart';
import '../widgets/add_to_playlist_sheet.dart' show showPlaylistNameDialog;
import '../widgets/app_search_bar.dart';
import '../widgets/icon_swap.dart';
import '../widgets/local_audio_import.dart' show importLocalAudioFilesFlow;
import '../widgets/lxmc_import.dart' show importLxmcFavoritesFlow;
import '../widgets/swipe_reveal_row.dart';
import '../widgets/track_row.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本页而不注册 delegate，
/// 此时回退到简体中文（与 lxmc_import / 其他页面同一约定）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 「收藏」页：默认收藏（♥）与已导入/自建列表、播放历史、本地歌曲的
/// 统一管理入口。
///
/// - 标题行即合集切换器（弹层内可新建/重命名/删除列表、拖动排序合集，
///   并提供「导入收藏」：.lxmc 文件 / 五平台歌单链接）；
///   默认落在有曲目的收藏，收藏为空时回退到第一个非空列表；
/// - 曲目行：点击播放；行尾显示歌曲时长；左滑「加入列表 / 移除类操作」
///   （「加入列表」含我的收藏 / 播放历史 / 自建列表）；长按进入多选；
/// - 标题右侧提供随机播放 / 搜索两个图标（播放/暂停在顶栏迷你条，
///   整表播放走随机或点行）；搜索按钮展开搜索栏
///   （日常不占用行高），排序与「调整顺序」收在搜索栏的 ⋮ 菜单里；
///   本地歌曲合集多一个「导入本地歌曲」按钮；
/// - 自建列表支持「调整顺序」模式：长按拖动曲目落位即持久化；
/// - 播放历史支持单条删除（左滑）与批量删除（多选）。
/// - 本地歌曲（下载副本 + 导入的本地文件）来自 `DownloadService`：
///   下载副本删除会删文件，导入项只从列表移除。
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key, this.shuffleRandom});

  /// 随机播放起点随机源（测试注入种子；默认系统随机源）。
  final math.Random? shuffleRandom;

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

enum _CollectionSort { added, title, artist }

class _FavoritesPageState extends State<FavoritesPage> {
  /// 标题行 / 搜索行统一内容高度：点搜索展开时头部不跳高
  /// （M3E 搜索胶囊默认高度 56，标题行按同一高度对齐）。
  static const double _headerRowHeight = 56;

  /// 头部（标题行 / 搜索行 / 多选栏）垂直留白：三者切换头部不跳高。
  static const double _headerPaddingTop = 12;
  static const double _headerPaddingBottom = 8;

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

  /// 状态恢复完成前不跑默认合集回退（避免覆盖恢复的选集）。
  bool _restoreDone = false;

  /// 恢复的选集是否已按首次加载的合集列表校准过（失效选集回退一次）。
  bool _restoredSelectionChecked = false;

  /// 各合集已保存的滚动位置（键同合集顺序键：`favorites` / `history` /
  /// `playlist:<id>`）；滚动/切换时增量写回。
  Map<String, double> _savedScrollOffsets = const {};

  /// 缓存服务（可能未注册）：缓存行识别与 revision 联动。
  CacheService? _cacheService;

  /// 本地歌曲的缓存行（播放历史 × 完整音频缓存命中；缓存 = 已下载）。
  List<_LocalSongRow> _cachedSongRows = const [];

  /// 缓存行最近一次重算的输入签名（历史 + 下载记录 + 缓存 revision）。
  int? _cachedSongRowsSignature;

  /// 缓存索引加载中（加载期不显示空态，避免闪烁）。
  bool _cachedSongRowsLoading = false;

  /// 缓存行加载令牌：输入变化后丢弃过期结果。
  int _cachedSongRowsLoadToken = 0;

  /// 当前 build 对应的合集键（滚动落盘用）。
  String? _activeCollectionKey;

  /// 已按合集键恢复过滚动位置的键（切换合集时各自只恢复一次）。
  String? _offsetRestoredFor;

  /// 已调度但未执行的滚动恢复键（避免每帧重复 addPostFrameCallback）。
  String? _offsetRestorePending;

  /// 滚动落盘节流（≤2 次/秒；不打断持续滚动）。
  Timer? _scrollSaveTimer;

  /// 随机播放起点随机源（测试可注入种子）。
  late final math.Random _shuffleRandom =
      widget.shuffleRandom ?? math.Random();

  /// 播放历史列表滚动控制器（常显滚动条，支持手拖定位）。
  final ScrollController _historyScrollController = ScrollController();

  /// 本地歌曲列表滚动控制器（与历史同理，独立于列表曲目）。
  final ScrollController _localSongsScrollController = ScrollController();

  bool get _selecting => _selection.isSelectionMode;

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelectionChanged);
    _listController.addListener(_scheduleScrollSave);
    _historyScrollController.addListener(_scheduleScrollSave);
    _localSongsScrollController.addListener(_scheduleScrollSave);
    unawaited(_restoreState());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<LibraryProvider>();
      provider.refreshPlaylists();
      provider.ensureFavoritesLoaded();
      provider.refreshHistory();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 缓存 revision：清缓存 / LRU 淘汰后重建缓存行（build 里按签名触发重算）。
    final cache = context.read<CacheService?>();
    if (identical(cache, _cacheService)) return;
    _cacheService?.revision.removeListener(_onCacheRevision);
    _cacheService = cache;
    cache?.revision.addListener(_onCacheRevision);
  }

  @override
  void dispose() {
    _cacheService?.revision.removeListener(_onCacheRevision);
    _selection.removeListener(_onSelectionChanged);
    _selection.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _scrollSaveTimer?.cancel();
    _saveScrollOffsets();
    _listController.dispose();
    _historyScrollController.dispose();
    _localSongsScrollController.dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  /// 缓存变化（清缓存 / LRU 淘汰）：重建以按新签名重算缓存行。
  void _onCacheRevision() {
    if (mounted) setState(() {});
  }

  /// 缓存行输入签名：历史曲目键 + 下载记录键 + 缓存 revision。
  int _cachedSongRowsInputSignature(
    LibraryProvider provider,
    DownloadService? downloads,
    CacheService? cache,
  ) {
    return Object.hash(
      Object.hashAll([for (final entry in provider.history) entry.key]),
      Object.hashAll([
        for (final record in downloads?.downloads ?? const <DownloadedTrack>[])
          record.key,
      ]),
      cache?.revision.value ?? -1,
    );
  }

  /// 缓存行重算触发：签名变化才重算（只在浏览本地歌曲合集时调用）。
  void _scheduleCachedSongRowsReload(
    LibraryProvider provider,
    DownloadService? downloads,
  ) {
    final cache = _cacheService;
    final signature = _cachedSongRowsInputSignature(provider, downloads, cache);
    if (_cachedSongRowsSignature == signature) return;
    _cachedSongRowsSignature = signature;
    _cachedSongRowsLoading = true;
    final token = ++_cachedSongRowsLoadToken;
    unawaited(
      _reloadCachedSongRows(provider, downloads, cache, signature, token),
    );
  }

  /// 重算缓存行：一次缓存目录列举 + 播放历史前缀匹配；命中任一已缓存音质
  /// 即视为「已下载」，已有下载记录的曲目跳过（下载优先）。
  Future<void> _reloadCachedSongRows(
    LibraryProvider provider,
    DownloadService? downloads,
    CacheService? cache,
    int signature,
    int token,
  ) async {
    var rows = const <_LocalSongRow>[];
    try {
      if (cache != null && downloads != null && downloads.supported) {
        final index = await cache.audioCacheIndex();
        final result = <_LocalSongRow>[];
        for (final entry in provider.history) {
          final record = downloads.recordFor(entry.sourceKey, entry.songId);
          if (record != null && record.hasAudio) continue;
          final prefix = CacheService.audioCacheKeyPrefix(
            sourceKey: entry.sourceKey,
            songId: entry.songId,
          );
          int? size;
          for (final file in index.entries) {
            if (!file.key.startsWith(prefix)) continue;
            // 同一曲目可能有多个音质变体：取最大（展示用）。
            size = size == null || file.value > size ? file.value : size;
          }
          if (size == null) continue;
          result.add(_LocalSongRow.cached(entry, cachedSizeBytes: size));
        }
        rows = result;
      }
    } catch (_) {
      // 列举失败按无缓存行呈现（不影响下载 / 导入行）。
      rows = const [];
    }
    if (!mounted || token != _cachedSongRowsLoadToken) return;
    setState(() {
      _cachedSongRows = rows;
      _cachedSongRowsLoading = false;
    });
    // 加载期间输入又变了：按最新签名再调度一次。
    final nowSignature = _cachedSongRowsInputSignature(
      provider,
      context.read<DownloadService?>(),
      _cacheService,
    );
    if (nowSignature != signature) {
      _scheduleCachedSongRowsReload(provider, context.read<DownloadService?>());
    }
  }

  /// 冷启动恢复：合集顺序 + 上次选中的合集 + 各合集滚动位置。
  ///
  /// 三者就绪前 [_restoreDone] 为 false，默认合集回退不会执行——否则
  /// 恢复的选集会被默认解析覆盖。
  Future<void> _restoreState() async {
    final order = await _collections.loadOrder();
    final selection = await _collections.loadSelection();
    final offsets = await _collections.loadScrollOffsets();
    if (!mounted) return;
    setState(() {
      _collectionOrder = order;
      _savedScrollOffsets = offsets;
      if (selection != null) _selectedId = selection;
      _restoreDone = true;
    });
  }

  /// 当前合集的持久化键；历史 / 本地歌曲 / 收藏用固定键，自建列表按 id。
  String _collectionKeyOf(_CollectionView view) {
    if (view.isHistory) return LibraryCollections.historyOrderKey;
    if (view.isLocalSongs) return LibraryCollections.downloadsOrderKey;
    if (view.isFavorites) return LibraryCollections.favoritesOrderKey;
    final id = view.playlistId;
    return id == null
        ? LibraryCollections.favoritesOrderKey
        : LibraryCollections.playlistOrderKey(id);
  }

  /// 合集键 → 滚动控制器（收藏 / 自建列表共用列表控制器）。
  ScrollController _scrollControllerForKey(String key) {
    if (key == LibraryCollections.historyOrderKey) {
      return _historyScrollController;
    }
    if (key == LibraryCollections.downloadsOrderKey) {
      return _localSongsScrollController;
    }
    return _listController;
  }

  /// 滚动位置节流落盘：首次滚动即写，之后每 500ms 至多一次。
  void _scheduleScrollSave() {
    if (_scrollSaveTimer?.isActive ?? false) return;
    _scrollSaveTimer = Timer(const Duration(milliseconds: 500), () {
      _scrollSaveTimer = null;
      _saveScrollOffsets();
    });
  }

  /// 把当前合集滚动位置并入持久化 map 写回（失败静默，不影响功能）。
  void _saveScrollOffsets() {
    final key = _activeCollectionKey;
    if (key == null) return;
    final controller = _scrollControllerForKey(key);
    if (!controller.hasClients) return;
    final offset = controller.offset;
    if (_savedScrollOffsets[key] == offset) return;
    final next = Map<String, double>.of(_savedScrollOffsets);
    next[key] = offset;
    _savedScrollOffsets = next;
    unawaited(_collections.saveScrollOffsets(next));
  }

  /// 合集/内容变化时调度一次滚动恢复（列表布局完成后 jumpTo）。
  void _scheduleOffsetRestore(String key) {
    if (key == _offsetRestoredFor || key == _offsetRestorePending) return;
    _offsetRestorePending = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _offsetRestorePending != key) return;
      _offsetRestorePending = null;
      // 合集已切换/列表尚未挂载：交给下一次 build 重新调度。
      if (_activeCollectionKey != key) return;
      final controller = _scrollControllerForKey(key);
      if (!controller.hasClients) return;
      _offsetRestoredFor = key;
      final saved = _savedScrollOffsets[key];
      if (saved == null || saved <= 0) return;
      final position = controller.position;
      controller.jumpTo(
        saved.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
  }

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

  String _displayName(
    AppLocalizations l10n,
    List<PlaylistInfo> playlists,
    int? favoritesId,
    int selected,
  ) {
    if (selected == LibraryCollections.historySentinel) return l10n.libraryHistory;
    if (selected == LibraryCollections.downloadsSentinel) {
      return l10n.libraryLocalSongs;
    }
    if (selected == LibraryCollections.favoritesSentinel) return l10n.favoritesPlaylistName;
    for (final playlist in playlists) {
      if (playlist.id == selected) return playlist.name;
    }
    return l10n.favoritesPlaylistName;
  }

  /// 合集弹层条目：收藏 / 播放历史 / 本地歌曲 / 各列表。按持久化顺序排列，
  /// 未记录的新列表按自然顺序（收藏 → 历史 → 本地歌曲 → 列表）追加在末尾；
  /// 已删除列表的持久化键自动忽略；下载能力不可用（Web）时不出现本地歌曲。
  List<_CollectionEntry> _collectionEntries(
    AppLocalizations l10n,
    LibraryProvider provider,
    List<PlaylistInfo> playlists,
    int? favoritesId,
    int selected,
    DownloadService? downloadService,
  ) {
    var favoritesCount = 0;
    for (final playlist in playlists) {
      if (playlist.id == favoritesId) {
        favoritesCount = playlist.trackCount;
        break;
      }
    }
    final showLocalSongs = downloadService?.supported ?? false;
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
      if (showLocalSongs)
        LibraryCollections.downloadsOrderKey: _CollectionEntry(
          key: LibraryCollections.downloadsOrderKey,
          id: LibraryCollections.downloadsSentinel,
          name: l10n.libraryLocalSongs,
          icon: Icons.library_music_rounded,
          trackCount: downloadService!.downloads.length,
          selected: selected == LibraryCollections.downloadsSentinel,
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
      if (showLocalSongs) LibraryCollections.downloadsOrderKey,
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
    final downloadService = context.read<DownloadService?>();
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
          downloadService,
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
    _selectCollection(picked);
  }

  /// 切换到指定合集：落盘旧合集滚动位置 → 选集 → 退出搜索/排序编辑态 →
  /// 持久化选择 → 清空多选。
  ///
  /// 弹层点选、链接导入、`.lxmc` 导入共用（导入完直接进入新列表）。
  void _selectCollection(int id) {
    if (!mounted || _selectedId == id) return;
    // 切换前先落盘当前合集的滚动位置（控制器即将换内容）。
    _saveScrollOffsets();
    setState(() {
      _selectedId = id;
      // 切换合集回到常规浏览态：退出搜索/排序编辑，避免空态困惑。
      _searching = false;
      _reordering = false;
      _searchController.clear();
    });
    unawaited(_collections.saveSelection(id));
    _selection.clear();
  }

  void _onCollectionOrderChanged(List<String> keys) {
    if (!mounted) return;
    setState(() => _collectionOrder = List.of(keys));
    unawaited(_collections.saveOrder(keys));
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

  /// 随机播放起点：在可见列表内随机取一首。
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

  /// 播放历史（可见顺序即播放队列；[mode] 用于「随机播放」）。
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

  /// 本地歌曲搜索过滤（同一语义：title/artist 子串）。
  List<_LocalSongRow> _filterLocalSongs(List<_LocalSongRow> songs) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return songs;
    return [
      for (final song in songs)
        if (song.title.toLowerCase().contains(query) ||
            song.artist.toLowerCase().contains(query))
          song,
    ];
  }

  /// 播放本地歌曲（可见顺序即播放队列；[mode] 用于「随机播放」）。
  Future<void> _playLocalSongsFrom(
    List<_LocalSongRow> songs,
    int index,
    String name, {
    PlayMode? mode,
  }) {
    HapticFeedback.lightImpact();
    final addedAt = DateTime.now().millisecondsSinceEpoch;
    return context.read<LibraryProvider>().playPlaylistTracks(
          [for (final song in songs) song.toPlaylistTrack(addedAt: addedAt)],
          index,
          contextName: name,
          mode: mode,
        );
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
      final result = await importLxmcFavoritesFlow(context);
      // 导入成功后直接进入该列表（与链接导入同语义）。
      if (!mounted || result == null) return;
      _selectCollection(result.playlistId);
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
      _selectCollection(result.playlistId);
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

  List<PlaylistTrack> _selectedTracks(_CollectionView view) => [
        for (final index in _selection.selectedIndices)
          if (index >= 0 && index < view.visible.length) view.visible[index],
      ];

  List<PlayHistoryEntry> _selectedHistory(_CollectionView view) => [
        for (final index in _selection.selectedIndices)
          if (index >= 0 && index < view.visibleHistory.length)
            view.visibleHistory[index],
      ];

  List<_LocalSongRow> _selectedLocalSongs(_CollectionView view) => [
        for (final index in _selection.selectedIndices)
          if (index >= 0 && index < view.visibleLocalSongs.length)
            view.visibleLocalSongs[index],
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

  /// 本地歌曲多选的收藏 / 取消收藏（与历史同一写路径）。
  Future<void> _favoriteSelectedLocalSongs(_CollectionView view) async {
    final selected = _selectedLocalSongs(view);
    _selection.clear();
    if (selected.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await context.read<LibraryProvider>().addTracksToFavorites([
      for (final song in selected) song.toPlaylistTrack(addedAt: now),
    ]);
  }

  Future<void> _unfavoriteSelectedLocalSongs(_CollectionView view) async {
    final selected = _selectedLocalSongs(view);
    _selection.clear();
    if (selected.isEmpty) return;
    await context.read<LibraryProvider>().removeTracksFromFavorites([
      for (final song in selected) song.favoriteKey,
    ]);
  }

  /// 本地歌曲多选删除：下载副本删文件、导入项只移除记录、缓存行清缓存
  /// （统一确认一次）。
  Future<void> _deleteSelectedLocalSongs(_CollectionView view) async {
    final selected = _selectedLocalSongs(view);
    _selection.clear();
    if (selected.isEmpty) return;
    final service = context.read<DownloadService?>();
    if (service == null) return;
    final confirmed = await _confirmDeleteLocalSongs(selected);
    if (confirmed != true) return;
    for (final song in selected) {
      if (song.isCached) {
        await _clearCachedAudio(song);
      } else {
        await service.delete(song.record!);
      }
    }
  }

  /// 删除确认：按选中项构成给文案（全导入 = 只移出列表；全缓存 = 清缓存；
  /// 混合 = 三者都说明）。
  Future<bool?> _confirmDeleteLocalSongs(List<_LocalSongRow> selected) {
    final l10n = _l10n(context);
    final anyCached = selected.any((song) => song.isCached);
    final anyDownloaded = selected.any((song) => !song.isCached && !song.isImported);
    final anyImported = selected.any((song) => song.isImported);
    final String title;
    final String content;
    if (anyCached && !anyDownloaded && !anyImported) {
      title = l10n.localSongsCachedRemove;
      content = l10n.localSongsCachedRemoveConfirm;
    } else if (anyCached) {
      title = l10n.downloadDelete;
      content = l10n.localSongsMixedRemoveConfirm;
    } else if (anyImported && !anyDownloaded) {
      title = l10n.localSongsRemove;
      content = l10n.localSongsRemoveConfirm;
    } else if (anyImported) {
      title = l10n.downloadDelete;
      content = l10n.downloadDeleteConfirmMixed;
    } else {
      title = l10n.downloadDelete;
      content = l10n.downloadDeleteConfirm;
    }
    return M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: title,
        content: Text(content),
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
  }

  Future<void> _copySelectionToPlaylist(_CollectionView view) async {
    final tracks = view.isHistory
        ? null
        : view.isLocalSongs
            ? [
                for (final song in _selectedLocalSongs(view))
                  song.toPlaylistTrack(
                    addedAt: DateTime.now().millisecondsSinceEpoch,
                  ),
              ]
            : _selectedTracks(view);
    final entries = view.isHistory ? _selectedHistory(view) : null;
    final copied = await _copyToPlaylist(
      tracks: tracks,
      entries: entries,
      includeFavorites: !view.isFavorites,
      includeHistory: !view.isHistory,
    );
    if (copied && mounted) _selection.clear();
  }

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
    final isLocalSongs = selected == LibraryCollections.downloadsSentinel;
    final isCustom = !isHistory && !isFavorites && !isLocalSongs;
    final selectedPlaylistId =
        (isFavorites || isHistory || isLocalSongs) ? favoritesId : selected;
    final displayName = _displayName(l10n, playlists, favoritesId, selected);

    // 本地歌曲数据来自 DownloadService：只在浏览该合集时订阅，避免下载
    // 进度 tick（32KB 节流）把整页拖进重建；弹层计数的读取在打开时进行。
    final DownloadService? downloadService = isLocalSongs
        ? context.watch<DownloadService?>()
        : context.read<DownloadService?>();
    final downloadSongs = downloadService?.supported ?? false
        ? downloadService!.downloads
        : const <DownloadedTrack>[];
    // 缓存行（缓存 = 已下载）：播放历史 × 完整音频缓存索引，随历史 / 缓存
    // revision / 下载记录变化重算；只在浏览本地歌曲时触发。
    if (isLocalSongs) {
      _scheduleCachedSongRowsReload(provider, downloadService);
    }
    final localSongs = isLocalSongs
        ? <_LocalSongRow>[
            for (final song in downloadSongs) _LocalSongRow.download(song),
            ..._cachedSongRows,
          ]
        : const <_LocalSongRow>[];

    // 选中合集的曲目视图：未缓存时 ensurePlaylistTracks 触发加载
    // （provider 统一管理 loading，页面不探测缓存内部）。
    if (!isHistory && !isLocalSongs && selectedPlaylistId != null) {
      provider.ensurePlaylistTracks(selectedPlaylistId);
    }
    final tracksView = (isHistory || isLocalSongs || selectedPlaylistId == null)
        ? null
        : provider.playlistTracksView(selectedPlaylistId);
    final tracks = tracksView?.tracks ?? const <PlaylistTrack>[];
    final visible = (isHistory || isLocalSongs)
        ? const <PlaylistTrack>[]
        : _filterAndSort(tracks);
    final history = provider.history;
    final visibleHistory =
        isHistory ? _filterHistory(history) : const <PlayHistoryEntry>[];
    final visibleLocalSongs =
        isLocalSongs ? _filterLocalSongs(localSongs) : const <_LocalSongRow>[];
    final hasItems = isHistory
        ? history.isNotEmpty
        : isLocalSongs
            ? localSongs.isNotEmpty
            : tracks.isNotEmpty;
    final isLoading = !isHistory &&
        !isLocalSongs &&
        selectedPlaylistId != null &&
        (tracksView?.loading ?? false);
    // 历史为空且正在加载时补一个加载态，其余情况沿用组合集加载态。
    final isHistoryLoading =
        isHistory && history.isEmpty && provider.isHistoryLoading;
    // 本地歌曲记录 / 缓存索引尚未加载时补加载态（避免空态闪烁）。
    final isLocalSongsLoading = isLocalSongs &&
        ((downloadService?.initialized != true) ||
            (localSongs.isEmpty && _cachedSongRowsLoading));
    // 首帧合集列表尚未加载完成：显示加载态，避免空态闪烁。
    final isInitialLoading = playlists.isEmpty && provider.isPlaylistsLoading;

    final view = _CollectionView(
      isHistory: isHistory,
      isFavorites: isFavorites,
      isLocalSongs: isLocalSongs,
      isCustom: isCustom,
      playlistId: (isHistory || isLocalSongs) ? null : selectedPlaylistId,
      displayName: displayName,
      tracks: tracks,
      visible: visible,
      visibleHistory: visibleHistory,
      visibleLocalSongs: visibleLocalSongs,
      hasItems: hasItems,
    );
    final reorderActive =
        _reordering && view.isCustom && !_searching && view.visible.length >= 2;

    // 滚动位置恢复：内容就绪后按当前合集键恢复一次（切换合集各自恢复）。
    _activeCollectionKey = _collectionKeyOf(view);
    if (!isInitialLoading && !isLoading && !isHistoryLoading &&
        !isLocalSongsLoading) {
      _scheduleOffsetRestore(_activeCollectionKey!);
    }

    // 恢复的选集校准：首次合集列表加载完成后，若持久化选集已不存在
    //（列表被删 / 下载能力不可用）则回退到默认解析结果并落盘；只校准一次，
    // 避免链接导入后新列表尚未进 `playlists` 时被误判为失效。
    // 下载能力要等服务 init 完成再判（首帧 supported 恒为 false）。
    final downloadsReady = downloadService?.initialized ?? true;
    if (_restoreDone &&
        !isInitialLoading &&
        downloadsReady &&
        !_restoredSelectionChecked) {
      _restoredSelectionChecked = true;
      final valid = _selectedId == LibraryCollections.unset ||
          _selectedId == LibraryCollections.favoritesSentinel ||
          _selectedId == LibraryCollections.historySentinel ||
          (_selectedId == LibraryCollections.downloadsSentinel &&
              (downloadService?.supported ?? false)) ||
          playlists.any((playlist) => playlist.id == _selectedId);
      if (!valid) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() => _selectedId = selected);
          unawaited(_collections.saveSelection(selected));
        });
      }
    }

    // 首次解析完成后固定合集选择：避免「我的收藏」从无到有时自动跳出
    // 当前正在浏览的列表（例如在自建列表里收藏后跳到收藏）。
    if (_restoreDone &&
        _selectedId == LibraryCollections.unset &&
        !isInitialLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _selectedId != LibraryCollections.unset) return;
        setState(() => _selectedId = selected);
        // 默认落定的合集也持久化：下次启动恢复上次活跃的收藏。
        unawaited(_collections.saveSelection(selected));
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
              child: isInitialLoading ||
                      isLoading ||
                      isHistoryLoading ||
                      isLocalSongsLoading
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

  /// 常驻标题行：合集切换器 + 随机播放 / （本地歌曲）导入 / 搜索按钮
  /// （播放/暂停在顶栏）。
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
        : view.isLocalSongs
            ? view.visibleLocalSongs.isNotEmpty
            : view.visible.isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, _headerPaddingTop,
          horizontalPadding, _headerPaddingBottom),
      child: SizedBox(
        height: _headerRowHeight,
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
              variant: M3EIconButtonVariant.standard,
              tooltip: l10n.shufflePlay,
              icon: const Icon(Icons.shuffle_rounded),
              onPressed: canPlay ? () => _playShuffledFor(view) : null,
            ),
            // 本地歌曲合集：导入本地文件（下载副本与导入项统一浏览）。
            if (view.isLocalSongs) ...[
              const SizedBox(width: 4),
              M3EIconButton(
                key: const Key('localSongsImportButton'),
                variant: M3EIconButtonVariant.standard,
                tooltip: l10n.libraryImportLocalSongs,
                icon: const Icon(Icons.audio_file_rounded),
                onPressed: () => unawaited(importLocalAudioFilesFlow(context)),
              ),
            ],
            const SizedBox(width: 4),
            M3EIconButton(
              variant: M3EIconButtonVariant.standard,
              tooltip: l10n.libraryTabSearch,
              icon: const Icon(Icons.search_rounded),
              onPressed: _openSearch,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _playShuffledFor(_CollectionView view) => view.isHistory
      ? _playHistoryFrom(
          view.visibleHistory,
          _randomStart(view.visibleHistory.length),
          view.displayName,
          mode: PlayMode.shuffle,
        )
      : view.isLocalSongs
          ? _playLocalSongsFrom(
              view.visibleLocalSongs,
              _randomStart(view.visibleLocalSongs.length),
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
      padding: EdgeInsets.fromLTRB(horizontalPadding, _headerPaddingTop,
          horizontalPadding, _headerPaddingBottom),
      child: SizedBox(
        height: _headerRowHeight,
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
            // 本地歌曲没有排序 / 清空类动作，不显示 ⋮。
            if (view.hasItems && !view.isLocalSongs)
              _buildOverflowMenu(context, l10n, view),
          ],
          onChanged: (_) => setState(() {}),
        ),
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
      padding: EdgeInsets.fromLTRB(horizontalPadding, _headerPaddingTop,
          horizontalPadding, _headerPaddingBottom),
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

  List<Widget> _buildSelectionActions(
    BuildContext context,
    AppLocalizations l10n,
    LibraryProvider provider,
    _CollectionView view,
  ) {
    final selected = view.isHistory
        ? _selectedHistory(view)
        : view.isLocalSongs
            ? _selectedLocalSongs(view)
            : _selectedTracks(view);
    if (selected.isEmpty) return const [];
    final allFavorited = selected.every((item) => switch (item) {
          PlaylistTrack track =>
            provider.isFavorite(track.sourceKey, track.songId),
          PlayHistoryEntry entry =>
            provider.isFavorite(entry.sourceKey, entry.songId),
          _LocalSongRow row =>
            provider.isFavorite(row.favoriteKey.sourceKey, row.favoriteKey.songId),
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
        icon: IconSwap<bool>(
          value: allFavorited,
          builder: (context, allFavorited) => Icon(
            allFavorited
                ? Icons.heart_broken_rounded
                : Icons.favorite_border_rounded,
          ),
        ),
        tooltip: allFavorited ? l10n.favoriteRemove : l10n.favoriteAdd,
        onPressed: () {
          if (view.isHistory) {
            unawaited(allFavorited
                ? _unfavoriteSelectedHistory(view)
                : _favoriteSelectedHistory(view));
          } else if (view.isLocalSongs) {
            unawaited(allFavorited
                ? _unfavoriteSelectedLocalSongs(view)
                : _favoriteSelectedLocalSongs(view));
          } else {
            unawaited(allFavorited
                ? _unfavoriteSelectedTracks(view)
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
          icon: const Icon(Icons.delete_rounded),
          tooltip: l10n.historyDeleteEntry,
          onPressed: () => unawaited(_deleteSelectedHistory(view)),
        ),
      // 本地歌曲：下载副本删文件、导入项只移出列表（确认文案在动作内区分）。
      if (view.isLocalSongs)
        M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          icon: const Icon(Icons.delete_rounded),
          tooltip: l10n.delete,
          onPressed: () => unawaited(_deleteSelectedLocalSongs(view)),
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
    final itemCount = view.isHistory
        ? view.visibleHistory.length
        : view.isLocalSongs
            ? view.visibleLocalSongs.length
            : view.visible.length;
    final allSelected = _selection.allSelectedFor(itemCount) == true;
    return ColoredBox(
      color: selectionTheme.contextualBackground(m3e.colorScheme),
      // 与标题行 / 搜索行同一套垂直留白：进入 / 退出多选头部不跳高。
      child: Padding(
        padding: const EdgeInsets.only(
          top: _headerPaddingTop,
          bottom: _headerPaddingBottom,
        ),
        child: IconTheme.merge(
          data: IconThemeData(color: foreground),
          child: SizedBox(
            height: _headerRowHeight,
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
                  tooltip:
                      allSelected ? l10n.deselectAll : l10n.selectAllItems,
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
      ),
    );
  }

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
    if (view.isLocalSongs) {
      return _buildLocalSongsBody(context, l10n, provider, view);
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
    final horizontalPadding =
        context.layoutType(ResponsivePageType.browse).horizontalPadding;
    final gap = TrackRow.gapOf(context);
    if (reorderActive) {
      return Scrollbar(
        controller: _listController,
        thumbVisibility: true,
        interactive: true,
        child: ReorderableListView.builder(
          scrollController: _listController,
          padding: EdgeInsets.fromLTRB(horizontalPadding, 8, horizontalPadding, 8),
          itemExtent: TrackRow.extent + gap,
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
        padding: EdgeInsets.fromLTRB(horizontalPadding, 8, horizontalPadding, 8),
        itemExtent: TrackRow.extent + gap,
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
      trailingText: durationText(track.durationMs),
      position: calculateCardPosition(index, view.visible.length),
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
    final Widget content = (reorderActive || _selecting)
        ? row
        : SwipeRevealRow(
            actions: _trackSwipeActions(context, l10n, view, track),
            child: row,
          );
    return Padding(
      padding: EdgeInsets.only(bottom: TrackRow.gapOf(context)),
      child: content,
    );
  }

  /// 侧滑动作图标：长按/悬停弹出动作名（tooltip 同时承担无障碍语义；
  /// 纯图标在窄胶囊里不容易自解释）。
  Widget _swipeActionIcon(IconData icon, String label) =>
      Tooltip(message: label, child: Icon(icon));

  /// 曲目左滑操作：加入列表 + 换源 + 移除类（按合集取语义）。
  ///
  /// 中性动作走 M3E 默认 tonal 胶囊；移除类用 filled + error 配色
  /// （对齐 M3E 列表示例的删除动作），图标直接表达「从本列表移除」。
  List<M3EListSwipeAction> _trackSwipeActions(
    BuildContext context,
    AppLocalizations l10n,
    _CollectionView view,
    PlaylistTrack track,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final playlistId = view.playlistId;
    return [
      M3EListSwipeAction(
        icon: _swipeActionIcon(
          Icons.playlist_add_rounded,
          l10n.addToPlaylist,
        ),
        onPressed: () => unawaited(
          _copyToPlaylist(
            tracks: [track],
            includeFavorites: !view.isFavorites,
            includeHistory: !view.isHistory,
          ),
        ),
      ),
      if (playlistId != null && track.sourceKey != kLocalSourceKey)
        M3EListSwipeAction(
          icon: _swipeActionIcon(
            Icons.swap_horiz_rounded,
            l10n.sourceSwap,
          ),
          onPressed: () => unawaited(
            showSourceSwapPage(
              context,
              seed: context
                  .read<LibraryProvider>()
                  .trackFromPlaylistTrack(track),
              lyricsProvider: context.read<LyricsProvider>(),
              playlistId: playlistId,
            ),
          ),
        ),
      if (view.isCustom && view.playlistId != null)
        M3EListSwipeAction(
          icon: _swipeActionIcon(
            Icons.playlist_remove_rounded,
            l10n.playlistRemoveTrack,
          ),
          isPrimary: true,
          backgroundColor: scheme.error,
          foregroundColor: scheme.onError,
          onPressed: () => unawaited(
            context.read<LibraryProvider>().removeTracksFromPlaylist(
              view.playlistId!,
              [track],
            ),
          ),
        )
      else if (view.isFavorites)
        M3EListSwipeAction(
          icon: _swipeActionIcon(
            Icons.delete_rounded,
            l10n.favoriteRemove,
          ),
          isPrimary: true,
          backgroundColor: scheme.error,
          foregroundColor: scheme.onError,
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
    final horizontalPadding =
        context.layoutType(ResponsivePageType.browse).horizontalPadding;
    final gap = TrackRow.gapOf(context);
    return Scrollbar(
      controller: _historyScrollController,
      thumbVisibility: true,
      interactive: true,
      child: ListView.builder(
        controller: _historyScrollController,
        padding: EdgeInsets.fromLTRB(horizontalPadding, 8, horizontalPadding, 8),
        itemExtent: TrackRow.extent + gap,
        itemCount: view.visibleHistory.length,
        itemBuilder: (context, index) {
          final entry = view.visibleHistory[index];
          final row = TrackRow(
            // 稳定 key：收藏切换后列表原地刷新，不整段重建/丢滚动位置。
            key: ValueKey<String>('h:${entry.sourceKey}:${entry.songId}'),
            title: entry.title,
            artist: entry.artist,
            coverUrl: entry.coverUrl,
            trailingText: durationText(entry.durationMs),
            position: calculateCardPosition(index, view.visibleHistory.length),
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
          final Widget content = _selecting
              ? row
              : SwipeRevealRow(
                  actions: [
                    M3EListSwipeAction(
                      icon: _swipeActionIcon(
                        Icons.playlist_add_rounded,
                        l10n.addToPlaylist,
                      ),
                      onPressed: () => unawaited(
                        _copyToPlaylist(
                          entries: [entry],
                          includeHistory: false,
                        ),
                      ),
                    ),
                    if (entry.sourceKey != kLocalSourceKey)
                      M3EListSwipeAction(
                        icon: _swipeActionIcon(
                          Icons.swap_horiz_rounded,
                          l10n.sourceSwap,
                        ),
                        onPressed: () => unawaited(
                          showSourceSwapPage(
                            context,
                            seed: context
                                .read<LibraryProvider>()
                                .trackFromHistoryEntry(entry),
                            lyricsProvider: context.read<LyricsProvider>(),
                            historyKey: (
                              sourceKey: entry.sourceKey,
                              songId: entry.songId,
                            ),
                          ),
                        ),
                      ),
                    M3EListSwipeAction(
                      icon: _swipeActionIcon(
                        Icons.delete_rounded,
                        l10n.historyDeleteEntry,
                      ),
                      isPrimary: true,
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                      onPressed: () => unawaited(
                        provider.deleteHistoryEntry(entry),
                      ),
                    ),
                  ],
                  child: row,
                );
          return Padding(
            padding: EdgeInsets.only(bottom: TrackRow.gapOf(context)),
            child: content,
          );
        },
      ),
    );
  }

  /// 本地歌曲单条删除（左滑入口）：先确认再按行来源删（下载副本删文件、
  /// 导入项只移出列表、缓存行清缓存）。
  Future<void> _deleteLocalSong(
    DownloadService service,
    _LocalSongRow song,
  ) async {
    final confirmed = await _confirmDeleteLocalSongs([song]);
    if (confirmed != true) return;
    if (song.isCached) {
      await _clearCachedAudio(song);
    } else {
      await service.delete(song.record!);
    }
  }

  /// 清除缓存行：只清音频缓存文件（不动下载 / 导入记录）；正在播放写入中的
  /// 文件受缓存保护期跳过，清不掉时给出提示。
  Future<void> _clearCachedAudio(_LocalSongRow song) async {
    final cache = context.read<CacheService?>();
    final entry = song.history;
    if (cache == null || entry == null) return;
    final messenger = context.read<NotificationService?>();
    final l10n = _l10n(context);
    final result = await cache.clearAudioForTrack(
      sourceKey: entry.sourceKey,
      songId: entry.songId,
    );
    if (result.deleted.count > 0) return;
    final message = result.skipped > 0
        ? l10n.trackInfoCachePlaying
        : l10n.trackCacheEmpty;
    messenger?.showSnackBar(message);
  }

  /// 本地歌曲列表：下载副本与导入的本地文件统一浏览。
  ///
  /// 行内点播走 `local` 音源（离线可用）；左滑「加入列表 / 收藏 / 删除」，
  /// 删除动作按记录来源区分文案（下载副本删文件、导入项只移出列表）。
  Widget _buildLocalSongsBody(
    BuildContext context,
    AppLocalizations l10n,
    LibraryProvider provider,
    _CollectionView view,
  ) {
    final service = context.read<DownloadService?>();
    if (service == null) return _buildEmptyState(context, l10n, view);
    if (view.visibleLocalSongs.isEmpty) {
      // 有内容但被搜索过滤掉：给搜索空态；否则给合集空态。
      if (view.hasItems) {
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
    final horizontalPadding =
        context.layoutType(ResponsivePageType.browse).horizontalPadding;
    final gap = TrackRow.gapOf(context);
    return Scrollbar(
      controller: _localSongsScrollController,
      thumbVisibility: true,
      interactive: true,
      child: ListView.builder(
        controller: _localSongsScrollController,
        padding: EdgeInsets.fromLTRB(horizontalPadding, 8, horizontalPadding, 8),
        itemExtent: TrackRow.extent + gap,
        itemCount: view.visibleLocalSongs.length,
        itemBuilder: (context, index) {
          final song = view.visibleLocalSongs[index];
          final favorite = song.favoriteKey;
          final isFavorite = provider.isFavorite(favorite.sourceKey, favorite.songId);
          final row = TrackRow(
            // 稳定 key：删除 / 导入后列表原地刷新，不整段重建/丢滚动位置。
            key: ValueKey<String>('l:${song.key}'),
            title: song.title,
            artist: song.artist,
            coverUrl: song.artworkUri,
            trailingText: durationText(song.durationMs),
            trailing: song.isCached
                ? Text(
                    l10n.localSongsCachedTag,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  )
                : null,
            position:
                calculateCardPosition(index, view.visibleLocalSongs.length),
            selected: _selection.isSelected(index),
            onTap: () {
              if (_selecting) {
                _selection.toggle(index);
              } else {
                _playLocalSongsFrom(
                  view.visibleLocalSongs,
                  index,
                  view.displayName,
                );
              }
            },
            onLongPress: () => _enterSelection(index),
          );
          final Widget content = _selecting
              ? row
              : SwipeRevealRow(
                  actions: [
                    M3EListSwipeAction(
                      icon: _swipeActionIcon(
                        Icons.playlist_add_rounded,
                        l10n.addToPlaylist,
                      ),
                      onPressed: () => unawaited(
                        _copyToPlaylist(
                          tracks: [
                            song.toPlaylistTrack(
                              addedAt: DateTime.now().millisecondsSinceEpoch,
                            ),
                          ],
                        ),
                      ),
                    ),
                    M3EListSwipeAction(
                      icon: _swipeActionIcon(
                        isFavorite
                            ? Icons.heart_broken_rounded
                            : Icons.favorite_border_rounded,
                        isFavorite ? l10n.favoriteRemove : l10n.favoriteAdd,
                      ),
                      onPressed: () => unawaited(
                        isFavorite
                            ? provider.removeTracksFromFavorites([favorite])
                            : provider.addTracksToFavorites([
                                song.toPlaylistTrack(
                                  addedAt:
                                      DateTime.now().millisecondsSinceEpoch,
                                ),
                              ]),
                      ),
                    ),
                    M3EListSwipeAction(
                      icon: _swipeActionIcon(
                        Icons.delete_rounded,
                        song.isCached
                            ? l10n.localSongsCachedRemove
                            : song.isImported
                                ? l10n.localSongsRemove
                                : l10n.downloadDelete,
                      ),
                      isPrimary: true,
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                      onPressed: () => unawaited(_deleteLocalSong(service, song)),
                    ),
                  ],
                  child: row,
                );
          return Padding(
            padding: EdgeInsets.only(bottom: TrackRow.gapOf(context)),
            child: content,
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
                  : view.isLocalSongs
                      ? Icons.library_music_rounded
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
                  : view.isLocalSongs
                      ? l10n.localSongsEmpty
                      : view.isFavorites
                          ? l10n.favoritesEmpty
                          : l10n.playlistTracksEmpty,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            // 本地歌曲空态：把导入入口摆在首屏（标题行按钮之外的第二入口）。
            if (view.isLocalSongs) ...[
              const SizedBox(height: 16),
              M3EButton.icon(
                style: M3EButtonStyle.tonal,
                icon: const Icon(Icons.audio_file_rounded),
                label: Text(l10n.libraryImportLocalSongs),
                onPressed: () =>
                    unawaited(importLocalAudioFilesFlow(context)),
              ),
            ],
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
    required this.isLocalSongs,
    required this.isCustom,
    required this.playlistId,
    required this.displayName,
    required this.tracks,
    required this.visible,
    required this.visibleHistory,
    required this.visibleLocalSongs,
    required this.hasItems,
  });

  final bool isHistory;
  final bool isFavorites;

  /// 本地歌曲伪合集（下载记录 + 导入的本地文件，来自 `DownloadService`）。
  final bool isLocalSongs;
  final bool isCustom;

  /// 实际落库的列表 id（收藏集合为收藏列表 id；历史 / 本地歌曲为 null）。
  final int? playlistId;
  final String displayName;

  /// 全量曲目（历史 / 本地歌曲集合为空）。
  final List<PlaylistTrack> tracks;

  /// 搜索 + 排序后的可见曲目（可见顺序即播放队列顺序）。
  final List<PlaylistTrack> visible;

  /// 搜索过滤后的历史条目。
  final List<PlayHistoryEntry> visibleHistory;

  /// 搜索过滤后的本地歌曲（下载 / 导入副本 + 缓存行）。
  final List<_LocalSongRow> visibleLocalSongs;

  final bool hasItems;
}

/// 本地歌曲行：下载 / 导入副本，或命中完整音频缓存的曲目（缓存 = 已下载）。
///
/// 缓存行保留原曲身份（`sourceKey` / `songId` / `raw`），播放走正常解析
/// （命中缓存即 `file://` 离线播放）；删除是「清缓存」，不动下载记录。
class _LocalSongRow {
  const _LocalSongRow.download(DownloadedTrack this.record)
      : history = null,
        cachedSizeBytes = null;

  const _LocalSongRow.cached(PlayHistoryEntry this.history,
      {required this.cachedSizeBytes})
      : record = null;

  final DownloadedTrack? record;
  final PlayHistoryEntry? history;

  /// 缓存行展示用体积（多音质变体取最大）；下载行为 null。
  final int? cachedSizeBytes;

  /// 是否缓存行（无下载 / 导入记录）。
  bool get isCached => record == null;

  /// 是否本地导入（就地引用）。
  bool get isImported => record?.imported ?? false;

  /// 稳定行 key。
  String get key => record?.key ?? '${history!.sourceKey}:${history!.songId}';

  String get title => record?.title ?? history!.title;

  String get artist => record?.artist ?? history!.artist;

  int? get durationMs {
    final record = this.record;
    if (record != null) return record.durationMs;
    return history!.durationMs;
  }

  /// 行封面地址：下载副本优先本地封面文件，缓存行用历史里的原图地址。
  String? get artworkUri {
    final record = this.record;
    if (record != null) return record.artworkUri?.toString();
    return history!.coverUrl;
  }

  /// 播放 / 收藏用的曲目快照（下载副本 = local 源；缓存行 = 原曲）。
  PlaylistTrack toPlaylistTrack({required int addedAt}) => record != null
      ? record!.toPlaylistTrack(addedAt: addedAt)
      : PlaylistTrack.fromHistoryEntry(history!, addedAt: addedAt);

  /// 收藏键（下载副本 = local 音源；缓存行 = 原曲键）。
  ({String sourceKey, String songId}) get favoriteKey => record != null
      ? (sourceKey: kLocalSourceKey, songId: record!.localSongId)
      : (sourceKey: history!.sourceKey, songId: history!.songId);
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
          // 标题行：合集名 + 右侧两个小按钮（新建 / 导入不再占用列表行）。
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(widget.title, style: theme.textTheme.titleMedium),
                ),
                M3EIconButton(
                  key: const Key('favoritesCreatePlaylist'),
                  variant: M3EIconButtonVariant.standard,
                  size: M3EIconButtonSize.sm,
                  tooltip: l10n.playlistCreate,
                  icon: const Icon(Icons.add_rounded),
                  onPressed: _createPlaylist,
                ),
                M3EIconButton(
                  key: const Key('favoritesImportCollection'),
                  variant: M3EIconButtonVariant.standard,
                  size: M3EIconButtonSize.sm,
                  tooltip: l10n.libraryImportFavorites,
                  icon: const Icon(Icons.library_add_rounded),
                  onPressed: () => Navigator.of(context).pop(
                    const _PickerOutcome.importRequested(),
                  ),
                ),
              ],
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
                  // 数量走 M3E 元文本槽（选中态自带配色）；当前合集走 selected
                  // 态（选中容器 + 对号），不再自绘数量文本。
                  trailingText: l10n.playlistTrackCount(entry.trackCount),
                  selected: entry.selected,
                  onTap: () =>
                      Navigator.of(context).pop(_PickerOutcome.select(entry.id)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (entry.selected)
                        const Icon(Icons.check_rounded, size: 20),
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
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Icon(Icons.drag_handle_rounded),
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
