/// 歌手页：头部（头像 / 名字 / 简介）+「播放全部」+「加入列表」+
/// 曲目列表（`FavoriteTrackTile`，与搜索结果行同款；滚到底加载下一页）。
///
/// 入口：歌曲信息页「歌手」行、搜索结果行内歌手名、搜索「歌手」条目
/// （能力位与 id 判定见 `lib/widgets/track_actions.dart`）。取数与缓存由
/// `ArtistService` 承担，页面只依赖领域 `ArtistDetail` 与注入的取数函数
/// （测试可直接传假 loader）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../data/catalog/artist_service.dart';
import '../domain/models/artist.dart';
import '../domain/models/failure.dart';
import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../models/play_mode.dart';
import '../providers/library_provider.dart';
import '../providers/paged_list_controller.dart';
import '../providers/playback_provider.dart';
import '../services/haptics.dart';
import '../theme/m3e_context.dart';
import '../utils/responsive.dart';
import '../widgets/add_to_library.dart';
import '../widgets/app_network_image.dart';
import '../widgets/favorite_action.dart';
import '../widgets/favorite_track_tile.dart';
import '../widgets/track_row.dart';

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

/// 按歌手名打开歌手页（曲目 payload 没有歌手 id 时的回退入口）。
///
/// id 解析延迟到页面加载：解析期间显示加载态，解析失败（未找到）显示可重试
/// 的错误态；解析结果在 `ArtistService` 内缓存（同一名字不重复检索）。
Future<void> showArtistPageByName(
  BuildContext context,
  String sourceKey,
  String name,
) {
  final service = context.read<ArtistService?>();
  if (service == null) return Future.value();
  String? resolvedId;
  return ResponsiveNavigation.showSecondaryPage<void>(
    context: context,
    title: _l10n(context).trackInfoArtist,
    body: ArtistPage(
      fallbackName: name,
      loader: (page) async {
        resolvedId ??= (await service.resolveByName(sourceKey, name))?.id;
        final id = resolvedId;
        if (id == null || id.isEmpty) {
          throw const SourceFailure(
            kind: FailureKind.notFound,
            message: '歌手未找到',
            l10nKey: 'artistNotFound',
          );
        }
        return service.load(sourceKey, id, page: page);
      },
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
  /// 歌手头部数据（随每页响应更新；由取数回调写入，控制器通知触发重建）。
  ArtistDetail? _artist;

  /// 分页状态机：首屏 / 加载更多 / 失败 / 在途守卫 / 跨页去重都在控制器内。
  late final PagedListController<Track> _paged;

  final ScrollController _listController = ScrollController();

  /// 随机播放起点用（与收藏页同一做法：可见列表内随机取一首起播）。
  final math.Random _shuffleRandom = math.Random();

  @override
  void initState() {
    super.initState();
    _paged = PagedListController<Track>(
      // 平台分页边界会重复返回（忽略 page 时重复整表）：按 track id 跨页去重。
      keyOf: (track) => track.id.uri,
      fetchPage: _fetchPage,
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _paged.dispose();
    _listController.dispose();
    super.dispose();
  }

  /// 取一页（缓存 / 错误边界在 `ArtistService`）；头部数据随响应更新。
  Future<PagedResult<Track>> _fetchPage(int page) async {
    final artist = await widget.loader(page);
    _artist = artist;
    return PagedResult(items: artist.tracks, hasMore: artist.hasMore);
  }

  /// 重试 / 失败重试：重新取首屏（在途请求由控制器过期丢弃）。
  Future<void> _load() => _paged.loadFirstPage();

  /// 触底 400px 内自动加载下一页（失败后不自动重试，保留按钮兜底）。
  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    if (notification.metrics.pixels >=
        notification.metrics.maxScrollExtent - 400) {
      _maybeLoadMore();
    }
    return false;
  }

  void _maybeLoadMore() {
    // 失败后不自动重试（底部保留重试按钮）；加载中 / 已到底由控制器守卫。
    if (_paged.state.loadMoreFailed) return;
    unawaited(_paged.loadMore());
  }

  /// 播放（[index] 为起始下标；队列上下文名为歌手名）。
  void _playFrom(int index) {
    final tracks = _paged.state.items;
    if (tracks.isEmpty) return;
    HapticsService.lightImpact();
    final name = _titleOf(_artist);
    unawaited(
      context.read<PlaybackProvider>().playDomainTracks(
            List<Track>.of(tracks),
            index,
            contextName: name.isEmpty ? null : name,
          ),
    );
  }

  /// 「随机播放全部」：先落 shuffle 模式再装载队列（洗牌顺序依赖装载前模式，
  /// 与收藏页一致），起点在已加载曲目内随机。
  Future<void> _playShuffled() async {
    final tracks = _paged.state.items;
    if (tracks.isEmpty) return;
    HapticsService.lightImpact();
    final name = _titleOf(_artist);
    final playback = context.read<PlaybackProvider>();
    await playback.setPlayMode(PlayMode.shuffle);
    await playback.playDomainTracks(
      List<Track>.of(tracks),
      _shuffleRandom.nextInt(tracks.length),
      contextName: name.isEmpty ? null : name,
    );
  }

  /// 「加入列表」：与收藏页 / 发现页共用同一流程（选择目标 → 写入 → 提示）。
  Future<void> _addToLibrary() async {
    final tracks = _paged.state.items;
    if (tracks.isEmpty) return;
    final library = context.read<LibraryProvider>();
    final addedAt = DateTime.now().millisecondsSinceEpoch;
    await addTracksToLibraryTarget(
      context,
      provider: library,
      tracks: [
        for (final track in tracks)
          PlaylistTrack.fromTrack(track, addedAt: addedAt),
      ],
    );
  }

  String _titleOf(ArtistDetail? artist) {
    final name = artist?.name.trim() ?? '';
    if (name.isNotEmpty) return name;
    return widget.fallbackName ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final body = ValueListenableBuilder<PagedListState<Track>>(
      valueListenable: _paged,
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
    if (state.isLoading) {
      return const Center(child: M3ELoadingIndicator());
    }
    final artist = _artist;
    if (state.failed || artist == null) {
      // `notFound` 与一般加载失败是两种文案（失败原因在控制器状态里）。
      final error = state.error;
      final notFound =
          error is SourceFailure && error.kind == FailureKind.notFound;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              notFound ? l10n.artistNotFound : l10n.artistLoadFailed,
              style: context.typeScale.bodyLarge,
            ),
            const SizedBox(height: 12),
            M3EButton.filled(
              onPressed: () => unawaited(_load()),
              child: Text(l10n.retry),
            ),
          ],
        ),
      );
    }
    if (state.isEmpty) {
      return Center(
        child: Text(
          l10n.artistEmpty,
          style: context.typeScale.bodyMedium.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final tracks = state.items;
    final cardList = M3ETheme.of(context).listTheme.cardList;
    final horizontalPadding = context.horizontalPadding;
    return Scrollbar(
      controller: _listController,
      thumbVisibility: true,
      interactive: true,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: CustomScrollView(
          controller: _listController,
          slivers: [
            SliverToBoxAdapter(
              child: _buildHeader(context, l10n, artist, tracks.length),
            ),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              sliver: SliverFixedExtentList.builder(
                // 行高 + 行距：固定 extent，长列表滚动条拖动一次定位。
                itemExtent: TrackRow.extent + cardList.gap,
                itemCount: tracks.length,
                itemBuilder: (context, index) {
                  final isLast = index == tracks.length - 1;
                  return Column(
                    children: [
                      _buildTrackRow(context, index, artist, tracks),
                      if (!isLast) SizedBox(height: cardList.gap),
                    ],
                  );
                },
              ),
            ),
            if (state.isLoadingMore || state.loadMoreFailed)
              SliverToBoxAdapter(
                  child: _buildLoadMoreFooter(context, l10n, state)),
            const SliverToBoxAdapter(child: SizedBox(height: 16)),
          ],
        ),
      ),
    );
  }

  Widget _buildTrackRow(
    BuildContext context,
    int index,
    ArtistDetail artist,
    List<Track> tracks,
  ) {
    final track = tracks[index];
    return FavoriteTrackTile.track(
      track: track,
      fallbackCoverUrl: artist.avatarUrl,
      position: calculateCardPosition(index, tracks.length),
      onTap: () => _playFrom(index),
      // 菜单行：成功也确认一句（动作藏在弹层里，弹层关闭后需要回执）。
      onToggleFavorite: () => unawaited(toggleLibraryFavorite(context, track)),
      onAddToPlaylist: () => unawaited(_addTrackToPlaylist(context, track)),
    );
  }

  /// 行尾菜单「加入列表」：与收藏页 / 发现页共用同一流程。
  Future<void> _addTrackToPlaylist(BuildContext context, Track track) async {
    final library = context.read<LibraryProvider?>();
    if (library == null) return;
    await addTracksToLibraryTarget(
      context,
      provider: library,
      tracks: [
        PlaylistTrack.fromTrack(
          track,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ],
    );
  }

  /// 底部加载更多：加载中显示进度圈；失败给重试按钮（不自动重试）。
  Widget _buildLoadMoreFooter(
    BuildContext context,
    AppLocalizations l10n,
    PagedListState<Track> state,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Center(
        child: state.loadMoreFailed
            ? M3EButton.icon(
                style: M3EButtonStyle.outlined,
                onPressed: () => unawaited(_paged.loadMore()),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(l10n.retry),
              )
            : const M3EProgressIndicator.circular(
                size: 28,
                strokeWidth: 2.5,
              ),
      ),
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
              ClipOval(
                child: SizedBox(
                  width: 96,
                  height: 96,
                  child: (avatar?.isNotEmpty ?? false)
                      ? AppNetworkImage(
                          url: avatar,
                          fit: BoxFit.cover,
                          placeholder: ColoredBox(
                            color: theme.colorScheme.surfaceContainerHighest,
                          ),
                          errorWidget: _buildAvatarPlaceholder(theme),
                        )
                      : _buildAvatarPlaceholder(theme),
                ),
              ),
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
                  unawaited(_addToLibrary());
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
