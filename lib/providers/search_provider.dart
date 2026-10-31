import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';

import '../app/perf/data_path_trace.dart';
import '../data/catalog/catalog_service.dart';
import '../data/settings/settings_access.dart';
import '../data/settings/settings_keys.dart';
import '../domain/models/artist.dart';
import '../domain/models/catalog.dart' show SearchKind, SearchQuery;
import '../domain/models/source.dart' show SourceDescriptor;
import '../domain/models/track.dart';
import '../domain/ports/source_registry.dart';
import 'paged_list_controller.dart';
import 'playback_provider.dart';
import 'search_row.dart';
import 'search_session.dart';
import 'search_source_group.dart';

export 'search_row.dart' show SearchRow;
export 'search_source_group.dart' show SearchSourceGroup;

/// 跨音源聚合搜索状态（内部经 [CatalogService] / [SourceRegistry]）。
///
/// 每个「搜索类型 × 来源」持有一个独立的 [SearchSession]：
/// - 换词清空所有旧会话，晚到的旧响应由 `PagedListController` 的代际丢弃；
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

  final Map<String, SearchSession<Track>> _songSessions = {};
  final Map<String, SearchSession<ArtistSummary>> _artistSessions = {};
  final Map<String, SearchSession<Track>> _lyricSessions = {};

  /// 歌词片段按来源保存（key = sourceKey，内层 key = `TrackId.uri`）。
  final Map<String, Map<String, String>> _lyricSnippets = {};

  /// 每种类型最近一次真正搜过的关键词：音源晚加载时据此补搜该来源。
  final Map<SearchKind, String> _lastSearchedKeyword = {};

  /// 最近一次读到的渠道快照：registry.changes 在描述未变化时不得重复发请求。
  List<SourceDescriptor> _lastDescriptors = const [];

  static const int _searchPageSize = 30;

  Timer? _debounceTimer;

  bool _disposed = false;
  bool _notifyScheduled = false;

  /// 输入防抖：300ms 是「停止输入到发请求」的折中。
  ///
  /// 原值 500ms 在 perf 场景里占首屏搜索墙钟的 90%+（mock 本地音源 1.5ms
  /// 返回，500ms 全是防抖等待）。300ms 仍能跨过中文输入法的组合键停顿，
  /// 且在途请求由 pager 的 reset 过期丢弃，不会因为请求变多而闪旧结果。
  static const _debounceTime = Duration(milliseconds: 300);

  SearchProvider(
    this._playbackProvider, {
    this._catalogService,
    this._sourceRegistry,
    this._settings,
  }) {
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
  /// `_lastSearchedKeyword` 在换词、提交、切类型时先清空；`_runKindSearch`
  /// 真正开始一轮搜索时才写入。因此它既能覆盖 300ms 防抖窗口，也能覆盖
  /// 切类型后尚未启动的间隔，UI 不会把这段时间误判成「无结果」。
  bool get isSearchPending {
    final keyword = _searchQuery.trim();
    if (keyword.isEmpty) return false;
    return _lastSearchedKeyword[_kind] != keyword;
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
      _songGroupsFor(SearchKind.song);

  List<SearchSourceGroup<ArtistSummary>> get artistGroups =>
      _artistGroupsFor(SearchKind.artist);

  List<SearchSourceGroup<SearchRow>> get lyricGroups =>
      _lyricGroupsFor(SearchKind.lyric);

  /// 当前类型是否任一目标来源首屏加载中。
  bool get isSearching => _visibleDescriptorsFor(
    _kind,
  ).any((descriptor) => _sessionFor(_kind, descriptor.key)?.isLoading ?? false);

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
  /// 换词 / 来源移除时的会话 dispose 已使在途请求过期。
  Future<void> loadMore(String sourceKey) async {
    final session = _sessionFor(_kind, sourceKey);
    if (session == null || session.keyword.trim().isEmpty) return;
    final pending = session.loadMore();
    notifyListeners();
    await pending;
    _notifySoon();
  }

  /// 首屏失败重载首屏；加载更多失败重试下一页（每来源独立）。
  Future<void> retry(String sourceKey) async {
    final session = _sessionFor(_kind, sourceKey);
    if (session == null) return;
    final Future<void> pending;
    if (session.loadMoreFailed) {
      pending = session.loadMore();
    } else if (session.failure != null) {
      pending = session.loadFirstPage();
    } else {
      return;
    }
    notifyListeners();
    await pending;
    _notifySoon();
  }

  /// 重试当前类型所有失败来源（首屏失败与加载更多失败一起处理）。
  Future<void> retryFailed() async {
    final keys = [
      for (final group in _groupsForKind(_kind))
        if (group.failure != null || group.loadMoreFailed) group.source.key,
    ];
    if (keys.isEmpty) return;
    await Future.wait([for (final key in keys) retry(key)]);
  }

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
    if (_lastSearchedKeyword[kind] == keyword) {
      unawaited(_ensureSessionsFor(kind, keyword));
    } else {
      unawaited(_runKindSearch(kind, keyword));
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
    _clearAllSessions();
    notifyListeners();

    if (query.isEmpty) return;

    // 防抖：只有最后一次输入会触发搜索；在途请求由会话 dispose 过期丢弃。
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
    _clearAllSessions();
    notifyListeners();
    if (query.isEmpty) return;
    unawaited(performSearch(query));
  }

  void clearSearch() {
    _debounceTimer?.cancel();
    _searchQuery = '';
    _clearAllSessions();
    notifyListeners();
  }

  /// 释放搜索结果（托盘隐藏时由内存守卫调用）。
  ///
  /// 清空关键词、所有来源会话与歌词片段；来源过滤偏好（用户偏好）保留。
  void releaseSearchResults() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _searchQuery = '';
    _clearAllSessions();
    notifyListeners();
  }

  Future<void> performSearch(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return;
    // 防抖计时器触发时可能已有更新的提交；以 provider 当前关键词为准。
    if (keyword != _searchQuery.trim()) return;
    await _runKindSearch(_kind, keyword);
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

  /// 起一轮当前类型的搜索：换词 / 切类型 / 首次搜索共用同一条路径。
  Future<void> _runKindSearch(SearchKind kind, String keyword) async {
    _lastSearchedKeyword[kind] = keyword;
    _disposeKindSessions(kind);
    if (kind == SearchKind.lyric) _lyricSnippets.clear();

    final targets = _targetDescriptors(kind);
    if (targets.isEmpty) {
      notifyListeners();
      return;
    }
    final pending = <Future<void>>[];
    for (final descriptor in targets) {
      pending.add(_createAndLoad(kind, descriptor, keyword));
    }
    // 会话已同步创建并置为 loading：先发一次通知让分组标题出现 spinner。
    notifyListeners();
    await Future.wait(pending);
  }

  /// 当前关键词下补齐缺失来源的首屏（不重发已有来源的请求）。
  Future<void> _ensureSessionsFor(SearchKind kind, String keyword) async {
    final targets = _targetDescriptors(kind);
    final pending = <Future<void>>[];
    for (final descriptor in targets) {
      if (_sessionFor(kind, descriptor.key) != null) continue;
      pending.add(_createAndLoad(kind, descriptor, keyword));
    }
    if (pending.isEmpty) return;
    notifyListeners();
    await Future.wait(pending);
  }

  Future<void> _createAndLoad(
    SearchKind kind,
    SourceDescriptor descriptor,
    String keyword,
  ) {
    final sourceKey = descriptor.key;
    switch (kind) {
      case SearchKind.song:
        late final SearchSession<Track> session;
        session = SearchSession<Track>(
          PagedListController<Track>(
            keyOf: (track) => track.id.uri,
            fetchPage: (page) => _fetchSongPage(sourceKey, session, page),
          ),
          'Search failed ($sourceKey)',
        )..begin(keyword);
        _songSessions[sourceKey] = session;
        return session.loadFirstPage().whenComplete(_notifySoon);
      case SearchKind.artist:
        late final SearchSession<ArtistSummary> session;
        session = SearchSession<ArtistSummary>(
          PagedListController<ArtistSummary>(
            keyOf: (artist) => artist.id,
            fetchPage: (page) => _fetchArtistPage(sourceKey, session, page),
          ),
          'Artist search failed ($sourceKey)',
        )..begin(keyword);
        _artistSessions[sourceKey] = session;
        return session.loadFirstPage().whenComplete(_notifySoon);
      case SearchKind.lyric:
        late final SearchSession<Track> session;
        session = SearchSession<Track>(
          PagedListController<Track>(
            keyOf: (track) => track.id.uri,
            fetchPage: (page) => _fetchLyricPage(sourceKey, session, page),
            onPageAccepted: (page, {required append}) =>
                _acceptLyricPage(sourceKey, page, append: append),
          ),
          'Lyric search failed ($sourceKey)',
        )..begin(keyword);
        _lyricSessions[sourceKey] = session;
        return session.loadFirstPage().whenComplete(_notifySoon);
    }
  }

  Future<PagedResult<Track>> _fetchSongPage(
    String sourceKey,
    SearchSession<Track> session,
    int page,
  ) async {
    final catalog = _catalogService;
    if (catalog == null) throw StateError('音源未初始化');
    final result = await DataPathTrace.async(
      'search.page',
      () => catalog.search(
        sourceKey,
        SearchQuery(
          keyword: session.keyword,
          page: page,
          limit: _searchPageSize,
        ),
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
    SearchSession<ArtistSummary> session,
    int page,
  ) async {
    final catalog = _catalogService;
    if (catalog == null) throw StateError('音源未初始化');
    final result = await catalog.searchArtists(
      sourceKey,
      SearchQuery(keyword: session.keyword, page: page, limit: _searchPageSize),
    );
    return PagedResult(
      items: result.items,
      hasMore: result.hasMore,
      total: result.total,
    );
  }

  Future<PagedResult<Track>> _fetchLyricPage(
    String sourceKey,
    SearchSession<Track> session,
    int page,
  ) async {
    final catalog = _catalogService;
    if (catalog == null) throw StateError('音源未初始化');
    final result = await catalog.searchLyrics(
      sourceKey,
      SearchQuery(keyword: session.keyword, page: page, limit: _searchPageSize),
    );
    final snippets = <String, String>{};
    for (final hit in result.items) {
      if (hit.snippet != null) snippets[hit.track.id.uri] = hit.snippet!;
    }
    return LyricPageResult(
      snippets: snippets,
      items: [for (final hit in result.items) hit.track],
      hasMore: result.hasMore,
      total: result.total,
    );
  }

  /// 接受页回调：只在这页仍属于该来源当前歌词会话时累计片段。
  void _acceptLyricPage(
    String sourceKey,
    PagedResult<Track> page, {
    required bool append,
  }) {
    if (page is! LyricPageResult) return;
    final previous = append
        ? (_lyricSnippets[sourceKey] ?? const {})
        : const {};
    _lyricSnippets[sourceKey] = Map.unmodifiable({
      ...previous,
      ...page.snippets,
    });
  }

  /// registry.changes：删来源、按新顺序重排、给晚到的新来源补搜。
  ///
  /// descriptors 未变化时直接返回，避免 SourceManager 的其它通知触发重复请求。
  void _onSourcesChanged() {
    final next = sourceChannels;
    if (listEquals(_lastDescriptors, next)) return;
    _lastDescriptors = next;

    final keys = {for (final descriptor in next) descriptor.key};
    _removeMissing(_songSessions, keys);
    _removeMissing(_artistSessions, keys);
    _removeMissing(_lyricSessions, keys);
    _lyricSnippets.removeWhere((key, _) => !keys.contains(key));

    if (!supportedSearchKinds.contains(_kind)) _kind = SearchKind.song;

    final keyword = _searchQuery.trim();
    if (keyword.isNotEmpty) {
      for (final kind in SearchKind.values) {
        if (_lastSearchedKeyword[kind] != keyword) continue;
        // 新来源出现且当前关键词已经搜过 → 自动补搜，脚本晚加载时也参与
        // 本轮搜索。
        unawaited(_ensureSessionsFor(kind, keyword));
      }
    }
    notifyListeners();
  }

  void _removeMissing<T>(
    Map<String, SearchSession<T>> sessions,
    Set<String> keys,
  ) {
    final missing = [
      for (final key in sessions.keys)
        if (!keys.contains(key)) key,
    ];
    for (final key in missing) {
      sessions.remove(key)?.dispose();
    }
  }

  List<SearchSourceGroup<SearchRow>> _songGroupsFor(SearchKind kind) =>
      _groupsFor(kind, _songSessions, (_, track) => SearchRow(track: track));

  List<SearchSourceGroup<ArtistSummary>> _artistGroupsFor(SearchKind kind) =>
      _groupsFor(kind, _artistSessions, (_, artist) => artist);

  List<SearchSourceGroup<SearchRow>> _lyricGroupsFor(SearchKind kind) =>
      _groupsFor(kind, _lyricSessions, (sourceKey, track) {
        final snippets = _lyricSnippets[sourceKey] ?? const {};
        return SearchRow(track: track, lyricSnippet: snippets[track.id.uri]);
      });

  /// 按渠道顺序把「来源会话」投影成 UI 分组；三种搜索类型共用同一遍历。
  List<SearchSourceGroup<R>> _groupsFor<T, R>(
    SearchKind kind,
    Map<String, SearchSession<T>> sessions,
    R Function(String sourceKey, T item) project,
  ) {
    final groups = <SearchSourceGroup<R>>[];
    for (final descriptor in _visibleDescriptorsFor(kind)) {
      final session = sessions[descriptor.key];
      if (session == null) continue;
      groups.add(
        _group<R>(descriptor, session, [
          for (final item in session.items) project(descriptor.key, item),
        ]),
      );
    }
    return List.unmodifiable(groups);
  }

  SearchSourceGroup<T> _group<T>(
    SourceDescriptor descriptor,
    SearchSessionState session,
    List<T> items,
  ) => SearchSourceGroup<T>(
    source: descriptor,
    items: List.unmodifiable(items),
    failure: session.failure,
    isLoading: session.isLoading,
    hasMore: session.hasMore,
    isLoadingMore: session.isLoadingMore,
    loadMoreFailed: session.loadMoreFailed,
    total: session.total,
    page: session.page,
  );

  Iterable<SearchSourceGroup<Object>> _groupsForKind(SearchKind kind) =>
      switch (kind) {
        SearchKind.song => songGroups,
        SearchKind.artist => artistGroups,
        SearchKind.lyric => lyricGroups,
      };

  List<SourceDescriptor> _visibleDescriptorsFor(SearchKind kind) =>
      _targetDescriptors(kind);

  List<SourceDescriptor> _targetDescriptors(SearchKind kind) {
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

  SearchSessionState? _sessionFor(SearchKind kind, String sourceKey) =>
      switch (kind) {
        SearchKind.song => _songSessions[sourceKey],
        SearchKind.artist => _artistSessions[sourceKey],
        SearchKind.lyric => _lyricSessions[sourceKey],
      };

  void _disposeKindSessions(SearchKind kind) {
    switch (kind) {
      case SearchKind.song:
        _disposeSessions(_songSessions);
        break;
      case SearchKind.artist:
        _disposeSessions(_artistSessions);
        break;
      case SearchKind.lyric:
        _disposeSessions(_lyricSessions);
        _lyricSnippets.clear();
        break;
    }
  }

  void _disposeSessions<T>(Map<String, SearchSession<T>> sessions) {
    for (final session in sessions.values) {
      session.dispose();
    }
    sessions.clear();
  }

  void _clearAllSessions() {
    _disposeSessions(_songSessions);
    _disposeSessions(_artistSessions);
    _disposeSessions(_lyricSessions);
    _lyricSnippets.clear();
    _lastSearchedKeyword.clear();
  }

  void _applySourceFilter(String value) {
    _sourceFilterPreference = value;
    final keyword = _searchQuery.trim();
    if (keyword.isNotEmpty && _lastSearchedKeyword[_kind] == keyword) {
      unawaited(_ensureSessionsFor(_kind, keyword));
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
    try {
      final value = (await settings.read(kSearchSourceFilter)).trim();
      if (_disposed || value == _sourceFilterPreference) return;
      _applySourceFilter(value);
    } catch (_) {}
  }

  /// 同一轮事件循环内的多来源完成通知合并为一次。
  void _notifySoon() {
    if (_disposed || _notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _registrySubscription?.cancel();
    _disposeSessions(_songSessions);
    _disposeSessions(_artistSessions);
    _disposeSessions(_lyricSessions);
    _lyricSnippets.clear();
    super.dispose();
  }
}
