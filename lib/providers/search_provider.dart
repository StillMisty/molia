import 'package:logger/logger.dart';
import 'dart:async';
import 'package:material_ui/material_ui.dart';
import '../data/catalog/catalog_service.dart';
import '../data/mapping/track_mapper.dart';
import '../domain/models/catalog.dart' show SearchQuery;
import '../domain/models/failure.dart';
import '../domain/models/source.dart' as domain;
import '../domain/ports/source_registry.dart';
import '../sources/source_manager.dart' show SourceKind, SourceOption;
import '../sources/source_track.dart';
import 'paged_list_controller.dart';
import 'playback_provider.dart';

final _logger = Logger();

/// 搜索状态（阶段 2 改道：内部经 [CatalogService]/[SourceRegistry]）。
///
/// 公开 API / 类名 / `filteredResults` / `loadMore` / `sourceOptions` / 分页 /
/// 空态行为与改道前完全一致；`_sourceTracks` 旁路保留，`playItem` 仍把
/// 旧 `SourceTrack` 队列交给 [PlaybackProvider]。
class SearchProvider extends ChangeNotifier {
  final PlaybackProvider _playbackProvider;

  /// 搜索入口：带 single-flight + LRU + TTL 的目录服务（可为 null：无音源）。
  final CatalogService? _catalogService;

  /// 音源注册表：描述列表与变更通知来源（可为 null：无音源）。
  final SourceRegistry? _sourceRegistry;

  StreamSubscription<void>? _registrySubscription;

  // Search state
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

  // 分页状态：唯一状态机 PagedListController（首屏/加载更多/失败/过期守卫/去重）
  static const int _searchPageSize = 30;

  /// 当前分页会话的关键词（pager 的 fetchPage 读取；换词/清空时重置）。
  String _pagerQuery = '';

  late final PagedListController<SourceTrack> _pager;

  // Track search requests to avoid applying stale results.
  int _searchRequestId = 0;

  // Debounce timer for search
  Timer? _debounceTimer;
  static const _debounceTime = Duration(milliseconds: 500);

  // Constructor
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
    _registrySubscription =
        _sourceRegistry?.changes.listen((_) => _onSourcesChanged());
    _onSourcesChanged();
  }

  // Getters
  String get searchQuery => _searchQuery;
  bool get isSearching => _isSearching;
  Map<String, List<Map<String, dynamic>>> get searchResults => _searchResults;
  String? get errorMessage => _errorMessage;

  /// 归一化失败对象（阶段 3 新增；UI 兼容期仍消费 [errorMessage] 字符串）。
  SourceFailure? get failure => _failure;
  String get sourceKey => _sourceKey;

  /// 当前已加载到第几页（从 1 开始）。
  int get currentPage => _pager.page;

  /// 平台返回的结果总数（部分平台/脚本不返回则为 null）。
  int? get totalResults => _pager.total;

  /// 是否还有下一页可加载。
  bool get hasMore => _pager.hasMore;

  /// 是否正在加载下一页。
  bool get isLoadingMore => _pager.isLoadingMore;

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
      _markFilteredResultsDirty();
    }
    notifyListeners();
  }

  /// 重置分页状态（换关键词 / 换音源 / 清空搜索时调用）：过期在途请求。
  void _resetPagination() {
    _pagerQuery = '';
    _pager.reset();
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
    _markFilteredResultsDirty();
    notifyListeners();
    if (_searchQuery.trim().isNotEmpty) {
      submitSearch(_searchQuery);
    }
  }

  // Check if search is active
  bool get isSearchActive => _searchQuery.isNotEmpty;

  // Get combined and filtered search results
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

    // Add tracks if available
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

    // Add albums if available
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

    // Add playlists if available
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

    // Add artists if available
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

  // Update search query with debounce
  void updateSearchQuery(String query) {
    if (query == _searchQuery) return;

    // Cancel previous timer only when query changes.
    _debounceTimer?.cancel();

    _searchQuery = query;
    _errorMessage = null;
    _failure = null;
    _resetPagination();
    _markFilteredResultsDirty();

    // Clear results if query is empty
    if (query.isEmpty) {
      _searchResults = {};
      _sourceTracks = const [];
      _isSearching = false;
      _searchRequestId++;
      _markFilteredResultsDirty();
      notifyListeners();
      return;
    }

    // Set new timer for search
    final requestId = ++_searchRequestId;
    _debounceTimer = Timer(_debounceTime, () {
      performSearch(query, requestId: requestId);
    });

    // Notify listeners immediately about query change
    notifyListeners();
  }

  // Immediate search without debounce (for submit action)
  void submitSearch(String query) {
    // Cancel any pending debounce
    _debounceTimer?.cancel();
    _resetPagination();

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

  // Clear search
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
    _markFilteredResultsDirty();
    notifyListeners();
  }

  // Perform the actual search
  Future<void> performSearch(String query, {int? requestId}) async {
    if (query.trim().isEmpty) return;
    // 旧 debounce 回调（已有更新的请求）直接丢弃。
    if (requestId != null && requestId != _searchRequestId) return;

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
  /// 失败时保留旧结果（与旧实现一致：错误提示与旧列表并存，不闪空）。
  void _applyPagerState() {
    final error = _pager.error;
    if (error != null) {
      _logger.d('Search failed: $error');
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

  /// 加载下一页音源搜索结果。
  ///
  /// 过期守卫与跨页去重由 [PagedListController] 持有：换词/换音源时
  /// `_resetPagination` 已使在途请求过期，旧响应不会覆盖新状态。
  Future<void> loadMore() async {
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
    return {
      'type': 'track',
      'id': track.id,
      'name': track.title,
      'images': images,
      'artists': [
        {'name': track.artist.isEmpty ? '未知歌手' : track.artist},
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
  void playItem(Map<String, dynamic> item) {
    final sourceTrack = item['_sourceTrack'];
    if (sourceTrack is! SourceTrack) {
      _logger.d('Error: Search item missing source track.');
      return;
    }
    final index = _sourceTracks.indexWhere((t) => t.id == sourceTrack.id);
    _playbackProvider.playSourceTracks(
      _sourceTracks,
      index < 0 ? 0 : index,
      contextName: sourceDisplayName,
    );
  }

  /// 领域音源种类 → 兼容 `SourceKind`（两者枚举名一一对应）。
  SourceKind _legacyKind(domain.SourceKind kind) {
    switch (kind) {
      case domain.SourceKind.builtin:
        return SourceKind.builtin;
      case domain.SourceKind.lx:
        return SourceKind.lx;
      case domain.SourceKind.anyListen:
        return SourceKind.anyListen;
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _registrySubscription?.cancel();
    _pager.dispose();
    super.dispose();
  }
}
