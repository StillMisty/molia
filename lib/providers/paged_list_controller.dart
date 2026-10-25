import 'package:flutter/foundation.dart';

/// 一页分页结果（最小形状，与具体领域结果类型解耦，任何列表可复用）。
class PagedResult<T> {
  const PagedResult({required this.items, required this.hasMore, this.total});

  final List<T> items;
  final bool hasMore;
  final int? total;
}

/// 分页列表的不可变只读状态：持有方以一个值消费（`Selector` /
/// `ValueListenableBuilder` 或直接读 [PagedListController.state]）。
@immutable
class PagedListState<T> {
  const PagedListState({
    this.items = const [],
    this.page = 0,
    this.total,
    this.hasMore = false,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.failed = false,
    this.loadMoreFailed = false,
    this.error,
  });

  /// 已加载条目（跨页去重后按平台原始顺序累计）。
  final List<T> items;

  /// 已成功加载到第几页（从 1 开始；0 = 尚未加载成功）。
  final int page;

  /// 平台返回的结果总数（不返回时保持上一次的值）。
  final int? total;

  /// 是否还有下一页（平台声明，并在追加去重无新增时推断为 false）。
  final bool hasMore;

  /// 首屏加载中。
  final bool isLoading;

  /// 下一页加载中。
  final bool isLoadingMore;

  /// 首屏失败：列表已清空（可重试，重试用 [PagedListController.loadFirstPage]）。
  final bool failed;

  /// 加载更多失败：保留已加载项，由 UI 提供底部重试。
  final bool loadMoreFailed;

  /// 最近一次请求的原始异常（成功时清空）；调用方按需归一化为领域失败。
  final Object? error;

  /// 首屏加载完成且没有任何条目（空态）。
  bool get isEmpty => page > 0 && items.isEmpty && !failed;

  /// 复制并覆盖部分字段（值语义：控制器每次变更都发布新实例）。
  ///
  /// [error] 只能覆盖为新的异常；成功路径用构造函数直接构造（error 归 null）。
  PagedListState<T> copyWith({
    List<T>? items,
    int? page,
    int? total,
    bool? hasMore,
    bool? isLoading,
    bool? isLoadingMore,
    bool? failed,
    bool? loadMoreFailed,
    Object? error,
  }) {
    return PagedListState<T>(
      items: items ?? this.items,
      page: page ?? this.page,
      total: total ?? this.total,
      hasMore: hasMore ?? this.hasMore,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      failed: failed ?? this.failed,
      loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
      error: error ?? this.error,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PagedListState<T> &&
      listEquals(other.items, items) &&
      other.page == page &&
      other.total == total &&
      other.hasMore == hasMore &&
      other.isLoading == isLoading &&
      other.isLoadingMore == isLoadingMore &&
      other.failed == failed &&
      other.loadMoreFailed == loadMoreFailed &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(items),
        page,
        total,
        hasMore,
        isLoading,
        isLoadingMore,
        failed,
        loadMoreFailed,
        error,
      );
}

/// 分页列表状态机：首屏 / 加载更多 / 失败态 / 过期响应丢弃 / 跨页去重。
///
/// 由列表的持有方（provider 或 widget）创建并提供 [fetchPage]：
/// 1. 切换筛选条件（平台 / 标签 / 关键词）时先 [reset]（使在途请求过期），
///    再 [loadFirstPage]；
/// 2. 触底自动调用 [loadMore]（加载中 / 已到底时由控制器忽略）；
/// 3. 通过 [state]（不可变值）渲染，不再自己维护 flag。
///
/// 语义：
/// - 过期响应（reset / 新请求之后的返回）直接丢弃，不覆盖新状态；
/// - 提供 [keyOf] 时按 key 跨页去重（部分平台分页边界会重复返回）；
/// - 追加页去重后无新增 → [PagedListState.hasMore] 置 false：部分平台
///   忽略 page、每次都返回整表，靠这条推断停住（防死循环）；
/// - 首屏失败清空列表并置 [PagedListState.failed]（可重试）；加载更多失败
///   保留已加载项并置 [PagedListState.loadMoreFailed]；
/// - [dispose] 使在途请求过期：销毁后不写状态、不发通知。
class PagedListController<T> extends ValueNotifier<PagedListState<T>> {
  PagedListController({
    required this._fetchPage,
    this._keyOf,
  })  : super(PagedListState<T>(hasMore: true));

  final Future<PagedResult<T>> Function(int page) _fetchPage;
  final String Function(T item)? _keyOf;

  /// 单调递增的请求 id：reset / dispose 后自增，使在途请求过期。
  int _requestId = 0;

  /// 当前状态（[ValueNotifier.value] 的别名，读起来更顺）。
  PagedListState<T> get state => value;

  List<T> get items => value.items;
  int get page => value.page;
  int? get total => value.total;
  bool get hasMore => value.hasMore;
  bool get isLoading => value.isLoading;
  bool get isLoadingMore => value.isLoadingMore;
  bool get failed => value.failed;
  bool get loadMoreFailed => value.loadMoreFailed;

  /// 最近一次请求的原始异常（成功时清空）；调用方按需归一化为领域失败。
  Object? get error => value.error;

  /// 使在途请求过期并清空状态（切换筛选条件时调用）。
  void reset() {
    _requestId++;
    value = PagedListState<T>(hasMore: true);
  }

  Future<void> loadFirstPage() async {
    if (value.isLoading) return;
    value = value.copyWith(
      isLoading: true,
      failed: false,
      loadMoreFailed: false,
    );
    await _load(page: 1, append: false);
  }

  Future<void> loadMore() async {
    final state = value;
    if (state.isLoading || state.isLoadingMore || !state.hasMore) return;
    value = state.copyWith(isLoadingMore: true, loadMoreFailed: false);
    await _load(page: state.page + 1, append: true);
  }

  Future<void> _load({required int page, required bool append}) async {
    final requestId = _requestId;
    // 本次请求的结果状态（null = 过期响应，整体丢弃，不覆盖新状态）。
    PagedListState<T>? next;
    try {
      final result = await _fetchPage(page);
      if (requestId == _requestId) {
        final previousCount = value.items.length;
        final merged =
            append ? [...value.items, ...result.items] : [...result.items];
        final items = _keyOf == null ? merged : _dedupe(merged);
        // 未传 failed / loadMoreFailed / error：成功即清空失败态与异常。
        next = PagedListState<T>(
          items: items,
          page: page,
          total: result.total ?? value.total,
          // 追加去重后无新增：平台忽略 page 时据此停止翻页（防死循环）。
          hasMore: result.hasMore && (!append || items.length > previousCount),
        );
      }
    } catch (e) {
      if (requestId == _requestId) {
        next = append
            // 加载更多失败：保留已加载项，底部提供重试。
            ? value.copyWith(loadMoreFailed: true, error: e)
            // 首屏失败：清空并标记失败（可重试）；页码回到「尚未加载成功」。
            : PagedListState<T>(hasMore: true, failed: true, error: e);
      }
    }
    if (next == null) return;
    value = next.copyWith(isLoading: false, isLoadingMore: false);
  }

  List<T> _dedupe(List<T> items) {
    final seen = <String>{};
    return [
      for (final item in items)
        if (seen.add(_keyOf!(item))) item,
    ];
  }

  @override
  void dispose() {
    // 在途请求过期：ChangeNotifier 禁止 dispose 后通知，回调一律不再回写。
    _requestId++;
    super.dispose();
  }
}
