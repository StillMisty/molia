import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/library.dart';
import '../../domain/models/smart_lists.dart';
import '../../domain/models/track.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_providers.dart';
import '../../providers/local_library_provider.dart';
import '../../providers/lyrics_provider.dart';
import '../../providers/collection_actions.dart';
import '../../providers/collection_io_commands.dart';
import '../../providers/collection_presenter.dart';
import '../../providers/collection_session.dart';
import '../../providers/discover_provider.dart';
import '../../providers/favorites_view_model.dart';
import '../../providers/library_collections.dart';
import '../../providers/library_outcome.dart';
import '../../providers/library_provider.dart';
import '../../providers/sync_provider.dart';
import '../../services/back_claims.dart';
import '../../services/download/download_requests.dart';
import '../../services/escape_claims.dart';
import '../../services/haptics.dart';
import '../../services/save_as.dart';
import '../../theme/motion_policy.dart';
import '../../widgets/responsive.dart';
import '../../widgets/collection_handoff.dart';
import '../../widgets/cross_fade_swap.dart';
import '../../widgets/local_audio_import.dart' show importLocalAudioFilesFlow;
import '../../widgets/shell_page_visibility.dart';
import '../../widgets/shell_reselect.dart';
import '../../widgets/track_row.dart';
import 'favorites_actions.dart';
import 'favorites_body.dart';
import 'favorites_escape.dart';
import 'favorites_header.dart';
import 'favorites_import.dart';
import 'favorites_local_actions.dart';
import 'favorites_models.dart';
import 'favorites_page_data.dart';
import 'favorites_picker.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本页而不注册 delegate，
/// 此时回退到简体中文（与 lxmc_import / 其他页面同一约定）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 「收藏」页：默认收藏（♥）与已导入/自建列表、播放历史、本地歌曲的
/// 统一管理入口。标题行即合集切换器（弹层内可新建 / 重命名 / 删除 /
/// 拖动排序 / 导入收藏）；宽屏按内容宽恢复表格列，窄屏双行列表；
/// 行点击播放、长按多选，壳层长按「收藏」定位当前播放曲目。
///
/// 页面只保留控件（滚动 / 焦点控制器）、[ListenableBuilder] 与 UI 回调；
/// 合集会话、设备服务订阅、智能列表展开、定位与弹层条目都在
/// [FavoritesViewModel]。
class FavoritesPage extends ConsumerStatefulWidget {
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
  /// 列表布局完成后滚到视口中央（见 [_FavoritesPageState._applyLocateResult]）。
  final ShellLongPressSignal? locatePlaying;

  @override
  ConsumerState<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends ConsumerState<FavoritesPage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// 曲目列表滚动控制器（配合常显滚动条，支持直接拖动定位）。
  final ScrollController _listController = ScrollController();

  /// 播放历史 / 本地歌曲列表滚动控制器（与列表曲目各自独立）。
  final ScrollController _historyScrollController = ScrollController();
  final ScrollController _localSongsScrollController = ScrollController();

  /// 桌面 Esc 键处理器引用：[HardwareKeyboard] 注册 / 注销必须是同一闭包。
  late final bool Function(KeyEvent) _keyHandler = _handleKeyEvent;

  /// 登记给壳层的 Esc 占用判定：与 [_handleKeyEvent] 同源。
  late final bool Function() _escapeClaim = _canHandleEscape;

  /// 返回占用判定：壳层 PopScope 收到系统返回时据此让位（多选 / 搜索 /
  /// 排序这些临时状态由本页自己的 PopScope 处理）。
  bool _backClaim() => favoritesBackClaim(
    context: context,
    selecting: _selecting,
    searching: _vm.searching,
    reordering: _vm.session.reordering,
  );

  /// 合集会话 / 服务订阅 / 智能列表展开 / 定位都在 ViewModel。
  late final FavoritesViewModel _vm = FavoritesViewModel(
    controllerOf: _scrollControllerForKey,
  );

  /// 曲库分组缓存（索引 / 模式 / 语言都没变时复用分组）。
  final FavoritesBrowseGroupsCache _browseGroups = FavoritesBrowseGroupsCache();

  /// 最近一次成功渲染的合集正文视图：同合集刷新 / 切合集时数据在途，先用它
  /// 顶住正文（顶部细进度条示意刷新），避免整块闪成居中 spinner。
  CollectionView? _lastBodyView;

  bool get _selecting => _vm.selecting;

  @override
  void initState() {
    super.initState();
    // 桌面 Esc 退出多选：页面级键处理器。壳层全局快捷键只把 Esc 交给队列
    // 面板（lib/app/desktop/desktop_shortcuts.dart），多选语义由本页补上；
    // 同时登记 Esc 占用，壳层据此让位（HardwareKeyboard 处理器不短路，不登记
    // 的话同一次 Esc 会既清选择又触发壳层命令）。
    if (isDesktopPlatform()) {
      HardwareKeyboard.instance.addHandler(_keyHandler);
      EscapeClaims.add(_escapeClaim);
    }
    BackClaims.add(_backClaim);
    _listController.addListener(_vm.saveFromScroll);
    _historyScrollController.addListener(_vm.saveFromScroll);
    _localSongsScrollController.addListener(_vm.saveFromScroll);
    widget.reselect?.addListener(_handleReselect);
    widget.locatePlaying?.addListener(_handleLocatePlaying);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _vm.attachServices(
      cacheService: ref.read(cacheServiceProvider),
      localDataService: ref.read(trackLocalDataServiceProvider),
      collectionRequest: ref.read(libraryCollectionRequestProvider),
      downloadRecords: ref.read(downloadRecordsControllerProvider),
      cacheIndex: ref.read(localCacheIndexProvider),
    );
    // 重新可见 = 重新进入本页：刷新历史顺序（provider 通知自带重建）。
    _vm.setPageVisible(ShellPageVisibility.maybeVisibleOf(context) ?? true);
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
    // dispose 看到的平台未必一致，漏注销会把已释放的 State 留在键盘链上。
    EscapeClaims.remove(_escapeClaim);
    BackClaims.remove(_backClaim);
    HardwareKeyboard.instance.removeHandler(_keyHandler);
    widget.reselect?.removeListener(_handleReselect);
    widget.locatePlaying?.removeListener(_handleLocatePlaying);
    _searchController.dispose();
    _searchFocus.dispose();
    _vm.dispose();
    _listController.dispose();
    _historyScrollController.dispose();
    _localSongsScrollController.dispose();
    super.dispose();
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

  late final VoidCallback _handleReselect = _vm.handleReselect;
  late final VoidCallback _handleLocatePlaying = _vm.requestLocate;

  /// 定位类提示：build 内只登记，帧后弹（build 里不能弹底栏）。
  void _showLocateMessage(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      M3ESnackbar.show(context, message: message);
    });
  }

  void _applyLocateResult(
    AppLocalizations l10n,
    CollectionView view,
    List<CollectionRow> rows,
    TrackRowSurface surface,
  ) => applyFavoritesLocateResult(
    context: context,
    l10n: l10n,
    result: _vm.resolveLocate(
      rows: rows,
      trackId: ref.read(playbackControllerProvider).snapshot.current?.id,
    ),
    controller: _scrollControllerForKey(view.collectionKey),
    surface: surface,
    showMessage: _showLocateMessage,
  );

  void _openSearch() {
    HapticsService.lightImpact();
    _vm.openSearch();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _exitSearch() {
    _searchFocus.unfocus();
    _searchController.clear();
    _vm.exitSearch();
  }

  /// 此刻 Esc 是否由本页接管（判定与壳层占用同源，见 favorites_escape）。
  bool _canHandleEscape() =>
      favoritesCanHandleEscape(context: context, selecting: _selecting);

  /// 桌面 Esc：退出选择模式；不接管时返回 false 放行。
  bool _handleKeyEvent(KeyEvent event) => handleFavoritesEscapeKey(
    event,
    canHandleEscape: _canHandleEscape,
    clearSelection: _vm.clearSelection,
  );

  void _enterReorder() {
    HapticsService.lightImpact();
    // 排序会整体重排可见顺序：会话清空多选并退出搜索态。
    _searchFocus.unfocus();
    _searchController.clear();
    _vm.enterReorder();
  }

  void _exitReorder() => _vm.exitReorder();

  /// 切换到指定合集：会话负责落盘旧滚动位置 / 清空多选；页面收起搜索输入。
  void _selectCollection(int id) {
    if (!mounted) return;
    if (!_vm.selectCollection(id)) return;
    _searchController.clear();
    _searchFocus.unfocus();
  }

  /// 本页动作的统一入口：端口按此刻 context 组装，命令 / 结果都在模块内。
  CollectionActions get _actions => CollectionActions(
    library: LibraryProviderCollectionActions(
      ref.read(libraryControllerProvider),
    ),
    handoff: TrackHandoffCollectionHandoff(
      context,
      random: widget.shuffleRandom,
    ),
    localData: ProviderCollectionLocalData(
      downloads: ref.read(downloadManagerControllerProvider),
      localData: _vm.localDataService,
    ),
  );

  /// 合集 I/O 命令：端口按此刻 context 组装，编排 / 类型化结果都在模块。
  CollectionIoCommands _ioCommands({
    DiscoverProvider? discover,
    DownloadRequests? requests,
    SyncProvider? sync,
    SaveAs? saveAs,
  }) => buildFavoritesIoCommands(
    ref,
    context,
    discover: discover,
    requests: requests,
    sync: sync,
    saveAs: saveAs,
  );

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

  /// 合集弹层的「导入收藏」：.lxmc 文件 或 平台歌单 / 收藏夹链接。
  Future<void> _importCollection() => importFavoritesCollection(
    context: context,
    l10n: _l10n(context),
    discover: ref.read(discoverProvider.notifier),
    isActive: () => mounted,
    selectCollection: _selectCollection,
    ioCommands: _ioCommands,
    viewModel: _vm,
  );

  /// 写失败提示（原始异常只进日志，界面只说「操作失败」）。
  void _reportMutation(LibraryMutationOutcome outcome) {
    if (!outcome.isFailure || !mounted) return;
    M3ESnackbar.show(context, message: _l10n(context).operationFailed);
  }

  /// 选中行里「现在就能下载」的曲目（本地 / 已下载 / 进行中都不算）。
  List<Track> _selectedDownloadableTracks(CollectionView view) {
    final DownloadRequests? requests = ref.read(
      downloadRequestsControllerProvider,
    );
    if (requests == null) return const [];
    return favoritesDownloadableTracks(
      view: view,
      selectedRows: _vm.selectedRows(view),
      provider: ref.read(libraryControllerProvider),
      requests: requests,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 可见性门控：本页在壳层中常驻挂载，隐藏时放弃 provider 订阅，
    // 否则每次播放历史写入（每首歌一次）都会让整页 build 并重跑过滤 / 排序。
    final library = ShellPageVisibility.maybeVisibleOf(context) ?? true
        ? ref.watch(libraryProvider)
        : ref.read(libraryProvider);
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) => _buildPage(context, library),
    );
  }

  Widget _buildPage(BuildContext context, LibraryState library) {
    final l10n = _l10n(context);
    final playlists = library.playlists;
    final favoritesId = LibraryCollections.favoritesPlaylistId(playlists);

    final smartRows = ref.watch(
      localLibraryProvider.select((provider) => provider.smartRows),
    );
    // 会话是 build 里唯一的「状态机」：身份解析、ensure 加载、恢复校准、
    // 加载组合、选择失效与滚动键激活都在 sync 内完成，页面只消费结果。
    final sessionView = _vm.sync(
      CollectionSessionInput(
        library: LibraryCollectionReader(
          library,
          ref.read(libraryControllerProvider),
        ),
        names: CollectionNames(
          favorites: l10n.favoritesPlaylistName,
          history: l10n.libraryHistory,
          localSongs: l10n.libraryLocalSongs,
          libraryBrowse: l10n.libraryBrowseTitle,
          smartLists: smartListNames(l10n),
        ),
        smartRows: smartRows,
        query: _searchController.text,
        downloads: _vm.downloadsSnapshot,
        cacheIndex: _vm.cacheIndexSnapshot,
        cacheRevision: _vm.cacheRevision,
      ),
    );
    final view = sessionView.view;
    final reorderActive = sessionView.reorderActive;

    // 正文四态：加载骨架 / 读取失败 / 曲库浏览 / 合集正文。骨架 / 失败 /
    // 正文统一走同一套 effects 时长交叉淡化。
    final surface = sessionView.isLoading
        ? FavoritesCollectionSurface.loading
        : sessionView.hasFailed
        ? FavoritesCollectionSurface.failed
        : view.isLibraryBrowse
        ? FavoritesCollectionSurface.libraryBrowse
        : FavoritesCollectionSurface.body;

    // 之前已有一份正文时，同一合集的刷新继续显示旧正文（顶部细进度条），
    // 只有首帧无内容才给居中 spinner；切到别的合集 / 曲库浏览 / 失败态
    // 不复用旧行，否则会出现「旧合集数据顶着新合集标题」的错位。
    if (surface == FavoritesCollectionSurface.body) {
      _lastBodyView = view;
    } else if (surface != FavoritesCollectionSurface.loading) {
      _lastBodyView = null;
    }
    final staleView =
        surface == FavoritesCollectionSurface.loading &&
            _lastBodyView?.collectionKey == view.collectionKey
        ? _lastBodyView
        : null;
    final displaySurface = staleView == null
        ? surface
        : FavoritesCollectionSurface.body;

    // 长按定位请求：加载中挂起（数据就绪后的下一次 build 再消费）；曲库
    // 浏览没有歌曲列表，直接提示先选列表；读取失败已有失败态，清掉即可。
    if (_vm.locatePending &&
        (surface == FavoritesCollectionSurface.failed ||
            surface == FavoritesCollectionSurface.libraryBrowse)) {
      _vm.clearLocate();
      if (surface == FavoritesCollectionSurface.libraryBrowse) {
        _showLocateMessage(l10n.favoritesLocateUnavailable);
      }
    }

    final headerCallbacks = FavoritesHeaderCallbacks(
      onOpenPicker: () => unawaited(
        _showCollectionPicker(
          l10n,
          sessionView.frame,
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
        _vm.onQueryChanged();
        setState(() {});
      },
      onExitReorder: _exitReorder,
      onEnterReorder: _enterReorder,
      onSortChanged: _vm.setSort,
      onToggleMostPlayedMetric: (byTime) {
        ref
            .read(localLibraryProvider.notifier)
            .setMostPlayedMetric(
              byTime
                  ? SmartListMetric.playCount
                  : SmartListMetric.listeningTime,
            );
      },
      onImportLocal: () => unawaited(importLocalAudioFilesFlow(context)),
      onCheckLocalCache: () {
        final index = ref.read(localCacheIndexProvider);
        final cache = ref.read(cacheServiceProvider);
        unawaited(
          checkFavoritesLocalCache(
            context: context,
            l10n: l10n,
            index: index,
            cache: cache,
            library: library,
            isActive: () => mounted,
          ),
        );
      },
      onEditDetails: (playlist, playlists) {
        if (playlist == null) return;
        unawaited(
          editFavoritesPlaylistDetails(
            context: context,
            playlist: playlist,
            playlists: playlists,
            provider: ref.read(libraryControllerProvider),
            isActive: () => mounted,
            onSaved: () => setState(() {}),
          ),
        );
      },
      onChangeCover: (playlist) {
        if (playlist == null) return;
        unawaited(
          changeFavoritesPlaylistCover(
            context: context,
            playlist: playlist,
            provider: ref.read(libraryControllerProvider),
            isActive: () => mounted,
          ),
        );
      },
      onExport: (playlist, view) {
        if (playlist == null) return;
        unawaited(
          exportFavoritesPlaylist(
            ref: ref,
            context: context,
            l10n: l10n,
            playlist: playlist,
            view: view,
            ioCommands: _ioCommands,
            isActive: () => mounted,
          ),
        );
      },
      onDownloadPlaylist: (view) {
        final DownloadRequests? activeRequests = ref.read(
          downloadRequestsControllerProvider,
        );
        if (activeRequests == null) return;
        unawaited(
          downloadFavoritesPlaylist(
            context: context,
            l10n: l10n,
            view: view,
            provider: ref.read(libraryControllerProvider),
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
    final selectionCallbacks = FavoritesSelectionCallbacks(
      isAllFavorited: (rows) =>
          _actions.favoriteChange(rows) == CollectionFavoriteChange.remove,
      hasDownloadable: (_) => _selectedDownloadableTracks(view).isNotEmpty,
      onCopyToPlaylist: () => unawaited(
        copyFavoritesSelectionToPlaylist(
          session: _vm.session,
          actions: _actions,
          view: view,
        ),
      ),
      onRemoveFromPlaylist: () => unawaited(
        removeFavoritesSelectionFromPlaylist(
          session: _vm.session,
          actions: _actions,
          view: view,
          reportMutation: _reportMutation,
        ),
      ),
      onDeleteHistory: () => unawaited(
        deleteFavoritesSelectionHistory(
          session: _vm.session,
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
          session: _vm.session,
          actions: _actions,
          notification: ref.read(notificationServiceProvider),
          isActive: () => mounted,
        ),
      ),
      onToggleFavorite: () => unawaited(
        setFavoritesSelectionFavorite(
          session: _vm.session,
          actions: _actions,
          view: view,
          reportMutation: _reportMutation,
        ),
      ),
      onDownloadSelected: () async {
        final DownloadRequests? requests = ref.read(
          downloadRequestsControllerProvider,
        );
        if (requests == null) return;
        await downloadFavoritesSelection(
          context: context,
          l10n: l10n,
          view: view,
          selectedRows: _vm.selectedRows(view),
          provider: ref.read(libraryControllerProvider),
          requests: requests,
          session: _vm.session,
          ioCommands: () => _ioCommands(requests: requests),
          isActive: () => mounted,
        );
      },
    );
    final content = Column(
      children: [
        // 标题行 / 搜索行 / 多选栏同高：两态交叉淡入淡出，头部不跳高，
        // 离场层不吃点击（多选栏入场 / 退场不误触下面的按钮）。
        FavoritesHeaderCrossFade(
          selecting: _selecting,
          idle: buildFavoritesIdleHeader(
            context,
            buildFavoritesHeaderData(
              context: context,
              ref: ref,
              l10n: l10n,
              viewModel: _vm,
              searchController: _searchController,
              searchFocus: _searchFocus,
              view: view,
              playlists: playlists,
              favoritesId: favoritesId,
              frame: sessionView.frame,
              reorderActive: reorderActive,
              callbacks: headerCallbacks,
            ),
          ),
          selection: buildFavoritesSelectionBar(
            context,
            buildFavoritesSelectionHeaderData(
              l10n: l10n,
              viewModel: _vm,
              view: view,
              callbacks: selectionCallbacks,
            ),
          ),
        ),
        Expanded(
          // 状态标识只看「哪一态」：同一态内的刷新不换 key、不重播过渡。
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (staleView != null)
                ExcludeSemantics(
                  child: reduceMotionOf(context)
                      ? const M3EProgressIndicator.linear(
                          key: Key('favoritesRefreshProgress'),
                        )
                      : const M3EProgressIndicator.linearWavy(
                          key: Key('favoritesRefreshProgress'),
                        ),
                ),
              Expanded(
                child: CrossFadeSwap(
                  value: displaySurface,
                  child: switch (displaySurface) {
                    FavoritesCollectionSurface.loading => const Center(
                      child: M3ELoadingIndicator(),
                    ),
                    FavoritesCollectionSurface.failed =>
                      buildFavoritesReadFailed(
                        context,
                        l10n: l10n,
                        onRetry: () => _vm.session.retry(sessionView.frame),
                      ),
                    FavoritesCollectionSurface.libraryBrowse =>
                      buildFavoritesBrowseTab(
                        context,
                        ref,
                        FavoritesBrowseData(
                          l10n: l10n,
                          query: _searchController.text,
                          groupsCache: _browseGroups,
                          shuffleRandom: widget.shuffleRandom,
                          actions: _actions,
                          downloadRecords: ref.read(
                            downloadRecordsControllerProvider,
                          ),
                          lyrics: ref.read(lyricsProvider.notifier),
                          library: library,
                          isActive: () => mounted,
                        ),
                      ),
                    FavoritesCollectionSurface.body =>
                      buildFavoritesCollectionTab(
                        context,
                        ref,
                        l10n: l10n,
                        viewModel: _vm,
                        view: staleView ?? view,
                        reorderActive: staleView == null && reorderActive,
                        selecting: _selecting,
                        query: _searchController.text,
                        controller: _scrollControllerForKey(
                          (staleView ?? view).collectionKey,
                        ),
                        actions: _actions,
                        isActive: () => mounted,
                        onRowsReady: _applyLocateResult,
                      ),
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return PopScope(
      canPop: !_selecting && !_vm.searching && !reorderActive,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          _vm.clearSelection();
          return;
        }
        if (reorderActive) {
          _exitReorder();
          return;
        }
        if (_vm.searching) _exitSearch();
      },
      child: ResponsivePageContainer(
        pageType: ResponsivePageType.browse,
        alignment: Alignment.topCenter,
        child: content,
      ),
    );
  }

  /// 打开合集切换弹层：点行切换、新建/重命名/删除、导入收藏、拖动排序。
  Future<void> _showCollectionPicker(
    AppLocalizations l10n,
    CollectionFrame frame,
    List<PlaylistInfo> playlists,
    int? favoritesId,
    int selected,
  ) async {
    final outcome = await openFavoritesCollectionPicker(
      ref: ref,
      context: context,
      l10n: l10n,
      frame: frame,
      playlists: playlists,
      favoritesId: favoritesId,
      selected: selected,
      viewModel: _vm,
      onOrderChanged: _vm.reorderCollections,
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
}
