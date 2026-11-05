/// 单渠道单类型的搜索结果：一个不可变快照 + 一个分页状态机。
///
/// 搜索是单渠道的（ADR-0019），所以这里没有来源 key 参数、分组列表或来源
/// 过滤：查询 / 分页 / 失败重试 / 迟到渠道补首屏都只作用于当前渠道。
library;

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../domain/models/failure.dart';
import 'paged_list_controller.dart';

final _logger = Logger('molia.search_results');

/// 某个搜索类型（单曲 / 歌手 / 歌词）的不可变结果快照。
@immutable
class SearchResults<T> {
  const SearchResults({
    this.keyword = '',
    this.items = const [],
    this.failure,
    this.page = 0,
    this.total,
    this.hasMore = false,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.loadMoreFailed = false,
  });

  /// 本轮结果对应的关键词（trim 后；空串 = 未搜索 / 已清空）。
  final String keyword;

  final List<T> items;

  /// 首屏归一化失败。追加页失败只体现在 [loadMoreFailed]，[items] 保留
  /// 已加载的行。
  final SourceFailure? failure;

  /// 已成功加载到第几页（0 = 尚未加载成功）。
  final int page;

  /// 平台返回的总数（部分平台 / 脚本不返回则为 null）。
  final int? total;

  final bool hasMore;

  /// 首屏加载中。
  final bool isLoading;

  final bool isLoadingMore;
  final bool loadMoreFailed;

  /// 已搜索完成且没有任何条目（空态）；不是「还没搜」。
  bool get isEmpty => page > 0 && items.isEmpty && failure == null;
}

/// 单渠道单类型搜索的唯一状态机。
///
/// 分页代际 / 跨页去重 / 失败语义由 [PagedListController] 持有；本类只叠加
/// 关键词、失败归一与迟到渠道补首屏。[canSearch] 为假时只记住关键词、不发
/// 请求，等渠道晚到后由 [ensureFirstPage] 补首屏。
class SearchResultsController<T> extends ValueNotifier<SearchResults<T>> {
  factory SearchResultsController({
    required String Function() failureLogLabel,
    required Future<PagedResult<T>> Function(String keyword, int page)
    fetchPage,
    bool Function()? canSearch,
    String Function(T item)? keyOf,
    T Function(T existing, T incoming)? mergeDuplicate,
  }) => SearchResultsController._(
    failureLogLabel,
    fetchPage,
    canSearch,
    keyOf,
    mergeDuplicate,
  );

  SearchResultsController._(
    this._failureLogLabel,
    this._fetchPage,
    this._canSearch,
    String Function(T item)? keyOf,
    T Function(T existing, T incoming)? mergeDuplicate,
  ) : super(SearchResults<T>()) {
    _pager = PagedListController<T>(
      fetchPage: (page) => _fetchPage(_keyword, page),
      keyOf: keyOf,
      mergeDuplicate: mergeDuplicate,
    )..addListener(_sync);
  }

  final String Function() _failureLogLabel;
  final Future<PagedResult<T>> Function(String keyword, int page) _fetchPage;
  final bool Function()? _canSearch;

  late final PagedListController<T> _pager;

  String _keyword = '';

  Object? _failureCause;
  SourceFailure? _failure;

  /// 当前查询关键词（trim 后；空串 = 未搜索 / 已清空）。
  String get keyword => _keyword;

  bool get _canSearchNow => _canSearch?.call() ?? true;

  /// 换词：清空旧页并使在途请求过期；当前渠道可搜索时立即取首屏。
  Future<void> search(String keyword) async {
    _keyword = keyword.trim();
    _failureCause = null;
    _failure = null;
    _pager.reset();
    if (_keyword.isEmpty || !_canSearchNow) return;
    await _pager.loadFirstPage();
  }

  /// 渠道晚到：当前关键词还没有成功首屏时补一次；已加载 / 在途 / 失败不动。
  Future<void> ensureFirstPage() async {
    if (_keyword.isEmpty || !_canSearchNow) return;
    final state = _pager.state;
    if (state.page > 0 || state.isLoading || state.failed) return;
    await _pager.loadFirstPage();
  }

  Future<void> loadMore() async {
    if (_keyword.isEmpty || !_canSearchNow) return;
    await _pager.loadMore();
  }

  /// 首屏失败重试首屏；追加页失败重试下一页；没有失败时 no-op。
  Future<void> retry() async {
    if (_keyword.isEmpty || !_canSearchNow) return;
    final state = _pager.state;
    if (state.loadMoreFailed) {
      await _pager.loadMore();
    } else if (state.failed) {
      await _pager.loadFirstPage();
    }
  }

  /// 清空结果与关键词；当前渠道偏好由 provider 另外持有。
  void clear() {
    _keyword = '';
    _failureCause = null;
    _failure = null;
    _pager.reset();
  }

  void _sync() {
    final state = _pager.state;
    value = SearchResults<T>(
      keyword: _keyword,
      items: List<T>.unmodifiable(state.items),
      failure: state.failed ? _failureFor(state.error) : null,
      page: state.page,
      total: state.total,
      hasMore: state.hasMore,
      isLoading: state.isLoading,
      isLoadingMore: state.isLoadingMore,
      loadMoreFailed: state.loadMoreFailed,
    );
  }

  /// 归一化失败并只记一次日志：分页状态每次变化都会重建快照，同一个异常
  /// 不应反复写日志。
  SourceFailure? _failureFor(Object? error) {
    if (error == null) return null;
    if (!identical(error, _failureCause)) {
      _failureCause = error;
      _failure = SourceFailure.from(error);
      _logger.fine('${_failureLogLabel()}: $error');
    }
    return _failure;
  }

  @override
  void dispose() {
    _pager.removeListener(_sync);
    _pager.dispose();
    super.dispose();
  }
}
