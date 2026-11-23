/// 评论会话模块：热门 / 最新两个 tab 的取数、分页、刷新与错误归一化。
///
/// UI 只调用 [open] / [selectKind] / [refresh] / [retry] / [loadMore] 并渲染
/// [stateOf]；缓存与错误边界在 `CommentsService`，能力位来自 [SourceRegistry]，
/// 分页状态机（在途守卫 / 跨页去重 / 失败语义）在 [PagedListController]。
library;

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../domain/ports/source_registry.dart';
import '../app/bootstrap/runtime_providers.dart';

import '../data/catalog/comments_service.dart';
import '../domain/models/comment.dart';
import '../domain/models/failure.dart';
import '../domain/models/track.dart';
import 'paged_list_controller.dart';

part 'comments_provider.g.dart';

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

/// 评论会话的不可变快照（两个 tab + 当前曲目 / tab）。
@immutable
class CommentsState {
  const CommentsState({
    required this.track,
    required this.kind,
    required this.tabs,
  });

  final Track? track;
  final CommentKind kind;
  final Map<CommentKind, CommentsTabState> tabs;

  CommentsTabState stateOf(CommentKind kind) =>
      tabs[kind] ?? const CommentsTabState();
}

@Riverpod(keepAlive: true, name: 'commentsProvider')
class CommentsProvider extends _$CommentsProvider {
  /// 每页条数（与内置实现同一口径）。
  static const int pageSize = kCommentPageSize;

  CommentsService? _service;
  SourceRegistry? _registry;

  /// 两个 tab 各持一个分页控制器（重开会话 / 切换 tab 互不影响）。
  final Map<CommentKind, PagedListController<Comment>> _controllers = {};

  /// 各 tab 最近一次成功加载已知的评论总数。
  final Map<CommentKind, int> _knownTotals = {};

  @override
  CommentsState build() {
    _service = ref.read(appRuntimeProvider).maybe<CommentsService>();
    _registry = ref.read(appRuntimeProvider).maybe<SourceRegistry>();
    for (final kind in CommentKind.values) {
      _controllers[kind] = PagedListController<Comment>(
        keyOf: (comment) => comment.id,
        fetchPage: (page) => _fetchPage(kind, page),
      )..addListener(_onTabChanged);
    }
    ref.onDispose(() {
      for (final controller in _controllers.values) {
        controller.removeListener(_onTabChanged);
        controller.dispose();
      }
    });
    return CommentsState(
      track: null,
      kind: CommentKind.hot,
      tabs: {
        for (final kind in CommentKind.values)
          kind: _project(kind, _controllers[kind]!.state),
      },
    );
  }

  Track? get track => state.track;
  CommentKind get kind => state.kind;
  CommentsTabState get stateOfCurrent => state.stateOf(state.kind);
  CommentsTabState stateOf(CommentKind kind) => state.stateOf(kind);

  /// 当前曲目的渠道是否支持评论（无曲目时为 false）。
  bool get isSupported {
    final track = state.track;
    return track != null && supports(track);
  }

  /// 渠道能力位查询（入口显隐与页面空态共用同一判定）。
  bool supports(Track track) =>
      _registry?.byKey(track.id.sourceKey)?.capabilities.comment ?? false;

  Future<void> open(Track track) async {
    _resetTabs();
    state = CommentsState(
      track: track,
      kind: CommentKind.hot,
      tabs: {
        for (final kind in CommentKind.values) kind: const CommentsTabState(),
      },
    );
    if (!supports(track)) return;
    await _controllerOf(CommentKind.hot).loadFirstPage();
  }

  Future<void> selectKind(CommentKind kind) async {
    if (state.kind == kind) return;
    state = CommentsState(track: state.track, kind: kind, tabs: state.tabs);
    if (state.track == null || _controllerOf(kind).state.page > 0) return;
    await _controllerOf(kind).loadFirstPage();
  }

  Future<void> refresh() async {
    final track = state.track;
    if (track == null || !supports(track)) return;
    _service?.invalidateTrack(track);
    await _controllerOf(state.kind).loadFirstPage();
  }

  Future<void> retry() {
    if (state.track == null) return Future.value();
    return _controllerOf(state.kind).loadFirstPage();
  }

  Future<void> loadMore() {
    if (state.track == null) return Future.value();
    return _controllerOf(state.kind).loadMore();
  }

  void close() {
    _resetTabs();
    state = CommentsState(
      track: null,
      kind: CommentKind.hot,
      tabs: {
        for (final kind in CommentKind.values) kind: const CommentsTabState(),
      },
    );
  }

  Future<PagedResult<Comment>> _fetchPage(CommentKind kind, int page) async {
    final track = state.track;
    final service = _service;
    if (track == null || service == null) {
      return const PagedResult(items: [], hasMore: false);
    }
    final result = await service.fetch(
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

  CommentsTabState _project(CommentKind kind, PagedListState<Comment> state) {
    final error = state.error;
    return CommentsTabState(
      items: state.items,
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
    state = CommentsState(
      track: state.track,
      kind: state.kind,
      tabs: {
        for (final kind in CommentKind.values)
          kind: _project(kind, _controllers[kind]!.state),
      },
    );
  }

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
    _knownTotals.clear();
  }
}
