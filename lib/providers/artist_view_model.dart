/// 歌手页 ViewModel：分页列表 + 头部实体 + 取数命令的唯一持有者。
///
/// 页面只依赖领域 [ArtistDetail] 与不可变 [PagedListState]；缓存 / TTL /
/// 错误归一化留在 data 层实现，过期响应与跨页去重复用
/// [PagedListController] 的代际守卫。
library;

import 'package:flutter/foundation.dart';

import '../domain/models/artist.dart';
import '../domain/models/track.dart';
import '../domain/ports/artist_repository.dart';
import 'paged_list_controller.dart';

/// 一页歌手响应：曲目与头部实体同页返回（头部随分页响应更新）。
class _ArtistPageResult extends PagedResult<Track> {
  const _ArtistPageResult({
    required this.artist,
    required super.items,
    required super.hasMore,
  });

  final ArtistDetail artist;
}

/// 歌手页状态机：首屏 / 加载更多 / 失败重试 / 过期响应丢弃。
class ArtistViewModel extends ChangeNotifier {
  ArtistViewModel({
    required this._repository,
    required this.sourceKey,
    required this.artistId,
  }) {
    _controller = PagedListController<Track>(
      fetchPage: _fetchPage,
      // 平台分页边界会重复返回（忽略 page 时重复整表）：按 track id 跨页去重。
      keyOf: (track) => track.id.uri,
      onPageAccepted: _acceptPage,
    )..addListener(notifyListeners);
  }

  final ArtistRepository _repository;
  final String sourceKey;
  final String artistId;

  late final PagedListController<Track> _controller;

  /// 最近一次成功响应携带的歌手实体；首屏成功前 / [reset] 后为 null。
  ArtistDetail? _artist;

  ArtistDetail? get artist => _artist;

  /// 当前分页状态（不可变值；控制器每次变更发布新实例）。
  PagedListState<Track> get state => _controller.state;

  List<Track> get items => _controller.items;

  Future<void> loadFirstPage() => _controller.loadFirstPage();

  Future<void> loadMore() => _controller.loadMore();

  /// 失败重试：作废在途请求并重新取首屏（旧响应整体丢弃）。
  Future<void> retry() {
    _artist = null;
    _controller.reset();
    return _controller.loadFirstPage();
  }

  Future<PagedResult<Track>> _fetchPage(int page) async {
    final artist = await _repository.loadArtistPage(
      sourceKey,
      artistId,
      page: page,
    );
    return _ArtistPageResult(
      artist: artist,
      items: artist.tracks,
      hasMore: artist.hasMore,
    );
  }

  /// 控制器已接受本页（请求仍为当前代际）：实体与列表同页更新。
  void _acceptPage(PagedResult<Track> page, {required bool append}) {
    if (page is _ArtistPageResult) _artist = page.artist;
  }

  @override
  void dispose() {
    _controller
      ..removeListener(notifyListeners)
      ..dispose();
    super.dispose();
  }
}
