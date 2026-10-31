import 'package:logging/logging.dart';

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../app/perf/data_path_trace.dart';
import '../data/catalog/catalog_service.dart';
import '../domain/models/artist.dart';
import '../domain/models/catalog.dart' show SearchKind, SearchQuery;
import '../domain/models/failure.dart';
import '../domain/models/source.dart' show SourceDescriptor;
import '../domain/models/track.dart';
import '../domain/ports/source_registry.dart';
import 'paged_list_controller.dart';
import 'playback_provider.dart';
import 'search_row.dart';

export 'search_row.dart' show SearchRow;

final _logger = Logger('molia.search_provider');

/// 歌词搜索的一页：在通用 [PagedResult] 上带回本页命中的片段。
///
/// 片段必须随页身份一起被接受：只有控制器判定请求仍为当前会话后，才把
/// 这页的片段并入累计表；旧查询晚到的响应不能污染新查询的行。
class _LyricPageResult extends PagedResult<Track> {
  const _LyricPageResult({
    required this.snippets,
    required super.items,
    required super.hasMore,
    super.total,
  });

  /// 本页命中的片段（key = `TrackId.uri`，与行身份同一口径）。
  final Map<String, String> snippets;
}

/// 一类搜索的分页部分（与结果类型无关）：关键词、归一化失败、分页元数据。
///
/// provider 只通过这个接口读当前类型的状态：八个同名 getter 与 `loadMore`
/// 的会话判定不再各写一份三向 switch；新增搜索类型时，分页 / 失败这部分
/// 只需多一个会话实例，结果投影仍由 provider 按行形状决定。
abstract interface class _SearchPaging {
  /// 本会话最近一次搜索的关键词（取页回调读取；换词 / 清空时归零）。
  String get keyword;

  /// 归一化失败（UI 的唯一错误出口；成功页会清掉上一次加载更多失败）。
  SourceFailure? get failure;

  int get page;
  int? get total;
  bool get hasMore;
  bool get isLoading;
  bool get isLoadingMore;
  bool get loadMoreFailed;

  /// 开始新关键词：先作废旧会话（关键词、失败与在途页），再记下新关键词。
  void begin(String keyword);

  /// 清空会话：关键词与失败归 null，pager 状态复位并使在途页过期。
  void reset();

  /// 取首屏（调用方已 [begin]）。
  Future<void> loadFirstPage();

  /// 取下一页；失败按会话统一口径归一，由调用方决定是否重新投影。
  Future<void> loadMore();

  void dispose();
}

/// 一个搜索会话：分页控制器 + 关键词 + 归一化失败。
///
/// 结果投影不放进会话：单曲 / 歌手 / 歌词的行形状不同（`SearchRow` /
/// `ArtistSummary` / 带片段的行），provider 仍按类型保留自己的结果字段；
/// 会话只保证「这一类的关键词、页码、失败属于同一次搜索」，切类型不会串台。
class _SearchSession<T> implements _SearchPaging {
  /// [failureLogLabel] 只用于失败日志前缀（保留三类会话各自的可诊断文案）。
  _SearchSession(this._pager, this._failureLogLabel);

  final PagedListController<T> _pager;

  /// 失败日志前缀：保留三类会话各自的可诊断文案。
  final String _failureLogLabel;

  @override
  String keyword = '';

  @override
  SourceFailure? failure;

  /// 已接受页累计后的条目（provider 做类型化投影时读取）。
  ///
  /// 失败时控制器仍保留已加载条目，但 provider 的失败分支不会用旧页覆盖
  /// 已发布列表（错误条与旧结果并存）。
  List<T> get items => _pager.items;

  @override
  int get page => _pager.page;

  @override
  int? get total => _pager.total;

  @override
  bool get hasMore => _pager.hasMore;

  @override
  bool get isLoading => _pager.isLoading;

  @override
  bool get isLoadingMore => _pager.isLoadingMore;

  @override
  bool get loadMoreFailed => _pager.loadMoreFailed;

  @override
  void begin(String keyword) {
    reset();
    this.keyword = keyword;
  }

  @override
  void reset() {
    keyword = '';
    failure = null;
    _pager.reset();
  }

  @override
  Future<void> loadFirstPage() async {
    await _pager.loadFirstPage();
    _syncFailure();
  }

  @override
  Future<void> loadMore() async {
    await _pager.loadMore();
    _syncFailure();
  }

  /// 失败归一化只在这一个出口：成功清失败，失败挂归一化对象。
  ///
  /// 结果投影的「失败保留旧行」由 provider 读取 [failure] 后决定；这里不
  /// 碰投影，避免会话反过来知道三种行形状。
  void _syncFailure() {
    final error = _pager.error;
    if (error == null) {
      failure = null;
      return;
    }
    _logger.fine('$_failureLogLabel: $error');
    failure = SourceFailure.from(error);
  }

  @override
  void dispose() => _pager.dispose();
}

/// 搜索状态（内部经 [CatalogService]/[SourceRegistry]）。
///
/// 公开 API：`filteredResults` / `loadMore` / `sourceChannels` / 分页 / 空态；
/// 结果行统一是 [SearchRow]（领域 `Track` + 可选歌词片段）。搜索会话与投影
/// 全程只存领域 `Track`（payload 同一引用），不再维护旁路 `SourceTrack` 列表：
/// 行、队列与播放身份都来自同一个对象，少一次往返转换。
class SearchProvider extends ChangeNotifier {
  final PlaybackProvider _playbackProvider;

  /// 搜索入口：带 single-flight + LRU + TTL 的目录服务（可为 null：无音源）。
  final CatalogService? _catalogService;

  /// 音源注册表：描述列表与变更通知来源（可为 null：无音源）。
  final SourceRegistry? _sourceRegistry;

  StreamSubscription<void>? _registrySubscription;

  String _searchQuery = '';

  /// 已加载的单曲搜索结果（分页追加、pager 去重后的稳定列表）。
  List<SearchRow> _searchRows = const [];

  /// 当前搜索音源：音源 key（kw/kg/tx/wy/mg/bili/脚本自定义源）。
  /// 无可用音源时为空字符串（搜索结果页展示空态引导）。
  String _sourceKey = '';

  /// 当前搜索类型（搜索页「单曲 / 歌手」分段；默认单曲）。
  SearchKind _kind = SearchKind.song;

  // 单曲 / 歌手 / 歌词各一个搜索会话：关键词、失败、分页控制器各一份，
  // 切类型只换读取的会话；结果投影仍按类型保留（行形状不同）。
  late final _SearchSession<Track> _songSession;
  late final _SearchSession<ArtistSummary> _artistSession;
  late final _SearchSession<Track> _lyricSession;

  /// 歌手类型的结果投影。
  List<ArtistSummary> _artistResults = const [];

  /// 歌词类型的行投影（与单曲同构的播放 / 收藏路径）。
  List<SearchRow> _lyricRows = const [];

  /// 已接受页累计的片段表（key = `TrackId.uri`）；换词 / 换源时清空。
  Map<String, String> _lyricSnippets = const {};

  // 分页状态：唯一状态机 PagedListController（首屏/加载更多/失败/过期守卫/去重）
  static const int _searchPageSize = 30;

  Timer? _debounceTimer;

  /// 已 dispose：释放入口可能比页面生命周期晚（组合根注册的回调），
  /// 销毁后不得再通知已卸下的监听器。
  bool _disposed = false;

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
  }) {
    _songSession = _SearchSession<Track>(
      PagedListController<Track>(
        keyOf: (track) => track.id.uri,
        fetchPage: _fetchSongPage,
      ),
      'Search failed',
    );
    _artistSession = _SearchSession<ArtistSummary>(
      PagedListController<ArtistSummary>(
        keyOf: (artist) => artist.id,
        fetchPage: _fetchArtistPage,
      ),
      'Artist search failed',
    );
    _lyricSession = _SearchSession<Track>(
      PagedListController<Track>(
        keyOf: (track) => track.id.uri,
        fetchPage: _fetchLyricPage,
        onPageAccepted: _acceptLyricPage,
      ),
      'Lyric search failed',
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

  /// 当前类型的分页会话：所有跨类型的元数据读取只在这里分派一次。
  _SearchPaging get _activeSearchSession => switch (_kind) {
    SearchKind.song => _songSession,
    SearchKind.artist => _artistSession,
    SearchKind.lyric => _lyricSession,
  };

  /// 是否正在搜索当前类型（首屏加载中）。
  ///
  /// 直接读当前类型分页会话的加载态（不再维护镜像 flag）。
  bool get isSearching => _activeSearchSession.isLoading;

  /// 归一化失败对象（UI 的唯一错误出口：标题走 l10n，详情用 message，
  /// 不再暴露 `'Search failed: $e'` 这类原始异常字符串）。
  SourceFailure? get failure => _activeSearchSession.failure;

  /// 当前已加载到第几页（从 1 开始）。
  int get currentPage => _activeSearchSession.page;

  /// 平台返回的结果总数（部分平台/脚本不返回则为 null）。
  int? get totalResults => _activeSearchSession.total;

  /// 是否还有下一页可加载。
  bool get hasMore => _activeSearchSession.hasMore;

  /// 是否正在加载下一页。
  bool get isLoadingMore => _activeSearchSession.isLoadingMore;

  /// 加载下一页是否失败（失败后停在当前页，由列表底部重试）。
  bool get loadMoreFailed => _activeSearchSession.loadMoreFailed;

  /// 「歌手」类型的结果（当前音源支持歌手能力时才有内容）。
  List<ArtistSummary> get artistResults => _artistResults;

  /// 「歌词」类型的结果（与单曲同构的条目 + [SearchRow.lyricSnippet]）。
  List<SearchRow> get lyricResults => _lyricRows;

  /// 是否已选中可用音源（空音源时搜索结果页展示引导空态）。
  bool get hasSelectedSource => _sourceKey.isNotEmpty;

  /// 可选音源列表：直接是 [SourceRegistry] 的渠道描述（唯一渠道形状）；
  /// 顺序即用户自定义排序（`lx_source_order`）。
  List<SourceDescriptor> get sourceChannels =>
      _sourceRegistry?.descriptors ?? const [];

  String get sourceDisplayName {
    for (final option in sourceChannels) {
      if (option.key == _sourceKey) return option.displayName;
    }
    return _sourceKey;
  }

  void _onSourcesChanged() {
    final available = sourceChannels;
    // 当前音源仍可用：仅通知 UI（音源列表可能变化）。
    if (_sourceKey.isNotEmpty && available.any((o) => o.key == _sourceKey)) {
      notifyListeners();
      return;
    }
    // 未选择 / 音源失效：回退到第一个可用音源，无可用音源则清空。
    final fallback = available.isEmpty ? '' : available.first.key;
    if (fallback != _sourceKey) {
      _sourceKey = fallback;
      _clearAllSearchState();
    }
    // 换源后当前类型可能不再可用（如脚本源没有歌手 / 歌词能力）：回退单曲。
    if (!supportedSearchKinds.contains(_kind)) _kind = SearchKind.song;
    notifyListeners();
  }

  /// 三类分页会话一起归零（关键词 / 失败 / 在途页）。
  ///
  /// 换词 / 换源 / 清空搜索都先经过这里：以前三个 `_reset*Pagination` 各自
  /// 维护关键词与失败，删改会话字段时容易只漏一条路径。
  void _resetAllPaging() {
    _songSession.reset();
    _artistSession.reset();
    _lyricSession.reset();
  }

  /// 换词前的公共清理：三类分页全部作废，非激活类型的投影立即清空。
  ///
  /// 单曲投影保留到新首屏落地：首屏失败时错误条与旧结果并存，不闪空
  /// （与旧行为一致；歌词片段表随歌词投影一起清）。
  void _prepareForNewKeyword() {
    _resetAllPaging();
    _clearArtistResults();
    _clearLyricResults();
  }

  /// 清空全部搜索状态（换源 / 清空搜索 / 释放内存）。
  void _clearAllSearchState() {
    _resetAllPaging();
    _clearSongResults();
    _clearArtistResults();
    _clearLyricResults();
  }

  /// 单曲结果投影清空（分页会话由 [_resetAllPaging] 负责）。
  void _clearSongResults() {
    _searchRows = const [];
  }

  /// 歌手结果投影清空。
  void _clearArtistResults() {
    _artistResults = const [];
  }

  /// 歌词结果投影与片段表清空。
  ///
  /// 片段表属于歌词会话：reset 使在途页过期后旧页不会再被 accepted 回调
  /// 接受，这里与行一起清空，新会话只从新页累计片段。
  void _clearLyricResults() {
    _lyricRows = const [];
    _lyricSnippets = const {};
  }

  /// 切换搜索类型：不支持的类型忽略；目标类型尚无结果时按当前关键词取首屏。
  void selectSearchKind(SearchKind kind) {
    if (kind == _kind || !supportedSearchKinds.contains(kind)) return;
    _kind = kind;
    notifyListeners();
    final query = _searchQuery.trim();
    if (query.isEmpty) return;
    if (kind == SearchKind.artist) {
      if (_artistResults.isEmpty && !_artistSession.isLoading) {
        unawaited(_performArtistSearch(query));
      }
      return;
    }
    if (kind == SearchKind.lyric) {
      // 用已发布的行判定「已有结果」：首屏失败时行会保留，旧行为不自动重试。
      if (_lyricRows.isEmpty && !_lyricSession.isLoading) {
        unawaited(_performLyricSearch(query));
      }
      return;
    }
    if (_searchRows.isEmpty && !_songSession.isLoading) {
      unawaited(performSearch(query));
    }
  }

  /// 切换搜索音源。
  void selectSource(String key) {
    if (key == _sourceKey) return;
    _sourceKey = key;
    _clearAllSearchState();
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

  void updateSearchQuery(String query) {
    if (query == _searchQuery) return;

    _debounceTimer?.cancel();

    _searchQuery = query;
    _prepareForNewKeyword();

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
    _prepareForNewKeyword();

    if (query.isEmpty) {
      _searchQuery = '';
      _clearSongResults();
      notifyListeners();
      return;
    }

    if (query != _searchQuery) {
      _searchQuery = query;
      notifyListeners();
    }

    performSearch(query);
  }

  void clearSearch() {
    _debounceTimer?.cancel();
    _searchQuery = '';
    _clearAllSearchState();
    notifyListeners();
  }

  /// 释放搜索结果（托盘隐藏时由内存守卫调用）。
  ///
  /// 搜索结果页随休眠门卸载，恢复时会重建；瞬时结果 / 歌词片段 / 分页会话
  /// 没有保留价值，却会连同 raw payload 一直挂到下次搜索。清空关键词与三类
  /// 分页会话（[PagedListController.reset] 同时使在途响应过期），并取消
  /// 防抖计时器；音源选择与当前类型分段保留（那是用户偏好，不占内存）。
  void releaseSearchResults() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _searchQuery = '';
    _clearAllSearchState();
    notifyListeners();
  }

  Future<void> performSearch(String query) async {
    // 归一化一次：搜索缓存 key 含关键词，带首尾空格的输入会命中不同条目
    // 并重复请求（手机键盘自动补空格很常见）。
    final keyword = query.trim();
    if (keyword.isEmpty) return;

    // 按当前类型分发到各自会话（三类互不共享关键词 / 页码 / 失败）。
    return switch (_kind) {
      SearchKind.song => _performSongSearch(keyword),
      SearchKind.artist => _performArtistSearch(keyword),
      SearchKind.lyric => _performLyricSearch(keyword),
    };
  }

  /// 单曲搜索首屏（失败保留已有行）。
  Future<void> _performSongSearch(String keyword) async {
    // 无可用音源：展示空态引导，不发起请求。
    if (_sourceKey.isEmpty) {
      _songSession.reset();
      _clearSongResults();
      notifyListeners();
      return;
    }

    _songSession.begin(keyword);
    notifyListeners();

    await _songSession.loadFirstPage();
    _projectSongResults();
    notifyListeners();
  }

  /// pager 的取页实现：按当前音源与会话关键词请求 CatalogService。
  ///
  /// CatalogService 已返回领域 `Track`（payload 原样），直接成为分页条目：
  /// 行、队列与播放共用同一对象，不再做 `Track → SourceTrack → Track` 往返。
  Future<PagedResult<Track>> _fetchSongPage(int page) async {
    final catalog = _catalogService;
    if (catalog == null) {
      throw StateError('音源未初始化');
    }
    final source = _sourceKey;
    final result = await DataPathTrace.async(
      'search.page',
      () => catalog.search(
        source,
        SearchQuery(
          keyword: _songSession.keyword,
          page: page,
          limit: _searchPageSize,
        ),
      ),
      fields: () => {'source': source, 'page': page},
    );
    return PagedResult(
      items: result.items,
      hasMore: result.hasMore,
      total: result.total,
    );
  }

  /// 单曲投影：成功页覆盖行；失败只挂错误并保留已有行（错误条与列表并存）。
  ///
  /// 成功页会清掉上一次「加载更多失败」留下的错误（会话已在取页后归一化）。
  void _projectSongResults() {
    final session = _songSession;
    if (session.failure != null) return;
    _searchRows = List.unmodifiable([
      for (final track in session.items) SearchRow(track: track),
    ]);
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
        keyword: _artistSession.keyword,
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
      _artistSession.reset();
      _clearArtistResults();
      notifyListeners();
      return;
    }

    _artistSession.begin(keyword);
    notifyListeners();

    await _artistSession.loadFirstPage();
    _projectArtistResults();
    notifyListeners();
  }

  /// 歌手投影：成功页覆盖结果；失败保留已有歌手行。
  void _projectArtistResults() {
    final session = _artistSession;
    if (session.failure != null) return;
    _artistResults = session.items;
  }

  /// pager 的取页实现：按歌词搜歌（`CatalogService.searchLyrics`，5min 缓存）。
  Future<PagedResult<Track>> _fetchLyricPage(int page) async {
    final catalog = _catalogService;
    if (catalog == null) {
      throw StateError('音源未初始化');
    }
    final result = await catalog.searchLyrics(
      _sourceKey,
      SearchQuery(
        keyword: _lyricSession.keyword,
        page: page,
        limit: _searchPageSize,
      ),
    );
    // 片段按 `TrackId.uri` 建表（与行身份严格一致），曲目直接用命中里的领域
    // Track（payload 同一引用）。片段只随本页返回，取数阶段不写共享状态：
    // 是否接受由控制器的 accepted-page 回调判定。
    final snippets = <String, String>{};
    for (final hit in result.items) {
      if (hit.snippet != null) snippets[hit.track.id.uri] = hit.snippet!;
    }
    return _LyricPageResult(
      snippets: snippets,
      items: [for (final hit in result.items) hit.track],
      hasMore: result.hasMore,
      total: result.total,
    );
  }

  /// 接受页回调：只在这页仍属于当前歌词会话时累计片段。
  ///
  /// 首屏页重置片段表（换词 / 换源后不继承旧页），追加页在已有片段上合并；
  /// 与旧行为一致，同一曲目后一页的片段覆盖前一页。
  void _acceptLyricPage(PagedResult<Track> page, {required bool append}) {
    if (page is! _LyricPageResult) return;
    _lyricSnippets = Map.unmodifiable({
      if (append) ..._lyricSnippets,
      ...page.snippets,
    });
  }

  /// 歌词搜索首屏：独立错误态（失败保留已有结果）。
  Future<void> _performLyricSearch(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return;

    if (_sourceKey.isEmpty) {
      _lyricSession.reset();
      _clearLyricResults();
      notifyListeners();
      return;
    }

    _lyricSession.begin(keyword);
    // 新关键词从空片段表开始；旧会话在途页已被 reset 作废，不会再回调。
    _lyricSnippets = const {};
    notifyListeners();

    await _lyricSession.loadFirstPage();
    _projectLyricResults();
    notifyListeners();
  }

  /// 歌词投影：typed rows + accepted-page 累计的片段 / 失败保留旧行。
  ///
  /// 片段表只含已接受页（accepted-page 回调累计）；这里不再从取数阶段读
  /// 共享暂存，避免旧查询晚到的片段混进新查询的行。
  void _projectLyricResults() {
    final session = _lyricSession;
    if (session.failure != null) return;
    _lyricRows = List.unmodifiable([
      for (final track in session.items)
        SearchRow(track: track, lyricSnippet: _lyricSnippets[track.id.uri]),
    ]);
  }

  /// 加载下一页当前类型（触底自动调用）。
  ///
  /// 「加载中 / 已到底 / 跨页去重」等守卫由 [PagedListController] 持有：
  /// 换词 / 换音源时的会话 reset 已使在途请求过期，旧响应不会覆盖新状态。
  /// 这里只判定会话是否可用（已选音源 + 当前会话有词），并只投影当前类型。
  Future<void> loadMore() async {
    if (!hasSelectedSource) return;
    // 记住发起时的类型：等待期间用户切到别的分段时，仍要投影这条会话
    // （否则切回原类型会看到 pager 已追加、行却没更新的半截列表）。
    final kind = _kind;
    final session = _activeSearchSession;
    if (session.keyword.trim().isEmpty) return;
    // 先在途置位并通知：列表底部进度圈要在请求返回前出现
    // （pager 的 isLoadingMore 是同步写入的）。
    final pending = session.loadMore();
    notifyListeners();
    await pending;
    _projectResults(kind);
    notifyListeners();
  }

  /// 只重新投影指定类型：失败时各投影方法保留旧行。
  void _projectResults(SearchKind kind) {
    switch (kind) {
      case SearchKind.song:
        _projectSongResults();
      case SearchKind.artist:
        _projectArtistResults();
      case SearchKind.lyric:
        _projectLyricResults();
    }
  }

  /// 播放搜索结果：已发布的领域曲目交给 PlaybackProvider 播放。
  ///
  /// 队列取当前类型已加载的行（单曲 / 歌词各自成队），行内就是领域 `Track`；
  /// 播放身份与行身份同一口径（`TrackId`），不再把行转回音源曲目。
  void playItem(SearchRow row) {
    final rows = _kind == SearchKind.lyric ? _lyricRows : _searchRows;
    if (rows.isEmpty) return;
    final queue = [for (final entry in rows) entry.track];
    final index = rows.indexWhere((entry) => entry.id == row.id);
    _playbackProvider.playDomainTracks(
      queue,
      index < 0 ? 0 : index,
      contextName: sourceDisplayName,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _registrySubscription?.cancel();
    _songSession.dispose();
    _artistSession.dispose();
    _lyricSession.dispose();
    super.dispose();
  }
}
