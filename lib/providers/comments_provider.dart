/// 评论会话模块：热门 / 最新两个 tab 的取数、分页、刷新与错误归一化。
///
/// UI 只调用 [open] / [selectKind] / [refresh] / [retry] / [loadMore] 并渲染
/// [stateOf]；缓存与错误边界在 `CommentsService`，能力位来自 [SourceRegistry]，
/// 分页状态机（在途守卫 / 跨页去重 / 失败语义）在 [PagedListController]。
library;

import 'package:flutter/foundation.dart';

import '../data/catalog/comments_service.dart';
import '../domain/models/comment.dart';
import '../domain/models/failure.dart';
import '../domain/models/track.dart';
import '../domain/ports/source_registry.dart';
import 'paged_list_controller.dart';

/// 单个 tab（热门 / 最新）的分页状态（不可变；`page == 0` = 尚未加载成功）。
///
/// 由 [CommentsProvider.stateOf] 从 tab 的分页控制器状态投影而来：失败在
/// 这里已归一化为 [SourceFailure]（UI 只展示 l10n 文案，不展示原始异常）。
@immutable
class CommentsTabState {
  const CommentsTabState({
    this.items = const [],
    this.total,
    this.page = 0,
    this.hasMore = false,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.loadMoreFailed = false,
    this.failure,
  });

  final List<Comment> items;

  /// 平台返回的评论总数（tab 计数展示；未知时为 null）。
  final int? total;

  final int page;
  final bool hasMore;
  final bool isLoading;
  final bool isLoadingMore;

  /// 加载更多失败（保留已加载项，底部显示重试）。
  final bool loadMoreFailed;

  /// 首屏失败（归一化后的失败；UI 只展示 l10n 文案，不展示原始异常）。
  final SourceFailure? failure;

  /// 首屏加载完成且没有任何评论（空态）。
  bool get isEmpty => page > 0 && items.isEmpty && failure == null;

  /// 首屏失败且无内容可展示（错误态）。
  bool get failed => failure != null && items.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is CommentsTabState &&
      listEquals(other.items, items) &&
      other.total == total &&
      other.page == page &&
      other.hasMore == hasMore &&
      other.isLoading == isLoading &&
      other.isLoadingMore == isLoadingMore &&
      other.loadMoreFailed == loadMoreFailed &&
      other.failure == failure;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(items),
        total,
        page,
        hasMore,
        isLoading,
        isLoadingMore,
        loadMoreFailed,
        failure,
      );
}

class CommentsProvider extends ChangeNotifier {
  CommentsProvider({
    required CommentsService service,
    required SourceRegistry registry,
  })  : _service = service,
        _registry = registry {
    for (final kind in CommentKind.values) {
      _controllers[kind] = PagedListController<Comment>(
        keyOf: (comment) => comment.id,
        fetchPage: (page) => _fetchPage(kind, page),
      )..addListener(_onTabChanged);
    }
  }

  /// 每页条数（与内置实现同一口径）。
  static const int pageSize = kCommentPageSize;

  final CommentsService _service;
  final SourceRegistry _registry;

  /// 两个 tab 各持一个分页控制器（重开会话 / 切换 tab 互不影响）。
  final Map<CommentKind, PagedListController<Comment>> _controllers = {};

  /// 各 tab 最近一次成功加载已知的评论总数。
  ///
  /// 控制器首屏失败会清空 total（它的既有契约）：这里兜住 tab 计数，
  /// 刷新失败时「热门 (45)」不掉成「热门」。会话边界（open/close）清空。
  final Map<CommentKind, int> _knownTotals = {};

  Track? _track;
  CommentKind _kind = CommentKind.hot;

  Track? get track => _track;

  /// 当前 tab。
  CommentKind get kind => _kind;

  /// 当前 tab 的状态。
  CommentsTabState get state => stateOf(_kind);

  CommentsTabState stateOf(CommentKind kind) =>
      _project(kind, _controllerOf(kind).state);

  /// 当前曲目的渠道是否支持评论（无曲目时为 false）。
  bool get isSupported {
    final track = _track;
    return track != null && supports(track);
  }

  /// 渠道能力位查询（入口显隐与页面空态共用同一判定）。
  bool supports(Track track) =>
      _registry.byKey(track.id.sourceKey)?.capabilities.comment ?? false;

  /// 打开会话：重置两个 tab 并加载默认 tab（热门）。
  ///
  /// 渠道不支持评论时不发起请求（页面展示「不支持」空态）。
  Future<void> open(Track track) async {
    _track = track;
    _kind = CommentKind.hot;
    _resetTabs();
    notifyListeners();
    if (!supports(track)) return;
    await _controllerOf(CommentKind.hot).loadFirstPage();
  }

  /// 切换 tab；未加载过的 tab 首次进入时加载首屏。
  Future<void> selectKind(CommentKind kind) async {
    if (_kind == kind) return;
    _kind = kind;
    notifyListeners();
    if (_track == null || _controllerOf(kind).state.page > 0) return;
    await _controllerOf(kind).loadFirstPage();
  }

  /// 下拉刷新当前 tab：清该曲目缓存后重新取第一页。
  Future<void> refresh() async {
    final track = _track;
    if (track == null || !supports(track)) return;
    _service.invalidateTrack(track);
    await _controllerOf(_kind).loadFirstPage();
  }

  /// 重试当前 tab 的首屏（错误态按钮；失败本就不进缓存，无需清缓存）。
  Future<void> retry() {
    if (_track == null) return Future.value();
    return _controllerOf(_kind).loadFirstPage();
  }

  /// 加载下一页（触底自动调用；失败保留已加载项，由 UI 提供重试）。
  ///
  /// 「加载中 / 已到底」的守卫由 [PagedListController] 持有。
  Future<void> loadMore() {
    if (_track == null) return Future.value();
    return _controllerOf(_kind).loadMore();
  }

  /// 结束会话（页面卸载；在途响应由各 tab 控制器的 reset 过期丢弃）。
  void close() {
    _track = null;
    _kind = CommentKind.hot;
    _resetTabs();
    notifyListeners();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.removeListener(_onTabChanged);
      controller.dispose();
    }
    super.dispose();
  }

  /// tab 的一页取数（会话已打开；曲目已不在时按空页收尾，不发起请求）。
  Future<PagedResult<Comment>> _fetchPage(CommentKind kind, int page) async {
    final track = _track;
    if (track == null) {
      return const PagedResult(items: [], hasMore: false);
    }
    final result = await _service.fetch(
      track,
      kind: kind,
      page: page,
      limit: pageSize,
    );
    return PagedResult(
      items: result.items,
      hasMore: result.hasMore,
      total: result.total,
    );
  }

  /// 控制器状态 → UI 稳定形状（失败归一化；`failed` 只在首屏失败时给出）。
  CommentsTabState _project(CommentKind kind, PagedListState<Comment> state) {
    final error = state.error;
    return CommentsTabState(
      items: state.items,
      // 首屏失败会把 total 清空（控制器契约）：回退到上次已知值（tab 计数）。
      total: state.total ?? _knownTotals[kind],
      page: state.page,
      hasMore: state.hasMore,
      isLoading: state.isLoading,
      isLoadingMore: state.isLoadingMore,
      loadMoreFailed: state.loadMoreFailed,
      failure: state.failed && error != null ? SourceFailure.from(error) : null,
    );
  }

  PagedListController<Comment> _controllerOf(CommentKind kind) =>
      _controllers[kind]!;

  void _onTabChanged() {
    _rememberTotals();
    notifyListeners();
  }

  /// 记住各 tab 最新已知的总数（控制器状态变化时调用）。
  void _rememberTotals() {
    for (final entry in _controllers.entries) {
      final total = entry.value.state.total;
      if (total != null) _knownTotals[entry.key] = total;
    }
  }

  void _resetTabs() {
    for (final controller in _controllers.values) {
      controller.reset();
    }
    // 顺序：reset 的通知里可能读到另一个 tab 的旧状态，最后再清记忆。
    _knownTotals.clear();
  }
}
