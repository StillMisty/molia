/// 歌手页：头部（头像 / 名字 / 简介）+「播放全部」+「加入列表」+
/// 曲目列表（`FavoriteTrackTile`，与搜索结果行同款；滚到底加载下一页）。
///
/// 入口：歌曲信息页「歌手」行、搜索结果行内歌手名、搜索「歌手」条目
/// （能力位与 id 判定见 `lib/widgets/track_actions.dart`）。取数与缓存由
/// `ArtistService` 承担，页面只依赖领域 `ArtistDetail` 与注入的取数函数
/// （测试可直接传假 loader）。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../data/catalog/artist_service.dart';
import '../domain/models/artist.dart';
import '../domain/models/failure.dart';
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

/// 打开歌手页（[sourceKey]/[artistId] 来自曲目歌手引用或歌手搜索条目）。
Future<void> showArtistPage(
  BuildContext context,
  String sourceKey,
  String artistId, {
  String? fallbackName,
}) {
  final service = context.read<ArtistService?>();
  if (service == null) return Future.value();
  return ResponsiveNavigation.showSecondaryPage<void>(
    context: context,
    title: _l10n(context).trackInfoArtist,
    body: ArtistPage(
      fallbackName: fallbackName,
      loader: (page) => service.load(sourceKey, artistId, page: page),
      embedded: true,
    ),
  );
}

/// 单页取数函数（缓存 / 错误边界在 `ArtistService`）。
typedef ArtistPageLoader = Future<ArtistDetail> Function(int page);

@visibleForTesting
class ArtistPage extends StatefulWidget {
  const ArtistPage({
    super.key,
    required this.loader,
    this.fallbackName,
    this.embedded = false,
  });

  final ArtistPageLoader loader;

  /// 入口已知的歌手名（加载完成前 / 平台未返回名称时的标题回退）。
  final String? fallbackName;

  /// 作为二级页正文挂进外层 chrome（侧边弹层 / 全屏路由的 AppBar）时为
  /// true：不再自带 Scaffold + AppBar，避免双层标题栏。
  final bool embedded;

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  /// 分页集合：首屏 / 加载更多 / 失败 / 在途守卫 / 跨页去重 / 页实体都在
  /// 控制器内。
  late final PagedTrackCollection<ArtistDetail, Track> _collection;

  /// 播放 / 加入列表的唯一编排（洗牌、上下文名、addedAt 都在模块内）。
  final TrackHandoff _handoff = const TrackHandoff();

  @override
  void initState() {
    super.initState();
    _collection = PagedTrackCollection<ArtistDetail, Track>(
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

  /// 取一页（缓存 / 错误边界在 `ArtistService`）；头部数据随响应更新。
  Future<PagedTrackPage<ArtistDetail, Track>> _fetchPage(int page) async {
    final artist = await widget.loader(page);
    return PagedTrackPage(
      entity: artist,
      items: artist.tracks,
      hasMore: artist.hasMore,
    );
  }

  /// 重试 / 失败重试：重新取首屏（在途请求由控制器过期丢弃）。
  Future<void> _load() => _collection.loadFirstPage();

  /// 播放（[index] 为起始下标；队列上下文名为歌手名）。
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

  String _titleOf(ArtistDetail? artist) => resolveTrackListName(
    name: artist?.name,
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
        title: Text(l10n.trackInfoArtist),
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
    // `notFound` 与一般加载失败是两种文案（失败原因在控制器状态里）。
    final error = state.error;
    final notFound =
        error is SourceFailure && error.kind == FailureKind.notFound;
    return PagedTrackCollectionBody<Track>(
      state: state,
      headerBuilder: (context, state) {
        final artist = _collection.entity;
        // 列表态必有实体（与曲目同一响应写入）；空值只为类型收窄。
        if (artist == null) return const SizedBox.shrink();
        return _buildHeader(context, l10n, artist, state.items.length);
      },
      rowBuilder: (context, index, count, tableColumns) =>
          _buildTrackRow(context, index, count),
      onRetry: () => unawaited(_load()),
      onLoadMore: () => unawaited(_collection.loadMore()),
      emptyText: l10n.artistEmpty,
      failureText: notFound ? l10n.artistNotFound : l10n.artistLoadFailed,
      retryText: l10n.retry,
    );
  }

  Widget _buildTrackRow(BuildContext context, int index, int count) {
    final track = _collection.items[index];
    return FavoriteTrackTile.track(
      track: track,
      fallbackCoverUrl: _collection.entity?.avatarUrl,
      position: calculateCardPosition(index, count),
      onTap: () => _playFrom(index),
      // 菜单行：成功也确认一句（动作藏在弹层里，弹层关闭后需要回执）。
      onToggleFavorite: () => unawaited(toggleLibraryFavorite(context, track)),
      // 行尾菜单「加入列表」：与头部 / 收藏页 / 发现页同一流程。
      onAddToPlaylist: () => unawaited(_handoff.addToLibrary(context, [track])),
    );
  }

  /// 头部头像：方形裁切；有图时点击看原图 / 保存原图。
  Widget _buildHeaderAvatar(
    BuildContext context,
    AppLocalizations l10n,
    ArtistDetail artist,
    String? avatar,
    ThemeData theme,
  ) {
    final image = ClipOval(
      child: SizedBox(
        width: 96,
        height: 96,
        child: (avatar?.isNotEmpty ?? false)
            ? AppNetworkImage(
                url: avatar,
                fit: BoxFit.cover,
                // 头部只有 96dp：按容器解码头像，避免按原图尺寸解码。
                memCacheWidth:
                    (96 * MediaQuery.of(context).devicePixelRatio).round(),
                placeholder: ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                ),
                errorWidget: _buildAvatarPlaceholder(theme),
              )
            : _buildAvatarPlaceholder(theme),
      ),
    );
    if (avatar == null || avatar.isEmpty) return image;
    return CoverTapTarget(
      key: const Key('artistHeaderAvatar'),
      size: 96,
      // 圆形头像：交互层与 ClipOval 同一形状。
      borderRadius: BorderRadius.circular(48),
      semanticLabel: l10n.coverLabel,
      onPressed: () {
        HapticsService.lightImpact();
        unawaited(
          showCoverViewer(
            context,
            coverUrl: avatar,
            title: l10n.coverLabel,
            subtitle: artist.name,
            fileNameBase: artist.name,
          ),
        );
      },
      child: image,
    );
  }

  Widget _buildHeader(
    BuildContext context,
    AppLocalizations l10n,
    ArtistDetail artist,
    int trackCount,
  ) {
    final theme = Theme.of(context);
    final avatar = artist.avatarUrl;
    final description = artist.description.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeaderAvatar(context, l10n, artist, avatar, theme),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _titleOf(artist),
                      style: context.typeScale.titleLarge,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l10n.artistSongCount(trackCount),
                      style: context.typeScale.bodySmall.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: context.typeScale.bodySmall.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 12),
          // 播放全部 = 主操作 + 尾部菜单（随机播放全部 / 加入列表）：
          // 头部动作数收缩为一个 split button，主次层级保持不变。
          M3ESplitButton<String>(
            key: const Key('artistPlayAll'),
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
                  unawaited(_handoff.addToLibrary(context, _collection.items));
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAvatarPlaceholder(ThemeData theme) => ColoredBox(
    color: theme.colorScheme.surfaceContainerHighest,
    child: Icon(
      Icons.person_rounded,
      size: 40,
      color: theme.colorScheme.onSurfaceVariant,
    ),
  );
}
