import 'package:logging/logging.dart';
import 'dart:async';
import 'package:material_ui/material_ui.dart';
import '../data/catalog/catalog_service.dart';
import '../data/mapping/track_mapper.dart';
import '../domain/models/artist.dart';
import '../domain/models/catalog.dart' show SearchKind, SearchQuery;
import '../domain/models/failure.dart';
import '../domain/models/source.dart' as domain;
import '../domain/ports/source_registry.dart';
import '../sources/raw_track.dart';
import '../sources/source_manager.dart' show SourceKind, SourceOption;
import '../sources/source_track.dart';
import 'paged_list_controller.dart';
import 'playback_provider.dart';

final _logger = Logger('molia.search_provider');

/// 搜索状态（内部经 [CatalogService]/[SourceRegistry]）。
///
/// 公开 API：`filteredResults` / `loadMore` / `sourceOptions` / 分页 / 空态；
/// `_sourceTracks` 旁路保留原始曲目，`playItem` 把 `SourceTrack` 队列交给
/// [PlaybackProvider] 播放。
class SearchProvider extends ChangeNotifier {
  final PlaybackProvider _playbackProvider;

  /// 搜索入口：带 single-flight + LRU + TTL 的目录服务（可为 null：无音源）。
  final CatalogService? _catalogService;

  /// 音源注册表：描述列表与变更通知来源（可为 null：无音源）。
  final SourceRegistry? _sourceRegistry;

  StreamSubscription<void>? _registrySubscription;

  String _searchQuery = '';
  bool _isSearching = false;
  Map<String, List<Map<String, dynamic>>> _searchResults = {};
  String? _errorMessage;
  SourceFailure? _failure;
  List<Map<String, dynamic>> _filteredResultsCache = const [];
  bool _filteredResultsDirty = true;

  /// 当前搜索音源：音源 key（kw/kg/tx/wy/mg/脚本自定义源）。
  /// 无可用音源时为空字符串（搜索结果页展示空态引导）。
  String _sourceKey = '';

  /// 音源搜索结果的原始曲目（用于播放时回传给音源脚本）
  List<SourceTrack> _sourceTracks = const [];

  /// 当前搜索类型（搜索页「单曲 / 歌手」分段；默认单曲）。
  SearchKind _kind = SearchKind.song;

  // 歌手类型会话：与单曲各自分页 / 错误 / 过期守卫（切类型才发起请求）。
  List<ArtistSummary> _artistResults = const [];
  bool _artistSearching = false;
  SourceFailure? _artistFailure;
  String? _artistErrorMessage;

  /// 歌手分页会话的关键词（pager 的 fetchPage 读取；换词/清空时重置）。
  String _artistPagerQuery = '';

  // 歌词类型会话：曲目（与单曲同构的播放 / 收藏路径）+ 命中歌词片段并行表。
  List<SourceTrack> _lyricTracks = const [];
  Map<String, String> _lyricSnippets = const {};
  bool _lyricSearching = false;
  SourceFailure? _lyricFailure;
  String? _lyricErrorMessage;

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

  // 单调递增的请求 id：丢弃过期搜索结果。
  int _searchRequestId = 0;

  Timer? _debounceTimer;
  static const _debounceTime = Duration(milliseconds: 500);

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
    _registrySubscription =
        _sourceRegistry?.changes.listen((_) => _onSourcesChanged());
    _onSourcesChanged();
  }

  String get searchQuery => _searchQuery;
  Map<String, List<Map<String, dynamic>>> get searchResults => _searchResults;
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

  bool get isSearching => switch (_kind) {
        SearchKind.song => _isSearching,
        SearchKind.artist => _artistSearching,
        SearchKind.lyric => _lyricSearching,
      };

  String? get errorMessage => switch (_kind) {
        SearchKind.song => _errorMessage,
        SearchKind.artist => _artistErrorMessage,
        SearchKind.lyric => _lyricErrorMessage,
      };

  /// 归一化失败对象（UI 兼容期仍消费 [errorMessage] 字符串）。
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

  /// 「歌词」类型的结果（与单曲同构的条目 + `lyric_snippet` 命中片段）。
  List<Map<String, dynamic>> get lyricResults => [
        for (final track in _lyricTracks)
          {
            ..._sourceTrackToItem(track),
            'lyric_snippet': _lyricSnippets[track.id],
          },
      ];

  /// 是否已选中可用音源（空音源时搜索结果页展示引导空态）。
  bool get hasSelectedSource => _sourceKey.isNotEmpty;

  /// 可选音源列表：由 [SourceRegistry] 的描述列表映射为兼容 [SourceOption]，
  /// 顺序即用户自定义排序（`lx_source_order`）。
  List<SourceOption> get sourceOptions {
    final descriptors = _sourceRegistry?.descriptors;
    if (descriptors == null) return const [];
    return [
      for (final descriptor in descriptors)
        SourceOption(
          key: descriptor.key,
          name: descriptor.displayName,
          kind: _legacyKind(descriptor.kind),
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
      _searchResults = {};
      _sourceTracks = const [];
      _resetPagination();
      _clearArtistSession();
      _clearLyricSession();
      _markFilteredResultsDirty();
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
    _artistErrorMessage = null;
    _artistSearching = false;
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
    _lyricSnippets = const {};
    _lyricFailure = null;
    _lyricErrorMessage = null;
    _lyricSearching = false;
  }

  /// 切换搜索类型：不支持的类型忽略；目标类型尚无结果时按当前关键词取首屏。
  void selectSearchKind(SearchKind kind) {
    if (kind == _kind || !supportedSearchKinds.contains(kind)) return;
    _kind = kind;
    notifyListeners();
    final query = _searchQuery.trim();
    if (query.isEmpty) return;
    if (kind == SearchKind.artist) {
      if (_artistResults.isEmpty && !_artistSearching) {
        unawaited(_performArtistSearch(query));
      }
      return;
    }
    if (kind == SearchKind.lyric) {
      if (_lyricTracks.isEmpty && !_lyricSearching) {
        unawaited(_performLyricSearch(query));
      }
      return;
    }
    if (_sourceTracks.isEmpty && !_isSearching) {
      unawaited(performSearch(query));
    }
  }

  /// 切换搜索音源。
  void selectSource(String key) {
    if (key == _sourceKey) return;
    _sourceKey = key;
    _errorMessage = null;
    _failure = null;
    _sourceTracks = const [];
    _searchResults = {};
    _resetPagination();
    _clearArtistSession();
    _clearLyricSession();
    _markFilteredResultsDirty();
    if (!supportedSearchKinds.contains(_kind)) _kind = SearchKind.song;
    notifyListeners();
    if (_searchQuery.trim().isNotEmpty) {
      submitSearch(_searchQuery);
    }
  }

  bool get isSearchActive => _searchQuery.isNotEmpty;

  List<Map<String, dynamic>> get filteredResults {
    if (_filteredResultsDirty) {
      _filteredResultsCache = _buildFilteredResults();
      _filteredResultsDirty = false;
    }
    return _filteredResultsCache;
  }

  List<Map<String, dynamic>> _buildFilteredResults() {
    final List<Map<String, dynamic>> result = [];

    if (_searchQuery.isEmpty) return result;

    if (_searchResults.containsKey('tracks')) {
      result.addAll(_searchResults['tracks']!
          .where((t) {
            final isLxTrack = t['_sourceTrack'] != null;
            final hasImage = t['images'] != null &&
                t['images'].isNotEmpty &&
                t['images'][0]['url'] != null;
            return hasImage || isLxTrack;
          })
          .map((t) => ({...t, 'type': 'track'})));
    }

    if (_searchResults.containsKey('albums')) {
      result.addAll(_searchResults['albums']!
          .where((a) {
            final hasImage = a['images'] != null &&
                a['images'].isNotEmpty &&
                a['images'][0]['url'] != null;
            return hasImage;
          })
          .map((a) => ({...a, 'type': 'album'})));
    }

    if (_searchResults.containsKey('playlists')) {
      result.addAll(_searchResults['playlists']!
          .where((p) {
            final hasImage = p['images'] != null &&
                p['images'].isNotEmpty &&
                p['images'][0]['url'] != null;
            return hasImage;
          })
          .map((p) => ({...p, 'type': 'playlist'})));
    }

    if (_searchResults.containsKey('artists')) {
      result.addAll(_searchResults['artists']!
          .where((a) {
            final hasImage = a['images'] != null &&
                a['images'].isNotEmpty &&
                a['images'][0]['url'] != null;
            return hasImage;
          })
          .map((a) => ({...a, 'type': 'artist'})));
    }

    return result;
  }

  void _markFilteredResultsDirty() {
    _filteredResultsDirty = true;
  }

  void updateSearchQuery(String query) {
    if (query == _searchQuery) return;

    _debounceTimer?.cancel();

    _searchQuery = query;
    _errorMessage = null;
    _failure = null;
    _resetPagination();
    _clearArtistSession();
    _clearLyricSession();
    _markFilteredResultsDirty();

    if (query.isEmpty) {
      _searchResults = {};
      _sourceTracks = const [];
      _isSearching = false;
      _searchRequestId++;
      _markFilteredResultsDirty();
      notifyListeners();
      return;
    }

    final requestId = ++_searchRequestId;
    _debounceTimer = Timer(_debounceTime, () {
      performSearch(query, requestId: requestId);
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
      _searchResults = {};
      _sourceTracks = const [];
      _errorMessage = null;
      _failure = null;
      _isSearching = false;
      _searchRequestId++;
      _markFilteredResultsDirty();
      notifyListeners();
      return;
    }

    if (query != _searchQuery) {
      _searchQuery = query;
      _errorMessage = null;
      _failure = null;
      _markFilteredResultsDirty();
      notifyListeners();
    }

    final requestId = ++_searchRequestId;
    performSearch(query, requestId: requestId);
  }

  void clearSearch() {
    _debounceTimer?.cancel();
    _searchQuery = '';
    _searchResults = {};
    _sourceTracks = const [];
    _errorMessage = null;
    _failure = null;
    _isSearching = false;
    _searchRequestId++;
    _resetPagination();
    _clearArtistSession();
    _clearLyricSession();
    _markFilteredResultsDirty();
    notifyListeners();
  }

  Future<void> performSearch(String query, {int? requestId}) async {
    if (query.trim().isEmpty) return;
    // 旧 debounce 回调（已有更新的请求）直接丢弃。
    if (requestId != null && requestId != _searchRequestId) return;

    // 按当前类型分发：歌手 / 歌词走各自会话（单曲路径保持原语义）。
    if (_kind == SearchKind.artist) {
      return _performArtistSearch(query, requestId: requestId);
    }
    if (_kind == SearchKind.lyric) {
      return _performLyricSearch(query, requestId: requestId);
    }

    // 无可用音源：展示空态引导，不发起请求。
    if (_sourceKey.isEmpty) {
      _isSearching = false;
      _errorMessage = null;
      _failure = null;
      _sourceTracks = const [];
      _searchResults = {};
      _resetPagination();
      _markFilteredResultsDirty();
      notifyListeners();
      return;
    }

    _pagerQuery = query;
    _isSearching = true;
    _errorMessage = null;
    _failure = null;
    _pager.reset();
    notifyListeners();

    await _pager.loadFirstPage();
    _applyPagerState();
    _isSearching = false;
    notifyListeners();
  }

  /// pager 的取页实现：按当前音源与分页会话关键词请求 CatalogService。
  Future<PagedResult<SourceTrack>> _fetchSearchPage(int page) async {
    final catalog = _catalogService;
    if (catalog == null) {
      throw StateError('音源未初始化');
    }
    final result = await catalog.search(
      _sourceKey,
      SearchQuery(keyword: _pagerQuery, page: page, limit: _searchPageSize),
    );
    return PagedResult(
      items: [for (final track in result.items) sourceTrackFromTrack(track)],
      hasMore: result.hasMore,
      total: result.total,
    );
  }

  /// 把分页状态机的结果映射到搜索兼容状态（tracks map / 失败 / 分页元数据）。
  ///
  /// 失败时保留已有结果：错误提示与列表并存，不闪空。
  void _applyPagerState() {
    final error = _pager.error;
    if (error != null) {
      _logger.fine('Search failed: $error');
      _failure = SourceFailure.from(error);
      _errorMessage = 'Search failed: $error';
    } else {
      _sourceTracks = _pager.items;
      _searchResults = {
        'tracks': _sourceTracks.map(_sourceTrackToItem).toList(),
      };
    }
    _markFilteredResultsDirty();
  }

  /// pager 的取页实现：歌手搜索（`CatalogService.searchArtists`，5min 缓存）。
  Future<PagedResult<ArtistSummary>> _fetchArtistPage(int page) async {
    final catalog = _catalogService;
    if (catalog == null) {
      throw StateError('音源未初始化');
    }
    final result = await catalog.searchArtists(
      _sourceKey,
      SearchQuery(keyword: _artistPagerQuery, page: page, limit: _searchPageSize),
    );
    return PagedResult(
      items: result.items,
      hasMore: result.hasMore,
      total: result.total,
    );
  }

  /// 歌手搜索首屏：独立错误态与过期守卫（失败保留已有结果）。
  Future<void> _performArtistSearch(String query, {int? requestId}) async {
    if (query.trim().isEmpty) return;
    if (requestId != null && requestId != _searchRequestId) return;

    if (_sourceKey.isEmpty) {
      _artistSearching = false;
      _artistFailure = null;
      _artistErrorMessage = null;
      _artistResults = const [];
      _resetArtistPagination();
      notifyListeners();
      return;
    }

    _artistPagerQuery = query;
    _artistSearching = true;
    _artistFailure = null;
    _artistErrorMessage = null;
    _artistPager.reset();
    notifyListeners();

    await _artistPager.loadFirstPage();
    _applyArtistPagerState();
    _artistSearching = false;
    notifyListeners();
  }

  /// 把歌手分页状态机的结果映射为兼容状态（结果 / 失败）。
  void _applyArtistPagerState() {
    final error = _artistPager.error;
    if (error != null) {
      _logger.fine('Artist search failed: $error');
      _artistFailure = SourceFailure.from(error);
      _artistErrorMessage = 'Search failed: $error';
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
      SearchQuery(keyword: _lyricPagerQuery, page: page, limit: _searchPageSize),
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

  /// 歌词搜索首屏：独立错误态与过期守卫（失败保留已有结果）。
  Future<void> _performLyricSearch(String query, {int? requestId}) async {
    if (query.trim().isEmpty) return;
    if (requestId != null && requestId != _searchRequestId) return;

    if (_sourceKey.isEmpty) {
      _clearLyricSession();
      notifyListeners();
      return;
    }

    _lyricPagerQuery = query;
    _lyricSearching = true;
    _lyricFailure = null;
    _lyricErrorMessage = null;
    _pendingLyricSnippets = {};
    _lyricPager.reset();
    notifyListeners();

    await _lyricPager.loadFirstPage();
    _applyLyricPagerState();
    _lyricSearching = false;
    notifyListeners();
  }

  /// 把歌词分页状态机的结果映射到兼容状态（曲目 + 片段 / 失败）。
  void _applyLyricPagerState() {
    final error = _lyricPager.error;
    if (error != null) {
      _logger.fine('Lyric search failed: $error');
      _lyricFailure = SourceFailure.from(error);
      _lyricErrorMessage = 'Search failed: $error';
    } else {
      _lyricTracks = _lyricPager.items;
      _lyricSnippets = Map.unmodifiable(_pendingLyricSnippets);
    }
  }

  /// 加载下一页音源搜索结果。
  ///
  /// 过期守卫与跨页去重由 [PagedListController] 持有：换词/换音源时
  /// `_resetPagination` 已使在途请求过期，旧响应不会覆盖新状态。
  Future<void> loadMore() async {
    if (_kind == SearchKind.artist) {
      if (_artistSearching ||
          !_artistPager.hasMore ||
          !hasSelectedSource ||
          _artistPagerQuery.trim().isEmpty) {
        return;
      }
      await _artistPager.loadMore();
      _applyArtistPagerState();
      notifyListeners();
      return;
    }
    if (_kind == SearchKind.lyric) {
      if (_lyricSearching ||
          !_lyricPager.hasMore ||
          !hasSelectedSource ||
          _lyricPagerQuery.trim().isEmpty) {
        return;
      }
      await _lyricPager.loadMore();
      _applyLyricPagerState();
      notifyListeners();
      return;
    }
    if (_isSearching ||
        !_pager.hasMore ||
        !hasSelectedSource ||
        _pagerQuery.trim().isEmpty) {
      return;
    }
    await _pager.loadMore();
    _applyPagerState();
    notifyListeners();
  }

  Map<String, dynamic> _sourceTrackToItem(SourceTrack track) {
    final images = (track.coverUrl != null && track.coverUrl!.isNotEmpty)
        ? [
            {'url': track.coverUrl}
          ]
        : const <Map<String, String>>[];
    // 歌手列表带平台内 id（raw `_artists`，内置平台解析时注入）：搜索结果行
    // 据此把每个歌手名做成进歌手页的链接；缺 id（脚本源）时退化为纯文本。
    final artists = artistsFromRaw(track.raw);
    return {
      'type': 'track',
      'id': track.id,
      'name': track.title,
      'images': images,
      'artists': artists.isEmpty
          ? [
              {'name': track.artist.isEmpty ? '未知歌手' : track.artist}
            ]
          : [
              for (final artist in artists)
                {'name': artist.name, 'id': artist.id},
            ],
      'album': {
        'name': track.album,
        'images': images,
      },
      'duration_ms': track.duration?.inMilliseconds ?? 0,
      'source': track.sourceKey,
      '_sourceTrack': track,
    };
  }

  /// 播放搜索结果：本地音源曲目交给 PlaybackProvider 播放。
  ///
  /// 队列取当前类型已加载的列表（单曲 / 歌词各自成队）。
  void playItem(Map<String, dynamic> item) {
    final sourceTrack = item['_sourceTrack'];
    if (sourceTrack is! SourceTrack) {
      _logger.fine('Error: Search item missing source track.');
      return;
    }
    final queue =
        _kind == SearchKind.lyric ? List<SourceTrack>.of(_lyricTracks)
            : List<SourceTrack>.of(_sourceTracks);
    if (queue.isEmpty) return;
    final index = queue.indexWhere((track) => track.id == sourceTrack.id);
    _playbackProvider.playSourceTracks(
      queue,
      index < 0 ? 0 : index,
      contextName: sourceDisplayName,
    );
  }

  /// 领域音源种类 → 兼容 `SourceKind`（两者枚举名一一对应）。
  ///
  /// `local`（本地下载副本）不出现在搜索 / 渠道列表，该分支不可达；
  /// 出现即编程错误，显式抛出而不是静默兜底。
  SourceKind _legacyKind(domain.SourceKind kind) {
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
