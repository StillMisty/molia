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
import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import '../providers/playback_provider.dart';
import '../utils/duration_text.dart';
import '../utils/responsive.dart';
import '../widgets/add_to_library.dart';
import '../widgets/app_network_image.dart';
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
  ArtistDetail? _artist;

  /// 已加载曲目（分页追加；去重后按平台原始顺序）。
  final List<Track> _tracks = <Track>[];

  /// 已加载的页数（0 = 尚未加载成功）。
  int _page = 0;

  bool _loading = true;
  bool _failed = false;
  bool _loadingMore = false;
  bool _loadMoreFailed = false;
  bool _hasMore = false;

  final ScrollController _listController = ScrollController();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _listController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final artist = await widget.loader(1);
      if (!mounted) return;
      setState(() {
        _artist = artist;
        _tracks
          ..clear()
          ..addAll(artist.tracks);
        _page = 1;
        _loading = false;
        _hasMore = artist.hasMore;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

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
    if (_loading || _loadingMore || _loadMoreFailed || !_hasMore) return;
    unawaited(_loadMore());
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() {
      _loadingMore = true;
      _loadMoreFailed = false;
    });
    try {
      final next = await widget.loader(_page + 1);
      if (!mounted) return;
      // 去重后追加：平台忽略 page 时会重复返回整表，靠「无新增即结束」防死循环。
      final known = <String>{for (final track in _tracks) track.id.uri};
      final added = <Track>[
        for (final track in next.tracks)
          if (known.add(track.id.uri)) track,
      ];
      setState(() {
        _page += 1;
        _tracks.addAll(added);
        _loadingMore = false;
        _hasMore = next.hasMore && added.isNotEmpty;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _loadMoreFailed = true;
      });
    }
  }

  void _retryLoadMore() {
    setState(() => _loadMoreFailed = false);
    unawaited(_loadMore());
  }

  /// 播放（[index] 为起始下标；队列上下文名为歌手名）。
  void _playFrom(int index) {
    if (_tracks.isEmpty) return;
    HapticFeedback.lightImpact();
    final name = _titleOf(_artist);
    unawaited(
      context.read<PlaybackProvider>().playDomainTracks(
            List<Track>.of(_tracks),
            index,
            contextName: name.isEmpty ? null : name,
          ),
    );
  }

  /// 「加入列表」：与收藏页 / 发现页共用同一流程（选择目标 → 写入 → 提示）。
  Future<void> _addToLibrary() async {
    if (_tracks.isEmpty) return;
    final library = context.read<LibraryProvider>();
    final addedAt = DateTime.now().millisecondsSinceEpoch;
    await addTracksToLibraryTarget(
      context,
      provider: library,
      tracks: [
        for (final track in _tracks)
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
      body: _buildBody(context, l10n),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    if (_loading) {
      return const Center(child: M3ELoadingIndicator());
    }
    final artist = _artist;
    if (_failed || artist == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.artistLoadFailed,
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
    if (_tracks.isEmpty) {
      return Center(
        child: Text(
          l10n.artistEmpty,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }

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
            SliverToBoxAdapter(child: _buildHeader(context, l10n, artist)),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              sliver: SliverFixedExtentList.builder(
                // 行高 + 行距：固定 extent，长列表滚动条拖动一次定位。
                itemExtent: TrackRow.extent + cardList.gap,
                itemCount: _tracks.length,
                itemBuilder: (context, index) {
                  final isLast = index == _tracks.length - 1;
                  return Column(
                    children: [
                      _buildTrackRow(context, index, artist),
                      if (!isLast) SizedBox(height: cardList.gap),
                    ],
                  );
                },
              ),
            ),
            if (_loadingMore || _loadMoreFailed)
              SliverToBoxAdapter(child: _buildLoadMoreFooter(context, l10n)),
            const SliverToBoxAdapter(child: SizedBox(height: 16)),
          ],
        ),
      ),
    );
  }

  Widget _buildTrackRow(BuildContext context, int index, ArtistDetail artist) {
    final track = _tracks[index];
    return TrackRow(
      title: track.title,
      artist: track.artists
          .map((item) => item.name)
          .where((name) => name.isNotEmpty)
          .join(', '),
      coverUrl: track.artwork?.uri.toString() ?? artist.avatarUrl,
      trailingText: durationText(track.duration?.inMilliseconds),
      position: calculateCardPosition(index, _tracks.length),
      onTap: () => _playFrom(index),
    );
  }

  /// 底部加载更多：加载中显示进度圈；失败给重试按钮（不自动重试）。
  Widget _buildLoadMoreFooter(BuildContext context, AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Center(
        child: _loadMoreFailed
            ? M3EButton.icon(
                style: M3EButtonStyle.outlined,
                onPressed: _retryLoadMore,
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
      BuildContext context, AppLocalizations l10n, ArtistDetail artist) {
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
                      l10n.artistSongCount(_tracks.length),
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
