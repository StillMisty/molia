/// 专辑页：头部（封面 / 专辑名 / 歌手 / 年份）+ 「播放全部」+「加入列表」+
/// 曲目列表（`FavoriteTrackTile`，与搜索结果 / 歌手页同款：行尾菜单收藏 /
/// 加入列表；滚到底加载下一页）。
///
/// 入口：歌曲信息页「专辑」行（payload 专辑 id + 渠道能力位判定，见
/// `lib/widgets/track_actions.dart`）。取数与缓存由 data 层实现
/// [AlbumRepository]，页面只依赖 view model 与领域 `Album`。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/album.dart';
import '../domain/models/track.dart';
import '../domain/ports/album_repository.dart';
import '../l10n/app_localizations.dart';
import '../providers/album_view_model.dart';
import '../providers/app_providers.dart';
import '../providers/paged_list_controller.dart';
import '../widgets/responsive.dart';
import '../widgets/detail_page/detail_cover_header.dart';
import '../widgets/favorite_action.dart';
import '../widgets/favorite_track_tile.dart';
import '../widgets/paged_track_collection.dart';
import '../widgets/track_handoff.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 打开专辑页（[sourceKey]/[albumId] 来自曲目 payload；能力位由入口先行判定）。
Future<void> showAlbumPage(
  BuildContext context,
  String sourceKey,
  String albumId, {
  String? fallbackName,
}) {
  // 调用方仍按 BuildContext 打开本页（入口批量迁移中），从当前作用域取容器读取。
  final repository = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(albumRepositoryProvider);
  return ResponsiveNavigation.showSecondaryPage<void>(
    context: context,
    title: _l10n(context).trackInfoAlbum,
    body: AlbumPage(
      repository: repository,
      sourceKey: sourceKey,
      albumId: albumId,
      fallbackName: fallbackName,
      embedded: true,
    ),
  );
}

@visibleForTesting
class AlbumPage extends StatefulWidget {
  const AlbumPage({
    super.key,
    required this.repository,
    required this.sourceKey,
    required this.albumId,
    this.fallbackName,
    this.embedded = false,
  });

  final AlbumRepository repository;
  final String sourceKey;
  final String albumId;

  /// 入口已知的专辑名（加载完成前 / 平台未返回名称时的标题回退）。
  final String? fallbackName;

  /// 作为二级页正文挂进外层 chrome（侧边弹层 / 全屏路由的 AppBar）时为
  /// true：不自带 Scaffold + AppBar，避免双层标题栏。
  final bool embedded;

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  /// 首屏 / 加载更多 / 失败 / 在途守卫 / 跨页去重 / 页实体都在 view model 内。
  late final AlbumViewModel _viewModel;

  /// 播放 / 加入列表的唯一编排（洗牌、上下文名、addedAt 都在模块内）。
  final TrackHandoff _handoff = const TrackHandoff();

  @override
  void initState() {
    super.initState();
    _viewModel = AlbumViewModel(
      repository: widget.repository,
      sourceKey: widget.sourceKey,
      albumId: widget.albumId,
    );
    unawaited(_viewModel.loadFirstPage());
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  /// 重试 / 失败重试：重新取首屏（在途请求由 view model 过期丢弃）。
  Future<void> _load() => _viewModel.retry();

  /// 播放（[index] 为起始下标；队列上下文名为专辑名）。
  void _playFrom(int index) {
    unawaited(
      _handoff.play(
        context,
        _viewModel.items,
        startIndex: index,
        contextName: _viewModel.album?.name,
        fallbackContextName: widget.fallbackName,
      ),
    );
  }

  /// 「随机播放全部」：洗牌与起播下标的顺序统一由 handoff 负责。
  Future<void> _playShuffled() => _handoff.play(
    context,
    _viewModel.items,
    shuffle: true,
    contextName: _viewModel.album?.name,
    fallbackContextName: widget.fallbackName,
  );

  String _titleOf(Album? album) => resolveTrackListName(
    name: album?.name,
    fallbackName: widget.fallbackName,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final body = ListenableBuilder(
      listenable: _viewModel,
      // view model 每次变更发布新的不可变分页状态：整块 body 按最新快照重建。
      builder: (context, _) => _buildBody(context, l10n, _viewModel.state),
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.trackInfoAlbum),
        automaticallyImplyLeading: true,
      ),
      body: body,
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    PagedListState<Track> state,
  ) {
    return PagedTrackCollectionBody<Track>(
      state: state,
      headerBuilder: (context, state) {
        final album = _viewModel.album;
        // 列表态必有实体（与曲目同一响应写入）；空值只为类型收窄。
        if (album == null) return const SizedBox.shrink();
        return _buildHeader(context, l10n, album, state.items.length);
      },
      rowBuilder: (context, index, count, tableColumns) =>
          _buildTrackRow(context, index, count),
      onRetry: () => unawaited(_load()),
      onLoadMore: () => unawaited(_viewModel.loadMore()),
      emptyText: l10n.albumEmpty,
      emptyIcon: Icons.album_rounded,
      failureText: l10n.albumLoadFailed,
      retryText: l10n.retry,
    );
  }

  Widget _buildTrackRow(BuildContext context, int index, int count) {
    final track = _viewModel.items[index];
    return FavoriteTrackTile.track(
      track: track,
      fallbackCoverUrl: _viewModel.album?.coverUrl,
      position: calculateCardPosition(index, count),
      onTap: () => _playFrom(index),
      // 菜单行：成功也确认一句（动作藏在弹层里，弹层关闭后需要回执）。
      onToggleFavorite: () => unawaited(toggleLibraryFavorite(context, track)),
      // 行尾菜单「加入列表」：与头部 / 收藏页 / 发现页同一流程。
      onAddToPlaylist: () => unawaited(_handoff.addToLibrary(context, [track])),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    AppLocalizations l10n,
    Album album,
    int trackCount,
  ) {
    final subtitleParts = <String>[
      if (album.artist.isNotEmpty) album.artist,
      if (album.year != null) l10n.albumYear(album.year!),
      l10n.playlistTrackCount(trackCount),
    ];
    return DetailCoverHeader(
      coverKey: const Key('albumHeaderCover'),
      coverUrl: album.coverUrl,
      shape: DetailCoverShape.square,
      fallbackIcon: Icons.album_rounded,
      title: _titleOf(album),
      subtitle: subtitleParts.join(' · '),
      // 查看器副标题用平台原名（标题可能已回退到入口名）；保存文件名
      // 保持「专辑 - 歌手」的可读组合。
      viewerSubtitle: album.name,
      viewerFileNameBase: album.artist.isEmpty
          ? album.name
          : '${album.name} - ${album.artist}',
      action: DetailPlayAllSplitButton(
        key: const Key('albumPlayAll'),
        onPlay: () => _playFrom(0),
        onShuffle: () => unawaited(_playShuffled()),
        onAddToLibrary: () =>
            unawaited(_handoff.addToLibrary(context, _viewModel.items)),
      ),
    );
  }
}
