/// 歌手页：头部（头像 / 名字 / 简介）+「播放全部」+「加入列表」+
/// 曲目列表（`TrackRow`，滚到底加载下一页）。
///
/// 入口：歌曲信息页「歌手」行、搜索结果行内歌手名、搜索「歌手」条目
/// （能力位与 id 判定见 `lib/widgets/track_actions.dart`）。取数与缓存由
/// `ArtistService` 承担，页面只依赖领域 `ArtistDetail` 与注入的取数函数
/// （测试可直接传假 loader）。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../data/catalog/artist_service.dart';
import '../domain/models/artist.dart';
import '../domain/models/failure.dart';
import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import '../providers/paged_list_controller.dart';
import '../providers/playback_provider.dart';
import '../utils/duration_text.dart';
import '../utils/responsive.dart';
import '../widgets/add_to_library.dart';
import '../widgets/app_network_image.dart';
import '../widgets/track_menu_tile.dart';
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
    // 大屏侧边弹层：页面自带 AppBar（含返回），不再叠一层关闭行。
    showCloseButton: false,
    child: ArtistPage(
      fallbackName: fallbackName,
      loader: (page) => service.load(sourceKey, artistId, page: page),
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
    showCloseButton: false,
    child: ArtistPage(
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
    ),
  );
}

/// 单页取数函数（缓存 / 错误边界在 `ArtistService`）。
typedef ArtistPageLoader = Future<ArtistDetail> Function(int page);

@visibleForTesting
class ArtistPage extends StatefulWidget {
  const ArtistPage({super.key, required this.loader, this.fallbackName});

  final ArtistPageLoader loader;

  /// 入口已知的歌手名（加载完成前 / 平台未返回名称时的标题回退）。
  final String? fallbackName;

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  /// 歌手头部数据（随每页响应更新；由取数回调写入，控制器通知触发重建）。
  ArtistDetail? _artist;

  /// 分页状态机：首屏 / 加载更多 / 失败 / 在途守卫 / 跨页去重都在控制器内。
  late final PagedListController<Track> _paged;

  final ScrollController _listController = ScrollController();

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
    HapticFeedback.lightImpact();
    final name = _titleOf(_artist);
    unawaited(
      context.read<PlaybackProvider>().playDomainTracks(
            List<Track>.of(tracks),
            index,
            contextName: name.isEmpty ? null : name,
          ),
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
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.trackInfoArtist),
        automaticallyImplyLeading: true,
      ),
      body: ValueListenableBuilder<PagedListState<Track>>(
        valueListenable: _paged,
        // 分页状态是不可变值：整块 body 按最新快照重建。
        builder: (context, state, _) => _buildBody(context, l10n, state),
      ),
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
              style: Theme.of(context).textTheme.bodyLarge,
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
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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
    final l10n = _l10n(context);
    return _ArtistTrackRow(
      track: track,
      fallbackCoverUrl: artist.avatarUrl,
      position: calculateCardPosition(index, tracks.length),
      onTap: () => _playFrom(index),
      onToggleFavorite: () => unawaited(_toggleFavorite(context, track, l10n)),
      onAddToPlaylist: () => unawaited(_addTrackToPlaylist(context, track)),
    );
  }

  /// 行尾菜单收藏切换：与播放页同一入口（[LibraryProvider.toggleFavoriteTrack]）。
  Future<void> _toggleFavorite(
    BuildContext context,
    Track track,
    AppLocalizations l10n,
  ) async {
    final library = context.read<LibraryProvider?>();
    if (library == null) return;
    final favorite = await library.toggleFavoriteTrack(track);
    if (!context.mounted) return;
    M3ESnackbar.show(
      context,
      message: favorite ? l10n.favoriteAdd : l10n.favoriteRemove,
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
                      style: theme.textTheme.titleLarge,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l10n.artistSongCount(trackCount),
                      style: theme.textTheme.bodySmall?.copyWith(
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
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              M3EButton.icon(
                key: const Key('artistPlayAll'),
                style: M3EButtonStyle.filled,
                onPressed: () => _playFrom(0),
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(l10n.playAll),
              ),
              const SizedBox(width: 12),
              M3EButton.icon(
                key: const Key('artistAddToLibrary'),
                style: M3EButtonStyle.outlined,
                onPressed: () => unawaited(_addToLibrary()),
                icon: const Icon(Icons.playlist_add_rounded),
                label: Text(l10n.addToPlaylist),
              ),
            ],
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

/// 歌手页曲目行：与搜索结果行同款（行尾菜单收藏 / 加入列表）。
///
/// 独立组件而不是在 sliver 的 itemBuilder 里直接 `select`：provider 禁止在
/// SliverList 的 itemBuilder 中 select（会整表重建并触发断言）。
class _ArtistTrackRow extends StatelessWidget {
  const _ArtistTrackRow({
    required this.track,
    required this.fallbackCoverUrl,
    required this.position,
    required this.onTap,
    required this.onToggleFavorite,
    required this.onAddToPlaylist,
  });

  final Track track;
  final String? fallbackCoverUrl;
  final M3ECardPosition position;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final VoidCallback onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    // 只订阅本行的收藏态：长列表不因 provider 任意通知整表重建
    // （可空：页面测试等场景可能不挂 LibraryProvider）。
    final favorite = context.select<LibraryProvider?, bool>(
      (library) => library?.isFavorite(track.id.sourceKey, track.id.id) ?? false,
    );
    return TrackMenuTile(
      title: track.title,
      artist: track.artists
          .map((artist) => artist.name)
          .where((name) => name.isNotEmpty)
          .join(', '),
      coverUrl: track.artwork?.uri.toString() ?? fallbackCoverUrl,
      trailingText: durationText(track.duration?.inMilliseconds),
      position: position,
      onTap: onTap,
      favorite: favorite,
      onToggleFavorite: onToggleFavorite,
      onAddToPlaylist: onAddToPlaylist,
    );
  }
}
