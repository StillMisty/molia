/// 评论会话模块：热门 / 最新两个 tab 的取数、分页、刷新与错误归一化。
///
/// UI 只调用 [open] / [selectKind] / [refresh] / [retry] / [loadMore] 并渲染
/// [stateOf]；缓存与错误边界在 `CommentsService`，能力位来自 [SourceRegistry]。
library;

import 'package:flutter/foundation.dart';

import '../data/catalog/comments_service.dart';
import '../domain/models/comment.dart';
import '../domain/models/failure.dart';
import '../domain/models/track.dart';
import '../domain/ports/source_registry.dart';

/// 单个 tab（热门 / 最新）的分页状态（不可变；`page == 0` = 尚未加载成功）。
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

  CommentsTabState copyWith({
    List<Comment>? items,
    int? total,
    int? page,
    bool? hasMore,
    bool? isLoading,
    bool? isLoadingMore,
    bool? loadMoreFailed,
    SourceFailure? failure,
    bool clearFailure = false,
  }) {
    return CommentsTabState(
      items: items ?? this.items,
      total: total ?? this.total,
      page: page ?? this.page,
      hasMore: hasMore ?? this.hasMore,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
      failure: clearFailure ? null : (failure ?? this.failure),
    );
  }

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
        _registry = registry;

  /// 每页条数（与内置实现同一口径）。
  static const int pageSize = kCommentPageSize;

  final CommentsService _service;
  final SourceRegistry _registry;

  /// 会话 id：open/close 时自增，过期响应直接丢弃。
  int _sessionId = 0;

  Track? _track;
  CommentKind _kind = CommentKind.hot;
  Map<CommentKind, CommentsTabState> _states = _emptyStates();

  Track? get track => _track;

  /// 当前 tab。
  CommentKind get kind => _kind;

  /// 当前 tab 的状态。
  CommentsTabState get state => stateOf(_kind);

  CommentsTabState stateOf(CommentKind kind) =>
      _states[kind] ?? const CommentsTabState();

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
    final sessionId = ++_sessionId;
    _track = track;
    _kind = CommentKind.hot;
    _states = _emptyStates();
    notifyListeners();
    if (!supports(track)) return;
    await _load(sessionId, CommentKind.hot, page: 1);
  }

  /// 切换 tab；未加载过的 tab 首次进入时加载首屏。
  Future<void> selectKind(CommentKind kind) async {
    if (_kind == kind) return;
    _kind = kind;
    notifyListeners();
    if (stateOf(kind).page == 0) {
      await _load(_sessionId, kind, page: 1);
    }
  }

  /// 下拉刷新当前 tab：清该曲目缓存后重新取第一页。
  Future<void> refresh() async {
    final track = _track;
    if (track == null || !supports(track)) return;
    _service.invalidateTrack(track);
    await _load(_sessionId, _kind, page: 1);
  }

  /// 重试当前 tab 的首屏（错误态按钮；失败本就不进缓存，无需清缓存）。
  Future<void> retry() {
    if (_track == null) return Future.value();
    return _load(_sessionId, _kind, page: 1);
  }

  /// 加载下一页（触底自动调用；失败保留已加载项，由 UI 提供重试）。
  Future<void> loadMore() {
    final current = state;
    if (current.isLoading || current.isLoadingMore || !current.hasMore) {
      return Future.value();
    }
    return _load(_sessionId, _kind, page: current.page + 1);
  }

  /// 结束会话（页面卸载；过期在途响应由会话 id 守卫丢弃）。
  void close() {
    _sessionId++;
    _track = null;
    _kind = CommentKind.hot;
    _states = _emptyStates();
    notifyListeners();
  }

  Future<void> _load(
    int sessionId,
    CommentKind kind, {
    required int page,
  }) async {
    final track = _track;
    if (track == null) return;
    final append = page > 1;
    _update(
      kind,
      (state) => state.copyWith(
        isLoading: !append,
        isLoadingMore: append,
        loadMoreFailed: false,
        clearFailure: !append,
      ),
    );
    try {
      final result = await _service.fetch(
        track,
        kind: kind,
        page: page,
        limit: pageSize,
      );
      if (sessionId != _sessionId) return;
      _update(kind, (state) {
        return state.copyWith(
          items: append ? _dedupe([...state.items, ...result.items]) : result.items,
          total: result.total ?? state.total,
          page: page,
          hasMore: result.hasMore,
          isLoading: false,
          isLoadingMore: false,
          loadMoreFailed: false,
          clearFailure: true,
        );
      });
    } catch (e) {
      if (sessionId != _sessionId) return;
      final failure = SourceFailure.from(e);
      _update(
        kind,
        (state) => append
            ? state.copyWith(isLoadingMore: false, loadMoreFailed: true)
            : state.copyWith(
                items: const [],
                isLoading: false,
                page: 0,
                hasMore: false,
                failure: failure,
              ),
      );
    }
  }

  /// 跨页去重（部分平台分页边界会重复返回）。
  static List<Comment> _dedupe(List<Comment> items) {
    final seen = <String>{};
    return [
      for (final item in items)
        if (seen.add(item.id)) item,
    ];
  }

  void _update(CommentKind kind, CommentsTabState Function(CommentsTabState) fn) {
    final next = fn(stateOf(kind));
    if (next == _states[kind]) return;
    _states = {..._states, kind: next};
    notifyListeners();
  }

  static Map<CommentKind, CommentsTabState> _emptyStates() => {
        for (final kind in CommentKind.values) kind: const CommentsTabState(),
      };
}
