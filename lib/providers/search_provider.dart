import 'package:flutter/foundation.dart';

import '../app/perf/data_path_trace.dart';
import '../data/catalog/catalog_service.dart';
import '../domain/models/artist.dart';
import '../domain/models/catalog.dart' show SearchKind, SearchQuery;
import '../domain/models/source.dart' show SourceDescriptor;
import '../domain/ports/source_registry.dart';
import 'channel_selection.dart';
import 'paged_list_controller.dart';
import 'playback_provider.dart';
import 'search_results.dart';
import 'search_row.dart';
import 'search_session.dart';

export 'search_input_binding.dart';
export 'search_results.dart' show SearchResults;
export 'search_row.dart' show SearchRow;
export 'search_session.dart';

/// 当前渠道搜索的对外门面：状态与调度全部委托 [SearchSession]。
///
/// 本类只保留三件事：
/// - 组合根注入的目录服务 → 会话页取数（网络 / 缓存层不搬进会话）；
/// - 播放出口 [playItem]（搜索结果整体进队列，依赖 [PlaybackProvider]）；
/// - 把会话通知转成 provider 通知，维持现有 `context.watch<SearchProvider>()`
///   订阅面。
///
/// 查询 / 清空 / 切类型 / 防抖 / 渠道补搜的策略都在会话内单点实现；UI 可
/// 直接读 [session]（投影 / 预览）并发送意图。
class SearchProvider extends ChangeNotifier {
  final PlaybackProvider _playbackProvider;

  /// 搜索入口：带 single-flight + LRU + TTL 的目录服务（可为 null：无音源）。
  final CatalogService? _catalogService;

  /// 搜索会话：关键词、类型、结果控制器、预览与渠道反应都在这里。
  late final SearchSession session;

  static const int _searchPageSize = 30;

  SearchProvider(
    this._playbackProvider, {
    required ChannelSelection selection,
    this._catalogService,
    SourceRegistry? sourceRegistry,
  }) {
    session = SearchSession(
      selection: selection,
      sourceRegistry: sourceRegistry,
      fetchSongPage: _fetchSongPage,
      fetchArtistPage: _fetchArtistPage,
      fetchLyricPage: _fetchLyricPage,
    );
    session.addListener(_onSessionChanged);
  }

  void _onSessionChanged() => notifyListeners();

  String get searchQuery => session.query;

  /// 当前搜索类型（搜索页分段）。
  SearchKind get searchKind => session.kind;

  bool get isSearchActive => session.isActive;

  /// 当前渠道 key（`''` = 尚未确定；不是「全部来源」）。
  String get activeSourceKey => session.activeSourceKey;

  /// 当前渠道的搜索描述；渠道未注册 / 脚本未加载时为 null。
  SourceDescriptor? get activeSource => session.activeSource;

  /// 当前渠道是否真的可搜索（Ctrl+F / 空态的唯一判据）。
  bool get hasActiveSearchSource => session.hasActiveSearchSource;

  /// 当前关键词已提交、但当前类型还没有真正发起搜索（防抖窗口 / 切类型）。
  bool get isSearchPending => session.isPending;

  /// 搜索是否仍在进行：防抖等待或当前类型首屏请求在途。
  bool get isSearchBusy => session.isBusy;

  /// 所有可搜索渠道：直接返回 registry 的描述列表（顺序 = 渠道管理排序）。
  List<SourceDescriptor> get sourceChannels => session.sourceChannels;

  /// 当前渠道支持且已启用的搜索类型（只读 [activeSource] 的能力位）。
  List<SearchKind> get supportedSearchKinds => session.supportedKinds;

  /// 是否存在可搜索来源（区别「全应用无音源」与「当前渠道不支持搜索」）。
  bool get hasSearchableSources => session.hasSearchableSources;

  /// 单曲 / 歌手 / 歌词结果快照（按类型保留行形状）。
  SearchResults<SearchRow> get songResults => session.songResults;

  SearchResults<ArtistSummary> get artistResults => session.artistResults;

  SearchResults<SearchRow> get lyricResults => session.lyricResults;

  /// 当前类型的视图投影（结果 / 预览 / 空态判据）。
  SearchProjection get projection => session.projection;

  /// 单曲结果的扁平投影（播放与性能场景读取这里）。
  List<SearchRow> get searchResults => songResults.items;

  /// 单曲结果列表（无关键词时为空）。
  List<SearchRow> get filteredResults =>
      searchQuery.isEmpty ? const [] : searchResults;

  /// 当前类型是否首屏加载中。
  bool get isSearching => session.isSearching;

  /// 当前类型加载下一页；守卫由 [PagedListController] 持有。
  Future<void> loadMore() => session.loadMore();

  /// 首屏失败重载首屏；加载更多失败重试下一页。
  Future<void> retry() => session.retry();

  /// 重试当前类型失败的首屏 / 追加页（[retry] 的无参便捷入口）。
  Future<void> retryFailed() => retry();

  /// 切换搜索类型：当前渠道不支持的类型忽略。
  void selectSearchKind(SearchKind kind) => session.selectKind(kind);

  void updateSearchQuery(String query) => session.updateQuery(query);

  /// 提交搜索（不走防抖，立即发起）。
  ///
  /// 建议 / 纠错 / 回车都复用本命令。
  void submitSearch(String query) {
    session.submit(query);
  }

  void clearSearch() => session.clear();

  /// 释放搜索结果（托盘隐藏时由内存守卫调用）。
  void releaseSearchResults() => session.releaseResults();

  Future<void> performSearch(String query) => session.perform(query);

  /// 播放搜索结果：队列只取当前渠道的已加载结果，不混平台队列。
  void playItem(SearchRow row) {
    final results = searchKind == SearchKind.lyric ? lyricResults : songResults;
    final items = results.items;
    // 行不属于当前渠道（旧结果）时不播，避免用错渠道的队列。
    if (items.isEmpty || row.id.sourceKey != activeSourceKey) return;
    final index = items.indexWhere((entry) => entry.id == row.id);
    _playbackProvider.playDomainTracks(
      [for (final entry in items) entry.track],
      index < 0 ? 0 : index,
      contextName: activeSource?.displayName,
    );
  }

  Future<PagedResult<SearchRow>> _fetchSongPage(
    String sourceKey,
    String keyword,
    int page,
  ) async {
    final catalog = _catalogService;
    if (catalog == null) throw StateError('音源未初始化');
    final result = await DataPathTrace.async(
      'search.page',
      () => catalog.search(
        sourceKey,
        SearchQuery(keyword: keyword, page: page, limit: _searchPageSize),
      ),
      fields: () => {'source': sourceKey, 'page': page},
    );
    return PagedResult(
      items: [for (final track in result.items) SearchRow(track: track)],
      hasMore: result.hasMore,
      total: result.total,
    );
  }

  Future<PagedResult<ArtistSummary>> _fetchArtistPage(
    String sourceKey,
    String keyword,
    int page,
  ) async {
    final catalog = _catalogService;
    if (catalog == null) throw StateError('音源未初始化');
    final result = await catalog.searchArtists(
      sourceKey,
      SearchQuery(keyword: keyword, page: page, limit: _searchPageSize),
    );
    return PagedResult(
      items: result.items,
      hasMore: result.hasMore,
      total: result.total,
    );
  }

  Future<PagedResult<SearchRow>> _fetchLyricPage(
    String sourceKey,
    String keyword,
    int page,
  ) async {
    final catalog = _catalogService;
    if (catalog == null) throw StateError('音源未初始化');
    final result = await catalog.searchLyrics(
      sourceKey,
      SearchQuery(keyword: keyword, page: page, limit: _searchPageSize),
    );
    return PagedResult(
      items: [
        for (final hit in result.items)
          SearchRow(track: hit.track, lyricSnippet: hit.snippet),
      ],
      hasMore: result.hasMore,
      total: result.total,
    );
  }

  @override
  void dispose() {
    session.removeListener(_onSessionChanged);
    session.dispose();
    super.dispose();
  }
}
