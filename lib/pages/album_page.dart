/// 专辑页：头部（封面 / 专辑名 / 歌手 / 年份）+ 「播放全部」+「加入列表」+
/// 曲目列表（`TrackRow`，滚到底加载下一页）。
///
/// 入口：歌曲信息页「专辑」行（payload 专辑 id + 渠道能力位判定，见
/// `lib/widgets/track_actions.dart`）。取数与缓存由 `AlbumService` 承担，
/// 页面只依赖领域 `Album` 与注入的取数函数（测试可直接传假 loader）。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../data/catalog/album_service.dart';
import '../domain/models/album.dart';
import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import '../providers/playback_provider.dart';
import '../utils/responsive.dart';
import '../widgets/add_to_library.dart';
import '../widgets/app_network_image.dart';
import '../widgets/track_row.dart';

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
    // 大屏侧边弹层：页面自带 AppBar（含返回），不再叠一层关闭行。
    showCloseButton: false,
    child: AlbumPage(
      fallbackName: fallbackName,
      loader: (page) => service.load(sourceKey, albumId, page: page),
    ),
  );
}

/// 单页取数函数（缓存 / 错误边界在 `AlbumService`）。
typedef AlbumPageLoader = Future<Album> Function(int page);

@visibleForTesting
class AlbumPage extends StatefulWidget {
  const AlbumPage({super.key, required this.loader, this.fallbackName});

  final AlbumPageLoader loader;

  /// 入口已知的专辑名（加载完成前 / 平台未返回名称时的标题回退）。
  final String? fallbackName;

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  Album? _album;

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
      final album = await widget.loader(1);
      if (!mounted) return;
      setState(() {
        _album = album;
        _tracks
          ..clear()
          ..addAll(album.tracks);
        _page = 1;
        _loading = false;
        _hasMore = album.hasMore;
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

  /// 播放（[index] 为起始下标；队列上下文名为专辑名）。
  void _playFrom(int index) {
    if (_tracks.isEmpty) return;
    HapticFeedback.lightImpact();
    final name = _titleOf(_album);
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

  String _titleOf(Album? album) {
    final name = album?.name.trim() ?? '';
    if (name.isNotEmpty) return name;
    return widget.fallbackName ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.trackInfoAlbum),
        automaticallyImplyLeading: true,
      ),
      body: _buildBody(context, l10n),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    if (_loading) {
      return const Center(child: M3ELoadingIndicator());
    }
    final album = _album;
    if (_failed || album == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.albumLoadFailed,
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
          l10n.albumEmpty,
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
            SliverToBoxAdapter(child: _buildHeader(context, l10n, album)),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              sliver: SliverFixedExtentList.builder(
                // 行高 + 行距：固定 extent，长专辑滚动条拖动一次定位。
                itemExtent: TrackRow.extent + cardList.gap,
                itemCount: _tracks.length,
                itemBuilder: (context, index) {
                  final isLast = index == _tracks.length - 1;
                  return Column(
                    children: [
                      _buildTrackRow(context, index, album),
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

  Widget _buildTrackRow(BuildContext context, int index, Album album) {
    final track = _tracks[index];
    final cover = track.artwork?.uri.toString() ?? album.coverUrl;
    return TrackRow(
      title: track.title,
      artist: track.artists
          .map((artist) => artist.name)
          .where((name) => name.isNotEmpty)
          .join(', '),
      coverUrl: cover,
      trailingText: _formatDuration(track.duration),
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

  Widget _buildHeader(BuildContext context, AppLocalizations l10n, Album album) {
    final theme = Theme.of(context);
    final cover = album.coverUrl;
    final subtitleParts = <String>[
      if (album.artist.isNotEmpty) album.artist,
      if (album.year != null) l10n.albumYear(album.year!),
      l10n.playlistTrackCount(_tracks.length),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
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
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _titleOf(album),
                      style: theme.textTheme.titleLarge,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitleParts.join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              M3EButton.icon(
                key: const Key('albumPlayAll'),
                style: M3EButtonStyle.filled,
                onPressed: () => _playFrom(0),
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(l10n.playAll),
              ),
              const SizedBox(width: 12),
              M3EButton.icon(
                key: const Key('albumAddToLibrary'),
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

  static String _formatDuration(Duration? duration) {
    if (duration == null || duration <= Duration.zero) return '--:--';
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
