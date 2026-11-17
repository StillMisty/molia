/// 专辑页 ViewModel：分页列表 + 头部实体 + 取数命令的唯一持有者。
///
/// 页面只依赖领域 [Album] 与不可变 [PagedListState]；缓存 / TTL / 错误归一化
/// 留在 data 层实现，过期响应与跨页去重复用 [PagedListController] 的代际守卫。
library;

import 'package:flutter/foundation.dart';

import '../domain/models/album.dart';
import '../domain/models/track.dart';
import '../domain/ports/album_repository.dart';
import 'paged_list_controller.dart';

/// 一页专辑响应：曲目与头部实体同页返回（头部随分页响应更新）。
class _AlbumPageResult extends PagedResult<Track> {
  const _AlbumPageResult({
    required this.album,
    required super.items,
    required super.hasMore,
  });

  final Album album;
}

/// 专辑页状态机：首屏 / 加载更多 / 失败重试 / 过期响应丢弃。
class AlbumViewModel extends ChangeNotifier {
  AlbumViewModel({
    required this._repository,
    required this.sourceKey,
    required this.albumId,
  }) {
    _controller = PagedListController<Track>(
      fetchPage: _fetchPage,
      // 平台分页边界会重复返回（忽略 page 时重复整表）：按 track id 跨页去重。
      keyOf: (track) => track.id.uri,
      onPageAccepted: _acceptPage,
    )..addListener(notifyListeners);
  }

  final AlbumRepository _repository;
  final String sourceKey;
  final String albumId;

  late final PagedListController<Track> _controller;

  /// 最近一次成功响应携带的专辑实体；首屏成功前 / [reset] 后为 null。
  Album? _album;

  Album? get album => _album;

  /// 当前分页状态（不可变值；控制器每次变更发布新实例）。
  PagedListState<Track> get state => _controller.state;

  List<Track> get items => _controller.items;

  Future<void> loadFirstPage() => _controller.loadFirstPage();

  Future<void> loadMore() => _controller.loadMore();

  /// 失败重试：作废在途请求并重新取首屏（旧响应整体丢弃）。
  Future<void> retry() {
    _album = null;
    _controller.reset();
    return _controller.loadFirstPage();
  }

  Future<PagedResult<Track>> _fetchPage(int page) async {
    final album = await _repository.loadAlbumPage(
      sourceKey,
      albumId,
      page: page,
    );
    return _AlbumPageResult(
      album: album,
      items: album.tracks,
      hasMore: album.hasMore,
    );
  }

  /// 控制器已接受本页（请求仍为当前代际）：实体与列表同页更新。
  void _acceptPage(PagedResult<Track> page, {required bool append}) {
    if (page is _AlbumPageResult) _album = page.album;
  }

  @override
  void dispose() {
    _controller
      ..removeListener(notifyListeners)
      ..dispose();
    super.dispose();
  }
}
