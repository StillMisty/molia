import 'package:logging/logging.dart';

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../app/perf/data_path_trace.dart';
import '../data/catalog/catalog_service.dart';
import '../data/mapping/track_mapper.dart';
import '../domain/models/artist.dart';
import '../domain/models/catalog.dart' show SearchKind, SearchQuery;
import '../domain/models/failure.dart';
import '../domain/models/source.dart' as domain;
import '../domain/ports/source_registry.dart';
import '../sources/source_manager.dart' show SourceKind, SourceOption;
import '../sources/source_track.dart';
import 'paged_list_controller.dart';
import 'playback_provider.dart';
import 'search_row.dart';

export 'search_row.dart' show SearchRow;

final _logger = Logger('molia.search_provider');

/// 搜索状态（内部经 [CatalogService]/[SourceRegistry]）。
///
/// 公开 API：`filteredResults` / `loadMore` / `sourceOptions` / 分页 / 空态；
/// 结果行统一是 [SearchRow]（领域 `Track` + 可选歌词片段）。音源侧的
/// `SourceTrack`（含 raw payload）只在内部保留，播放时由 `playItem` 交给
/// [PlaybackProvider]。
class SearchProvider extends ChangeNotifier {
  final PlaybackProvider _playbackProvider;

  /// 搜索入口：带 single-flight + LRU + TTL 的目录服务（可为 null：无音源）。
  final CatalogService? _catalogService;

  /// 音源注册表：描述列表与变更通知来源（可为 null：无音源）。
  final SourceRegistry? _sourceRegistry;

  StreamSubscription<void>? _registrySubscription;

  String _searchQuery = '';
  SourceFailure? _failure;

  /// 已加载的单曲搜索结果（分页追加、pager 去重后的稳定列表）。
  List<SearchRow> _searchRows = const [];

  /// 当前搜索音源：音源 key（kw/kg/tx/wy/mg/bili/脚本自定义源）。
  /// 无可用音源时为空字符串（搜索结果页展示空态引导）。
  String _sourceKey = '';

  /// 音源搜索结果的原始曲目（用于播放时回传给音源脚本）
  List<SourceTrack> _sourceTracks = const [];

  /// 当前搜索类型（搜索页「单曲 / 歌手」分段；默认单曲）。
  SearchKind _kind = SearchKind.song;

  // 歌手类型会话：与单曲各自分页 / 错误（切类型才发起请求）。
  List<ArtistSummary> _artistResults = const [];
  SourceFailure? _artistFailure;

  /// 歌手分页会话的关键词（pager 的 fetchPage 读取；换词/清空时重置）。
  String _artistPagerQuery = '';

  // 歌词类型会话：曲目（与单曲同构的播放 / 收藏路径）+ 命中歌词片段并行表。
  List<SourceTrack> _lyricTracks = const [];
  List<SearchRow> _lyricRows = const [];
  Map<String, String> _lyricSnippets = const {};
  SourceFailure? _lyricFailure;

  /// 歌词分页会话的关键词（pager 的 fetchPage 读取；换词/清空时重置）。
  String _lyricPagerQuery = '';

  /// 本次歌词分页会话累计的片段表（按曲目 id），成功后随结果发布。
  Map<String, String> _pendingLyricSnippets = {};

  // 分页状态：唯一状态机 PagedListController（首屏/加载更多/失败/过期守卫/去重）
  static const int _searchPageSize = 30;

  /// 当前分页会话的关键词（pager 的 fetchPage 读取；换词/清空时重置）。
  String _pagerQuery = '';

  late final PagedListController<SourceTrack> _pager;
  late final PagedListController<ArtistSummary> _artistPager;
  late final PagedListController<SourceTrack> _lyricPager;

  Timer? _debounceTimer;

  /// 输入防抖：300ms 是「停止输入到发请求」的折中。
  ///
  /// 原值 500ms 在 perf 场景里占首屏搜索墙钟的 90%+（mock 本地音源 1.5ms
  /// 返回，500ms 全是防抖等待）。300ms 仍能跨过中文输入法的组合键停顿，
  /// 且在途请求由 pager 的 reset 过期丢弃，不会因为请求变多而闪旧结果。
  static const _debounceTime = Duration(milliseconds: 300);

  SearchProvider(
    this._playbackProvider, {
    CatalogService? catalogService,
    SourceRegistry? sourceRegistry,
  })  : _catalogService = catalogService,
        _sourceRegistry = sourceRegistry {
    _pager = PagedListController<SourceTrack>(
      keyOf: (track) => track.id,
      fetchPage: _fetchSearchPage,
    );
    _artistPager = PagedListController<ArtistSummary>(
      keyOf: (artist) => artist.id,
      fetchPage: _fetchArtistPage,
    );
    _lyricPager = PagedListController<SourceTrack>(
      keyOf: (track) => track.id,
      fetchPage: _fetchLyricPage,
    );
    _registrySubscription = _sourceRegistry?.changes.listen(
      (_) => _onSourcesChanged(),
    );
    _onSourcesChanged();
  }

  String get searchQuery => _searchQuery;

  /// 已加载的单曲结果（当前音源 / 关键词；分页追加、跨页去重）。
  List<SearchRow> get searchResults => _searchRows;

  String get sourceKey => _sourceKey;

  /// 当前搜索类型（搜索页分段）。
  SearchKind get searchKind => _kind;

  /// 当前音源支持的搜索类型：单曲恒有，歌手 / 歌词按渠道能力位
  /// （UI 按此显隐分段；切到不支持的类型会被 [selectSearchKind] 忽略）。
  List<SearchKind> get supportedSearchKinds {
    final capabilities = _sourceRegistry?.byKey(_sourceKey)?.capabilities;
    return [
      SearchKind.song,
      if (capabilities?.artist ?? false) SearchKind.artist,
      if (capabilities?.lyricSearch ?? false) SearchKind.lyric,
    ];
  }

  /// 是否正在搜索当前类型（首屏加载中）。
  ///
  /// 直接读当前类型分页控制器的加载态（不再维护镜像 flag）。
  bool get isSearching => switch (_kind) {
        SearchKind.song => _pager.isLoading,
        SearchKind.artist => _artistPager.isLoading,
        SearchKind.lyric => _lyricPager.isLoading,
      };

  /// 归一化失败对象（UI 的唯一错误出口：标题走 l10n，详情用 message，
  /// 不再暴露 `'Search failed: $e'` 这类原始异常字符串）。
  SourceFailure? get failure => switch (_kind) {
        SearchKind.song => _failure,
        SearchKind.artist => _artistFailure,
        SearchKind.lyric => _lyricFailure,
      };

  /// 当前已加载到第几页（从 1 开始）。
  int get currentPage => switch (_kind) {
        SearchKind.song => _pager.page,
        SearchKind.artist => _artistPager.page,
        SearchKind.lyric => _lyricPager.page,
      };

  /// 平台返回的结果总数（部分平台/脚本不返回则为 null）。
  int? get totalResults => switch (_kind) {
        SearchKind.song => _pager.total,
        SearchKind.artist => _artistPager.total,
        SearchKind.lyric => _lyricPager.total,
      };

  /// 是否还有下一页可加载。
  bool get hasMore => switch (_kind) {
        SearchKind.song => _pager.hasMore,
        SearchKind.artist => _artistPager.hasMore,
        SearchKind.lyric => _lyricPager.hasMore,
      };

  /// 是否正在加载下一页。
  bool get isLoadingMore => switch (_kind) {
        SearchKind.song => _pager.isLoadingMore,
        SearchKind.artist => _artistPager.isLoadingMore,
        SearchKind.lyric => _lyricPager.isLoadingMore,
      };

  /// 「歌手」类型的结果（当前音源支持歌手能力时才有内容）。
  List<ArtistSummary> get artistResults => _artistResults;

  /// 「歌词」类型的结果（与单曲同构的条目 + [SearchRow.lyricSnippet]）。
  List<SearchRow> get lyricResults => _lyricRows;

  /// 是否已选中可用音源（空音源时搜索结果页展示引导空态）。
  bool get hasSelectedSource => _sourceKey.isNotEmpty;

  /// 可选音源列表：由 [SourceRegistry] 的描述列表映射为 [SourceOption]，
  /// 顺序即用户自定义排序（`lx_source_order`）。
  List<SourceOption> get sourceOptions {
    final descriptors = _sourceRegistry?.descriptors;
    if (descriptors == null) return const [];
    return [
      for (final descriptor in descriptors)
        SourceOption(
          key: descriptor.key,
          name: descriptor.displayName,
          kind: _sourceKind(descriptor.kind),
          canSearch: descriptor.capabilities.search,
        ),
    ];
  }

  String get sourceDisplayName {
    for (final option in sourceOptions) {
      if (option.key == _sourceKey) return option.name;
    }
    return _sourceKey;
  }

  void _onSourcesChanged() {
    final available = sourceOptions;
    // 当前音源仍可用：仅通知 UI（音源列表可能变化）。
    if (_sourceKey.isNotEmpty && available.any((o) => o.key == _sourceKey)) {
      notifyListeners();
      return;
    }
    // 未选择 / 音源失效：回退到第一个可用音源，无可用音源则清空。
    final fallback = available.isEmpty ? '' : available.first.key;
    if (fallback != _sourceKey) {
      _sourceKey = fallback;
      _clearSongResults();
      _resetPagination();
      _clearArtistSession();
      _clearLyricSession();
    }
    // 换源后当前类型可能不再可用（如脚本源没有歌手 / 歌词能力）：回退单曲。
    if (!supportedSearchKinds.contains(_kind)) _kind = SearchKind.song;
    notifyListeners();
  }

  /// 重置分页状态（换关键词 / 换音源 / 清空搜索时调用）：过期在途请求。
  void _resetPagination() {
    _pagerQuery = '';
    _pager.reset();
  }

  void _resetArtistPagination() {
    _artistPagerQuery = '';
    _artistPager.reset();
  }

  /// 清空歌手类型的结果与分页（与单曲路径的换词 / 换源同步）。
  void _clearArtistSession() {
    _resetArtistPagination();
    _artistResults = const [];
    _artistFailure = null;
  }

  void _resetLyricPagination() {
    _lyricPagerQuery = '';
    _pendingLyricSnippets = {};
    _lyricPager.reset();
  }

  /// 清空歌词类型的结果与分页（与单曲路径的换词 / 换源同步）。
  void _clearLyricSession() {
    _resetLyricPagination();
    _lyricTracks = const [];
    _lyricRows = const [];
    _lyricSnippets = const {};
    _lyricFailure = null;
  }

  /// 切换搜索类型：不支持的类型忽略；目标类型尚无结果时按当前关键词取首屏。
  void selectSearchKind(SearchKind kind) {
    if (kind == _kind || !supportedSearchKinds.contains(kind)) return;
    _kind = kind;
    notifyListeners();
    final query = _searchQuery.trim();
    if (query.isEmpty) return;
    if (kind == SearchKind.artist) {
      if (_artistResults.isEmpty && !_artistPager.isLoading) {
        unawaited(_performArtistSearch(query));
      }
      return;
    }
    if (kind == SearchKind.lyric) {
      if (_lyricTracks.isEmpty && !_lyricPager.isLoading) {
        unawaited(_performLyricSearch(query));
      }
      return;
    }
    if (_sourceTracks.isEmpty && !_pager.isLoading) {
      unawaited(performSearch(query));
    }
  }

  /// 切换搜索音源。
  void selectSource(String key) {
    if (key == _sourceKey) return;
    _sourceKey = key;
    _failure = null;
    _clearSongResults();
    _resetPagination();
    _clearArtistSession();
    _clearLyricSession();
    if (!supportedSearchKinds.contains(_kind)) _kind = SearchKind.song;
    notifyListeners();
    if (_searchQuery.trim().isNotEmpty) {
      submitSearch(_searchQuery);
    }
  }

  bool get isSearchActive => _searchQuery.isNotEmpty;

  /// 单曲结果列表（无关键词时为空）。
  ///
  /// 行内已有领域曲目：不再按封面过滤（旧 map 的 `_sourceTrack` 判据对
  /// 每条音源结果恒真），分页 / 去重语义由 pager 持有。
  List<SearchRow> get filteredResults =>
      _searchQuery.isEmpty ? const [] : _searchRows;

  /// 清空单曲结果（换词 / 换源 / 清空搜索）。
  void _clearSongResults() {
    _sourceTracks = const [];
    _searchRows = const [];
  }

  void updateSearchQuery(String query) {
    if (query == _searchQuery) return;

    _debounceTimer?.cancel();

    _searchQuery = query;
    _failure = null;
    _resetPagination();
    _clearArtistSession();
    _clearLyricSession();

    if (query.isEmpty) {
      _clearSongResults();
      notifyListeners();
      return;
    }

    // 防抖：只有最后一次输入会触发搜索；在途请求由 pager 的 reset 过期丢弃。
    // 计时从本次输入到真正发请求，用来判断「感知慢」里防抖占多少。
    final debounceWatch = DataPathTrace.enabled ? (Stopwatch()..start()) : null;
    _debounceTimer = Timer(_debounceTime, () {
      if (debounceWatch != null) {
        DataPathTrace.record(
          'search.debounce',
          debounceWatch.elapsed,
          fields: () => {'keyword_len': query.length},
        );
      }
      performSearch(query);
    });

    notifyListeners();
  }

  /// 提交搜索（不走防抖，立即发起）。
  void submitSearch(String query) {
    _debounceTimer?.cancel();
    _resetPagination();
    _clearArtistSession();
    _clearLyricSession();

    if (query.isEmpty) {
      _searchQuery = '';
      _clearSongResults();
      _failure = null;
      notifyListeners();
      return;
    }

    if (query != _searchQuery) {
      _searchQuery = query;
      _failure = null;
      notifyListeners();
    }

    performSearch(query);
  }

  void clearSearch() {
    _debounceTimer?.cancel();
    _searchQuery = '';
    _clearSongResults();
    _failure = null;
    _resetPagination();
    _clearArtistSession();
    _clearLyricSession();
    notifyListeners();
  }

  Future<void> performSearch(String query) async {
    // 归一化一次：搜索缓存 key 含关键词，带首尾空格的输入会命中不同条目
    // 并重复请求（手机键盘自动补空格很常见）。
    final keyword = query.trim();
    if (keyword.isEmpty) return;

    // 按当前类型分发：歌手 / 歌词走各自会话（单曲路径保持原语义）。
    if (_kind == SearchKind.artist) {
      return _performArtistSearch(keyword);
    }
    if (_kind == SearchKind.lyric) {
      return _performLyricSearch(keyword);
    }

    // 无可用音源：展示空态引导，不发起请求。
    if (_sourceKey.isEmpty) {
      _failure = null;
      _clearSongResults();
      _resetPagination();
      notifyListeners();
      return;
    }

    _pagerQuery = keyword;
    _failure = null;
    _pager.reset();
    notifyListeners();

    await _pager.loadFirstPage();
    _applyPagerState();
    notifyListeners();
  }

  /// pager 的取页实现：按当前音源与分页会话关键词请求 CatalogService。
  Future<PagedResult<SourceTrack>> _fetchSearchPage(int page) async {
    final catalog = _catalogService;
    if (catalog == null) {
      throw StateError('音源未初始化');
    }
    final source = _sourceKey;
    final result = await DataPathTrace.async(
      'search.page',
      () => catalog.search(
        source,
        SearchQuery(keyword: _pagerQuery, page: page, limit: _searchPageSize),
      ),
      fields: () => {'source': source, 'page': page},
    );
    final tracks = DataPathTrace.sync(
      'search.map',
      () => [for (final track in result.items) sourceTrackFromTrack(track)],
      fields: () => {'items': result.items.length},
    );
    return PagedResult(
      items: tracks,
      hasMore: result.hasMore,
      total: result.total,
    );
  }

  /// 把分页状态机的结果映射到搜索状态（typed rows / 失败 / 分页元数据）。
  ///
  /// 失败时保留已有结果：错误提示与列表并存，不闪空。
  void _applyPagerState() {
    final error = _pager.error;
    if (error != null) {
      _logger.fine('Search failed: $error');
      _failure = SourceFailure.from(error);
    } else {
      _sourceTracks = _pager.items;
      _searchRows = List.unmodifiable([
        for (final track in _sourceTracks) _searchRowOf(track),
      ]);
    }
  }

  /// pager 的取页实现：歌手搜索（`CatalogService.searchArtists`，5min 缓存）。
  Future<PagedResult<ArtistSummary>> _fetchArtistPage(int page) async {
    final catalog = _catalogService;
    if (catalog == null) {
      throw StateError('音源未初始化');
    }
    final result = await catalog.searchArtists(
      _sourceKey,
      SearchQuery(
        keyword: _artistPagerQuery,
        page: page,
        limit: _searchPageSize,
      ),
    );
    return PagedResult(
      items: result.items,
      hasMore: result.hasMore,
      total: result.total,
    );
  }

  /// 歌手搜索首屏：独立错误态（失败保留已有结果）。
  Future<void> _performArtistSearch(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return;

    if (_sourceKey.isEmpty) {
      _artistFailure = null;
      _artistResults = const [];
      _resetArtistPagination();
      notifyListeners();
      return;
    }

    _artistPagerQuery = keyword;
    _artistFailure = null;
    _artistPager.reset();
    notifyListeners();

    await _artistPager.loadFirstPage();
    _applyArtistPagerState();
    notifyListeners();
  }

  /// 把歌手分页状态机的结果映射为搜索状态（结果 / 失败）。
  void _applyArtistPagerState() {
    final error = _artistPager.error;
    if (error != null) {
      _logger.fine('Artist search failed: $error');
      _artistFailure = SourceFailure.from(error);
    } else {
      _artistResults = _artistPager.items;
    }
  }

  /// pager 的取页实现：按歌词搜歌（`CatalogService.searchLyrics`，5min 缓存）。
  Future<PagedResult<SourceTrack>> _fetchLyricPage(int page) async {
    final catalog = _catalogService;
    if (catalog == null) {
      throw StateError('音源未初始化');
    }
    final result = await catalog.searchLyrics(
      _sourceKey,
      SearchQuery(
        keyword: _lyricPagerQuery,
        page: page,
        limit: _searchPageSize,
      ),
    );
    // 播放需回 SourceTrack（payload 同一引用）；片段按回转过后的曲目 id
    // 建表（与行身份严格一致，分页追加时累计）。
    final items = <SourceTrack>[];
    final snippets = <String, String>{..._pendingLyricSnippets};
    for (final hit in result.items) {
      final track = sourceTrackFromTrack(hit.track);
      items.add(track);
      if (hit.snippet != null) snippets[track.id] = hit.snippet!;
    }
    _pendingLyricSnippets = snippets;
    return PagedResult(
      items: items,
      hasMore: result.hasMore,
      total: result.total,
    );
  }

  /// 歌词搜索首屏：独立错误态（失败保留已有结果）。
  Future<void> _performLyricSearch(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return;

    if (_sourceKey.isEmpty) {
      _clearLyricSession();
      notifyListeners();
      return;
    }

    _lyricPagerQuery = keyword;
    _lyricFailure = null;
    _pendingLyricSnippets = {};
    _lyricPager.reset();
    notifyListeners();

    await _lyricPager.loadFirstPage();
    _applyLyricPagerState();
    notifyListeners();
  }

  /// 把歌词分页状态机的结果映射到搜索状态（typed rows + 片段 / 失败）。
  void _applyLyricPagerState() {
    final error = _lyricPager.error;
    if (error != null) {
      _logger.fine('Lyric search failed: $error');
      _lyricFailure = SourceFailure.from(error);
    } else {
      _lyricTracks = _lyricPager.items;
      _lyricSnippets = Map.unmodifiable(_pendingLyricSnippets);
      _lyricRows = List.unmodifiable([
        for (final track in _lyricTracks)
          SearchRow(
            track: trackFromSourceTrack(track),
            lyricSnippet: _lyricSnippets[track.id],
          ),
      ]);
    }
  }

  /// 加载下一页当前类型（触底 / 底部按钮）。
  ///
  /// 「加载中 / 已到底 / 跨页去重」等守卫由 [PagedListController] 持有：
  /// 换词 / 换音源时的 `_reset*Pagination` 已使在途请求过期，旧响应不会
  /// 覆盖新状态。这里只判定会话是否可用（已选音源 + 当前会话有词）。
  Future<void> loadMore() async {
    if (!hasSelectedSource) return;
    switch (_kind) {
      case SearchKind.song:
        if (_pagerQuery.trim().isEmpty) return;
        await _pager.loadMore();
        _applyPagerState();
      case SearchKind.artist:
        if (_artistPagerQuery.trim().isEmpty) return;
        await _artistPager.loadMore();
        _applyArtistPagerState();
      case SearchKind.lyric:
        if (_lyricPagerQuery.trim().isEmpty) return;
        await _lyricPager.loadMore();
        _applyLyricPagerState();
    }
    notifyListeners();
  }

  /// 音源曲目 → 搜索结果行（领域 Track 的 payload 与 raw 同一引用）。
  SearchRow _searchRowOf(SourceTrack track) =>
      SearchRow(track: trackFromSourceTrack(track));

  /// 播放搜索结果：本地音源曲目交给 PlaybackProvider 播放。
  ///
  /// 队列取当前类型已加载的列表（单曲 / 歌词各自成队）；行身份与
  /// `SourceTrack.id` 同源（`TrackId.uri`）。
  void playItem(SearchRow row) {
    final queue = _kind == SearchKind.lyric
        ? List<SourceTrack>.of(_lyricTracks)
        : List<SourceTrack>.of(_sourceTracks);
    if (queue.isEmpty) return;
    final index = queue.indexWhere((track) => track.id == row.id.uri);
    _playbackProvider.playSourceTracks(
      queue,
      index < 0 ? 0 : index,
      contextName: sourceDisplayName,
    );
  }

  /// 领域音源种类 → UI `SourceKind`（两者枚举名一一对应）。
  ///
  /// `local`（本地下载副本）不出现在搜索 / 渠道列表，该分支不可达；
  /// 出现即编程错误，显式抛出而不是静默兜底。
  SourceKind _sourceKind(domain.SourceKind kind) {
    switch (kind) {
      case domain.SourceKind.builtin:
        return SourceKind.builtin;
      case domain.SourceKind.lx:
        return SourceKind.lx;
      case domain.SourceKind.anyListen:
        return SourceKind.anyListen;
      case domain.SourceKind.local:
        throw StateError('本地下载音源不参与搜索');
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _registrySubscription?.cancel();
    _pager.dispose();
    _artistPager.dispose();
    _lyricPager.dispose();
    super.dispose();
  }
}
