import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../domain/models/download.dart';
import '../../domain/models/library.dart';
import '../../domain/models/library_browse.dart';
import '../../domain/models/smart_lists.dart';
import '../../domain/models/track.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/collection_actions.dart';
import '../../providers/collection_batch_download_adapter.dart';
import '../../providers/collection_io_commands.dart';
import '../../providers/collection_presenter.dart';
import '../../providers/collection_session.dart';
import '../../providers/discover_provider.dart';
import '../../providers/library_collection_request.dart';
import '../../providers/library_collections.dart';
import '../../providers/library_outcome.dart';
import '../../providers/library_provider.dart';
import '../../providers/local_library_provider.dart';
import '../../providers/lyrics_provider.dart';
import '../../providers/playback_provider.dart';
import '../../providers/sync_provider.dart';
import '../../services/cache_service.dart';
import '../../services/download/download_manager.dart';
import '../../services/download/download_requests.dart';
import '../../services/download/download_records.dart';
import '../../services/escape_claims.dart';
import '../../services/haptics.dart';
import '../../services/library/playlist_folder_prefs.dart';
import '../../services/local_cache_index_store.dart';
import '../../services/notification_service.dart';
import '../../services/playlist/playlist_import_service.dart';
import '../../services/save_as.dart';
import '../../services/track_local_data_service.dart';
import '../../utils/responsive.dart';
import '../../utils/scroll_to_top.dart';
import '../../utils/smart_list_rows.dart';
import '../../widgets/collection_handoff.dart';
import '../../widgets/collection_scroll_bookkeeping.dart';
import '../../widgets/collection_track_list.dart';
import '../../widgets/cross_fade_swap.dart';
import '../../widgets/desktop_layout.dart';
import '../../widgets/local_audio_import.dart' show importLocalAudioFilesFlow;
import '../../widgets/playlist_sheets.dart';
import '../../widgets/shell_page_visibility.dart';
import '../../widgets/shell_reselect.dart';
import '../../widgets/track_row.dart';
import 'favorites_actions.dart';
import 'favorites_body.dart';
import 'favorites_header.dart';
import 'favorites_import.dart';
import 'favorites_local_actions.dart';
import 'favorites_models.dart';
import 'favorites_picker.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本页而不注册 delegate，
/// 此时回退到简体中文（与 lxmc_import / 其他页面同一约定）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 「收藏」页：默认收藏（♥）与已导入/自建列表、播放历史、本地歌曲的
/// 统一管理入口。
///
/// - 标题行即合集切换器（弹层内可新建/重命名/删除列表、拖动排序合集，
///   并提供「导入收藏」：.lxmc 文件 / 平台歌单 / 收藏夹链接）；
///   默认落在有曲目的收藏，收藏为空时回退到第一个非空列表；
/// - 宽屏表格列：内容宽（窗口宽 − 栏宽）够时曲目 / 历史 / 本地歌曲列表
///   显示表头与列（播放历史多一列「播放时间」），窄窗口回落双行列表；
/// - 曲目行：点击播放；行尾显示歌曲时长；⋮ 菜单（桌面右键）提供
///   （「加入列表」含我的收藏 / 播放历史 / 自建列表）；长按进入多选；
/// - 标题右侧提供随机播放 / 搜索两个图标（播放/暂停在顶栏迷你条，
///   整表播放走随机或点行）；搜索按钮展开搜索栏
///   （日常不占用行高），排序与「调整顺序」收在搜索栏的 ⋮ 菜单里；
///   本地歌曲合集多一个「导入本地歌曲」按钮；
/// - 自建列表支持「调整顺序」模式：长按拖动曲目落位即持久化；
/// - 播放历史支持单条删除（⋮ 菜单）与批量删除（多选）。
/// - 壳层底栏 / 导航轨长按「收藏」= 切到本页并定位当前播放曲目
///   （当前可见行里找；找不到 / 没在播 / 曲库浏览给底栏提示）。
/// - 本地歌曲（下载副本 + 导入的本地文件）来自下载记录：
///   下载副本删除会删文件，导入项只从列表移除。
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({
    super.key,
    this.shuffleRandom,
    this.reselect,
    this.locatePlaying,
  });

  /// 随机播放起点随机源（测试注入种子；默认系统随机源）。
  final math.Random? shuffleRandom;

  /// 壳层「重复点击底栏 / 导航轨收藏目的地」的请求通道：
  /// 当前合集的列表回到顶部。
  final ShellReselectSignal? reselect;

  /// 壳层「长按收藏目的地」的请求通道：定位当前播放曲目。
  ///
  /// 壳层负责先切到收藏页；页面在下一次 build 里按当帧可见行算下标，
  /// 列表布局完成后滚到视口中央（见 [_FavoritesPageState._locateCurrentTrack]）。
  final ShellLongPressSignal? locatePlaying;

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
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
    scroll: FavoritesPageScrollPort(
      restoreOffsetsCallback: (offsets) => _bookkeeping.restoreOffsets(offsets),
      activateCallback: (key) => _bookkeeping.activate(key),
      restoreCallback: () => _bookkeeping.scheduleRestore(),
      flushCallback: () => _bookkeeping.flush(),
    ),
    loadCachedAudioTrackIds: _loadCachedAudioTrackIds,
  );

  /// 滚动簿记：按合集键保存 / 恢复滚动偏移（防抖落盘 + 只恢复一次）。
  late final CollectionScrollBookkeeping _bookkeeping =
      CollectionScrollBookkeeping(
        controllerOf: _scrollControllerForKey,
        persist: _session.persistScrollOffsets,
      );

  /// 上次观察到的壳层可见性：隐藏 → 可见 = 重新进入收藏页，刷新播放历史
  /// 顺序（顺序在停留期间冻结，见 LibraryProvider）。未挂壳层的单测按可见。
  bool _pageVisible = true;

  /// 一次「定位当前播放曲目」请求：在列表数据 / 布局就绪后消费。
  ///
  /// 跨页长按时壳层先切页，本页要等下一帧才可见、列表才有滚动客户端；
  /// 加载中也先挂起，避免把请求丢在骨架屏上。
  bool _locatePending = false;

  /// 智能列表的重复版本展开（按代表行 key）与当前计数。
  final Set<String> _expandedSmartVersions = {};
  Map<String, int> _smartVersionCounts = const {};
  String _smartVersionSignature = '';

  /// 缓存服务（可能未注册）：缓存 revision 联动（清缓存 / LRU 淘汰后重算缓存行）。
  CacheService? _cacheService;

  /// 本地数据唯一读取口（可能未注册）：批量判定历史曲目的音频两档状态。
  TrackLocalDataService? _localDataService;

  /// 跨页面「打开智能列表」请求（下载维护 → 文件不见）。
  LibraryCollectionRequest? _collectionRequest;

  /// 下载记录（可能未注册）：只在记录 / 能力 / 初始化变化（低频）时重建。
  /// 记录 revision 随本地歌曲输入一起交给状态机做失效判定。
  DownloadRecords? _downloadRecords;

  /// 设备本地缓存索引（可能未注册）：缓存完成 / 对账 / 移除时重建。
  LocalCacheIndexStore? _cacheIndex;

  /// 曲库分组缓存（索引 / 模式 / 语言都没变时复用分组）。
  final FavoritesBrowseGroupsCache _browseGroups = FavoritesBrowseGroupsCache();

  /// 列表分组收起状态（设备本地；合集弹层共用这一个持有者）。
  late final PlaylistFolderCollapseController _folderCollapse =
      PlaylistFolderCollapseController();

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
    widget.locatePlaying?.addListener(_handleLocatePlaying);
    // 恢复（顺序 / 选集 / 滚动偏移）与会话内的首帧加载都在模块内，页面
    // 既不落 setState 校准，也不编排 ensure*。
    unawaited(_session.start());
    _folderCollapse.addListener(_onFolderCollapseChanged);
    unawaited(_folderCollapse.load());
  }

  void _onFolderCollapseChanged() {
    if (mounted) setState(() {});
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
    final request = context.read<LibraryCollectionRequest?>();
    if (!identical(request, _collectionRequest)) {
      _collectionRequest?.removeListener(_onCollectionRequest);
      _collectionRequest = request;
      request?.addListener(_onCollectionRequest);
      _onCollectionRequest();
    }
    final records = context.read<DownloadRecords?>();
    if (!identical(records, _downloadRecords)) {
      _downloadRecords?.removeListener(_onDownloadsChanged);
      _collectionRequest?.removeListener(_onCollectionRequest);
      _downloadRecords = records;
      records?.addListener(_onDownloadsChanged);
    }
    final cacheIndex = context.read<LocalCacheIndexStore?>();
    if (!identical(cacheIndex, _cacheIndex)) {
      _cacheIndex?.removeListener(_onCacheIndexChanged);
      _cacheIndex = cacheIndex;
      cacheIndex?.addListener(_onCacheIndexChanged);
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
    if (oldWidget.locatePlaying != widget.locatePlaying) {
      oldWidget.locatePlaying?.removeListener(_handleLocatePlaying);
      widget.locatePlaying?.addListener(_handleLocatePlaying);
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
    widget.locatePlaying?.removeListener(_handleLocatePlaying);
    _cacheService?.revision.removeListener(_onCacheRevision);
    _downloadRecords?.removeListener(_onDownloadsChanged);
    _cacheIndex?.removeListener(_onCacheIndexChanged);
    _collectionRequest?.removeListener(_onCollectionRequest);
    _folderCollapse
      ..removeListener(_onFolderCollapseChanged)
      ..dispose();
    _session.removeListener(_onSessionChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    // 释放前排空最后一次滚动位置（簿记内部取消防抖计时并落盘）。
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

  void _onCollectionRequest() {
    final id = _collectionRequest?.take();
    if (id == null || !mounted) return;
    _selectCollection(LibraryCollections.smartSentinelFor(id));
  }

  /// 下载记录变化（低频：完成 / 删除 / 导入 / 启动加载 / 能力变化）：
  /// 重建后由记录 revision 让本地歌曲状态机决定是否重算缓存行。
  void _onDownloadsChanged() {
    if (mounted) setState(() {});
  }

  /// 缓存变化（清缓存 / LRU 淘汰）：重建以按新签名重算缓存行。
  void _onCacheRevision() {
    if (mounted) setState(() {});
  }

  /// 缓存索引变化（完成 / 对账 / 移除）：与列表 / 计数同帧重建。
  void _onCacheIndexChanged() {
    if (mounted) setState(() {});
  }

  /// 本帧的缓存索引快照（本地歌曲合集的输入）。
  CollectionCacheIndex get _cacheIndexSnapshot {
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
  CollectionDownloads get _downloadsSnapshot {
    final records = _downloadRecords;
    return CollectionDownloads(
      records: records?.downloads ?? const <DownloadedTrack>[],
      supported: records?.supported ?? false,
      // 未注册下载记录 = 能力不可用但已「就绪」：不能永远卡住合集校准。
      initialized: records?.initialized ?? true,
      recordsRevision: records?.revision ?? 0,
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

  /// 壳层长按「收藏」目的地：请求定位当前播放曲目。
  ///
  /// 只挂起意图，不在这里算行下标：跨页切回来时本页下一帧才可见，列表也要
  /// 等这一帧布局完才有滚动客户端；加载中则等数据就绪后的下一次 build。
  void _handleLocatePlaying() {
    if (!mounted) return;
    setState(() => _locatePending = true);
  }

  /// 在当前可见行里找正在播放的曲目：找到滚到视口中央，找不到给底栏提示。
  ///
  /// 行身份与 `TrackRow` 的当前曲目判定同源（`TrackId` ↔ `favoriteKey`）：
  /// 收藏 / 历史 / 本地歌曲三种行共用这一条匹配，不按合集种类分支。
  void _locateCurrentTrack(
    CollectionView view,
    List<CollectionRow> rows,
    TrackRowSurface surface,
  ) {
    final l10n = _l10n(context);
    final trackId = context.read<PlaybackProvider?>()?.currentTrackId;
    if (trackId == null) {
      _showLocateMessage(l10n.favoritesLocateNoTrack);
      return;
    }
    final index = rows.indexWhere(
      (row) =>
          row.favoriteKey.sourceKey == trackId.sourceKey &&
          row.favoriteKey.songId == trackId.id,
    );
    if (index < 0) {
      _showLocateMessage(l10n.favoritesLocateMissing);
      return;
    }
    final controller = _scrollControllerForKey(view.collectionKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      CollectionTrackList.revealIndex(
        context,
        controller,
        index: index,
        surface: surface,
      );
    });
  }

  /// 定位类提示：build 内只登记，帧后弹（build 里不能弹底栏）。
  void _showLocateMessage(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      M3ESnackbar.show(context, message: message);
    });
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

  /// 行长按：不在多选时进入多选；已经在多选时把长按行作为区间终点。
  ///
  /// 触摸端没有 Shift，长按承担桌面 Shift 点击的第二段手势；锚点由上一次
  /// 普通点击 / 长按落下（见 `CollectionSelection.anchorKey`）。
  void _onRowLongPress(CollectionView view, String key) {
    HapticsService.lightImpact();
    if (_session.selecting && _session.selectionAnchorKey != null) {
      _session.selectRangeTo(view, key);
      return;
    }
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
    _session.clearSelection();
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
    library: LibraryProviderCollectionActions(context.read<LibraryProvider>()),
    handoff: TrackHandoffCollectionHandoff(
      context,
      random: widget.shuffleRandom,
    ),
    localData: ProviderCollectionLocalData(
      downloads: context.read<DownloadManager?>(),
      localData: _localDataService,
    ),
  );

  /// 合集 I/O 命令：端口按此刻 context 组装，编排 / 类型化结果都在模块。
  CollectionIoCommands _ioCommands({
    DiscoverProvider? discover,
    DownloadRequests? requests,
    SyncProvider? sync,
    SaveAs? saveAs,
  }) {
    final provider = context.read<LibraryProvider>();
    final records = context.read<DownloadRecords?>();
    const files = FilePickerCollectionPlaylistFiles();
    return CollectionIoCommands(
      filePicker: files,
      fileReader: files,
      importService: PlaylistImportService(
        localImporter: DownloadRecordsPlaylistLocalImporter(
          records,
          context.read<DownloadManager?>(),
        ),
        resolver: LibraryPlaylistKeyResolver(provider, records),
      ),
      importTarget: LibraryProviderPlaylistImportTarget(provider),
      playlistNames: () => [for (final item in provider.playlists) item.name],
      reviewImport: (plan) async =>
          (await showPlaylistImportReviewSheet(context, plan: plan)) == true,
      linkImporter: discover == null
          ? null
          : DiscoverCollectionLinkImporter(discover),
      exportLibrary: LibraryProviderCollectionExportLibrary(provider, records),
      backup: sync == null ? null : SyncCollectionPlaylistBackup(sync),
      saver: saveAs == null ? null : SaveAsCollectionExportSaver(saveAs),
      downloader: requests == null
          ? null
          : RequestsCollectionBatchDownloader(requests),
    );
  }

  /// 从当前合集可见行的 [index] 起播（随机播放传 [shuffle]）。
  Future<void> _playViewFrom(
    CollectionView view,
    int index, {
    bool shuffle = false,
  }) => playFavoritesView(
    actions: _actions,
    view: view,
    index: index,
    shuffle: shuffle,
  );

  /// 拖动排序落位：列表重建 / 持久化顺序在动作模块。
  Future<void> _reorderTracks(CollectionView view, int from, int to) =>
      reorderFavoritesTracks(
        actions: _actions,
        view: view,
        from: from,
        to: to,
        reportMutation: _reportMutation,
      );

  /// 合集弹层的「导入收藏」：.lxmc 文件 或 平台歌单 / 收藏夹链接。
  Future<void> _importCollection() => importFavoritesCollection(
    context: context,
    l10n: _l10n(context),
    discover: context.read<DiscoverProvider?>(),
    isActive: () => mounted,
    selectCollection: _selectCollection,
    ioCommands: _ioCommands,
  );

  List<CollectionRow> _selectedRows(CollectionView view) =>
      _session.selectedRows(view);

  /// 写失败提示（原始异常只进日志，界面只说「操作失败」）。
  void _reportMutation(LibraryMutationOutcome outcome) {
    if (!outcome.isFailure || !mounted) return;
    M3ESnackbar.show(context, message: _l10n(context).operationFailed);
  }

  /// 选中行里「现在就能下载」的曲目（本地 / 已下载 / 进行中都不算）。
  List<Track> _selectedDownloadableTracks(CollectionView view) {
    final requests = context.read<DownloadRequests?>();
    if (requests == null) return const [];
    return favoritesDownloadableTracks(
      view: view,
      selectedRows: _selectedRows(view),
      provider: context.read<LibraryProvider>(),
      requests: requests,
    );
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

    final smartRows = context
        .select<LocalLibraryProvider?, Map<String, List<CollectionRow>>>(
          (provider) => provider?.smartRows ?? const {},
        );
    // 会话是 build 里唯一的「状态机」：身份解析、ensure 加载、恢复校准、
    // 加载组合、选择失效与滚动键激活都在 sync 内完成，页面只消费结果。
    final sessionView = _session.sync(
      CollectionSessionInput(
        library: LibraryCollectionReader(provider),
        names: CollectionNames(
          favorites: l10n.favoritesPlaylistName,
          history: l10n.libraryHistory,
          localSongs: l10n.libraryLocalSongs,
          libraryBrowse: l10n.libraryBrowseTitle,
          smartLists: smartListNames(l10n),
        ),
        smartRows: smartRows,
        query: _searchController.text,
        downloads: _downloadsSnapshot,
        cacheIndex: _cacheIndexSnapshot,
        cacheRevision: _cacheService?.revision.value ?? -1,
      ),
    );
    final view = sessionView.view;
    final reorderActive = sessionView.reorderActive;

    // 正文四态：加载骨架 / 读取失败 / 曲库浏览 / 合集正文。骨架 / 失败 /
    // 正文原本是硬切，现在统一走同一套 effects 时长交叉淡化。
    final surface = sessionView.isLoading
        ? FavoritesCollectionSurface.loading
        : sessionView.hasFailed
        ? FavoritesCollectionSurface.failed
        : view.isLibraryBrowse
        ? FavoritesCollectionSurface.libraryBrowse
        : FavoritesCollectionSurface.body;

    // 长按定位请求：加载中挂起（数据就绪后的下一次 build 再消费）；曲库
    // 浏览没有歌曲列表，直接提示先选列表；读取失败已有失败态，清掉即可。
    if (_locatePending &&
        (surface == FavoritesCollectionSurface.failed ||
            surface == FavoritesCollectionSurface.libraryBrowse)) {
      _locatePending = false;
      if (surface == FavoritesCollectionSurface.libraryBrowse) {
        _showLocateMessage(l10n.favoritesLocateUnavailable);
      }
    }

    final headerData = _headerData(
      context: context,
      l10n: l10n,
      view: view,
      playlists: playlists,
      favoritesId: favoritesId,
      frame: sessionView.frame,
      reorderActive: reorderActive,
    );
    // 合集切换只有标题行弹层一个入口：条目不额外解析一份，弹层打开时按
    // 当下 provider 状态现算。
    final content = Column(
      children: [
        // 标题行 / 搜索行 / 多选栏同高：两态交叉淡入淡出，头部不跳高，
        // 离场层不吃点击（多选栏入场 / 退场不误触下面的按钮）。
        FavoritesHeaderCrossFade(
          selecting: _selecting,
          idle: buildFavoritesIdleHeader(context, headerData),
          selection: buildFavoritesSelectionBar(
            context,
            _selectionHeaderData(context: context, l10n: l10n, view: view),
          ),
        ),
        Expanded(
          // 状态标识只看「哪一态」：同一态内的刷新（列表数据、选择、排序）
          // 不换 key、不重播过渡。
          child: CrossFadeSwap(
            value: surface,
            child: switch (surface) {
              FavoritesCollectionSurface.loading => const Center(
                child: M3ELoadingIndicator(),
              ),
              FavoritesCollectionSurface.failed => buildFavoritesReadFailed(
                context,
                l10n: l10n,
                onRetry: () => _session.retry(sessionView.frame),
              ),
              FavoritesCollectionSurface.libraryBrowse =>
                buildFavoritesLibraryBrowse(
                  context,
                  l10n: l10n,
                  query: _searchController.text,
                  groupsCache: _browseGroups,
                  onPlay: (group, tracks, {bool shuffle = false}) =>
                      playFavoritesBrowseTracks(
                        context: context,
                        tracks: tracks,
                        contextName: group.subtitle.isEmpty
                            ? group.title
                            : '${group.title} · ${group.subtitle}',
                        random: widget.shuffleRandom,
                        shuffle: shuffle,
                      ),
                  onPlayTrack: (track) => playFavoritesBrowseTracks(
                    context: context,
                    tracks: [track],
                    contextName: track.title,
                    random: widget.shuffleRandom,
                  ),
                  onAdd: (tracks) => addFavoritesBrowseToLibrary(
                    context: context,
                    tracks: tracks,
                  ),
                  onToggleFavorite: (track) async {
                    await _actions.toggleFavorite([
                      TrackCollectionRow(track.toPlaylistTrack(addedAt: 0)),
                    ]);
                  },
                  onRefreshLocal: (track) =>
                      _refreshBrowseLocal(context, l10n, track),
                  onSwap: (track) => swapFavoritesBrowseTrack(
                    context: context,
                    track: track,
                    lyrics: context.read<LyricsProvider>(),
                  ),
                  isFavorite: (track) => context
                      .read<LibraryProvider>()
                      .isFavorite(track.sourceKey, track.songId),
                  canRefreshLocal: (track) => _localRecordOf(track) != null,
                ),
              FavoritesCollectionSurface.body => _buildCollectionBody(
                context,
                l10n,
                view,
                reorderActive: reorderActive,
              ),
            },
          ),
        ),
      ],
    );
    return PopScope(
      canPop: !_selecting && !_session.searching && !reorderActive,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          _session.clearSelection();
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
        child: content,
      ),
    );
  }

  /// 标题行 / 搜索行 / 多选栏需要的值 + 回调（依赖显式交给头部模块）。
  FavoritesHeaderData _headerData({
    required BuildContext context,
    required AppLocalizations l10n,
    required CollectionView view,
    required List<PlaylistInfo> playlists,
    required int? favoritesId,
    required CollectionFrame frame,
    required bool reorderActive,
  }) {
    PlaylistInfo? currentPlaylist;
    for (final playlist in playlists) {
      if (playlist.id == view.playlistId) {
        currentPlaylist = playlist;
        break;
      }
    }
    final libraryIndex = view.isLibraryBrowse
        ? context.select<LocalLibraryProvider?, LibraryBrowseIndex?>(
            (provider) => provider?.snapshot?.index,
          )
        : null;
    final byTime = view.isSmartList
        ? context.select<LocalLibraryProvider?, bool>(
            (provider) =>
                provider?.mostPlayedMetric == SmartListMetric.listeningTime,
          )
        : false;
    final requests = context.read<DownloadRequests?>();
    return FavoritesHeaderData(
      l10n: l10n,
      view: view,
      currentPlaylist: currentPlaylist,
      searching: _session.searching,
      reorderActive: reorderActive,
      sort: _session.sort,
      libraryIndex: libraryIndex,
      mostPlayedByTime: byTime,
      canDownloadPlaylist: requests != null,
      searchController: _searchController,
      searchFocus: _searchFocus,
      onOpenPicker: () => unawaited(
        _showCollectionPicker(
          l10n,
          frame,
          playlists,
          favoritesId,
          view.selectedId,
        ),
      ),
      onPlayShuffled: () => unawaited(_playViewFrom(view, 0, shuffle: true)),
      onOpenSearch: _openSearch,
      onExitSearch: _exitSearch,
      onQueryChanged: () {
        // 过滤改变可见列表：锚点随搜索词失效（选择保留）。
        _session.onQueryChanged();
        setState(() {});
      },
      onExitReorder: _exitReorder,
      onEnterReorder: _enterReorder,
      onSortChanged: _session.setSort,
      onToggleMostPlayedMetric: () {
        context.read<LocalLibraryProvider?>()?.setMostPlayedMetric(
          byTime ? SmartListMetric.playCount : SmartListMetric.listeningTime,
        );
      },
      onImportLocal: () => unawaited(importLocalAudioFilesFlow(context)),
      onCheckLocalCache: () {
        final index = context.read<LocalCacheIndexStore?>();
        final cache = context.read<CacheService?>();
        unawaited(
          checkFavoritesLocalCache(
            context: context,
            l10n: l10n,
            index: index,
            cache: cache,
            library: context.read<LibraryProvider>(),
            isActive: () => mounted,
          ),
        );
      },
      onEditDetails: () {
        if (currentPlaylist != null) {
          unawaited(
            editFavoritesPlaylistDetails(
              context: context,
              playlist: currentPlaylist,
              playlists: playlists,
              provider: context.read<LibraryProvider>(),
              isActive: () => mounted,
              onSaved: () => setState(() {}),
            ),
          );
        }
      },
      onChangeCover: () {
        if (currentPlaylist != null) {
          unawaited(
            changeFavoritesPlaylistCover(
              context: context,
              playlist: currentPlaylist,
              provider: context.read<LibraryProvider>(),
              isActive: () => mounted,
            ),
          );
        }
      },
      onExport: () {
        if (currentPlaylist != null) {
          unawaited(
            exportFavoritesPlaylist(
              context: context,
              l10n: l10n,
              playlist: currentPlaylist,
              view: view,
              ioCommands: _ioCommands,
              isActive: () => mounted,
            ),
          );
        }
      },
      onDownloadPlaylist: () {
        final activeRequests = context.read<DownloadRequests?>();
        if (activeRequests == null) return;
        unawaited(
          downloadFavoritesPlaylist(
            context: context,
            l10n: l10n,
            view: view,
            provider: context.read<LibraryProvider>(),
            ioCommands: () => _ioCommands(requests: activeRequests),
            isActive: () => mounted,
          ),
        );
      },
      onClearHistory: () => unawaited(
        confirmClearFavoritesHistory(
          context: context,
          l10n: l10n,
          clearHistory: _actions.clearHistory,
          reportMutation: _reportMutation,
        ),
      ),
    );
  }

  /// 多选栏需要的值 + 回调。
  FavoritesSelectionHeaderData _selectionHeaderData({
    required BuildContext context,
    required AppLocalizations l10n,
    required CollectionView view,
  }) {
    final selectedRows = _selectedRows(view);
    final allFavorited =
        selectedRows.isNotEmpty &&
        _actions.favoriteChange(selectedRows) ==
            CollectionFavoriteChange.remove;
    final hasDownloadable =
        selectedRows.isNotEmpty && _selectedDownloadableTracks(view).isNotEmpty;
    return FavoritesSelectionHeaderData(
      l10n: l10n,
      view: view,
      selectedCount: _session.selectedCount,
      allSelected: _session.allSelected(view) == true,
      allFavorited: allFavorited,
      hasDownloadable: hasDownloadable,
      onClose: _session.clearSelection,
      onSelectAll: () => _session.selectAllVisible(view),
      onCopyToPlaylist: () => unawaited(
        copyFavoritesSelectionToPlaylist(
          session: _session,
          actions: _actions,
          view: view,
        ),
      ),
      onRemoveFromPlaylist: () => unawaited(
        removeFavoritesSelectionFromPlaylist(
          session: _session,
          actions: _actions,
          view: view,
          reportMutation: _reportMutation,
        ),
      ),
      onDeleteHistory: () => unawaited(
        deleteFavoritesSelectionHistory(
          session: _session,
          actions: _actions,
          view: view,
          reportMutation: _reportMutation,
        ),
      ),
      onDeleteLocalSongs: () => unawaited(
        deleteFavoritesSelectedLocalSongs(
          context: context,
          l10n: l10n,
          view: view,
          session: _session,
          actions: _actions,
          notification: context.read<NotificationService?>(),
          isActive: () => mounted,
        ),
      ),
      onToggleFavorite: () => unawaited(
        setFavoritesSelectionFavorite(
          session: _session,
          actions: _actions,
          view: view,
          reportMutation: _reportMutation,
        ),
      ),
      onDownloadSelected: () async {
        final requests = context.read<DownloadRequests?>();
        if (requests == null) return;
        await downloadFavoritesSelection(
          context: context,
          l10n: l10n,
          view: view,
          selectedRows: selectedRows,
          provider: context.read<LibraryProvider>(),
          requests: requests,
          session: _session,
          ioCommands: () => _ioCommands(requests: requests),
          isActive: () => mounted,
        );
      },
    );
  }

  /// 合集正文：表格列 / 智能列表展开行 / 长按定位都在这一帧落定。
  Widget _buildCollectionBody(
    BuildContext context,
    AppLocalizations l10n,
    CollectionView view, {
    required bool reorderActive,
  }) {
    // 行 / 表头同一份列规范：只有播放历史多一列「播放时间」，其余合集与
    // 搜索 / 发现详情同档；判定按规范取阈值（行高也从同一份 spec 派生）。
    final spec = view.isHistory
        ? TrackRowColumnSpec.history
        : TrackRowColumnSpec.standard;
    final columnSpec = DesktopLayout.of(context).tableColumnsFor(spec)
        ? spec
        : null;
    // 智能列表按展示层重复聚类：代表行 + 展开后的版本行；不删除任何记录。
    final rows = view.isSmartList ? _smartDisplayRows(view) : view.visibleRows;
    final rowSurface = TrackRowSurface(tableSpec: columnSpec);
    // 长按定位：此刻可见行与行高都定了，算下标并安排帧后滚动 / 提示。
    if (_locatePending) {
      _locatePending = false;
      _locateCurrentTrack(view, rows, rowSurface);
    }
    return buildFavoritesBody(
      context,
      FavoritesBodyData(
        l10n: l10n,
        view: view,
        rows: rows,
        columnSpec: columnSpec,
        reorderActive: reorderActive,
        selecting: _selecting,
        controller: _scrollControllerForKey(view.collectionKey),
        smartVersionCounts: _smartVersionCounts,
        isSelected: _session.isSelected,
        isMissingRow: (row) =>
            view.isSmartList &&
            view.identity.smartListId == SmartListIds.missingFiles &&
            row is LocalSongCollectionRow &&
            row.song.isMissing,
        onToggleSmartVersions: _toggleSmartVersions,
        onRowTap: (index) => _onRowTap(view, index),
        onRowTapWithModifiers: (index, {required ctrl, required shift}) =>
            _onRowTap(view, index, ctrl: ctrl, shift: shift),
        onRowLongPress: (key) => _onRowLongPress(view, key),
        onReorder: (from, to) => _reorderTracks(view, from, to),
        rowActionsFor: (rowContext, row) => buildFavoritesRowActions(
          context: rowContext,
          l10n: l10n,
          session: _session,
          view: view,
          row: row,
          actions: _actions,
          isActive: () => mounted,
        ),
        onImportLocal: () => unawaited(importLocalAudioFilesFlow(context)),
      ),
    );
  }

  /// 智能列表的展示行：重复组只展开一次代表行，版本行按需插入。
  List<CollectionRow> _smartDisplayRows(CollectionView view) {
    final signature =
        '${view.identity.smartListId}|${_searchController.text}|${_session.sort.name}';
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

  void _toggleSmartVersions(CollectionRow row) {
    setState(() {
      if (!_expandedSmartVersions.remove(row.key)) {
        _expandedSmartVersions.add(row.key);
      }
    });
  }

  /// 打开合集切换弹层：点行切换、新建/重命名/删除、导入收藏、
  /// 行尾把手拖动排序。
  Future<void> _showCollectionPicker(
    AppLocalizations l10n,
    CollectionFrame frame,
    List<PlaylistInfo> playlists,
    int? favoritesId,
    int selected,
  ) async {
    final provider = context.read<LibraryProvider>();
    final records = context.read<DownloadRecords?>();
    final localLibrary = context.read<LocalLibraryProvider?>();
    final outcome = await showFavoritesCollectionPicker(
      context: context,
      l10n: l10n,
      frame: frame,
      playlists: playlists,
      favoritesId: favoritesId,
      selected: selected,
      provider: provider,
      records: records,
      localSongsCount: _session.localSongsCount,
      collectionOrder: _session.collectionOrder,
      browseIndex: localLibrary?.snapshot?.index,
      smartRows: localLibrary?.smartRows ?? const {},
      folderCollapse: _folderCollapse,
      ensureLocalSongsReady: _session.ensureLocalSongsReady,
      onOrderChanged: _session.reorderCollections,
      isActive: () => mounted,
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

  Future<void> _refreshBrowseLocal(
    BuildContext context,
    AppLocalizations l10n,
    BrowseTrack track,
  ) async {
    final record = _localRecordOf(track);
    if (record == null) return;
    final manager = context.read<DownloadManager?>();
    final notifications = context.read<NotificationService?>();
    final updated = await manager?.refreshLocalMetadata(record);
    if (!mounted) return;
    notifications?.showSnackBar(
      updated == null ? l10n.localTitleFailed : l10n.localInfoUpdated,
    );
  }

  DownloadedTrack? _localRecordOf(BrowseTrack track) {
    if (track.sourceKey != kLocalSourceKey) return null;
    for (final record
        in _downloadRecords?.downloads ?? const <DownloadedTrack>[]) {
      if (record.localSongId == track.songId) return record;
    }
    return null;
  }
}
