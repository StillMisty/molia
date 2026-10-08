import 'package:flutter/foundation.dart';

/// 一页分页结果（最小形状，与具体领域结果类型解耦，任何列表可复用）。
class PagedResult<T> {
  const PagedResult({required this.items, required this.hasMore, this.total});

  final List<T> items;
  final bool hasMore;
  final int? total;
}

/// 分页列表状态机：首屏 / 加载更多 / 失败态 / 过期响应丢弃 / 跨页去重。
///
/// 由列表的持有方（provider 或 widget）创建并提供 [fetchPage]：
/// 1. 切换筛选条件（平台 / 标签 / 关键词）时先 [reset]（使在途请求过期），
///    再 [loadFirstPage]；
/// 2. 触底或「加载更多」按钮调用 [loadMore]；
/// 3. 通过 [items] / [isLoading] / [isLoadingMore] / [failed] / [hasMore] 渲染。
///
/// 语义：
/// - 过期响应（reset 或新请求之后的返回）直接丢弃，不覆盖新状态；
/// - 提供 [keyOf] 时按 key 跨页去重（部分平台分页边界会重复返回）；
/// - 首屏失败置 [failed] 并清空列表（可重试）；加载更多失败保留已加载项。
class PagedListController<T> extends ChangeNotifier {
  PagedListController({
    required Future<PagedResult<T>> Function(int page) fetchPage,
    String Function(T item)? keyOf,
  })  : _fetchPage = fetchPage,
        _keyOf = keyOf;

  final Future<PagedResult<T>> Function(int page) _fetchPage;
  final String Function(T item)? _keyOf;

  List<T> _items = const [];
  int _page = 0;
  int? _total;
  bool _hasMore = true;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _failed = false;
  Object? _error;
  int _requestId = 0;

  List<T> get items => _items;
  int get page => _page;
  int? get total => _total;
  bool get hasMore => _hasMore;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get failed => _failed;

  /// 最近一次请求的原始异常（成功时清空）；调用方按需归一化为领域失败。
  Object? get error => _error;

  /// 使在途请求过期并清空状态（切换筛选条件时调用）。
  void reset() {
    _requestId++;
    _items = const [];
    _page = 0;
    _total = null;
    _hasMore = true;
    _isLoading = false;
    _isLoadingMore = false;
    _failed = false;
    _error = null;
    notifyListeners();
  }

  Future<void> loadFirstPage() async {
    if (_isLoading) return;
    _isLoading = true;
    _failed = false;
    notifyListeners();
    await _load(page: 1, append: false);
  }

  Future<void> loadMore() async {
    if (_isLoading || _isLoadingMore || !_hasMore) return;
    _isLoadingMore = true;
    notifyListeners();
    await _load(page: _page + 1, append: true);
  }

  Future<void> _load({required int page, required bool append}) async {
    final requestId = _requestId;
    try {
      final result = await _fetchPage(page);
      if (requestId != _requestId) return; // 过期响应：丢弃
      final items = append ? [..._items, ...result.items] : [...result.items];
      _items = _keyOf == null ? items : _dedupe(items);
      _page = page;
      _total = result.total ?? _total;
      _hasMore = result.hasMore;
      _failed = false;
      _error = null;
    } catch (e) {
      if (requestId != _requestId) return;
      _error = e;
      if (!append) {
        // 首屏失败：清空并标记失败（可重试）；加载更多失败保留已有项。
        _failed = true;
        _items = const [];
        _total = null;
        _hasMore = true;
      }
    } finally {
      if (requestId == _requestId) {
        _isLoading = false;
        _isLoadingMore = false;
        notifyListeners();
      }
    }
  }

  List<T> _dedupe(List<T> items) {
    final seen = <String>{};
    return [
      for (final item in items)
        if (seen.add(_keyOf!(item))) item,
    ];
  }
}
