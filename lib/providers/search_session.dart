import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../app/perf/data_path_trace.dart';
import '../domain/models/artist.dart';
import '../domain/models/catalog.dart' show SearchKind;
import '../domain/models/source.dart' show SourceDescriptor;
import '../domain/ports/source_registry.dart';
import 'channel_selection.dart';
import 'paged_list_controller.dart';
import 'search_results.dart';
import 'search_row.dart';

/// 单源取页：来源 key + 本轮关键词 + 页码（三种搜索类型共用）。
typedef SearchPageFetcher<T> = Future<PagedResult<T>> Function(
  String sourceKey,
  String keyword,
  int page,
);

/// 遮罩预览里的一个可高亮条目（跳过分组标题）。
sealed class SearchPreviewItem {
  const SearchPreviewItem({required this.sourceKey});

  final String sourceKey;

  /// 行身份（跨刷新 / 分组插入时按它保留高亮）。
  String get key;
}

final class SearchPreviewTrack extends SearchPreviewItem {
  const SearchPreviewTrack({required this.row, required super.sourceKey});

  final SearchRow row;

  @override
  String get key => 'track:${row.id.uri}';
}

final class SearchPreviewArtist extends SearchPreviewItem {
  const SearchPreviewArtist({required this.artist, required super.sourceKey});

  final ArtistSummary artist;

  @override
  String get key => 'artist:$sourceKey:${artist.id}';
}

/// 遮罩预览的唯一投影：渲染顺序与键盘高亮共用同一份顺序。
@immutable
class SearchPreview {
  const SearchPreview({required this.items, required this.totalItems});

  static const SearchPreview empty = SearchPreview(items: [], totalItems: 0);

  /// 扁平高亮顺序（最多 [SearchPreviewSession.maxItems] 行）。
  final List<SearchPreviewItem> items;

  /// 当前渠道的完整结果数（不是预览截断后的数量）。
  final int totalItems;
}

/// 遮罩预览会话：预览排序、「用户是否移动过高亮」与高亮失效回落的唯一实现。
///
/// 输入是当前 kind 的结果快照与关键词，输出是渲染 / 键盘共用的 [value]。
/// 不依赖 widget：不挂遮罩也能直接测排序与高亮移动。
class SearchPreviewSession extends ChangeNotifier {
  SearchPreviewSession({this.maxItems = defaultMaxItems});

  /// 遮罩就地预览的最大行数：更长的列表交给「查看全部结果」后的资料库。
  static const int defaultMaxItems = 8;

  final int maxItems;

  SearchPreview _value = SearchPreview.empty;
  String _query = '';
  String? _highlightedKey;
  bool _userMovedHighlight = false;

  SearchPreview get value => _value;

  List<SearchPreviewItem> get items => _value.items;

  int get totalItems => _value.totalItems;

  String? get highlightedKey => _highlightedKey;

  /// 当前高亮条目；存储的 key 已不在列表里时回退第一条。
  SearchPreviewItem? get highlightedItem {
    for (final item in _value.items) {
      if (item.key == _highlightedKey) return item;
    }
    return _value.items.isEmpty ? null : _value.items.first;
  }

  /// 同步当前投影：换词重置高亮策略；同一关键词下按行身份保留用户选择。
  void update({
    required SearchKind kind,
    required SearchResults<Object> results,
    required String sourceKey,
    required String query,
  }) {
    final next = _project(kind: kind, results: results, sourceKey: sourceKey);
    final queryChanged = query != _query;
    _query = query;
    if (queryChanged) _userMovedHighlight = false;

    final previewChanged = !_samePreview(_value, next);
    _value = next;

    final nextKey = _resolveHighlight();
    final highlightChanged = nextKey != _highlightedKey;
    _highlightedKey = nextKey;

    if (previewChanged || highlightChanged) notifyListeners();
  }

  /// ↑↓ / PageUp / PageDown：跨来源分组连续移动（组标题不在条目列表里）。
  void moveHighlight(int delta) {
    final items = _value.items;
    if (items.isEmpty) return;
    var index = items.indexWhere((item) => item.key == _highlightedKey);
    if (index < 0) index = delta > 0 ? -1 : items.length;
    final next = math.min(math.max(index + delta, 0), items.length - 1);
    _userMovedHighlight = true;
    final key = items[next].key;
    if (key == _highlightedKey) return;
    _highlightedKey = key;
    notifyListeners();
  }

  SearchPreview _project({
    required SearchKind kind,
    required SearchResults<Object> results,
    required String sourceKey,
  }) {
    final rows = results.items;
    final count = math.min(rows.length, maxItems);
    final items = <SearchPreviewItem>[];
    switch (kind) {
      case SearchKind.song || SearchKind.lyric:
        for (var index = 0; index < count; index++) {
          items.add(
            SearchPreviewTrack(
              row: rows[index] as SearchRow,
              sourceKey: sourceKey,
            ),
          );
        }
      case SearchKind.artist:
        for (var index = 0; index < count; index++) {
          items.add(
            SearchPreviewArtist(
              artist: rows[index] as ArtistSummary,
              sourceKey: sourceKey,
            ),
          );
        }
    }
    return SearchPreview(
      items: List.unmodifiable(items),
      totalItems: rows.length,
    );
  }

  /// 结果到达自动高亮第一条；用户手动移动后按行身份保留。
  String? _resolveHighlight() {
    final items = _value.items;
    if (items.isEmpty) return null;
    final key = _highlightedKey;
    if (!_userMovedHighlight || key == null) return items.first.key;
    return items.any((item) => item.key == key) ? key : items.first.key;
  }

  static bool _samePreview(SearchPreview a, SearchPreview b) {
    if (a.totalItems != b.totalItems || a.items.length != b.items.length) {
      return false;
    }
    for (var index = 0; index < a.items.length; index++) {
      if (a.items[index].key != b.items[index].key) return false;
    }
    return true;
  }
}

/// 视图消费的会话快照：当前 kind 的结果 / 预览 / 空态判据一次取齐。
///
/// UI 不再按 kind 自己 switch 结果集合；行类型投影由本类提供，视图只保留
/// 「歌手行还是曲目行」这一层必要的呈现分派。
@immutable
class SearchProjection {
  const SearchProjection({
    required this.query,
    required this.kind,
    required this.supportedKinds,
    required this.results,
    required this.preview,
    required this.isBusy,
    required this.hasActiveSearchSource,
    required this.hasSearchableSources,
    required this.activeSourceKey,
    required this.activeSourceName,
    required this.artistLinksEnabled,
  });

  final String query;
  final SearchKind kind;
  final List<SearchKind> supportedKinds;
  final SearchResults<Object> results;
  final SearchPreview preview;
  final bool isBusy;
  final bool hasActiveSearchSource;
  final bool hasSearchableSources;
  final String activeSourceKey;
  final String? activeSourceName;
  final bool artistLinksEnabled;

  bool get isActive => query.isNotEmpty;

  int get resultCount => results.items.length;

  /// 当前类型的单曲 / 歌词行（歌手类型为空）。
  List<SearchRow> get trackItems =>
      kind == SearchKind.artist ? const [] : results.items.cast<SearchRow>();

  /// 当前类型的歌手行（单曲 / 歌词类型为空）。
  List<ArtistSummary> get artistItems => kind == SearchKind.artist
      ? results.items.cast<ArtistSummary>()
      : const [];
}

/// 单渠道搜索会话：关键词、当前类型、结果与「重启 vs 保持」策略的唯一实现。
///
/// 事件入口只表达用户意图（输入 / 提交 / 清空 / 切类型 / 渠道或来源变化），
/// 是否清空、是否补首屏、是否被防抖吞掉都在本类判断。UI 只读 [projection] /
/// [preview]，`SearchProvider` 只是它的薄委托与播放出口。
///
/// 结果分页 / 失败 / 跨页去重仍由 [SearchResultsController] 持有；本类不复制
/// 分页状态机，只负责多类型之间的调度与查询代际对齐。
class SearchSession extends ChangeNotifier {
  SearchSession({
    required ChannelSelection selection,
    SourceRegistry? sourceRegistry,
    required SearchPageFetcher<SearchRow> fetchSongPage,
    required SearchPageFetcher<ArtistSummary> fetchArtistPage,
    required SearchPageFetcher<SearchRow> fetchLyricPage,
  }) : // 公开参数名保持 selection，字段仍按本类惯例私有。
       // ignore: prefer_initializing_formals
       _selection = selection,
       // ignore: prefer_initializing_formals
       _sourceRegistry = sourceRegistry {
    _songs = _buildController<SearchRow>(
      kind: SearchKind.song,
      failureLabel: 'Search failed',
      fetchPage: fetchSongPage,
      keyOf: (row) => row.id.uri,
    );
    _artists = _buildController<ArtistSummary>(
      kind: SearchKind.artist,
      failureLabel: 'Artist search failed',
      fetchPage: fetchArtistPage,
      keyOf: (artist) => artist.id,
    );
    _lyrics = _buildController<SearchRow>(
      kind: SearchKind.lyric,
      failureLabel: 'Lyric search failed',
      fetchPage: fetchLyricPage,
      keyOf: (row) => row.id.uri,
      // 同曲目在后续页再次命中时，片段跟随后页（与按页累计片段同口径），
      // 行身份与位置仍取首次出现。
      mergeDuplicate: (existing, incoming) => SearchRow(
        track: existing.track,
        lyricSnippet: incoming.lyricSnippet ?? existing.lyricSnippet,
      ),
    );
    _controls = {
      SearchKind.song: _songs,
      SearchKind.artist: _artists,
      SearchKind.lyric: _lyrics,
    };
    for (final control in _controls.values) {
      control.addListener(_onSearchChanged);
    }

    // 渠道变化可能来自任意入口（资料页 / Ctrl+F / 失效回退），统一在这里
    // 清空旧结果并按当前关键词重搜。
    _selection.addListener(_onChannelChanged);
    _registrySubscription = _sourceRegistry?.changes.listen(
      (_) => _onSourcesChanged(),
    );
    _onSourcesChanged();
  }

  /// 全局当前渠道的唯一所有者（发现内容读同一个实例）。
  final ChannelSelection _selection;

  /// 音源注册表：描述列表与变更通知来源（可为 null：无音源）。
  final SourceRegistry? _sourceRegistry;

  StreamSubscription<void>? _registrySubscription;

  String _query = '';
  SearchKind _kind = SearchKind.song;

  /// 三种搜索类型各一份结果控制器（行形状不同，类型留在控制器里）。
  late final SearchResultsController<SearchRow> _songs;
  late final SearchResultsController<ArtistSummary> _artists;
  late final SearchResultsController<SearchRow> _lyrics;

  /// 按类型索引的规范控制面：查询 / 分页 / 重试只经这一份。
  late final Map<SearchKind, SearchResultsController<Object>> _controls;

  /// 最近一次读到的渠道快照：registry.changes 在描述未变化时不得重复发请求。
  List<SourceDescriptor> _lastDescriptors = const [];

  /// 遮罩预览与高亮；页面版式不消费，但同一份投影归会话所有。
  final SearchPreviewSession preview = SearchPreviewSession();

  Timer? _debounceTimer;

  bool _disposed = false;

  /// 批量清空各控制器时先暂停转发：一次输入不应触发三次重建。
  bool _relaySearchChanges = true;

  /// 输入防抖：300ms 是「停止输入到发请求」的折中。
  ///
  /// 500ms 在 perf 场景里占首屏搜索墙钟的 90%+（mock 本地音源 1.5ms
  /// 返回，其余全是防抖等待）。300ms 仍能跨过中文输入法的组合键停顿，
  /// 且在途请求由执行体的 reset 过期丢弃，不会因为请求变多而闪旧结果。
  static const _debounceTime = Duration(milliseconds: 300);

  String get query => _query;

  /// 当前搜索类型（搜索页分段）。
  SearchKind get kind => _kind;

  bool get isActive => _query.isNotEmpty;

  /// 当前渠道 key（`''` = 尚未确定；不是「全部来源」）。
  ///
  /// 直接读 [ChannelSelection]：允许是当前版本不可搜索的渠道（脚本未加载 /
  /// 渠道无搜索能力），此时 [hasActiveSearchSource] 为 false（activeSource
  /// 可能已注册但能力位全 false），UI 显示不支持搜索的空态，而不是回退去搜
  /// 别的渠道。
  String get activeSourceKey => _selection.key;

  /// 当前渠道的搜索描述；渠道未注册 / 脚本未加载时为 null。
  SourceDescriptor? get activeSource {
    for (final descriptor in sourceChannels) {
      if (descriptor.key == activeSourceKey) return descriptor;
    }
    return null;
  }

  /// 当前渠道是否真的可搜索（Ctrl+F / 空态的唯一判据）。
  ///
  /// 不能用 `activeSource != null`：已注册但 search / artist / lyricSearch
  /// 全为 false 的渠道也要按「不支持搜索」处理。
  bool get hasActiveSearchSource => supportedKinds.isNotEmpty;

  /// 当前关键词已提交、但当前类型还没有真正发起搜索（防抖窗口 / 切类型）。
  bool get isPending {
    final keyword = _query.trim();
    if (keyword.isEmpty || !hasActiveSearchSource) return false;
    return _current.keyword != keyword;
  }

  /// 搜索是否仍在进行：防抖等待或当前类型首屏请求在途。
  bool get isBusy => isPending || isSearching;

  /// 所有可搜索渠道：直接返回 registry 的描述列表（顺序 = 渠道管理排序）。
  List<SourceDescriptor> get sourceChannels =>
      _sourceRegistry?.descriptors ?? const [];

  /// 当前渠道支持且已启用的搜索类型（只读能力位，映射在领域层唯一实现）。
  List<SearchKind> get supportedKinds =>
      activeSource?.capabilities.searchKinds ?? const [];

  /// 是否存在可搜索来源（区别「全应用无音源」与「当前渠道不支持搜索」）。
  bool get hasSearchableSources => sourceChannels.isNotEmpty;

  /// 单曲 / 歌手 / 歌词结果快照（按类型保留行形状）。
  SearchResults<SearchRow> get songResults => _songs.value;

  SearchResults<ArtistSummary> get artistResults => _artists.value;

  SearchResults<SearchRow> get lyricResults => _lyrics.value;

  /// 当前类型的结果快照（kind→结果集合的唯一选择处）。
  SearchResults<Object> get currentResults => _current.value;

  /// 当前类型已加载的结果条数（遮罩读屏播报 / 面板判空同口径）。
  int get resultCount => currentResults.items.length;

  /// 当前类型是否首屏加载中。
  bool get isSearching => _current.value.isLoading;

  /// 当前视图投影：结果 / 预览 / 空态判据一次取齐。
  SearchProjection get projection => SearchProjection(
    query: _query,
    kind: _kind,
    supportedKinds: supportedKinds,
    results: currentResults,
    preview: preview.value,
    isBusy: isBusy,
    hasActiveSearchSource: hasActiveSearchSource,
    hasSearchableSources: hasSearchableSources,
    activeSourceKey: activeSourceKey,
    activeSourceName: activeSource?.displayName,
    artistLinksEnabled: activeSource?.capabilities.artist ?? false,
  );

  /// 当前类型加载下一页；「加载中 / 已到底 / 跨页去重」守卫由
  /// [PagedListController] 持有。
  Future<void> loadMore() => _current.loadMore();

  /// 首屏失败重载首屏；加载更多失败重试下一页。
  Future<void> retry() => _current.retry();

  /// 切换搜索类型：当前渠道不支持的类型忽略。
  ///
  /// 目标类型尚未搜过当前关键词时补首屏；已搜过则只在渠道晚到 / 缺首屏时
  /// 补一次，不重复请求。
  void selectKind(SearchKind kind) {
    if (kind == _kind || !supportedKinds.contains(kind)) return;
    _kind = kind;
    _notify();
    final keyword = _query.trim();
    if (keyword.isEmpty) return;
    // 防抖计时器尚未触发：它触发时按当时的 _kind 发起搜索，这里只切换
    // 视图，避免同一关键词先按旧类型、再按新类型各请求一轮。
    if (_debounceTimer?.isActive ?? false) return;
    final control = _controls[kind]!;
    if (control.keyword == keyword) {
      unawaited(control.ensureFirstPage());
    } else {
      unawaited(control.search(keyword));
    }
  }

  /// 输入变化：换词清空所有类型旧结果，并防抖重启当前类型。
  void updateQuery(String query) {
    if (query == _query) return;

    _debounceTimer?.cancel();

    _query = query;
    _clearAll();
    _notify();

    if (query.isEmpty) return;

    // 防抖：只有最后一次输入会触发搜索；在途请求由执行体的 reset 过期丢弃。
    // 计时从本次输入到真正发请求，用来判断「感知慢」里防抖占多少。
    final debounceWatch = DataPathTrace.enabled ? (Stopwatch()..start()) : null;
    _debounceTimer = Timer(_debounceTime, () {
      if (_disposed) return;
      if (debounceWatch != null) {
        DataPathTrace.record(
          'search.debounce',
          debounceWatch.elapsed,
          fields: () => {'keyword_len': query.length},
        );
      }
      unawaited(perform(query));
    });
  }

  /// 提交搜索（不走防抖，立即发起）。
  void submit(String query) {
    _debounceTimer?.cancel();
    _query = query;
    _clearAll();
    _notify();
    if (query.isEmpty) return;
    unawaited(perform(query));
  }

  /// 清空关键词与所有结果；当前渠道保留。
  void clear() {
    _debounceTimer?.cancel();
    _query = '';
    _clearAll();
    _notify();
  }

  /// 释放搜索结果（托盘隐藏时由内存守卫调用）。
  ///
  /// 清空关键词与所有控制器；当前渠道（用户偏好）保留。
  void releaseResults() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _query = '';
    _clearAll();
    _notify();
  }

  Future<void> perform(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return;
    // 防抖计时器触发时可能已有更新的提交；以会话当前关键词为准。
    if (keyword != _query.trim()) return;
    await _current.search(keyword);
  }

  /// 渠道切换：清空旧渠道结果，并按当前关键词在新渠道重搜。
  ///
  /// key 已由 [ChannelSelection] 写入；这里只做搜索侧反应。允许切到当前
  /// 不可搜索的渠道（脚本未加载 / 无搜索能力）：此时只清空，不发请求；等
  /// registry 出现该渠道后由 [_onSourcesChanged] 补搜。
  void _onChannelChanged() {
    if (_disposed) return;
    _ensureKindSupported();
    // 旧渠道的结果不属于新渠道：先清空所有类型，再按当前关键词重搜。
    _clearAll();
    _notify();
    final keyword = _query.trim();
    if (keyword.isEmpty || supportedKinds.isEmpty) return;
    unawaited(_current.search(keyword));
  }

  /// registry.changes：删来源、给晚到的当前渠道补搜。
  ///
  /// descriptors 未变化时直接返回，避免 SourceManager 的其它通知触发重复请求。
  void _onSourcesChanged() {
    if (_disposed) return;
    final next = sourceChannels;
    if (listEquals(_lastDescriptors, next)) return;
    _lastDescriptors = next;

    // 当前渠道被移除 / 能力位全部关闭：旧结果不再属于任何可展示目标。
    // 渠道 key 保留（用户偏好），等它回来后再按当前关键词重新补首屏；
    // 失效回退由资料页在音源就绪后触发，搜索侧不自动改搜其它渠道。
    if (!hasActiveSearchSource) _clearAll();
    _ensureKindSupported();

    final keyword = _query.trim();
    if (keyword.isNotEmpty &&
        supportedKinds.isNotEmpty &&
        !(_debounceTimer?.isActive ?? false)) {
      final current = _current;
      if (current.keyword == keyword) {
        // 当前渠道晚到（例如脚本加载完成）时补首屏；其它类型在切过去时由
        // selectKind 的 ensureFirstPage 路径补齐。
        unawaited(current.ensureFirstPage());
      } else {
        // 切到暂不可搜索的渠道时渠道切换已清空控制器（keyword 为空）；
        // 能力补齐后必须主动按当前关键词重搜，不能等用户重新输入。
        unawaited(current.search(keyword));
      }
    }
    _notify();
  }

  /// 当前 kind 不被渠道支持时回退到第一个支持的 kind（优先 song）。
  void _ensureKindSupported() {
    final kinds = supportedKinds;
    if (kinds.contains(_kind)) return;
    _kind = kinds.contains(SearchKind.song)
        ? SearchKind.song
        : (kinds.isEmpty ? SearchKind.song : kinds.first);
  }

  /// 当前类型的结果控制器（三种行形状只在各自 getter 里类型化）。
  SearchResultsController<Object> get _current => _controls[_kind]!;

  /// 发布会话状态前先刷新预览：预览顺序 / 高亮与结果永远同一拍。
  void _notify() {
    if (_disposed) return;
    preview.update(
      kind: _kind,
      results: currentResults,
      sourceKey: activeSourceKey,
      query: _query,
    );
    notifyListeners();
  }

  SearchResultsController<R> _buildController<R>({
    required SearchKind kind,
    required String failureLabel,
    required SearchPageFetcher<R> fetchPage,
    String Function(R item)? keyOf,
    R Function(R existing, R incoming)? mergeDuplicate,
  }) {
    return SearchResultsController<R>(
      failureLogLabel: () => '$failureLabel ($activeSourceKey)',
      fetchPage: (keyword, page) => fetchPage(activeSourceKey, keyword, page),
      canSearch: () =>
          activeSource?.capabilities.supportsSearchKind(kind) ?? false,
      keyOf: keyOf,
      mergeDuplicate: mergeDuplicate,
    );
  }

  void _clearAll() {
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
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _selection.removeListener(_onChannelChanged);
    _registrySubscription?.cancel();
    for (final control in _controls.values) {
      control.removeListener(_onSearchChanged);
      control.dispose();
    }
    preview.dispose();
    super.dispose();
  }
}
