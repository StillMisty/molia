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
import '../providers/collection_actions.dart';
import '../providers/collection_presenter.dart';
import '../providers/collection_session.dart';
import '../providers/discover_provider.dart';
import '../providers/library_collections.dart';
import '../providers/library_outcome.dart';
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
import '../theme/m3e_context.dart';
import '../utils/responsive.dart';
import '../utils/collection_row_query.dart';
import '../utils/scroll_to_top.dart';
import '../utils/sync_format.dart';
import '../widgets/app_search_bar.dart';
import '../widgets/collection_handoff.dart';
import '../widgets/collection_picker.dart';
import '../widgets/collection_scroll_bookkeeping.dart';
import '../widgets/collection_track_list.dart';
import '../widgets/desktop_layout.dart';
import '../widgets/empty_state.dart';
import '../widgets/icon_swap.dart';
import '../widgets/link_import_dialog.dart';
import '../widgets/local_audio_import.dart' show importLocalAudioFilesFlow;
import '../widgets/lxmc_import.dart' show importLxmcFavoritesFlow;
import '../widgets/row_actions.dart';
import '../widgets/shell_page_visibility.dart';
import '../widgets/shell_reselect.dart';
import '../widgets/track_row.dart';
import '../widgets/track_table_header.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本页而不注册 delegate，
/// 此时回退到简体中文（与 lxmc_import / 其他页面同一约定）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

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
///   并提供「导入收藏」：.lxmc 文件 / 平台歌单 / 收藏夹链接）；
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

  /// 桌面 Esc 键处理器引用：[HardwareKeyboard] 注册 / 注销必须是同一闭包。
  late final bool Function(KeyEvent) _keyHandler = _handleKeyEvent;

  /// 登记给壳层的 Esc 占用判定：与 [_handleKeyEvent] 同源（[EscapeClaims]
  /// 让壳层在页面接管 Esc 时让位，见 escape_claims.dart）。
  late final bool Function() _escapeClaim = _canHandleEscape;

  /// 合集会话：当前合集身份 / 模式 / 多选 / 加载组合 / 滚动激活的唯一
  /// 实现。页面只保留控件与流程（弹层、导入、播放、删除确认）。
  late final CollectionSession _session = CollectionSession(
    scroll: _PageScrollPort(this),
    loadCachedAudioTrackIds: _loadCachedAudioTrackIds,
  );

  /// 滚动簿记：按合集键保存 / 恢复滚动偏移（节流落盘 + 只恢复一次）。
  late final CollectionScrollBookkeeping _bookkeeping =
      CollectionScrollBookkeeping(
    controllerOf: _scrollControllerForKey,
    persist: _session.persistScrollOffsets,
  );

  /// 上次观察到的壳层可见性：隐藏 → 可见 = 重新进入收藏页，刷新播放历史
  /// 顺序（顺序在停留期间冻结，见 LibraryProvider）。未挂壳层的单测按可见。
  bool _pageVisible = true;

  /// 缓存服务（可能未注册）：缓存 revision 联动（清缓存 / LRU 淘汰后重算缓存行）。
  CacheService? _cacheService;

  /// 本地数据唯一读取口（可能未注册）：批量判定历史曲目的音频两档状态。
  TrackLocalDataService? _localDataService;

  /// 下载服务（可能未注册）：只在能力位 / 初始化状态变化或正在浏览本地
  /// 歌曲时重建，下载进度 tick 不拖整页。
  DownloadService? _downloadService;
  bool _downloadsSupported = false;
  bool _downloadsInitialized = true;

  /// 当前是否正在浏览本地歌曲合集（决定下载进度要不要触发重建）。
  bool _browsingLocalSongs = false;

  /// 播放历史列表滚动控制器（常显滚动条，支持手拖定位）。
  final ScrollController _historyScrollController = ScrollController();

  /// 本地歌曲列表滚动控制器（与历史同理，独立于列表曲目）。
  final ScrollController _localSongsScrollController = ScrollController();

  bool get _selecting => _session.selecting;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
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
    // 恢复（顺序 / 选集 / 滚动偏移）与会话内的首帧加载都在模块内，页面
    // 既不落 setState 校准，也不编排 ensure*。
    unawaited(_session.start());
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
    final downloads = context.read<DownloadService?>();
    if (!identical(downloads, _downloadService)) {
      _downloadService?.removeListener(_onDownloadsChanged);
      _downloadService = downloads;
      _downloadsSupported = downloads?.supported ?? false;
      _downloadsInitialized = downloads?.initialized ?? true;
      downloads?.addListener(_onDownloadsChanged);
    }
    // 重新可见 = 重新进入本页：刷新历史顺序（provider 通知自带重建）。
    final visible = ShellPageVisibility.maybeVisibleOf(context) ?? true;
    if (visible && !_pageVisible) _session.onPageVisible();
    _pageVisible = visible;
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
    _downloadService?.removeListener(_onDownloadsChanged);
    _session.removeListener(_onSessionChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    // 释放前排空最后一次滚动位置（簿记内部取消节流计时并落盘）。
    _bookkeeping.dispose();
    _session.dispose();
    _listController.dispose();
    _historyScrollController.dispose();
    _localSongsScrollController.dispose();
    super.dispose();
  }

  /// 会话状态（选择 / 模式 / 恢复完成）变化：页面重建。
  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  /// 下载服务变化：能力位 / 初始化状态变化一定重建；其余（下载进度 tick）
  /// 只在正在浏览本地歌曲时重建，避免拖整页进重建。
  void _onDownloadsChanged() {
    if (!mounted) return;
    final downloads = _downloadService;
    final supported = downloads?.supported ?? false;
    final initialized = downloads?.initialized ?? true;
    final capabilityChanged = supported != _downloadsSupported ||
        initialized != _downloadsInitialized;
    _downloadsSupported = supported;
    _downloadsInitialized = initialized;
    if (capabilityChanged || _browsingLocalSongs) setState(() {});
  }

  /// 缓存变化（清缓存 / LRU 淘汰）：重建以按新签名重算缓存行。
  void _onCacheRevision() {
    if (mounted) setState(() {});
  }

  /// 本帧的下载能力快照（本地歌曲合集的输入）。
  CollectionDownloads get _downloadsSnapshot {
    final service = _downloadService;
    return CollectionDownloads(
      records: service?.downloads ?? const <DownloadedTrack>[],
      supported: service?.supported ?? false,
      // 未注册下载服务 = 能力不可用但已「就绪」：不能永远卡住合集校准。
      initialized: service?.initialized ?? true,
    );
  }

  /// 缓存索引读取：唯一读取口可能未注册（此时按无缓存行呈现）。
  Future<Set<TrackId>> _loadCachedAudioTrackIds(List<Track> tracks) {
    final service = _localDataService;
    if (service == null) return Future.value(const <TrackId>{});
    return service.cachedAudioTrackIds(tracks);
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
    _session.openSearch();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _exitSearch() {
    _searchFocus.unfocus();
    _searchController.clear();
    _session.exitSearch();
  }

  void _enterSelection(String key) {
    HapticsService.lightImpact();
    _session.selectRow(key);
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
    _session.selection.clear();
    return true;
  }

  /// 合集行点击：桌面修饰键手势优先，其余保持既有语义（多选内切换 / 点播）。
  ///
  /// 选择语义（Ctrl / Shift / 已有多选下的切换）在会话里按行 key 解释；
  /// 这里只保留点播分支。
  void _onRowTap(
    CollectionView view,
    int index, {
    bool ctrl = false,
    bool shift = false,
  }) {
    final row = view.visibleRows[index];
    if (_session.handleRowTap(row.key, view, ctrl: ctrl, shift: shift)) {
      return;
    }
    unawaited(_playViewFrom(view, index));
  }

  void _enterReorder() {
    HapticsService.lightImpact();
    // 排序会整体重排可见顺序：会话清空多选并退出搜索态。
    _searchFocus.unfocus();
    _searchController.clear();
    _session.enterReorder();
  }

  void _exitReorder() => _session.exitReorder();

  /// 合集条目：收藏 / 播放历史 / 本地歌曲 / 各列表。按持久化顺序排列，
  /// 未记录的新列表按自然顺序（收藏 → 历史 → 本地歌曲 → 列表）追加在末尾；
  /// 下载能力不可用时不出现本地歌曲。
  ///
  /// 合集弹层按这一份解析出顺序 / 图标 / 选中态。
  List<CollectionPickerEntry> _collectionEntries(
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
    final available = <String, CollectionPickerEntry>{
      LibraryCollections.favoritesOrderKey: CollectionPickerEntry(
        key: LibraryCollections.favoritesOrderKey,
        id: LibraryCollections.favoritesSentinel,
        name: l10n.favoritesPlaylistName,
        icon: Icons.favorite_rounded,
        trackCount: favoritesCount,
        selected: selected == LibraryCollections.favoritesSentinel,
      ),
      LibraryCollections.historyOrderKey: CollectionPickerEntry(
        key: LibraryCollections.historyOrderKey,
        id: LibraryCollections.historySentinel,
        name: l10n.libraryHistory,
        icon: Icons.history_rounded,
        trackCount: provider.history.length,
        selected: selected == LibraryCollections.historySentinel,
      ),
      if (showLocalSongs)
        LibraryCollections.downloadsOrderKey: CollectionPickerEntry(
          key: LibraryCollections.downloadsOrderKey,
          id: LibraryCollections.downloadsSentinel,
          name: l10n.libraryLocalSongs,
          icon: Icons.library_music_rounded,
          // 计数与列表行数同源：下载 / 导入记录 + 播放历史里的缓存行
          //（弹层打开前会先把缓存行重算到当前输入，见 _showCollectionPicker）。
          trackCount: _session.localSongsCount,
          selected: selected == LibraryCollections.downloadsSentinel,
        ),
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
          ),
    };
    final natural = <String>[
      LibraryCollections.favoritesOrderKey,
      LibraryCollections.historyOrderKey,
      if (showLocalSongs) LibraryCollections.downloadsOrderKey,
      for (final playlist in playlists)
        if (playlist.id != favoritesId) 'playlist:${playlist.id}',
    ];
    final ordered = <CollectionPickerEntry>[];
    // 持久化顺序优先，其次自然顺序；模块只返回自然顺序中存在的键
    //（已删除列表的持久化键自动忽略）。
    for (final key in LibraryCollections.applyOrder(
      natural,
      _session.collectionOrder,
    )) {
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
    await _session.ensureLocalSongsReady(
      downloads: _downloadsSnapshot,
      cacheRevision: _cacheService?.revision.value ?? -1,
    );
    if (!mounted) return;
    final outcome = await showCollectionPicker(
      context,
      title: l10n.favoritesSwitchTitle,
      entries: _collectionEntries(
        l10n,
        provider,
        playlists,
        favoritesId,
        selected,
        downloadService,
      ),
      onOrderChanged: _session.reorderCollections,
      onDelete: provider.deletePlaylist,
      onCreate: provider.createPlaylist,
      onRename: provider.renamePlaylist,
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

  /// 切换到指定合集：会话落盘旧合集滚动位置 → 选集 → 退出搜索/排序编辑态
  /// → 持久化选择 → 清空多选；页面只负责收起搜索输入。
  ///
  /// 弹层点选、链接导入、`.lxmc` 导入共用（导入完直接进入新列表）。
  void _selectCollection(int id) {
    if (!mounted) return;
    if (!_session.selectCollection(id)) return;
    _searchController.clear();
    _searchFocus.unfocus();
  }

  /// 本页动作的统一入口：端口按此刻 context 组装，命令 / 结果都在模块内。
  CollectionActions get _actions => CollectionActions(
        library: LibraryProviderCollectionActions(
          context.read<LibraryProvider>(),
        ),
        handoff: TrackHandoffCollectionHandoff(
          context,
          random: widget.shuffleRandom,
        ),
        localData: ProviderCollectionLocalData(
          downloads: context.read<DownloadService?>(),
          localData: _localDataService,
        ),
      );

  /// 从当前合集可见行的 [index] 起播（随机播放传 [shuffle]）。
  ///
  /// 播放队列组装 / 洗牌 / 上下文名 / 触感都在 TrackHandoff；页面只说「从
  /// 哪个视图的哪一行、要不要洗牌」。
  Future<void> _playViewFrom(
    CollectionView view,
    int index, {
    bool shuffle = false,
  }) =>
      _actions.play(view, startIndex: index, shuffle: shuffle);

  /// 拖动排序落位：列表重建 / 持久化顺序在动作模块（与页面原语义同一口径）。
  Future<void> _reorderTracks(CollectionView view, int from, int to) async {
    HapticsService.lightImpact();
    _reportMutation(await _actions.reorder(view, from, to));
  }

  /// 合集弹层的「导入收藏」：.lxmc 文件 或 平台歌单 / 收藏夹链接。
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
                style: sheetContext.typeScale.titleMedium,
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

  /// 内置平台歌单 / 收藏夹链接导入：选平台 + 粘贴链接/ID → 拉取并存入本地列表。
  Future<void> _importFromLink(DiscoverProvider discover) async {
    final l10n = _l10n(context);
    final channels = [
      for (final key in discover.sourceKeys)
        (key: key, name: discover.sourceDisplayName(key)),
    ];
    final input = await showLinkImportDialog(context, channels: channels);
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

  Future<void> _confirmClearHistory(AppLocalizations l10n) async {
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
      _reportMutation(await _actions.clearHistory());
    }
  }

  List<CollectionRow> _selectedRows(CollectionView view) =>
      _session.selectedRows(view);

  /// 多选写入的统一收口：会话只在成功时清空选择，失败保留选择并提示。
  Future<void> _applySelection(
    CollectionView view,
    Future<LibraryMutationOutcome> Function(List<CollectionRow> rows) write,
  ) async {
    final outcome = await _session.applySelection(view, write);
    _reportMutation(outcome);
  }

  /// 写失败提示（原始异常只进日志，界面只说「操作失败」）。
  void _reportMutation(LibraryMutationOutcome outcome) {
    if (!outcome.isFailure || !mounted) return;
    M3ESnackbar.show(context, message: _l10n(context).operationFailed);
  }

  Future<void> _mutate(Future<LibraryMutationOutcome> Function() write) async {
    _reportMutation(await write());
  }

  /// 行动作的统一反馈包装：命令返回类型化结果，页面只负责提示失败。
  Future<void> Function()? _reported(
    Future<LibraryMutationOutcome> Function()? write,
  ) =>
      write == null ? null : () => _mutate(write);

  /// 本地删除的反馈：缓存行沿用原提示（写入中 / 无缓存），失败统一提示。
  void _reportLocalDelete(CollectionLocalDeleteOutcome outcome) {
    if (!mounted) return;
    final l10n = _l10n(context);
    final notification = context.read<NotificationService?>();
    for (final item in outcome.items) {
      switch (item.status) {
        case CollectionLocalDeleteStatus.skipped:
          notification?.showSnackBar(
            item.skippedFiles > 0
                ? l10n.trackInfoCachePlaying
                : l10n.trackCacheEmpty,
          );
        case CollectionLocalDeleteStatus.deleted:
        case CollectionLocalDeleteStatus.removed:
        case CollectionLocalDeleteStatus.cleared:
        case CollectionLocalDeleteStatus.failed:
        case CollectionLocalDeleteStatus.unavailable:
          break;
      }
    }
    if (outcome.hasFailure) {
      M3ESnackbar.show(context, message: l10n.operationFailed);
    }
  }

  /// 多选收藏 / 取消收藏：加 / 删意图由当前收藏状态推导（行联合提供曲目
  /// 快照与收藏键），三种行只有这一条写路径。
  Future<void> _setSelectedFavorite(CollectionView view) async {
    final actions = _actions;
    await _applySelection(
      view,
      (rows) => actions.setFavorite(
        rows,
        change: actions.favoriteChange(rows),
      ),
    );
  }

  Future<void> _removeSelectedFromPlaylist(CollectionView view) async {
    final actions = _actions;
    await _applySelection(
      view,
      (rows) => actions.removeFromPlaylist(view, rows),
    );
  }

  Future<void> _deleteSelectedHistory(CollectionView view) async {
    final actions = _actions;
    await _applySelection(view, actions.deleteHistory);
  }

  /// 本地歌曲多选删除：下载副本删文件、导入项只移除记录、缓存行清缓存
  /// （统一确认一次；全部处理完才清空选择）。
  Future<void> _deleteSelectedLocalSongs(CollectionView view) async {
    final actions = _actions;
    final selected = actions.localSongsOf(_selectedRows(view));
    if (selected.isEmpty || !actions.localDataAvailable) return;
    final confirmed = await _confirmDeleteLocalSongs(selected);
    if (confirmed != true || !mounted) return;
    final outcome = await actions.deleteLocalSongs(selected);
    if (!mounted) return;
    _reportLocalDelete(outcome);
    _session.selection.clear();
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
    final copied = await _actions.copyToLibrary(view, _selectedRows(view));
    if (copied && mounted) _session.selection.clear();
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

    // 会话是 build 里唯一的「状态机」：身份解析、ensure 加载、恢复校准、
    // 加载组合、选择失效与滚动键激活都在 sync 内完成，页面只消费结果。
    final sessionView = _session.sync(
      CollectionSessionInput(
        library: LibraryCollectionReader(provider),
        names: CollectionNames(
          favorites: l10n.favoritesPlaylistName,
          history: l10n.libraryHistory,
          localSongs: l10n.libraryLocalSongs,
        ),
        query: _searchController.text,
        downloads: _downloadsSnapshot,
        cacheRevision: _cacheService?.revision.value ?? -1,
      ),
    );
    final view = sessionView.view;
    final reorderActive = sessionView.reorderActive;
    // 下载进度只在该合集可见时需要重建（见 _onDownloadsChanged）。
    _browsingLocalSongs = view.isLocalSongs;

    // 合集切换只有标题行弹层一个入口：条目不额外解析一份，弹层打开时按
    // 当下 provider 状态现算。
    final listColumn = Column(
      children: [
        _selecting
            ? _buildSelectionBar(context, l10n, view)
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
          child: sessionView.isLoading
              ? const Center(child: M3ELoadingIndicator())
              : sessionView.hasFailed
                  ? _buildReadFailed(context, l10n)
                  : _buildBody(
                      context,
                      l10n,
                      view,
                      reorderActive: reorderActive,
                    ),
        ),
      ],
    );

    return PopScope(
      canPop: !_selecting && !_session.searching && !reorderActive,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          _session.selection.clear();
          return;
        }
        if (reorderActive) {
          _exitReorder();
          return;
        }
        if (_session.searching) _exitSearch();
      },
      child: ResponsivePageContainer(
        pageType: ResponsivePageType.browse,
        alignment: Alignment.topCenter,
        child: listColumn,
      ),
    );
  }

  /// 资料库读取失败：给出错误 + 重试，而不是把失败伪装成空资料库。
  Widget _buildReadFailed(BuildContext context, AppLocalizations l10n) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.libraryLoadFailed, style: context.typeScale.bodyLarge),
          const SizedBox(height: 12),
          M3EButton.filled(
            onPressed: _session.retry,
            child: Text(l10n.retryButton),
          ),
        ],
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
    if (_session.searching) return _buildSearchHeader(context, l10n, view);
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
              // 透明底 M3ECard 只借它的交互层：hover / press 状态、焦点环与
              // Enter/Space 激活（裸 InkWell 没有键盘语义）。
              child: M3ECard(
                variant: M3ECardVariant.filled,
                color: Colors.transparent,
                elevation: 0,
                borderRadius: BorderRadius.circular(12),
                padding: EdgeInsets.zero,
                onPressed: () {
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
                          // 强调字阶自带字重；字距保持合集标题的收紧口径。
                          style: context.emphasizedTypeScale.headlineSmall
                              .copyWith(letterSpacing: -0.4),
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

  /// 随机播放：在可见行内随机起点，播放编排（洗牌 / 触感 / 上下文名）都在
  /// TrackHandoff，点播与普通点击同源。
  Future<void> _playShuffledFor(CollectionView view) =>
      _playViewFrom(view, 0, shuffle: true);

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
          onChanged: (_) {
            // 过滤改变可见列表：锚点随搜索词失效（选择保留）；
            // 会话不负责重建，页面输入变化需要一次 setState。
            _session.onQueryChanged();
            setState(() {});
          },
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
                        style: context.emphasizedTypeScale.headlineSmall
                            .copyWith(letterSpacing: -0.4),
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
              style: context.typeScale.labelMedium.copyWith(
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
          // 排序改变可见顺序：锚点失效 + 重建。
          _session.setSort(value);
        } else if (value == 'reorder') {
          _enterReorder();
        } else if (value == 'clearHistory') {
          _confirmClearHistory(l10n);
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
              leading: _session.sort == sort
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
    CollectionView view,
  ) {
    final selected = _selectedRows(view);
    if (selected.isEmpty) return const [];
    // 图标 / 文案与写意图同源：全部已收藏 → 取消，否则 → 收藏。
    final favoriteChange = _actions.favoriteChange(selected);
    final allFavorited = favoriteChange == CollectionFavoriteChange.remove;
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
        onPressed: () => unawaited(_setSelectedFavorite(view)),
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
    CollectionView view,
  ) {
    final m3e = M3ETheme.of(context);
    final selectionTheme = m3e.selectionTheme;
    final foreground = selectionTheme.contextualForeground(m3e.colorScheme);
    final allSelected = _session.allSelected(view) == true;
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
                  onPressed: _session.selection.clear,
                ),
                Expanded(
                  child: Text(
                    '${_session.selection.selectedCount}',
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
                      _session.selection.clear();
                    } else {
                      _session.selection.selectAll(
                        [for (final row in view.visibleRows) row.key],
                      );
                    }
                  },
                ),
                ..._buildSelectionActions(context, l10n, view),
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
      // 行高与行渲染同档（表格 56 / 双行 72）：同一份 surface 同时决定
      // itemExtent 与行内版式，差一档滚动条拇指与拖动定位就落在错误位置上。
      surface: TrackRowSurface(tableSpec: columnSpec),
      itemBuilder: (context, row, index) => _buildRow(
        context,
        l10n,
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
          style: context.typeScale.labelSmall.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      _ => null,
    };
    return CollectionTrackRow(
      row: TrackRowModel(
        title: row.title,
        artist: row.artist,
        coverUrl: row.artworkUrl,
        album: row.album,
        // 播放时间 = 毫秒时间戳的紧凑文案（与同步日志同一格式）。
        time: switch (row) {
          HistoryCollectionRow(:final playedAt) => syncTimeText(playedAt),
          _ => '',
        },
        durationMs: row.durationMs,
        // 收藏键与播放 TrackId 同源（`sourceKey:songId`）；本地下载副本用
        // local 源键，缓存行 / 历史行保留原曲键。
        trackId: TrackId(row.favoriteKey.sourceKey, row.favoriteKey.songId),
        selected: _session.selection.isSelected(row.key),
      ),
      surface: TrackRowSurface(tableSpec: columnSpec),
      trailing: reorderActive
          ? Icon(
              Icons.drag_handle_rounded,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            )
          : cachedTag,
      position: calculateCardPosition(index, view.visibleCount),
      onTap: reorderActive ? null : () => _onRowTap(view, index),
      onTapWithModifiers: (reorderActive || !isDesktopPlatform())
          ? null
          : (ctrl, shift) => _onRowTap(view, index, ctrl: ctrl, shift: shift),
      onLongPress: reorderActive ? null : () => _enterSelection(row.key),
      actions: (reorderActive || _selecting)
          ? null
          : _rowActions(context, l10n, view, row),
    );
  }

  /// 行动作：投影器决定构成（`CollectionPresenter.rowActionsFor`），动作载荷
  /// 由 `CollectionActions.rowCommands` 按行变体归一（复制 / 换源 / 移除 /
  /// 收藏 / 删除）；页面只把回调接成提示与确认，接线缺席的动作不会出现
  /// （见 `buildCollectionRowActions`）。
  List<RowAction> _rowActions(
    BuildContext context,
    AppLocalizations l10n,
    CollectionView view,
    CollectionRow row,
  ) {
    return buildCollectionRowActions(
      l10n: l10n,
      specs: _session.rowActionsFor(row, view),
      wiring: _actionWiring(context, view, row),
    );
  }

  CollectionRowActionWiring _actionWiring(
    BuildContext context,
    CollectionView view,
    CollectionRow row,
  ) {
    final commands = _actions.rowCommands(view, row);
    final swap = commands.swap;
    final localSong = commands.localSong;
    return CollectionRowActionWiring(
      onCopy: commands.copy,
      onSwap: swap == null
          ? null
          : () => showSourceSwapPage(
                context,
                seed: swap.track,
                lyricsProvider: context.read<LyricsProvider>(),
                playlistId: swap.playlistId,
                historyKey: swap.historyKey,
              ),
      onRemoveFromPlaylist: _reported(commands.removeFromPlaylist),
      onRemoveFromFavorites: _reported(commands.removeFromFavorites),
      onToggleFavorite: _reported(commands.toggleFavorite),
      onDeleteHistory: _reported(commands.deleteHistory),
      onDeleteLocalSong:
          localSong == null ? null : () => _deleteLocalSong(localSong),
      isFavorite: commands.isFavorite,
      localSongCached: commands.localSongCached,
      localSongImported: commands.localSongImported,
    );
  }

  /// 本地歌曲单条删除（行动作入口：触摸端左滑 / 桌面右键）：先确认再按行
  /// 来源删（下载副本删文件、导入项只移出列表、缓存行清缓存）。
  Future<void> _deleteLocalSong(CollectionLocalSong song) async {
    final actions = _actions;
    if (!actions.localDataAvailable) return;
    final confirmed = await _confirmDeleteLocalSongs([song]);
    if (confirmed != true || !mounted) return;
    _reportLocalDelete(await actions.deleteLocalSongs([song]));
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

/// 会话 → 页面滚动簿记的适配：控制器与节流落盘都留在页面，会话只决定
/// 合集键和恢复时机（见 `CollectionScrollPort`）。
class _PageScrollPort implements CollectionScrollPort {
  _PageScrollPort(this._page);

  final _FavoritesPageState _page;

  @override
  void restoreOffsets(Map<String, double> offsets) =>
      _page._bookkeeping.restoreOffsets(offsets);

  @override
  void activate(String collectionKey) =>
      _page._bookkeeping.activate(collectionKey);

  @override
  void restore() => _page._bookkeeping.scheduleRestore();

  @override
  void flush() => _page._bookkeeping.flush();
}
