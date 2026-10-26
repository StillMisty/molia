/// 专辑页：头部（封面 / 专辑名 / 歌手 / 年份）+ 「播放全部」+「加入列表」+
/// 曲目列表（`FavoriteTrackTile`，与搜索结果 / 歌手页同款：行尾菜单收藏 /
/// 加入列表；滚到底加载下一页）。
///
/// 入口：歌曲信息页「专辑」行（payload 专辑 id + 渠道能力位判定，见
/// `lib/widgets/track_actions.dart`）。取数与缓存由 `AlbumService` 承担，
/// 页面只依赖领域 `Album` 与注入的取数函数（测试可直接传假 loader）。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../data/catalog/album_service.dart';
import '../domain/models/album.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/paged_list_controller.dart';
import '../services/haptics.dart';
import '../theme/m3e_context.dart';
import '../utils/responsive.dart';
import '../widgets/app_network_image.dart';
import '../widgets/cover_tap_target.dart';
import '../widgets/cover_viewer.dart';
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
  final service = context.read<AlbumService?>();
  if (service == null) return Future.value();
  return ResponsiveNavigation.showSecondaryPage<void>(
    context: context,
    title: _l10n(context).trackInfoAlbum,
    body: AlbumPage(
      fallbackName: fallbackName,
      loader: (page) => service.load(sourceKey, albumId, page: page),
      embedded: true,
    ),
  );
}

/// 单页取数函数（缓存 / 错误边界在 `AlbumService`）。
typedef AlbumPageLoader = Future<Album> Function(int page);

@visibleForTesting
class AlbumPage extends StatefulWidget {
  const AlbumPage({
    super.key,
    required this.loader,
    this.fallbackName,
    this.embedded = false,
  });

  final AlbumPageLoader loader;

  /// 入口已知的专辑名（加载完成前 / 平台未返回名称时的标题回退）。
  final String? fallbackName;

  /// 作为二级页正文挂进外层 chrome（侧边弹层 / 全屏路由的 AppBar）时为
  /// true：不再自带 Scaffold + AppBar，避免双层标题栏。
  final bool embedded;

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  /// 分页集合：首屏 / 加载更多 / 失败 / 在途守卫 / 跨页去重 / 页实体都在
  /// 控制器内（页面不再自己持有 `_album`）。
  late final PagedTrackCollection<Album, Track> _collection;

  /// 播放 / 加入列表的唯一编排（洗牌、上下文名、addedAt 都在模块内）。
  final TrackHandoff _handoff = const TrackHandoff();

  @override
  void initState() {
    super.initState();
    _collection = PagedTrackCollection<Album, Track>(
      // 平台分页边界会重复返回（忽略 page 时重复整表）：按 track id 跨页去重。
      keyOf: (track) => track.id.uri,
      loadPage: _fetchPage,
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _collection.dispose();
    super.dispose();
  }

  /// 取一页（缓存 / 错误边界在 `AlbumService`）；头部数据随响应更新。
  Future<PagedTrackPage<Album, Track>> _fetchPage(int page) async {
    final album = await widget.loader(page);
    return PagedTrackPage(
      entity: album,
      items: album.tracks,
      hasMore: album.hasMore,
    );
  }

  /// 重试 / 失败重试：重新取首屏（在途请求由控制器过期丢弃）。
  Future<void> _load() => _collection.loadFirstPage();

  /// 播放（[index] 为起始下标；队列上下文名为专辑名）。
  void _playFrom(int index) {
    unawaited(
      _handoff.play(
        context,
        _collection.items,
        startIndex: index,
        contextName: _collection.entity?.name,
        fallbackContextName: widget.fallbackName,
      ),
    );
  }

  /// 「随机播放全部」：洗牌与起播下标的顺序统一由 handoff 负责。
  Future<void> _playShuffled() => _handoff.play(
        context,
        _collection.items,
        shuffle: true,
        contextName: _collection.entity?.name,
        fallbackContextName: widget.fallbackName,
      );

  String _titleOf(Album? album) => resolveTrackListName(
        name: album?.name,
        fallbackName: widget.fallbackName,
      );

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final body = ValueListenableBuilder<PagedListState<Track>>(
      valueListenable: _collection,
      // 分页状态是不可变值：整块 body 按最新快照重建。
      builder: (context, state, _) => _buildBody(context, l10n, state),
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
        final album = _collection.entity;
        // 列表态必有实体（与曲目同一响应写入）；空值只为类型收窄。
        if (album == null) return const SizedBox.shrink();
        return _buildHeader(context, l10n, album, state.items.length);
      },
      rowBuilder: (context, index, count, tableColumns) =>
          _buildTrackRow(context, index, count),
      onRetry: () => unawaited(_load()),
      onLoadMore: () => unawaited(_collection.loadMore()),
      emptyText: l10n.albumEmpty,
      failureText: l10n.albumLoadFailed,
      retryText: l10n.retry,
    );
  }

  Widget _buildTrackRow(BuildContext context, int index, int count) {
    final track = _collection.items[index];
    return FavoriteTrackTile.track(
      track: track,
      fallbackCoverUrl: _collection.entity?.coverUrl,
      position: calculateCardPosition(index, count),
      onTap: () => _playFrom(index),
      // 菜单行：成功也确认一句（动作藏在弹层里，弹层关闭后需要回执）。
      onToggleFavorite: () => unawaited(toggleLibraryFavorite(context, track)),
      // 行尾菜单「加入列表」：与头部 / 收藏页 / 发现页同一流程。
      onAddToPlaylist: () => unawaited(_handoff.addToLibrary(context, [track])),
    );
  }

  /// 头部封面：方形缩略图按 cover 裁切；有封面时点击看原图。
  Widget _buildHeaderCover(
    BuildContext context,
    AppLocalizations l10n,
    Album album,
    String? cover,
    ThemeData theme,
  ) {
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 96,
        height: 96,
        child: (cover?.isNotEmpty ?? false)
            ? AppNetworkImage(
                url: cover,
                fit: BoxFit.cover,
                placeholder: ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                ),
                errorWidget: ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.album_rounded,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            : ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.album_rounded,
                  size: 40,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
      ),
    );
    if (cover == null || cover.isEmpty) return image;
    return CoverTapTarget(
      key: const Key('albumHeaderCover'),
      size: 96,
      borderRadius: BorderRadius.circular(16),
      semanticLabel: l10n.coverLabel,
      onPressed: () {
        HapticsService.lightImpact();
        unawaited(
          showCoverViewer(
            context,
            coverUrl: cover,
            title: l10n.coverLabel,
            subtitle: album.name,
            fileNameBase: album.artist.isEmpty
                ? album.name
                : '${album.name} - ${album.artist}',
          ),
        );
      },
      child: image,
    );
  }

  Widget _buildHeader(
    BuildContext context,
    AppLocalizations l10n,
    Album album,
    int trackCount,
  ) {
    final theme = Theme.of(context);
    final cover = album.coverUrl;
    final subtitleParts = <String>[
      if (album.artist.isNotEmpty) album.artist,
      if (album.year != null) l10n.albumYear(album.year!),
      l10n.playlistTrackCount(trackCount),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeaderCover(context, l10n, album, cover, theme),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _titleOf(album),
                      style: context.typeScale.titleLarge,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitleParts.join(' · '),
                      style: context.typeScale.bodySmall.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 播放全部 = 主操作 + 尾部菜单（随机播放全部 / 加入列表）：
          // 头部动作数收缩为一个 split button，主次层级保持不变。
          M3ESplitButton<String>(
            key: const Key('albumPlayAll'),
            label: l10n.playAll,
            leadingIcon: Icons.play_arrow_rounded,
            style: M3EButtonStyle.filled,
            onPressed: () => _playFrom(0),
            items: [
              M3ESplitButtonItem<String>(
                value: 'shuffle',
                child: Text(l10n.playAllShuffled),
              ),
              M3ESplitButtonItem<String>(
                value: 'addToLibrary',
                child: Text(l10n.addToPlaylist),
              ),
            ],
            onSelected: (value) {
              switch (value) {
                case 'shuffle':
                  unawaited(_playShuffled());
                case 'addToLibrary':
                  unawaited(
                    _handoff.addToLibrary(context, _collection.items),
                  );
              }
            },
          ),
        ],
      ),
    );
  }
}
