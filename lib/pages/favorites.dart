import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/download.dart' show DownloadedTrack, kLocalSourceKey;
import '../domain/models/library.dart';
import '../domain/models/playlist_folders.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/collection_actions.dart';
import '../providers/collection_mode.dart';
import '../providers/collection_presenter.dart';
import '../providers/collection_session.dart';
import '../providers/discover_provider.dart';
import '../providers/library_collection_request.dart';
import '../providers/library_collections.dart';
import '../providers/library_outcome.dart';
import '../providers/library_provider.dart';
import '../providers/local_library_provider.dart';
import '../providers/local_songs_collection.dart';
import '../providers/playlist_batch_download.dart';
import '../domain/models/library_browse.dart';
import '../domain/models/smart_lists.dart';
import '../providers/lyrics_provider.dart';
import '../providers/sync_provider.dart';
import '../pages/source_swap_page.dart';
import '../services/artwork_palette_service.dart';
import '../services/cache_service.dart';
import '../services/covers/custom_cover_store.dart';
import '../services/poster_color_store.dart';
import '../services/poster_font_store.dart';
import '../services/save_as.dart';
import '../services/system_fonts_service.dart';
import '../services/download/download_intent.dart';
import '../services/download/download_manager.dart';
import '../services/download/download_records.dart';
import '../services/download/download_service.dart' show LocalRelocateResult;
import '../services/library/playlist_folder_prefs.dart';
import '../services/local/local_metadata_service.dart';
import '../services/playlist/playlist_export_builder.dart';
import '../services/playlist/playlist_file_codec.dart';
import '../services/playlist/playlist_import_service.dart';
import '../services/playlist/playlist_share_source.dart';
import '../theme/poster_palette.dart';
import '../services/escape_claims.dart';
import '../services/haptics.dart';
import '../services/notification_service.dart';
import '../services/track_local_data_service.dart';
import '../theme/m3e_context.dart';
import '../theme/motion_policy.dart';
import '../theme/scheme_builder.dart';
import '../utils/responsive.dart';
import '../widgets/adaptive_layout.dart';
import '../utils/collection_row_query.dart';
import '../utils/download_failure_label.dart';
import '../utils/file_name.dart';
import '../utils/save_as_label.dart';
import '../utils/scroll_to_top.dart';
import '../utils/smart_list_rows.dart';
import '../utils/sync_format.dart';
import '../widgets/app_search_bar.dart';
import '../widgets/collection_handoff.dart';
import '../widgets/collection_mode_switch.dart';
import '../widgets/collection_picker.dart';
import '../widgets/collection_scroll_bookkeeping.dart';
import '../widgets/collection_track_list.dart';
import '../widgets/cover_picker_sheet.dart';
import '../widgets/library_browse_view.dart';
import '../widgets/desktop_layout.dart';
import '../widgets/download_data_saver_guard.dart';
import '../widgets/empty_state.dart';
import '../widgets/icon_swap.dart';
import '../widgets/link_import_dialog.dart';
import '../widgets/local_audio_import.dart' show importLocalAudioFilesFlow;
import '../widgets/lxmc_import.dart' show importLxmcFavoritesFlow;
import '../widgets/playlist_cover.dart';
import '../widgets/playlist_folder_dialog.dart';
import '../widgets/playlist_header_overflow.dart';
import '../widgets/playlist_sheets.dart';
import '../widgets/row_actions.dart';
import '../widgets/settings/settings_tiles.dart';
import '../widgets/shell_page_visibility.dart';
import '../widgets/shell_reselect.dart';
import '../widgets/track_row.dart';
import '../widgets/track_row_actions.dart';
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

/// 智能列表展示名（弹层与合集标题共用）。
Map<String, String> _smartListNames(AppLocalizations l10n) => {
  SmartListIds.recentlyAdded: l10n.smartRecentlyAdded,
  SmartListIds.recentlyPlayed: l10n.smartRecentlyPlayed,
  SmartListIds.mostPlayed: l10n.smartMostPlayed,
  SmartListIds.neverPlayed: l10n.smartNeverPlayed,
  SmartListIds.localOnly: l10n.smartLocalOnly,
  SmartListIds.downloaded: l10n.smartDownloaded,
  SmartListIds.missingFiles: l10n.smartMissingFiles,
};

IconData _smartListIcon(String id) => switch (id) {
  SmartListIds.recentlyAdded => Icons.new_releases_rounded,
  SmartListIds.recentlyPlayed => Icons.history_rounded,
  SmartListIds.mostPlayed => Icons.trending_up_rounded,
  SmartListIds.neverPlayed => Icons.music_off_rounded,
  SmartListIds.localOnly => Icons.folder_special_rounded,
  SmartListIds.downloaded => Icons.download_done_rounded,
  _ => Icons.report_gmailerrorred_rounded,
};

/// 「收藏」页：默认收藏（♥）与已导入/自建列表、播放历史、本地歌曲的
/// 统一管理入口。
///
/// - 标题行即合集切换器（弹层内可新建/重命名/删除列表、拖动排序合集，
///   并提供「导入收藏」：.lxmc 文件 / 平台歌单 / 收藏夹链接）；
///   默认落在有曲目的收藏，收藏为空时回退到第一个非空列表；
/// - 宽屏表格列：内容宽（窗口宽 − 栏宽）够时曲目 / 历史 / 本地歌曲列表
///   显示表头与列（播放历史多一列「播放时间」），窄窗口回落单列；
/// - 曲目行：点击播放；行尾显示歌曲时长；⋮ 菜单（桌面右键）提供
///   （「加入列表」含我的收藏 / 播放历史 / 自建列表）；长按进入多选；
/// - 标题右侧提供随机播放 / 搜索两个图标（播放/暂停在顶栏迷你条，
///   整表播放走随机或点行）；搜索按钮展开搜索栏
///   （日常不占用行高），排序与「调整顺序」收在搜索栏的 ⋮ 菜单里；
///   本地歌曲合集多一个「导入本地歌曲」按钮；
/// - 自建列表支持「调整顺序」模式：长按拖动曲目落位即持久化；
/// - 播放历史支持单条删除（⋮ 菜单）与批量删除（多选）。
/// - 本地歌曲（下载副本 + 导入的本地文件）来自下载记录：
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
  /// 标题行 / 多选栏的内容高度（M3E 56）。
  ///
  /// 搜索行不套这个固定高度：展开搜索后由 AppSearchBar 按系统文字缩放
  /// 自行决定高度，大字体下才能容纳完整 hint 与输入行框。
  static const double _headerRowHeight = 56;

  /// 头部行高：随系统字号放大，避免标题 / 副标题在 200% 字号下被裁。
  static double _headerHeight(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(_headerRowHeight);

  /// 头部（标题行 / 搜索行 / 多选栏）垂直留白：三者切换时留白一致；
  /// 搜索行高度本身由 AppSearchBar 决定。
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

  /// 滚动簿记：按合集键保存 / 恢复滚动偏移（防抖落盘 + 只恢复一次）。
  late final CollectionScrollBookkeeping _bookkeeping =
      CollectionScrollBookkeeping(
        controllerOf: _scrollControllerForKey,
        persist: _session.persistScrollOffsets,
      );

  /// 上次观察到的壳层可见性：隐藏 → 可见 = 重新进入收藏页，刷新播放历史
  /// 顺序（顺序在停留期间冻结，见 LibraryProvider）。未挂壳层的单测按可见。
  bool _pageVisible = true;

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

  /// 列表分组收起状态（设备本地；页面侧栏与合集弹层共用这一个持有者）。
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
    _downloadRecords?.removeListener(_onDownloadsChanged);
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
  ///
  /// 下载进度不进这里（进度只属于任务自身），无需记录序列化比对。
  void _onDownloadsChanged() {
    if (mounted) setState(() {});
  }

  /// 缓存变化（清缓存 / LRU 淘汰）：重建以按新签名重算缓存行。
  void _onCacheRevision() {
    if (mounted) setState(() {});
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
  /// 普通点击 / 长按落下（见 [CollectionSelection.anchorKey]）。
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
    DownloadRecords? records,
  ) {
    var favoritesCount = 0;
    for (final playlist in playlists) {
      if (playlist.id == favoritesId) {
        favoritesCount = playlist.trackCount;
        break;
      }
    }
    final showLocalSongs = records?.supported ?? false;
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

    // 固定入口（收藏 / 历史 / 本地歌曲）永远在分组之上；自建列表按分组
    // 投影：命名分组顺序、未分组最后，组内保留设备本地排序。
    final pinned = <CollectionPickerEntry>[];
    final playlistEntries = <CollectionPickerEntry>[];
    for (final entry in ordered) {
      if (entry.playlistId == null) {
        pinned.add(entry);
      } else {
        final info = playlists.firstWhere(
          (item) => item.id == entry.playlistId,
        );
        playlistEntries.add(
          CollectionPickerEntry(
            key: entry.key,
            id: entry.id,
            name: entry.name,
            icon: entry.icon,
            trackCount: entry.trackCount,
            selected: entry.selected,
            playlistId: entry.playlistId,
            folder: normalizePlaylistFolderName(info.folder),
          ),
        );
      }
    }
    if (!hasNamedPlaylistFolders(playlists)) {
      return [...pinned, ...playlistEntries];
    }
    final byId = {for (final entry in playlistEntries) entry.id: entry};
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
            if (byId[playlist.id] != null)
              CollectionPickerEntry(
                key: byId[playlist.id]!.key,
                id: byId[playlist.id]!.id,
                name: byId[playlist.id]!.name,
                icon: byId[playlist.id]!.icon,
                trackCount: byId[playlist.id]!.trackCount,
                selected: byId[playlist.id]!.selected,
                playlistId: byId[playlist.id]!.playlistId,
                folder: '',
              ),
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
            if (byId[playlist.id] != null)
              CollectionPickerEntry(
                key: byId[playlist.id]!.key,
                id: byId[playlist.id]!.id,
                name: byId[playlist.id]!.name,
                icon: byId[playlist.id]!.icon,
                trackCount: byId[playlist.id]!.trackCount,
                selected: byId[playlist.id]!.selected,
                playlistId: byId[playlist.id]!.playlistId,
                folder: group.folder,
              ),
        ],
    ];
  }

  List<CollectionPickerEntry> _smartPickerEntries(
    AppLocalizations l10n,
    int selected,
  ) {
    final localLibrary = context.read<LocalLibraryProvider?>();
    final names = _smartListNames(l10n);
    return [
      CollectionPickerEntry(
        key: 'smart:header',
        id: LibraryCollections.unset,
        name: l10n.smartListsSection,
        icon: Icons.auto_awesome_rounded,
        trackCount: 0,
        selected: false,
        isHeader: true,
      ),
      for (final id in SmartListIds.all)
        CollectionPickerEntry(
          key: id,
          id: LibraryCollections.smartSentinelFor(id),
          name: names[id] ?? id,
          icon: _smartListIcon(id),
          trackCount: localLibrary?.smartRows[id]?.length ?? 0,
          selected: selected == LibraryCollections.smartSentinelFor(id),
          isSmart: true,
        ),
    ];
  }

  /// 打开合集切换弹层：点行切换、新建/重命名/删除、导入收藏、
  /// 行尾把手拖动排序。
  ///
  /// 本地歌曲计数含缓存行：弹层打开前先把缓存行重算到当前输入，否则刚启动
  /// （还没进过本地歌曲合集）时计数会漏掉缓存行、与列表行数对不上。
  /// 重算只读传入的 [frame]；签名未变时是零等待，只有输入变过才等一次音频
  /// 缓存目录列举。
  Future<void> _showCollectionPicker(
    AppLocalizations l10n,
    CollectionFrame frame,
    List<PlaylistInfo> playlists,
    int? favoritesId,
    int selected,
  ) async {
    final provider = context.read<LibraryProvider>();
    final records = context.read<DownloadRecords?>();
    await _session.ensureLocalSongsReady(frame);
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
        records,
      ),
      smartEntries: _smartPickerEntries(l10n, selected),
      onOrderChanged: _session.reorderCollections,
      onDelete: provider.deletePlaylist,
      onCreate: provider.createPlaylist,
      onRename: provider.renamePlaylist,
      folderCollapse: _folderCollapse,
      onFolderRename: (from, to) async {
        try {
          await provider.renamePlaylistFolder(from, to);
          return const LibraryMutationOutcome.applied();
        } catch (e) {
          debugPrint('[Favorites] 重命名分组失败: $e');
          return LibraryMutationOutcome.failed(e);
        }
      },
      onFolderDelete: (folder) async {
        try {
          await provider.deletePlaylistFolder(folder);
          return const LibraryMutationOutcome.applied();
        } catch (e) {
          debugPrint('[Favorites] 删除分组失败: $e');
          return LibraryMutationOutcome.failed(e);
        }
      },
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

  /// 从当前合集可见行的 [index] 起播（随机播放传 [shuffle]）。
  ///
  /// 播放队列组装 / 洗牌 / 上下文名 / 触感都在 TrackHandoff；页面只说「从
  /// 哪个视图的哪一行、要不要洗牌」。
  Future<void> _playViewFrom(
    CollectionView view,
    int index, {
    bool shuffle = false,
  }) => _actions.play(view, startIndex: index, shuffle: shuffle);

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
      (
        value: 'playlistFile',
        icon: Icons.playlist_add_rounded,
        label: l10n.playlistImport,
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
    if (choice == 'playlistFile') {
      await _importPlaylistFile(l10n);
      return;
    }
    if (discover != null) await _importFromLink(discover);
  }

  /// M3U / M3U8 / PLS 导入：解析 → 本机解析 → 复核 → 才创建列表。
  Future<void> _importPlaylistFile(AppLocalizations l10n) async {
    final provider = context.read<LibraryProvider>();
    final records = context.read<DownloadRecords?>();
    final downloads = context.read<DownloadManager?>();
    final List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['m3u', 'm3u8', 'pls'],
        dialogTitle: l10n.playlistImport,
      );
    } catch (_) {
      if (mounted) {
        M3ESnackbar.show(context, message: l10n.playlistImportFailed);
      }
      return;
    }
    final path = files.isEmpty ? null : files.first.path;
    if (path == null || !mounted) return;
    final String text;
    try {
      final bytes = await File(path).readAsBytes();
      text = utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      if (mounted) {
        M3ESnackbar.show(context, message: l10n.playlistImportFailed);
      }
      return;
    }
    if (!mounted) return;
    final parsed = parsePlaylistFile(
      text,
      fileName: p.basename(path),
      baseDirectory: p.dirname(path),
    );
    if (parsed.entries.isEmpty && parsed.problems.isEmpty) {
      M3ESnackbar.show(context, message: l10n.playlistImportEmpty);
      return;
    }
    final service = PlaylistImportService(
      localImporter: _PagePlaylistLocalImporter(records, downloads),
      resolver: _PagePlaylistKeyResolver(provider, records),
    );
    final plan = await service.plan(
      parsed,
      fallbackName: p.basenameWithoutExtension(path),
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (!mounted) return;
    final confirmed = await showPlaylistImportReviewSheet(context, plan: plan);
    if (confirmed != true || !mounted) return;
    try {
      final result = await service.commit(
        plan: plan,
        target: _PagePlaylistImportTarget(provider),
        existingNames: [for (final item in provider.playlists) item.name],
      );
      if (!mounted) return;
      _selectCollection(result.playlistId);
      M3ESnackbar.show(
        context,
        message: l10n.playlistImportDone(result.added, result.skipped),
      );
    } catch (_) {
      if (mounted) {
        M3ESnackbar.show(context, message: l10n.playlistImportFailed);
      }
    }
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
  ) => write == null ? null : () => _mutate(write);

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
      (rows) => actions.setFavorite(rows, change: actions.favoriteChange(rows)),
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
    _session.clearSelection();
  }

  /// 删除确认：按选中项构成给文案（全导入 = 只移出列表；全缓存 = 清缓存；
  /// 混合 = 三者都说明）。
  Future<bool?> _confirmDeleteLocalSongs(List<CollectionLocalSong> selected) {
    final l10n = _l10n(context);
    final anyCached = selected.any((song) => song.isCached);
    final anyDownloaded = selected.any(
      (song) => !song.isCached && !song.isImported,
    );
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
    if (copied && mounted) _session.clearSelection();
  }

  /// 选中行里「现在就能下载」的曲目（本地 / 已下载 / 进行中都不算）。
  List<Track> _selectedDownloadableTracks(CollectionView view) {
    if (!view.isCustom && !view.isFavorites) return const [];
    final launcher = context.read<DownloadLauncher?>();
    if (launcher == null) return const [];
    final provider = context.read<LibraryProvider>();
    final selectedRows = [
      for (final row in _selectedRows(view))
        if (row is TrackCollectionRow) row.track,
    ];
    final actionable = PlaylistBatchDownloadAction.downloadableRows(
      selectedRows,
      toTrack: provider.trackFromPlaylistTrack,
      statusOf: launcher.statusOf,
    );
    return [for (final row in actionable) provider.trackFromPlaylistTrack(row)];
  }

  Future<void> _downloadSelected(CollectionView view) async {
    final tracks = _selectedDownloadableTracks(view);
    final launcher = context.read<DownloadLauncher?>();
    if (tracks.isEmpty || launcher == null) return;
    final l10n = _l10n(context);
    await _runBatchDownload(
      l10n,
      launcher,
      tracks,
      onSucceeded: () {
        if (mounted) _session.clearSelection();
      },
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
          smartLists: _smartListNames(l10n),
        ),
        smartRows: smartRows,
        query: _searchController.text,
        downloads: _downloadsSnapshot,
        cacheRevision: _cacheService?.revision.value ?? -1,
      ),
    );
    final view = sessionView.view;
    final reorderActive = sessionView.reorderActive;
    final mode =
        context.watch<CollectionModeStore?>()?.mode ?? CollectionMode.songs;
    final browseIndex = context
        .select<LocalLibraryProvider?, LibraryBrowseIndex?>(
          (provider) => provider?.snapshot?.index,
        );

    // 分栏判定先算：右栏宽度不够时不能再叠表格列（判据仍只看宽度，
    // 只是这里把左栏占掉的宽度算进「内容宽是否允许」）。
    final twoPane = collectionsUseSplitLayout(
      AdaptiveLayoutScope.of(context).sizeClass,
    );
    // 合集切换只有标题行弹层一个入口：条目不额外解析一份，弹层打开时按
    // 当下 provider 状态现算。
    final listColumn = Column(
      children: [
        // 标题行 / 搜索行 / 多选栏同高：两态交叉淡入淡出，头部不跳高，
        // 离场层不吃点击（多选栏入场 / 退场不误触下面的按钮）。
        _HeaderCrossFade(
          selecting: _selecting,
          idle: _buildIdleHeader(
            context,
            l10n,
            provider,
            playlists,
            favoritesId,
            view,
            frame: sessionView.frame,
            reorderActive: reorderActive,
          ),
          selection: _buildSelectionBar(context, l10n, view),
        ),
        _buildModeSwitch(context, l10n, mode),
        Expanded(
          child: sessionView.isLoading
              ? const Center(child: M3ELoadingIndicator())
              : sessionView.hasFailed
              ? _buildReadFailed(context, l10n, sessionView.frame)
              : _buildBody(
                  context,
                  l10n,
                  view,
                  reorderActive: reorderActive,
                  tableColumnsAllowed: !twoPane,
                ),
        ),
      ],
    );

    final body = mode == CollectionMode.songs
        ? listColumn
        : _buildBrowsePage(
            context,
            l10n,
            mode: mode,
            index: browseIndex,
            twoPane: twoPane,
          );
    final content = twoPane && mode == CollectionMode.songs
        ? Row(
            children: [
              SizedBox(
                key: const Key('collectionSplitView'),
                width: DesktopLayout.collectionSidePaneWidth,
                child: _buildCollectionSidePane(
                  context,
                  l10n,
                  provider,
                  playlists,
                  favoritesId,
                  view.selectedId,
                ),
              ),
              const M3EDivider(axis: M3EDividerAxis.vertical),
              Expanded(child: body),
            ],
          )
        : body;
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

  /// 资料库读取失败：给出错误 + 重试，而不是把失败伪装成空资料库。
  ///
  /// 重试按渲染失败态的这一帧发起：列表 id 与本地歌曲输入不依赖会话里是否
  /// 又 sync 过别的合集。
  Widget _buildReadFailed(
    BuildContext context,
    AppLocalizations l10n,
    CollectionFrame frame,
  ) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.libraryLoadFailed, style: context.typeScale.bodyLarge),
          const SizedBox(height: 12),
          M3EButton.filled(
            onPressed: () => _session.retry(frame),
            child: Text(l10n.retryButton),
          ),
        ],
      ),
    );
  }

  Widget _buildModeSwitch(
    BuildContext context,
    AppLocalizations l10n,
    CollectionMode mode,
  ) {
    final horizontalPadding = context
        .layoutType(ResponsivePageType.browse)
        .horizontalPadding;
    return Padding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, 0, horizontalPadding, 8),
      child: CollectionModeSwitch(
        mode: mode,
        onChanged: (next) {
          unawaited(context.read<CollectionModeStore?>()?.setMode(next));
        },
      ),
    );
  }

  /// 展开宽度的 Songs 左栏：合集清单（收藏 / 历史 / 本地 / 智能 / 列表）。
  Widget _buildCollectionSidePane(
    BuildContext context,
    AppLocalizations l10n,
    LibraryProvider provider,
    List<PlaylistInfo> playlists,
    int? favoritesId,
    int selectedId,
  ) {
    final all = [
      ..._collectionEntries(
        l10n,
        provider,
        playlists,
        favoritesId,
        selectedId,
        _downloadRecords,
      ),
      ..._smartPickerEntries(l10n, selectedId),
    ];
    // 与合集弹层共用同一份收起状态：分组标题始终可见，组内列表按需隐藏。
    final entries = <CollectionPickerEntry>[];
    String? hiddenFolder;
    for (final entry in all) {
      if (entry.isFolderHeader) {
        hiddenFolder = _folderCollapse.isCollapsed(entry.folder)
            ? entry.folder
            : null;
        entries.add(entry);
        continue;
      }
      if (hiddenFolder != null && entry.folder == hiddenFolder) continue;
      entries.add(entry);
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry.isFolderHeader) {
          final collapsed = _folderCollapse.isCollapsed(entry.folder);
          return M3ECard(
            variant: M3ECardVariant.filled,
            color: Colors.transparent,
            elevation: 0,
            borderRadius: BorderRadius.circular(12),
            padding: EdgeInsets.zero,
            onPressed: () {
              unawaited(_folderCollapse.toggle(entry.folder));
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Icon(
                    collapsed
                        ? Icons.chevron_right_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      entry.folder,
                      style: context.typeScale.labelMedium.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  M3EMenu.entries(
                    position: M3EMenuAnchorPosition.bottomEnd,
                    anchorBuilder: (context, open) => M3EIconButton(
                      variant: M3EIconButtonVariant.standard,
                      size: M3EIconButtonSize.sm,
                      icon: const Icon(Icons.more_vert_rounded),
                      semanticLabel: l10n.playlistFolder,
                      onPressed: open,
                    ),
                    onSelected: (value) {
                      if (value == 'rename') {
                        unawaited(_renameFolderFromSide(entry.folder));
                      } else if (value == 'delete') {
                        unawaited(_deleteFolderFromSide(entry.folder));
                      }
                    },
                    entries: [
                      M3EMenuEntry(
                        label: l10n.playlistFolderRename,
                        value: 'rename',
                        leading: const Icon(Icons.edit_rounded, size: 20),
                      ),
                      M3EMenuEntry(
                        label: l10n.playlistFolderDelete,
                        value: 'delete',
                        isDestructive: true,
                        leading: const Icon(
                          Icons.delete_outline_rounded,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }
        if (entry.isHeader) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              entry.name,
              style: context.typeScale.labelMedium.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        return M3EListItem(
          leading: Icon(entry.icon),
          headline: entry.name,
          trailingText: entry.isSmart ? null : '${entry.trackCount}',
          selected: entry.selected,
          onTap: () => _selectCollection(entry.id),
        );
      },
    );
  }

  Future<void> _renameFolderFromSide(String folder) async {
    final l10n = _l10n(context);
    final name = await showPlaylistFolderNameDialog(
      context,
      initialValue: folder,
    );
    if (name == null || !mounted || name == folder) return;
    final provider = context.read<LibraryProvider>();
    final merging = provider.playlists.any(
      (playlist) => normalizePlaylistFolderName(playlist.folder) == name,
    );
    try {
      await provider.renamePlaylistFolder(folder, name);
      if (!mounted) return;
      unawaited(_folderCollapse.rename(folder, name, merged: merging));
      M3ESnackbar.show(context, message: l10n.playlistFolderRenamed);
    } catch (_) {
      if (mounted) {
        M3ESnackbar.show(context, message: l10n.operationFailed);
      }
    }
  }

  Future<void> _deleteFolderFromSide(String folder) async {
    final l10n = _l10n(context);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.playlistFolderDelete,
        content: Text(l10n.playlistFolderDeleteConfirm(folder)),
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
    if (confirmed != true || !mounted) return;
    final provider = context.read<LibraryProvider>();
    try {
      await provider.deletePlaylistFolder(folder);
      if (!mounted) return;
      unawaited(_folderCollapse.delete(folder));
      M3ESnackbar.show(context, message: l10n.playlistFolderDeleted);
    } catch (_) {
      if (mounted) {
        M3ESnackbar.show(context, message: l10n.operationFailed);
      }
    }
  }

  Widget _buildBrowsePage(
    BuildContext context,
    AppLocalizations l10n, {
    required CollectionMode mode,
    required LibraryBrowseIndex? index,
    required bool twoPane,
  }) {
    final query = _searchController.text;
    final albums = index?.albums ?? const <AlbumGroup>[];
    final artists = index?.artists ?? const <ArtistGroup>[];
    final groups = mode == CollectionMode.albums
        ? [
            for (final album in albums)
              LibraryBrowseGroup(
                key: album.sortKey,
                title: album.album.isEmpty ? l10n.unknownAlbum : album.album,
                subtitle: album.primaryArtist,
                coverUrl: _firstCover(album.tracks),
                tracks: album.tracks,
              ),
          ]
        : [
            for (final artist in artists)
              LibraryBrowseGroup(
                key: artist.sortKey,
                title: artist.artist.isEmpty
                    ? l10n.unknownArtist
                    : artist.artist,
                subtitle: '',
                icon: Icons.person_rounded,
                tracks: artist.tracks,
              ),
          ];
    return Column(
      children: [
        _buildModeSwitch(context, l10n, mode),
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.layoutType(ResponsivePageType.browse).horizontalPadding,
            0,
            context.layoutType(ResponsivePageType.browse).horizontalPadding,
            8,
          ),
          child: AppSearchBar(
            controller: _searchController,
            focusNode: _searchFocus,
            hintText: l10n.favoritesSearchHint,
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: LibraryBrowseView(
            groups: groups,
            modeName: mode.name,
            query: query,
            emptyTitle: l10n.browseEmptyTitle,
            emptyBody: l10n.browseEmptyBody,
            searchEmpty: l10n.browseSearchEmpty,
            selectHint: l10n.browseSelectHint,
            resetSignature:
                '${mode.name}|${_session.selectedId}|'
                '${_searchController.text}|${_session.sort.name}',
            twoPane: twoPane,
            isFavorite: (track) => context.read<LibraryProvider>().isFavorite(
              track.sourceKey,
              track.songId,
            ),
            onPlay: (group, tracks, {bool shuffle = false}) => _playBrowse(
              tracks,
              contextName: group.subtitle.isEmpty
                  ? group.title
                  : '${group.title} · ${group.subtitle}',
              shuffle: shuffle,
            ),
            onPlayTrack: (track) =>
                _playBrowse([track], contextName: track.title),
            onAdd: _addBrowseToLibrary,
            onToggleFavorite: (track) async {
              await _actions.toggleFavorite([
                TrackCollectionRow(track.toPlaylistTrack(addedAt: 0)),
              ]);
            },
            canRefreshLocal: (track) => _localRecordOf(track) != null,
            onRefreshLocal: (track) async {
              final record = _localRecordOf(track);
              if (record == null) return;
              final manager = context.read<DownloadManager?>();
              final notifications = context.read<NotificationService?>();
              final updated = await manager?.refreshLocalMetadata(record);
              if (!mounted) return;
              notifications?.showSnackBar(
                updated == null ? l10n.localTitleFailed : l10n.localInfoUpdated,
              );
            },
            onSwap: (track) async {
              final library = context.read<LibraryProvider>();
              await showSourceSwapPage(
                context,
                seed: library.trackFromPlaylistTrack(
                  track.toPlaylistTrack(addedAt: 0),
                ),
                lyricsProvider: context.read<LyricsProvider>(),
              );
            },
          ),
        ),
      ],
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

  String? _firstCover(List<BrowseTrack> tracks) {
    for (final track in tracks) {
      final url = track.coverUrl;
      if (url != null && url.isNotEmpty) return url;
    }
    return null;
  }

  Future<void> _playBrowse(
    List<BrowseTrack> tracks, {
    required String contextName,
    bool shuffle = false,
    int startIndex = 0,
  }) async {
    if (tracks.isEmpty) return;
    final library = context.read<LibraryProvider>();
    final handoff = TrackHandoffCollectionHandoff(
      context,
      random: widget.shuffleRandom,
    );
    await handoff.play(
      [
        for (final track in tracks)
          library.trackFromPlaylistTrack(
            track.toPlaylistTrack(addedAt: 0, playlistId: 0),
          ),
      ],
      startIndex: startIndex.clamp(0, tracks.length - 1),
      shuffle: shuffle,
      contextName: contextName,
    );
  }

  Future<void> _addBrowseToLibrary(List<BrowseTrack> tracks) async {
    if (tracks.isEmpty) return;
    final handoff = TrackHandoffCollectionHandoff(context);
    await handoff.addToLibrary(
      [
        for (final track in tracks)
          track.toPlaylistTrack(addedAt: 0, playlistId: 0),
      ],
      includeFavorites: true,
      includeHistory: false,
    );
  }

  Widget _buildIdleHeader(
    BuildContext context,
    AppLocalizations l10n,
    LibraryProvider provider,
    List<PlaylistInfo> playlists,
    int? favoritesId,
    CollectionView view, {
    required CollectionFrame frame,
    required bool reorderActive,
  }) {
    if (reorderActive) return _buildReorderHeader(context, l10n, view);
    if (_session.searching) return _buildSearchHeader(context, l10n, view);
    return _buildTitleRow(context, l10n, playlists, favoritesId, view, frame);
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
    CollectionFrame frame,
  ) {
    final theme = Theme.of(context);
    final horizontalPadding = context
        .layoutType(ResponsivePageType.browse)
        .horizontalPadding;
    final missingSmartList =
        view.isSmartList &&
        view.identity.smartListId == SmartListIds.missingFiles;
    final canPlay = view.visibleCount > 0 && !missingSmartList;
    PlaylistInfo? currentPlaylist;
    for (final playlist in playlists) {
      if (playlist.id == view.playlistId) {
        currentPlaylist = playlist;
        break;
      }
    }
    final isRealPlaylist = view.isFavorites || view.isCustom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        _headerPaddingTop,
        horizontalPadding,
        _headerPaddingBottom,
      ),
      child: SizedBox(
        height: _headerHeight(context),
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
                    frame,
                    playlists,
                    favoritesId,
                    view.selectedId,
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      if (isRealPlaylist && currentPlaylist != null) ...[
                        PlaylistCover(
                          playlist: currentPlaylist,
                          size: 40,
                          borderRadius: 10,
                        ),
                        const SizedBox(width: 12),
                      ] else ...[
                        Container(
                          width: 5,
                          height: 38,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              view.displayName,
                              // 强调字阶自带字重；字距保持合集标题的收紧口径。
                              style: context.emphasizedTypeScale.headlineSmall
                                  .copyWith(letterSpacing: -0.4),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if ((currentPlaylist?.description ?? '')
                                .trim()
                                .isNotEmpty)
                              Text(
                                currentPlaylist!.description,
                                style: context.typeScale.bodySmall.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
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
            if (view.isSmartList &&
                view.identity.smartListId == SmartListIds.mostPlayed)
              Builder(
                builder: (context) {
                  final local = context.watch<LocalLibraryProvider?>();
                  final byTime =
                      local?.mostPlayedMetric == SmartListMetric.listeningTime;
                  return M3EIconButton(
                    key: const Key('mostPlayedMetricSwitch'),
                    variant: M3EIconButtonVariant.standard,
                    semanticLabel: byTime
                        ? l10n.smartMetricListeningTime
                        : l10n.smartMetricPlayCount,
                    icon: Icon(
                      byTime
                          ? Icons.schedule_rounded
                          : Icons.format_list_numbered_rounded,
                    ),
                    onPressed: local == null
                        ? null
                        : () => local.setMostPlayedMetric(
                            byTime
                                ? SmartListMetric.playCount
                                : SmartListMetric.listeningTime,
                          ),
                  );
                },
              ),
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
            if (isRealPlaylist && currentPlaylist != null) ...[
              const SizedBox(width: 4),
              PlaylistHeaderOverflow(
                onEditDetails: () => unawaited(
                  _editPlaylistDetails(l10n, currentPlaylist!, playlists),
                ),
                onChangeCover: () =>
                    unawaited(_changePlaylistCover(l10n, currentPlaylist!)),
                onShare: () =>
                    unawaited(_sharePlaylist(l10n, currentPlaylist!, view)),
                onExport: () =>
                    unawaited(_exportPlaylist(l10n, currentPlaylist!, view)),
                onDownloadAll:
                    context.read<DownloadLauncher?>() != null &&
                        view.tracks.isNotEmpty
                    ? () => unawaited(_downloadPlaylist(l10n, view))
                    : null,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _editPlaylistDetails(
    AppLocalizations l10n,
    PlaylistInfo playlist,
    List<PlaylistInfo> playlists,
  ) async {
    final provider = context.read<LibraryProvider>();
    final existingNames = [
      for (final item in playlists)
        if (item.id != playlist.id && !item.isFavorites) item.name,
    ];
    final saved = await showPlaylistDetailsSheet(
      context,
      playlist: playlist,
      existingNames: existingNames,
      onSave: (name, description, folder) async {
        final outcome = await provider.updatePlaylistDetails(
          playlist.id,
          name: name,
          description: description,
          folder: folder,
        );
        return !outcome.isFailure;
      },
    );
    if (saved == true && mounted) setState(() {});
  }

  Future<void> _changePlaylistCover(
    AppLocalizations l10n,
    PlaylistInfo playlist,
  ) async {
    final provider = context.read<LibraryProvider>();
    final key = await provider.ensurePlaylistCoverKey(playlist.id);
    if (!mounted || key == null) return;
    await showCoverPickerSheet(
      context,
      playlistCoverKey: key,
      fileNameBase: playlist.name,
      onPlaylistCoverChanged: (hasCover) async {
        await provider.setPlaylistCoverKey(playlist.id, hasCover ? key : null);
      },
    );
  }

  /// 分享内容：只从本机封面读像素，不把路径 / 链接 / 账号放进模型。
  Future<void> _sharePlaylist(
    AppLocalizations l10n,
    PlaylistInfo playlist,
    CollectionView view,
  ) async {
    final records = context.read<DownloadRecords?>();
    final covers = context.read<CustomCoverStore?>();
    final paletteService = context.read<ArtworkPaletteService?>();
    final appScheme = Theme.of(context).colorScheme;
    final textStyle = context.typeScale.bodyMedium;
    final source = PlaylistShareSource(
      playlist: playlist,
      tracks: view.tracks,
      playlistCoverPathOf: (key) => covers?.playlistCoverPath(key),
      downloadedCoverPathOf: (track) =>
          records?.recordFor(track.sourceKey, track.songId)?.coverPath,
      customCoverPathOf: (track) =>
          covers?.trackCoverPath(TrackId(track.sourceKey, track.songId)),
    );
    final content = source.buildContent(
      displayName: view.displayName,
      trackCountLabel: l10n.playlistTrackCount(view.tracks.length),
      andMoreLabel: l10n.playlistShareMore,
    );
    final localCoverPaths = source.localCoverPaths();
    final saved = await PosterColorStore.load();
    if (!mounted) return;
    var scheme = appScheme;
    if (saved.source == PosterColorSource.custom) {
      scheme = buildColorScheme(Color(saved.seed), appScheme.brightness);
    } else if (saved.source == PosterColorSource.artwork &&
        localCoverPaths.isNotEmpty) {
      final palette = await paletteService?.loadLocalFile(
        localCoverPaths.first,
      );
      if (palette != null) {
        scheme = buildColorScheme(palette.seed, appScheme.brightness);
      }
    }
    if (!mounted) return;
    final override = await PosterFontStore.load();
    if (!mounted) return;
    final font = switch (override) {
      null => (
        family: textStyle.fontFamily,
        fallback: textStyle.fontFamilyFallback,
      ),
      '' => (
        family: SystemFontsService.platformDefaultFamily,
        fallback: SystemFontsService.platformDefaultFontFallbacks,
      ),
      final family => (family: family, fallback: null),
    };
    await showPlaylistShareSheet(
      context,
      content: content,
      loadCovers: source.loadCovers,
      palette: PosterPalette.fromScheme(scheme),
      fontFamily: font.family,
      fontFamilyFallback: font.fallback,
    );
  }

  Future<void> _downloadPlaylist(
    AppLocalizations l10n,
    CollectionView view,
  ) async {
    final launcher = context.read<DownloadLauncher?>();
    final provider = context.read<LibraryProvider>();
    if (launcher == null || view.tracks.isEmpty) return;
    await _runBatchDownload(l10n, launcher, [
      for (final track in view.tracks) provider.trackFromPlaylistTrack(track),
    ]);
  }

  Future<bool> _runBatchDownload(
    AppLocalizations l10n,
    DownloadLauncher launcher,
    List<Track> tracks, {
    void Function()? onSucceeded,
  }) async {
    try {
      final result = await const PlaylistBatchDownloadAction().run(
        tracks: tracks,
        confirm: () => confirmDownloadOnDataSaver(context),
        startBatch: launcher.startBatch,
        onSucceeded: onSucceeded,
        onEnqueued: (enqueued) {
          if (!mounted) return;
          M3ESnackbar.show(
            context,
            message: enqueued == 0
                ? l10n.downloadsNothingToAdd
                : l10n.downloadsQueued(enqueued),
          );
        },
      );
      if (!mounted || result == null || result.enqueued == 0) {
        return result != null;
      }
      M3ESnackbar.show(
        context,
        message: l10n.downloadsBatchDone(result.done, result.failed),
      );
      return true;
    } catch (error) {
      if (!mounted) return false;
      final message = downloadFailureMessage(l10n, error);
      if (message != null) {
        M3ESnackbar.show(context, message: message);
      }
      return false;
    }
  }

  Future<void> _exportPlaylist(
    AppLocalizations l10n,
    PlaylistInfo playlist,
    CollectionView view,
  ) async {
    final sync = context.read<SyncProvider?>();
    final format = await showPlaylistExportSheet(
      context,
      moliaAvailable: sync != null,
    );
    if (!mounted || format == null) return;
    final saveAs = context.read<SaveAs?>();
    if (saveAs == null) {
      M3ESnackbar.show(context, message: l10n.playlistExportFailed);
      return;
    }
    final provider = context.read<LibraryProvider>();
    final records = context.read<DownloadRecords?>();
    try {
      if (format == PlaylistExportFormat.m3u8) {
        final export = await PlaylistExportBuilder(
          pageUrlOf: (track) =>
              provider.trackFromPlaylistTrack(track).platformPageUrl,
          downloadedRecordOf: (track) =>
              records?.recordFor(track.sourceKey, track.songId),
          fileExists: (path) => File(path).exists(),
        ).buildM3u8(name: view.displayName, tracks: view.tracks);
        final result = await saveAs.saveBytes(
          fileName:
              '${sanitizeFileName(view.displayName, fallback: 'playlist')}.m3u8',
          bytes: Uint8List.fromList(utf8.encode(export.text)),
          mimeType: 'audio/x-mpegurl',
          relativeDir: saveAsExportsDirName,
          dialogTitle: l10n.playlistExportM3u8,
        );
        if (!mounted) return;
        _showExportResult(l10n, result, missingFiles: export.missingFiles);
      } else {
        final coverKey = await provider.ensurePlaylistCoverKey(playlist.id);
        if (coverKey == null || sync == null) {
          if (mounted) {
            M3ESnackbar.show(context, message: l10n.playlistExportFailed);
          }
          return;
        }
        final syncId = playlistSyncIdFromCoverKey(coverKey) ?? coverKey;
        final json = await sync.commands.backup.exportPlaylistJson(
          playlistSyncId: syncId,
          coverKey: playlist.effectiveCoverKey ?? coverKey,
        );
        final result = await saveAs.saveBytes(
          fileName:
              '${sanitizeFileName(view.displayName, fallback: 'playlist')}.molia.json',
          bytes: Uint8List.fromList(utf8.encode(json)),
          mimeType: 'application/json',
          relativeDir: saveAsExportsDirName,
          dialogTitle: l10n.playlistExportMolia,
        );
        if (!mounted) return;
        _showExportResult(l10n, result);
      }
    } catch (_) {
      if (mounted) {
        M3ESnackbar.show(context, message: l10n.playlistExportFailed);
      }
    }
  }

  void _showExportResult(
    AppLocalizations l10n,
    SaveAsResult result, {
    int missingFiles = 0,
  }) {
    switch (result) {
      case SaveAsSaved(:final displayPath, :final kind):
        M3ESnackbar.show(
          context,
          message: playlistExportMessage(l10n, kind, displayPath, missingFiles),
        );
      case SaveAsCancelled():
        break;
      case SaveAsFailed():
        M3ESnackbar.show(context, message: l10n.playlistExportFailed);
    }
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
    final horizontalPadding = context
        .layoutType(ResponsivePageType.browse)
        .horizontalPadding;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        _headerPaddingTop,
        horizontalPadding,
        _headerPaddingBottom,
      ),
      // 不套固定高度：AppSearchBar 会随系统文字缩放长高，父级再钉 56 会把
      // hint 压回裁切；搜索态头部允许比标题行高。
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
    );
  }

  /// 排序模式行：标题 + 提示 + 完成。
  Widget _buildReorderHeader(
    BuildContext context,
    AppLocalizations l10n,
    CollectionView view,
  ) {
    final theme = Theme.of(context);
    final horizontalPadding = context
        .layoutType(ResponsivePageType.browse)
        .horizontalPadding;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        _headerPaddingTop,
        horizontalPadding,
        _headerPaddingBottom,
      ),
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

  /// 多选栏只保留两个高频动作（按合集种类定），其余批量动作收进 ⋮。
  List<Widget> _buildSelectionActions(
    BuildContext context,
    AppLocalizations l10n,
    CollectionView view,
  ) {
    final selected = _selectedRows(view);
    if (selected.isEmpty) return const [];
    final addToPlaylist = M3EIconButton(
      key: const Key('collectionSelectionAddToPlaylist'),
      variant: M3EIconButtonVariant.standard,
      icon: const Icon(Icons.playlist_add_rounded),
      semanticLabel: l10n.addToPlaylist,
      onPressed: () => unawaited(_copySelectionToPlaylist(view)),
    );
    if (view.isCustom) {
      return [
        M3EIconButton(
          key: const Key('collectionSelectionRemove'),
          variant: M3EIconButtonVariant.standard,
          icon: const Icon(Icons.playlist_remove_rounded),
          semanticLabel: l10n.playlistRemoveTrack,
          onPressed: () => unawaited(_removeSelectedFromPlaylist(view)),
        ),
        addToPlaylist,
      ];
    }
    if (view.isHistory) {
      return [
        M3EIconButton(
          key: const Key('collectionSelectionDelete'),
          variant: M3EIconButtonVariant.standard,
          icon: const Icon(Icons.delete_rounded),
          semanticLabel: l10n.historyDeleteEntry,
          onPressed: () => unawaited(_deleteSelectedHistory(view)),
        ),
        addToPlaylist,
      ];
    }
    if (view.isLocalSongs) {
      return [
        M3EIconButton(
          key: const Key('collectionSelectionDelete'),
          variant: M3EIconButtonVariant.standard,
          icon: const Icon(Icons.delete_rounded),
          semanticLabel: l10n.delete,
          onPressed: () => unawaited(_deleteSelectedLocalSongs(view)),
        ),
        addToPlaylist,
      ];
    }
    // 收藏 / 智能列表：收藏开关 + 加入列表（全部已收藏时开关变取消）。
    final favoriteChange = _actions.favoriteChange(selected);
    final allFavorited = favoriteChange == CollectionFavoriteChange.remove;
    return [
      M3EIconButton(
        key: const Key('collectionSelectionFavorite'),
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
        onPressed: () => unawaited(_setSelectedFavorite(view)),
      ),
      addToPlaylist,
    ];
  }

  /// 多选栏 ⋮：下载等低频批量动作只在这里出现，避免选中栏变成功作墙。
  Widget _buildSelectionOverflow(
    BuildContext context,
    AppLocalizations l10n,
    CollectionView view,
  ) {
    final entries = <M3EMenuEntry>[
      if (_selectedDownloadableTracks(view).isNotEmpty)
        M3EMenuEntry(
          label: l10n.playlistDownloadSelected,
          value: 'download',
          leading: const Icon(Icons.download_rounded),
        ),
    ];
    if (entries.isEmpty) return const SizedBox.shrink();
    return M3EMenu.entries(
      position: M3EMenuAnchorPosition.bottomEnd,
      anchorBuilder: (context, open) => M3EIconButton(
        variant: M3EIconButtonVariant.standard,
        icon: const Icon(Icons.more_vert_rounded),
        semanticLabel: l10n.moreActions,
        onPressed: open,
      ),
      onSelected: (value) {
        if (value == 'download') unawaited(_downloadSelected(view));
      },
      entries: entries,
    );
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selectionTheme.contextualBackground(m3e.colorScheme),
        // 选中栏只在多选时出现：圆底 + 一条低对比分隔线把它与列表分开，
        // 不抢标题行的层级，也不用阴影（M3E 列表表面本来就没有阴影）。
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
        border: Border(
          bottom: BorderSide(color: foreground.withValues(alpha: 0.12)),
        ),
      ),
      // 与标题行 / 搜索行同一套垂直留白：进入 / 退出多选头部不跳高。
      child: Padding(
        padding: const EdgeInsets.only(
          top: _headerPaddingTop,
          bottom: _headerPaddingBottom,
        ),
        child: IconTheme.merge(
          data: IconThemeData(color: foreground),
          child: SizedBox(
            height: _headerHeight(context),
            child: Row(
              children: [
                const SizedBox(width: 4),
                M3EIconButton(
                  key: const Key('collectionSelectionClose'),
                  variant: M3EIconButtonVariant.standard,
                  icon: const Icon(Icons.close_rounded),
                  semanticLabel: l10n.cancel,
                  onPressed: _session.clearSelection,
                ),
                // 计数是纯文本（没有上限，也没有胶囊 / 警告色）。
                Text(
                  l10n.selectionCountSelected(_session.selectedCount),
                  key: const Key('collectionSelectionCount'),
                  style: m3e.typeScale.titleSmall.copyWith(color: foreground),
                ),
                const Spacer(),
                // 全选只负责选中；清空 / 退出只走 ✕。
                M3EIconButton(
                  key: const Key('collectionSelectionSelectAll'),
                  variant: M3EIconButtonVariant.standard,
                  icon: const Icon(Icons.select_all_rounded),
                  semanticLabel: l10n.selectAllItems,
                  onPressed: allSelected
                      ? null
                      : () => _session.selectAllVisible(view),
                ),
                ..._buildSelectionActions(context, l10n, view),
                _buildSelectionOverflow(context, l10n, view),
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
    required bool tableColumnsAllowed,
  }) {
    // 行 / 表头同一份列规范（历史多一列「播放时间」），表格档判定按规范
    // 取阈值：行内是否给列、表头画哪几列、行高取哪一档都由这一个决定。
    final spec = _columnSpec(view.columnLayout);
    final tableColumns =
        tableColumnsAllowed && DesktopLayout.of(context).tableColumnsFor(spec);
    final columnSpec = tableColumns ? spec : null;
    // 智能列表按展示层重复聚类：代表行 + 展开后的版本行；不删除任何记录。
    final rows = view.isSmartList ? _smartDisplayRows(view) : view.visibleRows;
    // 三种合集的可见行已是同一份有序联合：列表脚手架只搭一次，行内展示与
    // 行动作按行变体分派，不再按合集类型选列表形状。
    final body = CollectionTrackList<CollectionRow>(
      controller: _scrollControllerForKey(view.collectionKey),
      rows: rows,
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
        totalRows: rows.length,
      ),
    );
    // 表头固定在滚动区之上（与搜索页同一口径）：列标题不随列表滚走，
    // 列与行内列同宽同左缘。空列表（含被搜索过滤空）不给表头。
    if (columnSpec == null || view.visibleCount == 0) return body;
    final horizontalPadding = context
        .layoutType(ResponsivePageType.browse)
        .horizontalPadding;
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
    int? totalRows,
  }) {
    // 行尾缓存标签：非表格档保留文字；表格档塞进 56dp 固定槽，用紧凑图标
    // （与 ⋮ 并排时不挤掉列）。多选 / 排序模式不渲染 ⋮（见 CollectionTrackRow）。
    final table = columnSpec != null;
    final cached = switch (row) {
      LocalSongCollectionRow(:final song) when song.isCached => true,
      _ => false,
    };
    final versionCount = _smartVersionCounts[row.key] ?? 0;
    final versionTrailing = versionCount <= 1
        ? null
        : M3EButton.text(
            key: ValueKey('smartVersions-${row.key}'),
            onPressed: () => setState(() {
              if (!_expandedSmartVersions.remove(row.key)) {
                _expandedSmartVersions.add(row.key);
              }
            }),
            child: Text(l10n.duplicateVersions(versionCount)),
          );
    final cachedTrailing =
        versionTrailing ??
        (!cached
            ? null
            : table
            ? Icon(
                Icons.download_done_rounded,
                size: 16,
                semanticLabel: l10n.localSongsCachedTag,
              )
            : Text(
                l10n.localSongsCachedTag,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: context.typeScale.labelSmall.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ));
    return RowActionsBuilder(
      // Sliver itemBuilder 里不能直接 select：动作构造放进独立 build。
      actions: (rowContext) => (reorderActive || _selecting)
          ? const <RowAction>[]
          : _rowActions(rowContext, l10n, view, row),
      builder: (rowContext, actions) => CollectionTrackRow(
        row: TrackRowModel(
          title: row.title,
          artist: switch (row) {
            LocalSongCollectionRow(:final song) when song.isMissing =>
              row.artist.isEmpty
                  ? l10n.localFileMissing
                  : '${row.artist} · ${l10n.localFileMissing}',
            _ => row.artist,
          },
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
          selected: _session.isSelected(row.key),
        ),
        surface: TrackRowSurface(tableSpec: columnSpec),
        trailing: reorderActive
            ? Icon(
                Icons.drag_handle_rounded,
                color: Theme.of(rowContext).colorScheme.onSurfaceVariant,
              )
            : cachedTrailing,
        position: calculateCardPosition(index, totalRows ?? view.visibleCount),
        onTap: reorderActive || _missingSmartRow(view, row)
            ? null
            : () => _onRowTap(view, index),
        onTapWithModifiers: (reorderActive || !isDesktopPlatform())
            ? null
            : (ctrl, shift) => _onRowTap(view, index, ctrl: ctrl, shift: shift),
        onLongPress: reorderActive
            ? null
            : () => _onRowLongPress(view, row.key),
        // 多选时长按 = 选中锚点到这一行的区间；读屏通过自定义动作拿到同一
        // 语义（普通长按进入多选时不给这个动作，避免两种含义混在一起）。
        longPressSemanticLabel: _selecting ? l10n.selectionRangeToHere : null,
        actions: actions.isEmpty ? null : actions,
      ),
    );
  }

  /// 行动作：投影器决定构成（`CollectionPresenter.rowActionsFor`），动作载荷
  /// 由 `CollectionActions.rowCommands` 按行变体归一（复制 / 换源 / 移除 /
  /// 收藏 / 删除）；页面只把回调接成提示与确认，接线缺席的动作不会出现
  /// （见 `buildCollectionRowActions`）。公共动作（加入队列 / 下载 / 评论 /
  /// 专辑 / 歌手）按能力位追加，移除 / 删除类保持在最后。
  List<RowAction> _rowActions(
    BuildContext context,
    AppLocalizations l10n,
    CollectionView view,
    CollectionRow row,
  ) {
    final primary = buildCollectionRowActions(
      l10n: l10n,
      specs: _session.rowActionsFor(row, view),
      wiring: _actionWiring(context, view, row),
    );
    // 智能列表行只保留播放 / 收藏 / 加入列表（文件不见再加定位 / 移除），
    // 不追加下载 / 评论等在线动作。
    if (view.isSmartList) return primary;
    return mergeRowActions(
      primary,
      trackCommonActions(context, _domainTrackOf(row)),
    );
  }

  bool _missingSmartRow(CollectionView view, CollectionRow row) =>
      view.isSmartList &&
      view.identity.smartListId == SmartListIds.missingFiles &&
      row is LocalSongCollectionRow &&
      row.song.isMissing;

  /// 合集行 → 领域曲目（公共动作的能力位 / 平台 id 需要领域形状）。
  ///
  /// 与 `CollectionActions.play` 共用同一套转换（历史行还原历史曲目，
  /// 本地歌曲行还原 local 源快照），不另造一份映射。
  Track _domainTrackOf(CollectionRow row) {
    final library = context.read<LibraryProvider>();
    return switch (row) {
      TrackCollectionRow(:final track) => library.trackFromPlaylistTrack(track),
      HistoryCollectionRow(:final entry) => library.trackFromHistoryEntry(
        entry,
      ),
      LocalSongCollectionRow(:final song) => library.trackFromPlaylistTrack(
        song.toPlaylistTrack(addedAt: 0),
      ),
    };
  }

  CollectionRowActionWiring _actionWiring(
    BuildContext context,
    CollectionView view,
    CollectionRow row,
  ) {
    final commands = _actions.rowCommands(view, row);
    final swap = commands.swap;
    final localSong = commands.localSong;
    final localRecord = row is LocalSongCollectionRow ? row.song.record : null;
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
      onDeleteLocalSong: localSong == null
          ? null
          : () => _deleteLocalSong(localSong),
      onEditLocalTitle: localRecord == null
          ? null
          : () => _editLocalTitle(localRecord),
      onLocateLocalFile: localRecord?.isMissing == true
          ? () => _locateLocalFile(localRecord!)
          : null,
      onRefreshLocalInfo: localRecord == null
          ? null
          : () => _refreshLocalMetadata(localRecord),
      isFavorite: commands.isFavorite,
      localSongCached: commands.localSongCached,
      localSongImported: commands.localSongImported,
    );
  }

  /// 本地歌曲单条删除（行动作入口：触摸端 ⋮ / 桌面右键）：先确认再按行
  /// 来源删（下载副本删文件、导入项只移出列表、缓存行清缓存）。
  Future<void> _deleteLocalSong(CollectionLocalSong song) async {
    final actions = _actions;
    if (!actions.localDataAvailable) return;
    final confirmed = await _confirmDeleteLocalSongs([song]);
    if (confirmed != true || !mounted) return;
    _reportLocalDelete(await actions.deleteLocalSongs([song]));
  }

  /// 只改标题：先尝试写文件标签；格式不支持 / 失败 / 文件不见时再让用户
  /// 选择「只在 Molia 中修改」。
  Future<void> _editLocalTitle(DownloadedTrack record) async {
    final l10n = AppLocalizations.of(context)!;
    final notifications = context.read<NotificationService?>();
    final service = context.read<LocalMetadataService?>();
    if (service == null) return;
    final controller = TextEditingController(text: record.title);
    final title = await M3EDialog.show<String>(
      context,
      dialog: M3EDialog(
        title: l10n.localTitleEdit,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              M3ETextField(
                controller: controller,
                autofocus: true,
                maxLength: 200,
                label: l10n.localTitleEdit,
              ),
              const SizedBox(height: kSettingsSmallSpacing),
              Text(
                l10n.localTitleNote,
                style: context.typeScale.bodySmall.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
            child: Text(l10n.cancelButton),
          ),
          M3EButton.text(
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(controller.text),
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null || !mounted) return;
    var status = await service.editTitle(record, title);
    if (status == LocalTitleEditStatus.invalidTitle) {
      notifications?.showSnackBar(l10n.localTitleInvalid);
      return;
    }
    if (status == LocalTitleEditStatus.appOnlyRequired && mounted) {
      final appOnly = await M3EDialog.show<bool>(
        context,
        dialog: M3EDialog(
          title: l10n.localTitleMoliaOnly,
          content: SizedBox(
            width: settingsDialogWidth(context),
            child: Text(l10n.localTitleMoliaOnlyNote),
          ),
          actions: [
            M3EButton.text(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              child: Text(l10n.cancelButton),
            ),
            M3EButton.text(
              onPressed: () =>
                  Navigator.of(context, rootNavigator: true).pop(true),
              child: Text(l10n.localTitleMoliaOnly),
            ),
          ],
        ),
      );
      if (appOnly != true || !mounted) return;
      status = await service.editTitle(record, title, appOnly: true);
    }
    if (!mounted) return;
    if (status == LocalTitleEditStatus.written) {
      notifications?.showSnackBar(l10n.localTitleUpdated);
    } else if (status == LocalTitleEditStatus.failed) {
      notifications?.showErrorSnackBar(l10n.localTitleFailed);
    }
  }

  /// 显式「从文件刷新信息」：重读标签并覆盖展示元数据；扫描不会自动调用。
  Future<void> _refreshLocalMetadata(DownloadedTrack record) async {
    final l10n = AppLocalizations.of(context)!;
    final notifications = context.read<NotificationService?>();
    final manager = context.read<DownloadManager?>();
    final updated = await manager?.refreshLocalMetadata(record);
    if (!mounted) return;
    if (updated == null) {
      notifications?.showErrorSnackBar(l10n.localTitleFailed);
      return;
    }
    notifications?.showSnackBar(l10n.save);
  }

  /// 重定位：选一个可读音频文件，身份 / 引用保持不变。
  Future<void> _locateLocalFile(DownloadedTrack record) async {
    final l10n = AppLocalizations.of(context)!;
    final notifications = context.read<NotificationService?>();
    final manager = context.read<DownloadManager>();
    String? path;
    try {
      final files = await FilePicker.pickFiles(type: FileType.audio);
      path = files.singleOrNull?.path;
    } catch (_) {
      path = null;
    }
    if (path == null || path.isEmpty) return;
    final result = await manager.relocate(record, path);
    if (!mounted) return;
    switch (result) {
      case LocalRelocateResult.relocated:
        notifications?.showSnackBar(l10n.localFileRelocated);
      case LocalRelocateResult.unsupportedFormat:
        notifications?.showErrorSnackBar(l10n.localFileMissing);
      case LocalRelocateResult.fileMissing:
        notifications?.showErrorSnackBar(l10n.localFileMissing);
    }
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
          icon: view.isSmartList
              ? Icons.auto_awesome_rounded
              : view.isHistory
              ? Icons.history_rounded
              : view.isLocalSongs
              ? Icons.library_music_rounded
              : view.isFavorites
              ? Icons.favorite_border_rounded
              : Icons.queue_music_rounded,
          message: view.isSmartList
              ? l10n.smartEmpty
              : view.isHistory
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

/// 本机路径导入端口：复用下载服务的导入路径与稳定身份。
class _PagePlaylistLocalImporter implements PlaylistLocalImporter {
  _PagePlaylistLocalImporter(this._records, this._downloads);

  final DownloadRecords? _records;
  final DownloadManager? _downloads;

  @override
  Future<PlaylistTrack?> importPath(String path) async {
    final normalized = p.normalize(path);
    final existing = _records?.importedRecordForPath(normalized);
    if (existing != null) {
      return existing.toPlaylistTrack(
        addedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
    final downloads = _downloads;
    if (downloads == null) return null;
    final (imported, _) = await downloads.importLocalFiles([normalized]);
    if (imported == 0) return null;
    final record = _records?.importedRecordForPath(normalized);
    return record?.toPlaylistTrack(
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}

/// `#MOLIA` 键解析：下载记录 → 播放历史 → 库内列表，全部只查本机。
class _PagePlaylistKeyResolver implements PlaylistKeyResolver {
  _PagePlaylistKeyResolver(this._provider, this._records);

  final LibraryProvider _provider;
  final DownloadRecords? _records;

  @override
  Future<PlaylistTrack?> resolve(String moliaKey) async {
    final split = moliaKey.indexOf(':');
    if (split <= 0 || split >= moliaKey.length - 1) return null;
    final sourceKey = moliaKey.substring(0, split);
    final songId = moliaKey.substring(split + 1);
    final record = _records?.recordFor(sourceKey, songId);
    if (record != null) {
      return record.toPlaylistTrack(
        addedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
    return _provider.findTrackByKey(sourceKey, songId);
  }
}

/// 导入执行端口：只经 provider 的公开写入口；失败交给服务清理空列表。
class _PagePlaylistImportTarget implements PlaylistImportTarget {
  _PagePlaylistImportTarget(this._provider);

  final LibraryProvider _provider;

  @override
  Future<int> createPlaylist(String name) => _provider.createPlaylist(name);

  @override
  Future<int> addTracks(int playlistId, List<PlaylistTrack> tracks) async {
    final outcome = await _provider.addTracksToPlaylist(playlistId, tracks);
    if (outcome.isFailure) throw outcome.error ?? StateError('add failed');
    return outcome.changed;
  }

  @override
  Future<void> deletePlaylist(int playlistId) async {
    final outcome = await _provider.deletePlaylist(playlistId);
    if (outcome.isFailure) throw outcome.error ?? StateError('delete failed');
  }
}

/// 页头两态（常规 / 多选）交叉淡入淡出。
///
/// 两态高度相同（顶部 / 底部留白 + 56 行高），避免切换时头部跳高、列表
/// 滚动位置抖动。落定后只挂当前层：隐藏态不参与 finder / 焦点 / 点击。
/// 用自绘控制器而不是 `AnimatedSwitcher`（图标切换专用，架构测试会拦），
/// 也不直接用 `AnimatedCrossFade`（隐藏层仍留在树里，测试与焦点会命中原层）。
class _HeaderCrossFade extends StatefulWidget {
  const _HeaderCrossFade({
    required this.selecting,
    required this.idle,
    required this.selection,
  });

  final bool selecting;
  final Widget idle;
  final Widget selection;

  @override
  State<_HeaderCrossFade> createState() => _HeaderCrossFadeState();
}

class _HeaderCrossFadeState extends State<_HeaderCrossFade>
    with SingleTickerProviderStateMixin {
  static const Duration _duration = M3EMotion.short4;

  late final AnimationController _progress = AnimationController(
    vsync: this,
    value: widget.selecting ? 1 : 0,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // effects 时长随系统减弱动效归零（硬切）。
    _progress.duration = effectDurationOf(context, _duration);
  }

  @override
  void didUpdateWidget(covariant _HeaderCrossFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selecting == widget.selecting) return;
    final double target = widget.selecting ? 1 : 0;
    if (_progress.duration == Duration.zero) {
      _progress.value = target;
      return;
    }
    _progress.animateTo(target, curve: M3EMotion.emphasizedDecelerate);
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, _) {
        final double t = _progress.value;
        // 落定后只保留当前态：隐藏层不再构建（finder / 键盘焦点 / 语义都
        // 不会命中已经离开的页头）。
        if (t <= 0) {
          return IgnorePointer(ignoring: widget.selecting, child: widget.idle);
        }
        if (t >= 1) {
          return IgnorePointer(
            ignoring: !widget.selecting,
            child: widget.selection,
          );
        }
        return Stack(
          alignment: Alignment.topCenter,
          children: [
            IgnorePointer(
              ignoring: widget.selecting,
              child: Opacity(opacity: 1 - t, child: widget.idle),
            ),
            IgnorePointer(
              ignoring: !widget.selecting,
              child: Opacity(opacity: t, child: widget.selection),
            ),
          ],
        );
      },
    );
  }
}

/// 会话 → 页面滚动簿记的适配：控制器与防抖落盘都留在页面，会话只决定
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
