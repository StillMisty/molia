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

  // 分页状态
  static const int _searchPageSize = 30;
  int _currentPage = 1;
  int? _totalResults;
  bool _hasMore = false;
  bool _isLoadingMore = false;

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
  int get currentPage => _currentPage;

  /// 平台返回的结果总数（部分平台/脚本不返回则为 null）。
  int? get totalResults => _totalResults;

  /// 是否还有下一页可加载。
  bool get hasMore => _hasMore;

  /// 是否正在加载下一页。
  bool get isLoadingMore => _isLoadingMore;

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

  /// 重置分页状态（换关键词 / 换音源 / 清空搜索时调用）。
  void _resetPagination() {
    _currentPage = 1;
    _totalResults = null;
    _hasMore = false;
    _isLoadingMore = false;
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

    final activeRequestId = requestId ?? ++_searchRequestId;
    final sourceKeyAtStart = _sourceKey;

    // 无可用音源：展示空态引导，不发起请求。
    if (sourceKeyAtStart.isEmpty) {
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

    _sourceKeyUsedInRequest = sourceKeyAtStart;
    _isSearching = true;
    _errorMessage = null;
    _failure = null;
    _resetPagination();
    notifyListeners();

    try {
      final catalog = _catalogService;
      if (catalog == null) {
        throw StateError('音源未初始化');
      }
      final result = await catalog.search(
        sourceKeyAtStart,
        SearchQuery(keyword: query, page: 1, limit: _searchPageSize),
      );

      if (!_isLatestRequest(activeRequestId, query)) return;

      final tracks = [
        for (final track in result.items) sourceTrackFromTrack(track),
      ];
      _sourceTracks = tracks;
      _currentPage = 1;
      _hasMore = result.hasMore;
      _totalResults = result.total;
      _searchResults = {
        'tracks': tracks.map(_sourceTrackToItem).toList(),
      };
      _markFilteredResultsDirty();
    } catch (e) {
      _logger.d('Search failed: $e');
      if (!_isLatestRequest(activeRequestId, query)) return;
      _failure = SourceFailure.from(e);
      _errorMessage = 'Search failed: $e';
    } finally {
      if (_isLatestRequest(activeRequestId, query)) {
        _isSearching = false;
        notifyListeners();
      }
    }
  }

  /// 加载下一页音源搜索结果。
  ///
  /// 延续当前 query/音源；若期间用户换了关键词或音源（requestId 变化），
  /// 结果会被丢弃，避免旧请求覆盖新状态。
  Future<void> loadMore() async {
    if (_isSearching ||
        _isLoadingMore ||
        !_hasMore ||
        !hasSelectedSource ||
        _searchQuery.trim().isEmpty) {
      return;
    }
    final catalog = _catalogService;
    if (catalog == null) return;

    final requestId = _searchRequestId;
    final sourceKeyAtStart = _sourceKey;
    final query = _searchQuery;
    final nextPage = _currentPage + 1;

    _isLoadingMore = true;
    notifyListeners();

    try {
      final result = await catalog.search(
        sourceKeyAtStart,
        SearchQuery(keyword: query, page: nextPage, limit: _searchPageSize),
      );

      if (!_isLatestRequest(requestId, query)) return;

      // 跨页去重：部分平台分页边界可能重复返回同一首歌
      final existingIds = _sourceTracks.map((t) => t.id).toSet();
      final freshTracks = [
        for (final track in result.items)
          if (!existingIds.contains(sourceTrackFromTrack(track).id))
            sourceTrackFromTrack(track),
      ];
      _sourceTracks = [..._sourceTracks, ...freshTracks];
      _currentPage = nextPage;
      _hasMore = result.hasMore;
      _totalResults = result.total ?? _totalResults;
      _searchResults = {
        'tracks': _sourceTracks.map(_sourceTrackToItem).toList(),
      };
      _markFilteredResultsDirty();
    } catch (e) {
      _logger.d('Load more failed: $e');
      if (_isLatestRequest(requestId, query)) {
        _failure = SourceFailure.from(e);
        _errorMessage = 'Search failed: $e';
      }
    } finally {
      _isLoadingMore = false;
      notifyListeners();
    }
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

  bool _isLatestRequest(int requestId, String query) {
    return requestId == _searchRequestId &&
        query == _searchQuery &&
        _sourceKey == _sourceKeyUsedInRequest;
  }

  /// 缓存发起请求时的音源 key，避免切换音源后旧结果覆盖。
  String _sourceKeyUsedInRequest = '';

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
    super.dispose();
  }
}
