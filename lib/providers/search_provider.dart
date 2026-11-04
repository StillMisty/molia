import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';

import '../app/perf/data_path_trace.dart';
import '../data/catalog/catalog_service.dart';
import '../domain/models/artist.dart';
import '../domain/models/catalog.dart' show LyricHit, SearchKind, SearchQuery;
import '../domain/models/source.dart' show SourceDescriptor;
import '../domain/models/track.dart';
import '../domain/ports/source_registry.dart';
import 'paged_fan_out_run.dart';
import 'paged_list_controller.dart';
import 'playback_provider.dart';
import 'search_branch.dart';
import 'search_row.dart';
import 'search_source_group.dart';
import 'source_fan_out.dart';

export 'search_row.dart' show SearchRow;
export 'search_source_group.dart' show SearchSourceGroup;

/// 单源取页：来源 key + 本轮关键词 + 页码（三种搜索类型共用）。
typedef _PageFetcher<T> = Future<PagedResult<T>> Function(
  String sourceKey,
  String keyword,
  int page,
);

/// 当前渠道的单源搜索状态（内部经 [CatalogService] / [SourceRegistry]）。
///
/// 全局只有一个搜索渠道：`DiscoverProvider.channelKey` 是唯一渠道偏好，
/// 组合根 / 资料页把它同步到 [activeSourceKey]。每个搜索类型各持一条分页
/// 分支；查询代际 / 失败 / 通知节拍统一由 [FanOutSearchSession] 持有：
/// - 换词清空所有旧执行体，晚到的旧响应由查询代际与分页控制器丢弃；
/// - 当前渠道独立分页 / 失败 / 加载态；
/// - 渠道切换时清空旧结果并按当前关键词重搜；不支持搜索的渠道不发请求，
///   由 UI 展示「当前渠道不支持搜索」空态。
class SearchProvider extends ChangeNotifier {
  final PlaybackProvider _playbackProvider;

  /// 搜索入口：带 single-flight + LRU + TTL 的目录服务（可为 null：无音源）。
  final CatalogService? _catalogService;

  /// 音源注册表：描述列表与变更通知来源（可为 null：无音源）。
  final SourceRegistry? _sourceRegistry;

  StreamSubscription<void>? _registrySubscription;

  String _searchQuery = '';
  SearchKind _kind = SearchKind.song;

  /// 当前搜索渠道（与 `DiscoverProvider.channelKey` 同源）。
  ///
  /// 允许是当前版本不可搜索的渠道（脚本未加载 / 渠道无搜索能力）：
  /// 此时 [hasActiveSearchSource] 为 false（activeSource 可能已注册但能力位
  /// 全 false），UI 显示不支持搜索的空态，而不是回退去搜别的渠道。
  String _activeSourceKey = '';

  /// 三种搜索类型各一份分页分支（行形状不同，类型留在分支里）。
  late final SearchBranch<Track, SearchRow> _songs;
  late final SearchBranch<ArtistSummary, ArtistSummary> _artists;
  late final SearchBranch<LyricHit, SearchRow> _lyrics;

  /// 按类型索引的规范控制面：查询 / 分页 / 重试只经这一份。
  late final Map<SearchKind, FanOutSearchControl> _controls;

  /// 最近一次读到的渠道快照：registry.changes 在描述未变化时不得重复发请求。
  List<SourceDescriptor> _lastDescriptors = const [];

  static const int _searchPageSize = 30;

  Timer? _debounceTimer;

  bool _disposed = false;

  /// 批量清空各分支时先暂停转发：一次输入不应触发三次重建。
  bool _relaySearchChanges = true;

  /// 输入防抖：300ms 是「停止输入到发请求」的折中。
  ///
  /// 原值 500ms 在 perf 场景里占首屏搜索墙钟的 90%+（mock 本地音源 1.5ms
  /// 返回，500ms 全是防抖等待）。300ms 仍能跨过中文输入法的组合键停顿，
  /// 且在途请求由执行体的 reset 过期丢弃，不会因为请求变多而闪旧结果。
  static const _debounceTime = Duration(milliseconds: 300);

  SearchProvider(
    this._playbackProvider, {
    this._catalogService,
    this._sourceRegistry,
  }) {
    _songs = _buildBranch<Track, SearchRow>(
      kind: SearchKind.song,
      failureLogLabel: (sourceKey) => 'Search failed ($sourceKey)',
      fetchPage: _fetchSongPage,
      project: (track) => SearchRow(track: track),
      keyOf: (track) => track.id.uri,
    );
    _artists = _buildBranch<ArtistSummary, ArtistSummary>(
      kind: SearchKind.artist,
      failureLogLabel: (sourceKey) => 'Artist search failed ($sourceKey)',
      fetchPage: _fetchArtistPage,
      project: (artist) => artist,
      keyOf: (artist) => artist.id,
    );
    _lyrics = _buildBranch<LyricHit, SearchRow>(
      kind: SearchKind.lyric,
      failureLogLabel: (sourceKey) => 'Lyric search failed ($sourceKey)',
      fetchPage: _fetchLyricPage,
      project: (hit) => SearchRow(track: hit.track, lyricSnippet: hit.snippet),
      keyOf: (hit) => hit.track.id.uri,
      // 同曲目在后续页再次命中时，片段跟随后页（与按页累计片段同口径），
      // 行身份与位置仍取首次出现。
      mergeDuplicate: (existing, incoming) => LyricHit(
        track: existing.track,
        snippet: incoming.snippet ?? existing.snippet,
      ),
    );
    _controls = {
      for (final branch in [_songs, _artists, _lyrics])
        branch.kind: branch.session,
    };
    for (final control in _controls.values) {
      control.addListener(_onSearchChanged);
    }

    _registrySubscription = _sourceRegistry?.changes.listen(
      (_) => _onSourcesChanged(),
    );
    _onSourcesChanged();
  }

  String get searchQuery => _searchQuery;

  /// 当前搜索类型（搜索页分段）。
  SearchKind get searchKind => _kind;

  bool get isSearchActive => _searchQuery.isNotEmpty;

  /// 当前渠道 key（`''` = 尚未确定；不是「全部来源」）。
  String get activeSourceKey => _activeSourceKey;

  /// 当前渠道的搜索描述；渠道未注册 / 脚本未加载时为 null。
  SourceDescriptor? get activeSource {
    for (final descriptor in sourceChannels) {
      if (descriptor.key == _activeSourceKey) return descriptor;
    }
    return null;
  }

  /// 当前渠道是否真的可搜索（Ctrl+F / 空态的唯一判据）。
  ///
  /// 不能用 `activeSource != null`：已注册但 search / artist / lyricSearch
  /// 全为 false 的渠道也要按「不支持搜索」处理。
  bool get hasActiveSearchSource => supportedSearchKinds.isNotEmpty;

  /// 当前关键词已提交、但当前类型还没有真正发起搜索（防抖窗口 / 切类型）。
  ///
  /// 换词 / 提交清空所有分支的查询；切类型则按目标类型会话的查询是否已是
  /// 当前关键词判断。真正开始一轮搜索时会话才写入关键词，因此它既能覆盖
  /// 300ms 防抖窗口，也能覆盖切类型后尚未启动的间隔，UI 不会把这段时间
  /// 误判成「无结果」。
  bool get isSearchPending {
    final keyword = _searchQuery.trim();
    if (keyword.isEmpty || !hasActiveSearchSource) return false;
    return _controls[_kind]!.query != keyword;
  }

  /// 搜索是否仍在进行：防抖等待或任一目标来源首屏请求在途。
  bool get isSearchBusy => isSearchPending || isSearching;

  /// 所有可搜索渠道：直接返回 registry 的描述列表（顺序 = 渠道管理排序）。
  List<SourceDescriptor> get sourceChannels =>
      _sourceRegistry?.descriptors ?? const [];

  /// 当前渠道支持且已启用的搜索类型（只读 [activeSource] 的能力位）。
  ///
  /// 当前渠道不可搜索时返回空列表；搜索页据此隐藏类型分段。
  List<SearchKind> get supportedSearchKinds {
    final source = activeSource;
    if (source == null) return const [];
    return [
      if (_supports(SearchKind.song, source)) SearchKind.song,
      if (_supports(SearchKind.artist, source)) SearchKind.artist,
      if (_supports(SearchKind.lyric, source)) SearchKind.lyric,
    ];
  }

  /// 是否存在可搜索来源（区别「全应用无音源」与「当前渠道不支持搜索」）。
  bool get hasSearchableSources => sourceChannels.isNotEmpty;

  /// 单曲 / 歌词结果分组（单渠道，最多一组）。
  List<SearchSourceGroup<SearchRow>> get songGroups =>
      _songs.groups(_targetsFor(SearchKind.song));

  List<SearchSourceGroup<ArtistSummary>> get artistGroups =>
      _artists.groups(_targetsFor(SearchKind.artist));

  List<SearchSourceGroup<SearchRow>> get lyricGroups =>
      _lyrics.groups(_targetsFor(SearchKind.lyric));

  /// 当前类型是否任一目标来源首屏加载中。
  bool get isSearching {
    final control = _controls[_kind]!;
    return _targetsFor(_kind)
        .any((descriptor) => control.isLoading(descriptor.key));
  }

  /// 单曲 / 歌词 / 歌手结果的扁平投影（当前可见分组的已加载条目）。
  ///
  /// 播放、性能场景与扁平列表消费面读取这里；分组渲染读
  /// [songGroups] / [artistGroups] / [lyricGroups]。
  List<SearchRow> get searchResults => [
    for (final group in songGroups) ...group.items,
  ];

  List<ArtistSummary> get artistResults => [
    for (final group in artistGroups) ...group.items,
  ];

  List<SearchRow> get lyricResults => [
    for (final group in lyricGroups) ...group.items,
  ];

  /// 单曲结果列表（无关键词时为空）。
  List<SearchRow> get filteredResults =>
      _searchQuery.isEmpty ? const [] : searchResults;

  /// 每来源独立分页：加载该来源的下一页。
  ///
  /// 「加载中 / 已到底 / 跨页去重」守卫仍由 [PagedListController] 持有；
  /// 换词 / 来源移除时的执行体 dispose 已使在途请求过期。
  Future<void> loadMore(String sourceKey) =>
      _controls[_kind]!.loadMore(sourceKey);

  /// 首屏失败重载首屏；加载更多失败重试下一页（每来源独立）。
  Future<void> retry(String sourceKey) => _controls[_kind]!.retry(sourceKey);

  /// 重试当前渠道失败的首屏 / 追加页。
  Future<void> retryFailed() => _controls[_kind]!.retryFailed(
    onlyKeys: {for (final descriptor in _targetsFor(_kind)) descriptor.key},
  );

  /// 切换搜索类型：当前渠道不支持的类型忽略。
  ///
  /// 目标类型尚未搜过当前关键词时给当前渠道补首屏；已搜过则不重复请求。
  void selectSearchKind(SearchKind kind) {
    if (kind == _kind || !supportedSearchKinds.contains(kind)) return;
    _kind = kind;
    notifyListeners();
    final keyword = _searchQuery.trim();
    if (keyword.isEmpty) return;
    // 防抖计时器尚未触发：它触发时按当时的 _kind 发起搜索，这里只切换
    // 视图，避免同一关键词先按旧类型、再按新类型各请求一轮。
    if (_debounceTimer?.isActive ?? false) return;
    final control = _controls[kind]!;
    if (control.query == keyword) {
      unawaited(control.ensureSources());
    } else {
      unawaited(control.search(keyword));
    }
  }

  /// 切换搜索渠道：清空旧渠道结果，并按当前关键词在新渠道重搜。
  ///
  /// 允许切到当前不可搜索的渠道（脚本未加载 / 无搜索能力）：此时只清空，
  /// 不发请求；等 registry 出现该渠道后由 [_onSourcesChanged] 补搜。
  /// 空 key = 回到第一个可搜索渠道，绝不表示「全部来源」。
  void setActiveSource(String key) {
    final normalized = key.trim();
    if (normalized.isEmpty) {
      final fallback = _defaultActiveSourceKey();
      if (fallback == _activeSourceKey) return;
      _switchActiveSource(fallback);
      return;
    }
    if (normalized == _activeSourceKey) return;
    _switchActiveSource(normalized);
  }

  void _switchActiveSource(String key) {
    _activeSourceKey = key;
    _ensureKindSupported();
    // 旧渠道的结果不属于新渠道：先清空所有类型，再按当前关键词重搜。
    _clearAllRuns();
    notifyListeners();
    final keyword = _searchQuery.trim();
    if (keyword.isEmpty || supportedSearchKinds.isEmpty) return;
    unawaited(_controls[_kind]!.search(keyword));
  }

  void updateSearchQuery(String query) {
    if (query == _searchQuery) return;

    _debounceTimer?.cancel();

    _searchQuery = query;
    _clearAllRuns();
    notifyListeners();

    if (query.isEmpty) return;

    // 防抖：只有最后一次输入会触发搜索；在途请求由执行体 dispose 过期丢弃。
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
      unawaited(performSearch(query));
    });
  }

  /// 提交搜索（不走防抖，立即发起）。
  void submitSearch(String query) {
    _debounceTimer?.cancel();
    _searchQuery = query;
    _clearAllRuns();
    notifyListeners();
    if (query.isEmpty) return;
    unawaited(performSearch(query));
  }

  void clearSearch() {
    _debounceTimer?.cancel();
    _searchQuery = '';
    _clearAllRuns();
    notifyListeners();
  }

  /// 释放搜索结果（托盘隐藏时由内存守卫调用）。
  ///
  /// 清空关键词与所有渠道执行体；当前渠道（用户偏好）保留。
  void releaseSearchResults() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _searchQuery = '';
    _clearAllRuns();
    notifyListeners();
  }

  Future<void> performSearch(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return;
    // 防抖计时器触发时可能已有更新的提交；以 provider 当前关键词为准。
    if (keyword != _searchQuery.trim()) return;
    await _controls[_kind]!.search(keyword);
  }

  /// 播放搜索结果：队列只取该行所属来源分组的已加载结果，不混平台队列。
  void playItem(SearchRow row) {
    final groups = _kind == SearchKind.lyric ? lyricGroups : songGroups;
    SearchSourceGroup<SearchRow>? group;
    for (final candidate in groups) {
      if (candidate.source.key == row.id.sourceKey) {
        group = candidate;
        break;
      }
    }
    if (group == null || group.items.isEmpty) return;
    final queue = [for (final entry in group.items) entry.track];
    final index = group.items.indexWhere((entry) => entry.id == row.id);
    _playbackProvider.playDomainTracks(
      queue,
      index < 0 ? 0 : index,
      contextName: group.source.displayName,
    );
  }

  /// registry.changes：删来源、给晚到的当前渠道补搜。
  ///
  /// descriptors 未变化时直接返回，避免 SourceManager 的其它通知触发重复请求。
  void _onSourcesChanged() {
    final next = sourceChannels;
    if (listEquals(_lastDescriptors, next)) return;
    _lastDescriptors = next;

    final keys = {for (final descriptor in next) descriptor.key};
    for (final control in _controls.values) {
      control.retainSources(keys);
    }

    if (_activeSourceKey.isEmpty) _activeSourceKey = _defaultActiveSourceKey();
    _ensureKindSupported();

    final keyword = _searchQuery.trim();
    if (keyword.isNotEmpty &&
        supportedSearchKinds.isNotEmpty &&
        !(_debounceTimer?.isActive ?? false)) {
      final current = _controls[_kind]!;
      if (current.query == keyword) {
        // 当前渠道晚到（例如脚本加载完成）时补首屏；其它类型在切过去时由
        // selectSearchKind 的 ensureSources 路径补齐。
        unawaited(current.ensureSources());
      } else {
        // 切到暂不可搜索的渠道时 setActiveSource 已清空执行体（query 为空）；
        // 能力补齐后必须主动按当前关键词重搜，不能等用户重新输入。
        unawaited(current.search(keyword));
      }
    }
    notifyListeners();
  }

  /// 默认渠道：第一个具备任一搜索能力的来源；都不支持搜索时退回第一个描述。
  String _defaultActiveSourceKey() {
    final channels = sourceChannels;
    for (final descriptor in channels) {
      if (_hasAnySearchCapability(descriptor)) return descriptor.key;
    }
    return channels.isEmpty ? '' : channels.first.key;
  }

  static bool _hasAnySearchCapability(SourceDescriptor descriptor) {
    final capabilities = descriptor.capabilities;
    return capabilities.search ||
        capabilities.artist ||
        capabilities.lyricSearch;
  }

  /// 当前 kind 不被渠道支持时回退到第一个支持的 kind（优先 song）。
  void _ensureKindSupported() {
    final kinds = supportedSearchKinds;
    if (kinds.contains(_kind)) return;
    _kind = kinds.contains(SearchKind.song)
        ? SearchKind.song
        : (kinds.isEmpty ? SearchKind.song : kinds.first);
  }

  Iterable<SourceDescriptor> _targetsFor(SearchKind kind) {
    final source = activeSource;
    if (source == null || !_supports(kind, source)) return const [];
    return [source];
  }

  static bool _supports(SearchKind kind, SourceDescriptor descriptor) {
    final capabilities = descriptor.capabilities;
    return switch (kind) {
      SearchKind.song => capabilities.search,
      SearchKind.artist => capabilities.artist,
      SearchKind.lyric => capabilities.lyricSearch,
    };
  }

  SearchBranch<T, R> _buildBranch<T, R>({
    required SearchKind kind,
    required String Function(String sourceKey) failureLogLabel,
    required _PageFetcher<T> fetchPage,
    required R Function(T item) project,
    String Function(T item)? keyOf,
    T Function(T existing, T incoming)? mergeDuplicate,
  }) {
    return SearchBranch<T, R>(
      kind: kind,
      project: project,
      session: FanOutSearchSession<T>(
        sources: () => [
          for (final descriptor in _targetsFor(kind))
            FanOutSource<T>.paged(
              key: descriptor.key,
              openRun: (keyword) => PagedFanOutRun<T>(
                failureLogLabel: failureLogLabel(descriptor.key),
                fetchPage: (page) => fetchPage(descriptor.key, keyword, page),
                keyOf: keyOf,
                mergeDuplicate: mergeDuplicate,
              ),
            ),
        ],
      ),
    );
  }

  Future<PagedResult<Track>> _fetchSongPage(
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
      items: result.items,
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

  Future<PagedResult<LyricHit>> _fetchLyricPage(
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
      items: result.items,
      hasMore: result.hasMore,
      total: result.total,
    );
  }

  void _clearAllRuns() {
    final relay = _relaySearchChanges;
    _relaySearchChanges = false;
    try {
      for (final control in _controls.values) {
        control.clear();
      }
    } finally {
      _relaySearchChanges = relay;
    }
  }

  void _onSearchChanged() {
    if (_disposed || !_relaySearchChanges) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _registrySubscription?.cancel();
    for (final control in _controls.values) {
      control.removeListener(_onSearchChanged);
      control.dispose();
    }
    super.dispose();
  }
}
