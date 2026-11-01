import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';

import '../app/perf/data_path_trace.dart';
import '../data/catalog/catalog_service.dart';
import '../data/settings/settings_access.dart';
import '../data/settings/settings_keys.dart';
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

/// 跨音源聚合搜索状态（内部经 [CatalogService] / [SourceRegistry]）。
///
/// 每个「搜索类型 × 来源」是一个分页执行体，查询代际 / 逐源状态 / 失败 /
/// 通知节拍统一由 [FanOutSearchSession] 持有：
/// - 换词清空所有旧执行体，晚到的旧响应由查询代际与分页控制器丢弃；
/// - 每个来源独立分页 / 失败 / 加载态，一个平台失败不影响其它平台；
/// - 分组顺序永远直接读 `SourceRegistry.descriptors`（音源管理的渠道排序），
///   provider 不按内置规范顺序重排。
class SearchProvider extends ChangeNotifier {
  final PlaybackProvider _playbackProvider;

  /// 搜索入口：带 single-flight + LRU + TTL 的目录服务（可为 null：无音源）。
  final CatalogService? _catalogService;

  /// 音源注册表：描述列表与变更通知来源（可为 null：无音源）。
  final SourceRegistry? _sourceRegistry;

  /// 搜索来源过滤偏好（跨重启记住）；null = 测试 / 无持久化场景。
  final SettingsAccess? _settings;

  StreamSubscription<void>? _registrySubscription;

  String _searchQuery = '';
  SearchKind _kind = SearchKind.song;

  /// 持久化的过滤偏好（原始值）；有效值见 [sourceFilter]。
  String _sourceFilterPreference = '';

  /// 过滤偏好的异步恢复代际：用户手动选择后，晚到的 prefs 读取不得覆盖。
  int _sourceFilterGeneration = 0;

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
    this._settings,
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

    final settings = _settings;
    if (settings != null) {
      settings.bindReload(kSearchSourceFilter, _reloadSourceFilter);
      unawaited(_restoreSourceFilter());
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

  /// 当前关键词已提交、但当前类型还没有真正发起搜索（防抖窗口 / 切类型）。
  ///
  /// 换词 / 提交清空所有分支的查询；切类型则按目标类型会话的查询是否已是
  /// 当前关键词判断。真正开始一轮搜索时会话才写入关键词，因此它既能覆盖
  /// 300ms 防抖窗口，也能覆盖切类型后尚未启动的间隔，UI 不会把这段时间
  /// 误判成「无结果」。
  bool get isSearchPending {
    final keyword = _searchQuery.trim();
    if (keyword.isEmpty) return false;
    return _controls[_kind]!.query != keyword;
  }

  /// 搜索是否仍在进行：防抖等待或任一目标来源首屏请求在途。
  bool get isSearchBusy => isSearchPending || isSearching;

  /// 所有可搜索渠道：直接返回 registry 的描述列表（顺序 = 渠道管理排序）。
  List<SourceDescriptor> get sourceChannels =>
      _sourceRegistry?.descriptors ?? const [];

  /// 当前类型支持且已启用的来源（顺序严格取 [sourceChannels]）。
  List<SourceDescriptor> get sourceFilterOptions => [
    for (final descriptor in sourceChannels)
      if (_supports(_kind, descriptor)) descriptor,
  ];

  /// 有效过滤值：`''` = 全部。
  ///
  /// 持久化偏好可能与当前类型的能力集不匹配（例如过滤到只有单曲能力的
  /// 脚本源后切到「歌手」）：此时临时按全部处理，偏好本身保留，切回支持的
  /// 类型后自动恢复。
  String get sourceFilter => _effectiveFilterFor(_kind);

  /// 当前类型支持的搜索类型（启用来源能力位的并集）。
  List<SearchKind> get supportedSearchKinds {
    final channels = sourceChannels;
    return [
      SearchKind.song,
      if (channels.any((d) => d.capabilities.artist)) SearchKind.artist,
      if (channels.any((d) => d.capabilities.lyricSearch)) SearchKind.lyric,
    ];
  }

  /// 是否存在可搜索来源（空态引导与资料库搜索 tab 显隐的唯一判据）。
  bool get hasSearchableSources => sourceChannels.isNotEmpty;

  /// 单曲 / 歌词结果按来源分组（顺序 = 渠道管理排序，过滤后）。
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

  /// 重试当前类型所有失败来源（首屏失败与加载更多失败一起处理）。
  Future<void> retryFailed() => _controls[_kind]!.retryFailed(
    onlyKeys: {for (final descriptor in _targetsFor(_kind)) descriptor.key},
  );

  /// 切换搜索类型：不支持的类型忽略。
  ///
  /// 目标类型尚未搜过当前关键词时按所有支持该类型的来源并行补首屏；已搜过
  /// 则只补当前过滤值下缺失的来源（不重复请求已有会话）。
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

  /// 只过滤已加载分组，不重发请求；该来源尚未参与本轮搜索时才补首屏。
  void selectSourceFilter(String key) {
    final normalized = key.trim();
    if (normalized.isNotEmpty &&
        !sourceFilterOptions.any((option) => option.key == normalized)) {
      return;
    }
    _sourceFilterGeneration++;
    _applySourceFilter(normalized);
    final settings = _settings;
    if (settings == null) return;
    unawaited(
      settings.write(kSearchSourceFilter, normalized).catchError((Object _) {}),
    );
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
  /// 清空关键词与所有来源执行体；来源过滤偏好（用户偏好）保留。
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

  /// registry.changes：删来源、按新顺序重排、给晚到的新来源补搜。
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

    if (!supportedSearchKinds.contains(_kind)) _kind = SearchKind.song;

    final keyword = _searchQuery.trim();
    final current = _controls[_kind]!;
    if (keyword.isNotEmpty && current.query == keyword) {
      // 只给当前可见类型补搜：其它类型切过去时由 selectSearchKind 的
      // ensureSources 路径补齐，避免为不在当前页的类型发额外请求。
      unawaited(current.ensureSources());
    }
    notifyListeners();
  }

  Iterable<SourceDescriptor> _targetsFor(SearchKind kind) {
    final options = [
      for (final descriptor in sourceChannels)
        if (_supports(kind, descriptor)) descriptor,
    ];
    final filter = _effectiveFilterFor(kind);
    if (filter.isEmpty) return options;
    return [
      for (final descriptor in options)
        if (descriptor.key == filter) descriptor,
    ];
  }

  String _effectiveFilterFor(SearchKind kind) {
    if (_sourceFilterPreference.isEmpty) return '';
    final options = sourceChannels.where((d) => _supports(kind, d));
    return options.any((d) => d.key == _sourceFilterPreference)
        ? _sourceFilterPreference
        : '';
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

  void _applySourceFilter(String value) {
    _sourceFilterPreference = value;
    final keyword = _searchQuery.trim();
    final current = _controls[_kind]!;
    if (keyword.isNotEmpty && current.query == keyword) {
      unawaited(current.ensureSources());
    }
    notifyListeners();
  }

  Future<void> _restoreSourceFilter() async {
    final settings = _settings;
    if (settings == null) return;
    final generation = _sourceFilterGeneration;
    try {
      final raw = await settings.read(kSearchSourceFilter);
      if (_disposed || generation != _sourceFilterGeneration) return;
      final value = raw.trim();
      if (value == _sourceFilterPreference) return;
      _applySourceFilter(value);
    } catch (_) {
      // 读取失败保持默认「全部来源」。
    }
  }

  /// 同步应用远端值后的重载入口。
  Future<void> _reloadSourceFilter() async {
    final settings = _settings;
    if (settings == null) return;
    final generation = _sourceFilterGeneration;
    try {
      final value = (await settings.read(kSearchSourceFilter)).trim();
      // reload 在途时用户可能已经手动选了新来源：晚到的旧值不得覆盖。
      if (_disposed ||
          generation != _sourceFilterGeneration ||
          value == _sourceFilterPreference) {
        return;
      }
      _applySourceFilter(value);
    } catch (_) {}
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
