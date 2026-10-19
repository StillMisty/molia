import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/download.dart' show DownloadedTrack;
import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../models/play_mode.dart';
import '../providers/collection_presenter.dart';
import '../providers/discover_provider.dart';
import '../providers/library_collections.dart';
import '../providers/library_provider.dart';
import '../providers/local_songs_collection.dart';
import '../providers/lyrics_provider.dart';
import '../pages/source_swap_page.dart';
import '../services/cache_service.dart';
import '../services/download/download_service.dart';
import '../services/escape_claims.dart';
import '../services/haptics.dart';
import '../services/notification_service.dart';
import '../services/track_local_data_service.dart';
import '../utils/duration_text.dart';
import '../utils/responsive.dart';
import '../utils/collection_row_query.dart';
import '../utils/scroll_to_top.dart';
import '../utils/sync_format.dart';
import '../widgets/add_to_library.dart';
import '../widgets/add_to_playlist_sheet.dart' show showPlaylistNameDialog;
import '../widgets/app_search_bar.dart';
import '../widgets/collection_scroll_bookkeeping.dart';
import '../widgets/collection_selection.dart';
import '../widgets/collection_track_list.dart';
import '../widgets/desktop_layout.dart';
import '../widgets/empty_state.dart';
import '../widgets/icon_swap.dart';
import '../widgets/local_audio_import.dart' show importLocalAudioFilesFlow;
import '../widgets/lxmc_import.dart' show importLxmcFavoritesFlow;
import '../widgets/shell_page_visibility.dart';
import '../widgets/shell_reselect.dart';
import '../widgets/track_row.dart';
import '../widgets/track_table_header.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本页而不注册 delegate，
/// 此时回退到简体中文（与 lxmc_import / 其他页面同一约定）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 行内表格列：三处合集行（曲目 / 历史 / 本地歌曲）共用同一映射，
/// 时长统一走 `durationText`。
///
/// [spec]（列宽与列构成）由调用方与表头传**同一份**：行尾只补文案，不看
/// 单行内容决定列的有无（否则同表内行与行、行与表头会左右错位）。
TrackRowColumns _rowColumns(
  TrackRowColumnSpec spec, {
  String artist = '',
  String album = '',
  String time = '',
  int? durationMs,
}) =>
    TrackRowColumns(
      spec: spec,
      artist: artist,
      album: album,
      time: time,
      duration: durationText(durationMs) ?? '',
    );

/// 当前合集的表格列规范：播放历史多一列「播放时间」，收藏 / 本地歌曲与
/// 搜索结果同档（唯一来源，表头与行都从这里取）。
TrackRowColumnSpec _columnSpec(CollectionColumnLayout layout) =>
    switch (layout) {
      CollectionColumnLayout.history => TrackRowColumnSpec.history,
      CollectionColumnLayout.standard => TrackRowColumnSpec.standard,
    };

/// 「收藏」页：默认收藏（♥）与已导入/自建列表、播放历史、本地歌曲的
/// 统一管理入口。
///
/// - 标题行即合集切换器（弹层内可新建/重命名/删除列表、拖动排序合集，
///   并提供「导入收藏」：.lxmc 文件 / 五平台歌单链接）；
///   默认落在有曲目的收藏，收藏为空时回退到第一个非空列表；
/// - 宽屏表格列：内容宽（窗口宽 − 栏宽）够时曲目 / 历史 / 本地歌曲列表
///   显示表头与列（播放历史多一列「播放时间」），窄窗口回落单列；
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
  const FavoritesPage({super.key, this.shuffleRandom, this.reselect});

  /// 随机播放起点随机源（测试注入种子；默认系统随机源）。
  final math.Random? shuffleRandom;

  /// 壳层「重复点击底栏 / 导航轨收藏目的地」的请求通道：
  /// 当前合集的列表回到顶部。
  final ShellReselectSignal? reselect;

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

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

  /// 多选状态机（索引以当前合集的可见列表为准；收藏 / 历史 / 本地歌曲共用）。
  final CollectionSelection _selection = CollectionSelection();

  /// 桌面 Esc 键处理器引用：[HardwareKeyboard] 注册 / 注销必须是同一闭包。
  late final bool Function(KeyEvent) _keyHandler = _handleKeyEvent;

  /// 登记给壳层的 Esc 占用判定：与 [_handleKeyEvent] 同源（[EscapeClaims]
  /// 让壳层在页面接管 Esc 时让位，见 escape_claims.dart）。
  late final bool Function() _escapeClaim = _canHandleEscape;

  int _selectedId = LibraryCollections.unset;
  CollectionTrackSort _sort = CollectionTrackSort.added;

  /// 搜索栏是否展开（不展开时完全不占行高）。
  bool _searching = false;

  /// 自建列表的「调整顺序」模式。
  bool _reordering = false;

  /// 合集自定义顺序（持久化键 `favorites` / `history` / `playlist:<id>`）；
  /// 未记录的新列表按自然顺序追加在末尾。
  List<String> _collectionOrder = const [];
  final LibraryCollections _collections = LibraryCollections();

  /// 滚动簿记：按合集键保存 / 恢复滚动偏移（节流落盘 + 只恢复一次）。
  late final CollectionScrollBookkeeping _bookkeeping =
      CollectionScrollBookkeeping(
    controllerOf: _scrollControllerForKey,
    persist: _collections.saveScrollOffsets,
  );

  /// 状态恢复完成前不跑默认合集回退（避免覆盖恢复的选集）。
  bool _restoreDone = false;

  /// 恢复的选集是否已按首次加载的合集列表校准过（失效选集回退一次）。
  bool _restoredSelectionChecked = false;

  /// 缓存服务（可能未注册）：缓存 revision 联动（清缓存 / LRU 淘汰后重算缓存行）。
  CacheService? _cacheService;

  /// 本地数据唯一读取口（可能未注册）：批量判定历史曲目的音频两档状态。
  TrackLocalDataService? _localDataService;

  /// 本地歌曲伪合集的数据状态机：联结、签名、令牌与加载态都在模块内，
  /// 页面只请求同步并消费行。
  late final LocalSongsCollection _localSongs = LocalSongsCollection(
    loadCachedAudioTrackIds: _loadCachedAudioTrackIds,
  );

  /// 合集视图投影器：身份 / 可见行 / 排序记忆化都在模块内。
  final CollectionPresenter _presenter = CollectionPresenter();

  /// 随机播放起点随机源（测试可注入种子）。
  late final math.Random _shuffleRandom = widget.shuffleRandom ?? math.Random();

  /// 播放历史列表滚动控制器（常显滚动条，支持手拖定位）。
  final ScrollController _historyScrollController = ScrollController();

  /// 本地歌曲列表滚动控制器（与历史同理，独立于列表曲目）。
  final ScrollController _localSongsScrollController = ScrollController();

  bool get _selecting => _selection.isSelecting;

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelectionChanged);
    _localSongs.addListener(_onLocalSongsChanged);
    // 桌面 Esc 退出多选：页面级键处理器。壳层全局快捷键只把 Esc 交给队列
    // 面板（lib/app/desktop/desktop_shortcuts.dart），多选语义由本页补上；
    // 同时登记 Esc 占用，壳层据此让位（HardwareKeyboard 处理器不短路，不登记
    // 的话同一次 Esc 会既清选择又触发壳层命令）。
    if (isDesktopPlatform()) {
      HardwareKeyboard.instance.addHandler(_keyHandler);
      EscapeClaims.add(_escapeClaim);
    }
    _listController.addListener(_bookkeeping.saveFromScroll);
    _historyScrollController.addListener(_bookkeeping.saveFromScroll);
    _localSongsScrollController.addListener(_bookkeeping.saveFromScroll);
    widget.reselect?.addListener(_handleReselect);
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
    if (!identical(cache, _cacheService)) {
      _cacheService?.revision.removeListener(_onCacheRevision);
      _cacheService = cache;
      cache?.revision.addListener(_onCacheRevision);
    }
    _localDataService = context.read<TrackLocalDataService?>();
  }

  @override
  void didUpdateWidget(covariant FavoritesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reselect != widget.reselect) {
      oldWidget.reselect?.removeListener(_handleReselect);
      widget.reselect?.addListener(_handleReselect);
    }
  }

  @override
  void dispose() {
    // 无条件注销（未注册时为空操作）：平台在测试里可能被覆盖，initState 与
    // dispose 看到的平台未必一致，漏注销会把已释放的 State 留在键盘链上
    // （Esc 占用判定也会读到已释放的页面）。
    EscapeClaims.remove(_escapeClaim);
    HardwareKeyboard.instance.removeHandler(_keyHandler);
    widget.reselect?.removeListener(_handleReselect);
    _cacheService?.revision.removeListener(_onCacheRevision);
    _selection.removeListener(_onSelectionChanged);
    _selection.dispose();
    _localSongs.removeListener(_onLocalSongsChanged);
    _localSongs.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    // 释放前排空最后一次滚动位置（簿记内部取消节流计时并落盘）。
    _bookkeeping.dispose();
    _listController.dispose();
    _historyScrollController.dispose();
    _localSongsScrollController.dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  /// 本地歌曲合集的一轮落定（下载优先联结 / 过期结果丢弃在模块内）。
  void _onLocalSongsChanged() {
    if (mounted) setState(() {});
  }

  /// 缓存变化（清缓存 / LRU 淘汰）：重建以按新签名重算缓存行。
  void _onCacheRevision() {
    if (mounted) setState(() {});
  }

  /// 当前本地歌曲合集的输入快照：历史键 + 下载记录键 + 缓存 revision
  /// 共同决定是否需要重算（签名与联结都在 `LocalSongsCollection` 内）。
  LocalSongsInput _localSongsInput(
    LibraryProvider provider,
    DownloadService? downloads,
  ) {
    final history = provider.history;
    return LocalSongsInput(
      history: history,
      // 惰性转换：签名只读历史键；真正列举缓存时才需要领域曲目。
      historyTracks: () => [
        for (final entry in history) provider.trackFromHistoryEntry(entry),
      ],
      downloads: downloads?.downloads ?? const <DownloadedTrack>[],
      supported: downloads?.supported ?? false,
      initialized: downloads?.initialized ?? false,
      cacheRevision: _cacheService?.revision.value ?? -1,
    );
  }

  /// 缓存索引读取：唯一读取口可能未注册（此时按无缓存行呈现）。
  Future<Set<TrackId>> _loadCachedAudioTrackIds(List<Track> tracks) {
    final service = _localDataService;
    if (service == null) return Future.value(const <TrackId>{});
    return service.cachedAudioTrackIds(tracks);
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
      _bookkeeping.restoreOffsets(offsets);
      if (selection != null) _selectedId = selection;
      _restoreDone = true;
    });
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

  /// 壳层重复点击「收藏」目的地：当前合集的列表回到顶部。
  ///
  /// 合集键在 build 里落定（簿记的活跃合集）；加载中 / 首帧为空 = 空操作。
  void _handleReselect() {
    final controller = _bookkeeping.activeController;
    if (controller == null) return;
    animateScrollToTop(controller);
  }

  void _openSearch() {
    HapticsService.lightImpact();
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _exitSearch() {
    _searchFocus.unfocus();
    _searchController.clear();
    if (!_searching) return;
    // 过滤条件清空后可见列表回到全量：Shift 范围选择的锚点下标失效。
    _selection.clearAnchor();
    setState(() {
      _searching = false;
    });
  }

  void _enterSelection(int index) {
    HapticsService.lightImpact();
    _selection.select(index);
  }

  /// 此刻 Esc 是否由本页接管：多选生效 + 页面可见 + 输入框未聚焦。
  ///
  /// [_handleKeyEvent]（页面级处理器）与登记给壳层的 [EscapeClaims] 占用
  /// 判定共用本方法——两处判定必须同源，否则会出现「壳层让位但本页不处理」
  /// 的按键黑洞，或壳层与页面双重消费。
  bool _canHandleEscape() {
    if (!_selecting) return false;
    // 壳层页面常驻挂载：隐藏页不响应 Esc——按键属于用户当前看到的页面，
    // 不该在别的页面上清掉看不见的多选（未挂壳层的单测按可见处理）。
    if (context.getInheritedWidgetOfExactType<ShellPageVisibility>()?.visible ==
        false) {
      return false;
    }
    // 输入框聚焦时让位（仓库硬约定，与壳层全局快捷键一致）。
    if (FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>() !=
        null) {
      return false;
    }
    return true;
  }

  /// 桌面 Esc：退出选择模式；此刻不接管时返回 false 放行
  /// （关队列面板、关上层弹层等其它 Esc 作用域不受影响）。
  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    if (!_canHandleEscape()) return false;
    _selection.clear();
    return true;
  }

  /// 合集行点击：桌面修饰键手势优先，其余保持既有语义（多选内切换 / 点播）。
  ///
  /// 三种行（曲目 / 历史 / 本地歌曲）共用同一套下标与选择语义：可见行数由
  /// [CollectionView.visibleCount] 给出，点播分支按 [CollectionView.kind] 落
  /// 到唯一的 [_playViewFrom]。
  void _onRowTap(
    CollectionView view,
    int index, {
    bool ctrl = false,
    bool shift = false,
  }) {
    if (_selection.applyModifiers(
      index,
      itemCount: view.visibleCount,
      ctrl: ctrl,
      shift: shift,
    )) {
      return;
    }
    if (_selecting) {
      _selection.toggle(index);
    } else {
      unawaited(_playViewFrom(view, index));
    }
  }

  void _enterReorder() {
    HapticsService.lightImpact();
    // 排序会整体重排可见顺序：clear 一并让多选锚点失效。
    _selection.clear();
    _searchFocus.unfocus();
    _searchController.clear();
    setState(() {
      _searching = false;
      _sort = CollectionTrackSort.added;
      _reordering = true;
    });
  }

  void _exitReorder() {
    if (!_reordering) return;
    setState(() => _reordering = false);
  }

  /// 合集条目：收藏 / 播放历史 / 本地歌曲 / 各列表。按持久化顺序排列，
  /// 未记录的新列表按自然顺序（收藏 → 历史 → 本地歌曲 → 列表）追加在末尾；
  /// 下载能力不可用时不出现本地歌曲。
  ///
  /// 合集弹层按这一份解析出顺序 / 图标 / 选中态。
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
          // 计数与列表行数同源：下载 / 导入记录 + 播放历史里的缓存行
          //（弹层打开前会先把缓存行重算到当前输入，见 _showCollectionPicker）。
          trackCount: _localSongs.count,
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
    for (final key
        in LibraryCollections.applyOrder(natural, _collectionOrder)) {
      final entry = available.remove(key);
      if (entry != null) ordered.add(entry);
    }
    return ordered;
  }

  /// 打开合集切换弹层：点行切换、新建/重命名/删除、导入收藏、
  /// 行尾把手拖动排序。
  ///
  /// 本地歌曲计数含缓存行：弹层打开前先把缓存行重算到当前输入，否则刚启动
  /// （还没进过本地歌曲合集）时计数会漏掉缓存行、与列表行数对不上。
  /// 签名未变时是零等待；只有输入变过才等一次音频缓存目录列举。
  Future<void> _showCollectionPicker(
    AppLocalizations l10n,
    List<PlaylistInfo> playlists,
    int? favoritesId,
    int selected,
  ) async {
    final provider = context.read<LibraryProvider>();
    final downloadService = context.read<DownloadService?>();
    await _localSongs.sync(_localSongsInput(provider, downloadService));
    if (!mounted) return;
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
    _bookkeeping.flush();
    setState(() {
      _selectedId = id;
      // 切换合集回到常规浏览态：退出搜索/排序编辑，避免空态困惑。
      _searching = false;
      _reordering = false;
      _searchController.clear();
    });
    unawaited(_collections.saveSelection(id));
    // 切换合集后可见列表整体替换：clear 一并让多选锚点失效。
    _selection.clear();
  }

  void _onCollectionOrderChanged(List<String> keys) {
    if (!mounted) return;
    setState(() => _collectionOrder = List.of(keys));
    unawaited(_collections.saveOrder(keys));
  }

  /// 随机播放起点：在可见列表内随机取一首。
  int _randomStart(int count) => count <= 0 ? 0 : _shuffleRandom.nextInt(count);

  /// 从当前合集可见行的 [index] 起播；[mode] 只由「随机播放」传入。
  ///
  /// 按行联合的变体取播放载荷：历史走 `playHistory`（保留历史语义），本地
  /// 歌曲把行还原成 `local` 源快照，其余走列表曲目；可见顺序即播放队列顺序。
  /// 三种合集的点播入口只有这一份。
  Future<void> _playViewFrom(
    CollectionView view,
    int index, {
    PlayMode? mode,
  }) {
    HapticsService.lightImpact();
    final provider = context.read<LibraryProvider>();
    switch (view.visibleRows[index]) {
      case HistoryCollectionRow():
        return provider.playHistory(
          [
            for (final row in view.visibleRows)
              (row as HistoryCollectionRow).entry
          ],
          index,
          contextName: view.displayName,
          mode: mode,
        );
      case LocalSongCollectionRow():
        final addedAt = DateTime.now().millisecondsSinceEpoch;
        return provider.playPlaylistTracks(
          [
            for (final row in view.visibleRows)
              (row as LocalSongCollectionRow)
                  .song
                  .toPlaylistTrack(addedAt: addedAt),
          ],
          index,
          contextName: view.displayName,
          mode: mode,
        );
      case TrackCollectionRow():
        return provider.playPlaylistTracks(
          [
            for (final row in view.visibleRows)
              (row as TrackCollectionRow).track
          ],
          index,
          contextName: view.displayName,
          mode: mode,
        );
    }
  }

  /// 拖动排序落位：M3E 宿主给的是「直接移动」语义（曲目落在目标下标）。
  Future<void> _reorderTracks(CollectionView view, int from, int to) async {
    final playlistId = view.playlistId;
    // 排序只在自建列表生效，可见行必为列表曲目行；按同一有序列表还原。
    final tracks = [
      for (final row in view.visibleRows) (row as TrackCollectionRow).track,
    ];
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
    HapticsService.lightImpact();
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

  List<CollectionRow> _selectedRows(CollectionView view) =>
      _selection.selectedFrom(view.visibleRows);

  /// 多选收藏 / 取消收藏：三种行统一走行联合的曲目快照与收藏键。
  Future<void> _setSelectedFavorite(
    CollectionView view, {
    required bool favorited,
  }) async {
    final selected = _selectedRows(view);
    _selection.clear();
    if (selected.isEmpty) return;
    final provider = context.read<LibraryProvider>();
    if (favorited) {
      final now = DateTime.now().millisecondsSinceEpoch;
      await provider.addTracksToFavorites([
        for (final row in selected) row.toPlaylistTrack(addedAt: now),
      ]);
    } else {
      await provider.removeTracksFromFavorites([
        for (final row in selected) row.favoriteKey,
      ]);
    }
  }

  Future<void> _removeSelectedFromPlaylist(CollectionView view) async {
    final playlistId = view.playlistId;
    final selected = _selectedRows(view);
    _selection.clear();
    if (playlistId == null || selected.isEmpty) return;
    await context.read<LibraryProvider>().removeTracksFromPlaylist(playlistId, [
      for (final row in selected) (row as TrackCollectionRow).track,
    ]);
  }

  Future<void> _deleteSelectedHistory(CollectionView view) async {
    final selected = _selectedRows(view);
    _selection.clear();
    if (selected.isEmpty) return;
    await context.read<LibraryProvider>().deleteHistoryEntries([
      for (final row in selected) (row as HistoryCollectionRow).entry,
    ]);
  }

  /// 本地歌曲多选删除：下载副本删文件、导入项只移除记录、缓存行清缓存
  /// （统一确认一次）。
  Future<void> _deleteSelectedLocalSongs(CollectionView view) async {
    final selected = [
      for (final row in _selectedRows(view))
        (row as LocalSongCollectionRow).song,
    ];
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
  Future<bool?> _confirmDeleteLocalSongs(List<CollectionLocalSong> selected) {
    final l10n = _l10n(context);
    final anyCached = selected.any((song) => song.isCached);
    final anyDownloaded =
        selected.any((song) => !song.isCached && !song.isImported);
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

  Future<void> _copySelectionToPlaylist(CollectionView view) async {
    final selected = _selectedRows(view);
    final now = DateTime.now().millisecondsSinceEpoch;
    final tracks = [
      for (final row in selected)
        if (row is! HistoryCollectionRow) row.toPlaylistTrack(addedAt: now),
    ];
    final entries = [
      for (final row in selected)
        if (row is HistoryCollectionRow) row.entry,
    ];
    final copied = await _copyToPlaylist(
      tracks: tracks.isEmpty ? null : tracks,
      entries: entries.isEmpty ? null : entries,
      includeFavorites: !view.isFavorites,
      includeHistory: !view.isHistory,
    );
    if (copied && mounted) _selection.clear();
  }

  @override
  Widget build(BuildContext context) {
    // 可见性门控：本页在壳层中常驻挂载，隐藏时放弃 provider 订阅，
    // 否则每次播放历史写入（每首歌一次）都会让整页 build 并重跑
    // 过滤 / 排序（见 ShellPageVisibility）。
    final provider = ShellPageVisibility.maybeVisibleOf(context) ?? true
        ? context.watch<LibraryProvider>()
        : context.read<LibraryProvider>();
    final l10n = _l10n(context);
    final playlists = provider.playlists;
    final favoritesId = LibraryCollections.favoritesPlaylistId(playlists);
    // 合集身份（kind / 落库 id / 展示名 / 滚动键）只在投影器里推导一次；
    // 已知选集后页面只按 kind 决定订阅与加载。
    final identity = _presenter.identityFor(
      selectedId: _selectedId,
      playlists: playlists,
      favoritesId: favoritesId,
      favoritesName: l10n.favoritesPlaylistName,
      historyName: l10n.libraryHistory,
      localSongsName: l10n.libraryLocalSongs,
    );
    final selected = identity.selectedId;
    final isHistory = identity.isHistory;
    final isLocalSongs = identity.isLocalSongs;

    // 本地歌曲数据来自 DownloadService：只在浏览该合集时订阅，避免下载
    // 进度 tick（32KB 节流）把整页拖进重建；弹层计数的读取在打开时进行。
    final DownloadService? downloadService = isLocalSongs
        ? context.watch<DownloadService?>()
        : context.read<DownloadService?>();
    // 缓存行（缓存 = 已下载）：播放历史 × 完整音频缓存命中，随历史 / 缓存
    // revision / 下载记录变化重算；只在浏览本地歌曲合集时触发。联结、签名
    // 与过期丢弃都在 `LocalSongsCollection` 内，页面只消费行。
    if (isLocalSongs) {
      unawaited(_localSongs.sync(_localSongsInput(provider, downloadService)));
    }
    final localSongs =
        isLocalSongs ? _localSongs.rows : const <CollectionLocalSong>[];

    // 选中合集的曲目视图：未缓存时 ensurePlaylistTracks 触发加载
    // （provider 统一管理 loading，页面不探测缓存内部）。
    final selectedPlaylistId = identity.playlistId;
    if (selectedPlaylistId != null) {
      provider.ensurePlaylistTracks(selectedPlaylistId);
    }
    final tracksView = selectedPlaylistId == null
        ? null
        : provider.playlistTracksView(selectedPlaylistId);
    final tracks = tracksView?.tracks ?? const <PlaylistTrack>[];
    final history = provider.history;
    final view = _presenter.viewFor(
      identity: identity,
      tracks: tracks,
      history: history,
      localSongs: localSongs,
      query: _searchController.text,
      sort: _sort,
    );
    final isLoading = !isHistory &&
        !isLocalSongs &&
        selectedPlaylistId != null &&
        (tracksView?.loading ?? false);
    // 历史为空且正在加载时补一个加载态，其余情况沿用组合集加载态。
    final isHistoryLoading =
        isHistory && history.isEmpty && provider.isHistoryLoading;
    // 本地歌曲记录 / 缓存索引尚未加载时补加载态（避免空态闪烁）。
    final isLocalSongsLoading = isLocalSongs && _localSongs.loading;
    // 首帧合集列表尚未加载完成：显示加载态，避免空态闪烁。
    final isInitialLoading = playlists.isEmpty && provider.isPlaylistsLoading;

    final reorderActive =
        _reordering && view.isCustom && !_searching && view.visibleCount >= 2;

    // 滚动位置恢复：内容就绪后按当前合集键恢复一次（切换合集各自恢复）。
    _bookkeeping.activate(view.collectionKey);
    if (!isInitialLoading &&
        !isLoading &&
        !isHistoryLoading &&
        !isLocalSongsLoading) {
      _bookkeeping.scheduleRestore();
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

    // 合集切换只有标题行弹层一个入口：条目不额外解析一份，弹层打开时按
    // 当下 provider 状态现算。
    final listColumn = Column(
      children: [
        _selecting
            ? _buildSelectionBar(context, l10n, provider, view)
            : _buildIdleHeader(
                context,
                l10n,
                provider,
                playlists,
                favoritesId,
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
    );

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
        child: listColumn,
      ),
    );
  }

  Widget _buildIdleHeader(
    BuildContext context,
    AppLocalizations l10n,
    LibraryProvider provider,
    List<PlaylistInfo> playlists,
    int? favoritesId,
    CollectionView view, {
    required bool reorderActive,
  }) {
    if (reorderActive) return _buildReorderHeader(context, l10n, view);
    if (_searching) return _buildSearchHeader(context, l10n, view);
    return _buildTitleRow(
      context,
      l10n,
      playlists,
      favoritesId,
      view,
    );
  }

  /// 常驻标题行：合集切换器（弹层）+ 随机播放 / （本地歌曲）导入 / 搜索按钮
  /// （播放/暂停在顶栏）。
  ///
  /// 弹层是合集切换与管理的**唯一入口**：点行切换，弹层内新建 / 重命名 /
  /// 删除 / 拖动排序 / 导入收藏都在这里，事件同源不会出现两套观感。
  Widget _buildTitleRow(
    BuildContext context,
    AppLocalizations l10n,
    List<PlaylistInfo> playlists,
    int? favoritesId,
    CollectionView view,
  ) {
    final theme = Theme.of(context);
    final horizontalPadding =
        context.layoutType(ResponsivePageType.browse).horizontalPadding;
    final canPlay = view.visibleCount > 0;
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
                  HapticsService.lightImpact();
                  _showCollectionPicker(
                    l10n,
                    playlists,
                    favoritesId,
                    view.selectedId,
                  );
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
              semanticLabel: l10n.shufflePlay,
              icon: const Icon(Icons.shuffle_rounded),
              onPressed: canPlay ? () => _playShuffledFor(view) : null,
            ),
            // 本地歌曲合集：导入本地文件（下载副本与导入项统一浏览）。
            if (view.isLocalSongs) ...[
              const SizedBox(width: 4),
              M3EIconButton(
                key: const Key('localSongsImportButton'),
                variant: M3EIconButtonVariant.standard,
                semanticLabel: l10n.libraryImportLocalSongs,
                icon: const Icon(Icons.audio_file_rounded),
                onPressed: () => unawaited(importLocalAudioFilesFlow(context)),
              ),
            ],
            const SizedBox(width: 4),
            M3EIconButton(
              variant: M3EIconButtonVariant.standard,
              semanticLabel: l10n.libraryTabSearch,
              icon: const Icon(Icons.search_rounded),
              onPressed: _openSearch,
            ),
          ],
        ),
      ),
    );
  }

  /// 随机播放：在可见行内随机起点，点播分支与普通点击同源。
  Future<void> _playShuffledFor(CollectionView view) => _playViewFrom(
        view,
        _randomStart(view.visibleCount),
        mode: PlayMode.shuffle,
      );

  /// 搜索行：单胶囊布局——返回键、输入框/清除键与 ⋮（排序 / 调整顺序 /
  /// 清空历史）都收在搜索栏内，日常不展开搜索时不占行高。
  Widget _buildSearchHeader(
    BuildContext context,
    AppLocalizations l10n,
    CollectionView view,
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
            semanticLabel: l10n.cancel,
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: _exitSearch,
          ),
          trailing: [
            // 本地歌曲没有排序 / 清空类动作，不显示 ⋮。
            if (view.hasItems && !view.isLocalSongs)
              _buildOverflowMenu(context, l10n, view),
          ],
          onChanged: (_) => setState(() {
            // 过滤改变可见列表：多选锚点随搜索词失效（选择保留）。
            _selection.clearAnchor();
          }),
        ),
      ),
    );
  }

  /// 排序模式行：标题 + 提示 + 完成。
  Widget _buildReorderHeader(
    BuildContext context,
    AppLocalizations l10n,
    CollectionView view,
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
                semanticLabel: l10n.playlistReorderDone,
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
    CollectionView view,
  ) {
    return M3EMenu.entries(
      position: M3EMenuAnchorPosition.bottomEnd,
      anchorBuilder: (context, open) => M3EIconButton(
        variant: M3EIconButtonVariant.standard,
        icon: const Icon(Icons.more_vert_rounded),
        semanticLabel: view.isHistory ? l10n.historyClear : l10n.sortTooltip,
        onPressed: open,
      ),
      onSelected: (value) {
        if (value is CollectionTrackSort) {
          // 排序改变可见顺序：多选锚点失效。
          setState(() {
            _sort = value;
            _selection.clearAnchor();
          });
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
          for (final sort in CollectionTrackSort.values)
            M3EMenuEntry(
              label: switch (sort) {
                CollectionTrackSort.added => l10n.sortDefaultOrder,
                CollectionTrackSort.title => l10n.sortByTitle,
                CollectionTrackSort.artist => l10n.sortByArtist,
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
    CollectionView view,
  ) {
    final selected = _selectedRows(view);
    if (selected.isEmpty) return const [];
    final allFavorited = selected.every((row) => provider.isFavorite(
          row.favoriteKey.sourceKey,
          row.favoriteKey.songId,
        ));
    return [
      M3EIconButton(
        variant: M3EIconButtonVariant.standard,
        icon: const Icon(Icons.playlist_add_rounded),
        semanticLabel: l10n.addToPlaylist,
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
        semanticLabel: allFavorited ? l10n.favoriteRemove : l10n.favoriteAdd,
        // 三种行共用同一写路径（行联合提供曲目快照 / 收藏键）。
        onPressed: () => unawaited(
          _setSelectedFavorite(view, favorited: !allFavorited),
        ),
      ),
      if (view.isCustom)
        M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          icon: const Icon(Icons.playlist_remove_rounded),
          semanticLabel: l10n.playlistRemoveTrack,
          onPressed: () => unawaited(_removeSelectedFromPlaylist(view)),
        ),
      if (view.isHistory)
        M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          icon: const Icon(Icons.delete_rounded),
          semanticLabel: l10n.historyDeleteEntry,
          onPressed: () => unawaited(_deleteSelectedHistory(view)),
        ),
      // 本地歌曲：下载副本删文件、导入项只移出列表（确认文案在动作内区分）。
      if (view.isLocalSongs)
        M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          icon: const Icon(Icons.delete_rounded),
          semanticLabel: l10n.delete,
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
    CollectionView view,
  ) {
    final m3e = M3ETheme.of(context);
    final selectionTheme = m3e.selectionTheme;
    final foreground = selectionTheme.contextualForeground(m3e.colorScheme);
    final itemCount = view.visibleCount;
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
                  semanticLabel: l10n.cancel,
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
                  semanticLabel:
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
    CollectionView view, {
    required bool reorderActive,
  }) {
    // 行 / 表头同一份列规范（历史多一列「播放时间」），表格档判定按规范
    // 取阈值：行内是否给列、表头画哪几列、行高取哪一档都由这一个决定。
    final spec = _columnSpec(view.columnLayout);
    final tableColumns = DesktopLayout.of(context).tableColumnsFor(spec);
    final columnSpec = tableColumns ? spec : null;
    // 三种合集的可见行已是同一份有序联合：列表脚手架只搭一次，行内展示与
    // 行动作按行变体分派，不再按合集类型选列表形状。
    final body = CollectionTrackList<CollectionRow>(
      controller: _scrollControllerForKey(view.collectionKey),
      rows: view.visibleRows,
      keyOf: (row) => ValueKey<String>(row.key),
      // 合集本身为空 → 合集空态；有内容但被搜索过滤掉 → 搜索空态。
      empty: view.hasItems
          ? CollectionSearchEmpty(message: l10n.favoritesSearchEmpty)
          : _buildEmptyState(context, l10n, view),
      onReorder: reorderActive
          ? (from, to) => unawaited(_reorderTracks(view, from, to))
          : null,
      // 行高与行渲染同档（表格 56 / 单列 72）：差一档滚动条拇指与
      // 拖动定位就落在错误位置上。
      tableColumns: tableColumns,
      itemBuilder: (context, row, index) => _buildRow(
        context,
        l10n,
        provider,
        view,
        row,
        index,
        reorderActive: reorderActive,
        columnSpec: columnSpec,
      ),
    );
    // 表头固定在滚动区之上（与搜索页同一口径）：列标题不随列表滚走，
    // 列与行内列同宽同左缘。空列表（含被搜索过滤空）不给表头。
    if (columnSpec == null || view.visibleCount == 0) return body;
    final horizontalPadding =
        context.layoutType(ResponsivePageType.browse).horizontalPadding;
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: TrackTableHeader(spec: columnSpec),
        ),
        Expanded(child: body),
      ],
    );
  }

  /// 三种合集共用同一行外壳：展示字段来自行联合，行尾标签 / 拖动把手与
  /// 行动作按行变体分派；点播 / 多选 / 排序手势与既有语义一致。
  Widget _buildRow(
    BuildContext context,
    AppLocalizations l10n,
    LibraryProvider provider,
    CollectionView view,
    CollectionRow row,
    int index, {
    required bool reorderActive,
    required TrackRowColumnSpec? columnSpec,
  }) {
    // 行尾标签与 ⋮ 菜单共用 56dp 固定槽：大字号下必须单行省略，
    // 否则换行会被 72dp 固定行高裁切。
    final cachedTag = switch (row) {
      LocalSongCollectionRow(:final song) when song.isCached => Text(
          l10n.localSongsCachedTag,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      _ => null,
    };
    return CollectionTrackRow(
      title: row.title,
      artist: row.artist,
      coverUrl: row.artworkUrl,
      columns: columnSpec == null
          ? null
          : _rowColumns(
              columnSpec,
              artist: row.artist,
              album: row.album,
              // 播放时间 = 毫秒时间戳的紧凑文案（与同步日志同一格式）。
              time:
                  row is HistoryCollectionRow ? syncTimeText(row.playedAt) : '',
              durationMs: row.durationMs,
            ),
      trailingText: durationText(row.durationMs),
      trailing: reorderActive
          ? Icon(
              Icons.drag_handle_rounded,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            )
          : cachedTag,
      position: calculateCardPosition(index, view.visibleCount),
      selected: _selection.isSelected(index),
      onTap: reorderActive ? null : () => _onRowTap(view, index),
      onTapWithModifiers: (reorderActive || !isDesktopPlatform())
          ? null
          : (ctrl, shift) => _onRowTap(view, index, ctrl: ctrl, shift: shift),
      onLongPress: reorderActive ? null : () => _enterSelection(index),
      actions: (reorderActive || _selecting)
          ? null
          : _rowActions(context, l10n, provider, view, row),
    );
  }

  /// 行动作：投影器决定构成（`CollectionPresenter.rowActionsFor`），这里只把
  /// 行变体接成具体流程（复制 / 换源 / 移除 / 收藏 / 删除）。
  List<CollectionRowAction> _rowActions(
    BuildContext context,
    AppLocalizations l10n,
    LibraryProvider provider,
    CollectionView view,
    CollectionRow row,
  ) {
    return buildCollectionRowActions(
      l10n: l10n,
      specs: _presenter.rowActionsFor(row, view.identity),
      wiring: _actionWiring(context, provider, view, row),
    );
  }

  CollectionRowActionWiring _actionWiring(
    BuildContext context,
    LibraryProvider provider,
    CollectionView view,
    CollectionRow row,
  ) {
    switch (row) {
      case TrackCollectionRow(:final track):
        return CollectionRowActionWiring(
          onCopy: () => _copyToPlaylist(
            tracks: [track],
            includeFavorites: !view.isFavorites,
            includeHistory: !view.isHistory,
          ),
          onSwap: () => showSourceSwapPage(
            context,
            seed: provider.trackFromPlaylistTrack(track),
            lyricsProvider: context.read<LyricsProvider>(),
            playlistId: view.playlistId,
          ),
          onRemoveFromPlaylist: () => provider.removeTracksFromPlaylist(
            view.playlistId!,
            [track],
          ),
          onRemoveFromFavorites: () =>
              provider.removeTracksFromFavorites([row.favoriteKey]),
        );
      case HistoryCollectionRow(:final entry):
        return CollectionRowActionWiring(
          onCopy: () =>
              _copyToPlaylist(entries: [entry], includeHistory: false),
          onSwap: () => showSourceSwapPage(
            context,
            seed: provider.trackFromHistoryEntry(entry),
            lyricsProvider: context.read<LyricsProvider>(),
            historyKey: (sourceKey: entry.sourceKey, songId: entry.songId),
          ),
          onDeleteHistory: () => provider.deleteHistoryEntry(entry),
        );
      case LocalSongCollectionRow(:final song):
        final favorite = song.favoriteKey;
        final isFavorite =
            provider.isFavorite(favorite.sourceKey, favorite.songId);
        PlaylistTrack playable() => song.toPlaylistTrack(
              addedAt: DateTime.now().millisecondsSinceEpoch,
            );
        return CollectionRowActionWiring(
          onCopy: () => _copyToPlaylist(tracks: [playable()]),
          onToggleFavorite: () => isFavorite
              ? provider.removeTracksFromFavorites([favorite])
              : provider.addTracksToFavorites([playable()]),
          onDeleteLocalSong: () async {
            final service = context.read<DownloadService?>();
            if (service == null) return;
            await _deleteLocalSong(service, song);
          },
          isFavorite: isFavorite,
          localSongCached: song.isCached,
          localSongImported: song.isImported,
        );
    }
  }

  /// 本地歌曲单条删除（行动作入口：触摸端左滑 / 桌面右键）：先确认再按行
  /// 来源删（下载副本删文件、导入项只移出列表、缓存行清缓存）。
  Future<void> _deleteLocalSong(
    DownloadService service,
    CollectionLocalSong song,
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
  Future<void> _clearCachedAudio(CollectionLocalSong song) async {
    final service = context.read<TrackLocalDataService?>();
    final entry = song.history;
    if (service == null || entry == null) return;
    final messenger = context.read<NotificationService?>();
    final l10n = _l10n(context);
    final track = context.read<LibraryProvider>().trackFromHistoryEntry(entry);
    final result = await service.clear(track, LocalCachePart.audio);
    if (result.cleared) return;
    final message =
        result.skipped > 0 ? l10n.trackInfoCachePlaying : l10n.trackCacheEmpty;
    messenger?.showSnackBar(message);
  }

  Widget _buildEmptyState(
    BuildContext context,
    AppLocalizations l10n,
    CollectionView view,
  ) {
    // 页面级空态版式：在可用高度里居中（Center），外边距 24。
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: EmptyState(
          icon: view.isHistory
              ? Icons.history_rounded
              : view.isLocalSongs
                  ? Icons.library_music_rounded
                  : view.isFavorites
                      ? Icons.favorite_border_rounded
                      : Icons.queue_music_rounded,
          message: view.isHistory
              ? l10n.historyEmpty
              : view.isLocalSongs
                  ? l10n.localSongsEmpty
                  : view.isFavorites
                      ? l10n.favoritesEmpty
                      : l10n.playlistTracksEmpty,
          // 主行动只在「本页就能完成」时给：本地歌曲空态 = 导入入口（标题行按钮
          // 之外的第二入口，同一动作）。收藏 / 历史 / 自建列表空态不给按钮——
          // 收藏要先在别处收藏、历史要先有播放、自建列表要先在别处加入曲目，
          // 页内没有对应动作可挂（挂「去发现」还得给本页新增跨目的地导航通道）。
          action: view.isLocalSongs
              ? M3EButton.icon(
                  style: M3EButtonStyle.tonal,
                  icon: const Icon(Icons.audio_file_rounded),
                  label: Text(l10n.libraryImportLocalSongs),
                  onPressed: () =>
                      unawaited(importLocalAudioFilesFlow(context)),
                )
              : null,
        ),
      ),
    );
  }
}

/// 合集条目：收藏 / 播放历史 / 本地歌曲伪合集（哨兵 id）或一个自建列表。
///
/// 只服务本页的合集弹层：顺序、图标、数量与选中态由页面按持久化顺序 +
/// 自然顺序统一解析。
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

  /// 顺序持久化键：`favorites` / `history` / `downloads` / `playlist:<id>`。
  final String key;

  /// 选择结果：哨兵值或列表 id。
  final int id;

  final String name;
  final IconData icon;
  final int trackCount;

  /// 当前正在浏览的合集（列表选中态）。
  final bool selected;

  /// 非空表示自建列表（可重命名 / 删除）。
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
    HapticsService.lightImpact();
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
                // 这是两个工具动作（新建 / 导入）。docs/architecture.md §6 的
                // 目标是收成 icon-only 动作组，但当前依赖版本
                // （material_3_expressive 1.1.7）里 M3EButton 仅当 icon 与
                // label 同时非空才渲染内容，icon-only 动作会退化成空白按钮
                // （上游修复需 ≥ 1.1.8，尚未发布）；在依赖升级前保持两颗标准
                // 图标键：可见、可点，纯图标语义走 semanticLabel，key 保留稳定定位。
                M3EIconButton(
                  key: const Key('favoritesCreatePlaylist'),
                  variant: M3EIconButtonVariant.standard,
                  size: M3EIconButtonSize.sm,
                  semanticLabel: l10n.playlistCreate,
                  icon: const Icon(Icons.add_rounded),
                  onPressed: _createPlaylist,
                ),
                M3EIconButton(
                  key: const Key('favoritesImportCollection'),
                  variant: M3EIconButtonVariant.standard,
                  size: M3EIconButtonSize.sm,
                  semanticLabel: l10n.libraryImportFavorites,
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
                  // 数量走 M3E 元文本槽（选中态自带配色）；当前合集只靠
                  // selected 高亮（选中容器），不叠对号图标。
                  trailingText: l10n.playlistTrackCount(entry.trackCount),
                  selected: entry.selected,
                  onTap: () => Navigator.of(context)
                      .pop(_PickerOutcome.select(entry.id)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (entry.playlistId != null)
                        M3EMenu.entries(
                          position: M3EMenuAnchorPosition.bottomEnd,
                          anchorBuilder: (context, open) => M3EIconButton(
                            variant: M3EIconButtonVariant.standard,
                            icon: const Icon(Icons.more_vert_rounded),
                            semanticLabel: l10n.playlistRename,
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
