import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/discover.dart';
import '../l10n/app_localizations.dart';
import '../providers/discover_provider.dart';
import '../utils/responsive.dart';
import '../widgets/app_network_image.dart';
import '../widgets/discover_actions.dart';
import '../widgets/track_row.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 详情曲目加载器：按页取（平台不支持分页时忽略 page、一次返回全部，
/// 首末页判定见 [DiscoverTracksPage]）。
typedef DiscoverTracksLoader = Future<DiscoverDetail> Function(int page);

/// 发现详情页（热榜 / 歌单共用）：
/// - 头部：封面、名称、作者 / 播放量 / 曲目数、简介；
/// - 曲目：播放全部 / 单曲播放 / 收藏 / 加入列表。
///
/// 性能：曲目列表懒构建 + 固定行高（[TrackRow.extent] + 行距），
/// 滚动接近底部时自动加载下一页（无限滚动）；平台忽略分页或已到尾部时
/// 自动停止，失败保留底部重试按钮（不自动重试）。
///
/// [loader] 由入口注入（榜单曲目或歌单详情），页面自管加载态与错误态。
class DiscoverTracksPage extends StatefulWidget {
  final String title;

  /// 打开时已知的封面（歌单卡片点击进入时避免头部闪烁）。
  final String? coverUrl;

  final DiscoverTracksLoader loader;

  /// 是否提供「导入到我的列表」（歌单支持；榜单不提供）。
  final bool importable;

  const DiscoverTracksPage({
    super.key,
    required this.title,
    required this.loader,
    this.coverUrl,
    this.importable = false,
  });

  @override
  State<DiscoverTracksPage> createState() => _DiscoverTracksPageState();
}

class _DiscoverTracksPageState extends State<DiscoverTracksPage> {
  DiscoverDetail? _detail;

  /// 已加载曲目（分页追加；去重后按平台原始顺序）。
  final List<DiscoverTrack> _tracks = <DiscoverTrack>[];

  /// 已加载的页数（0 = 尚未加载成功）。
  int _page = 0;

  bool _loading = true;
  bool _failed = false;
  bool _loadingMore = false;
  bool _loadMoreFailed = false;
  bool _hasMore = false;

  /// 曲目区滚动控制器（常显滚动条，支持手拖定位）。
  final ScrollController _listController = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
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
      final detail = await widget.loader(1);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _tracks
          ..clear()
          ..addAll(detail.tracks);
        _page = 1;
        _loading = false;
        _hasMore = _hasMoreAfter(_tracks.length);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  /// 是否可能还有下一页：以平台曲目总数（`info.trackCount`）为准。
  /// 无总数信息（榜单 / 部分平台）或已取满即结束。
  bool _hasMoreAfter(int loaded) {
    final int total = _detail?.info.trackCount ?? 0;
    if (total <= 0) return false;
    return loaded < total;
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
      final known = <String>{for (final track in _tracks) track.key};
      final added = <DiscoverTrack>[
        for (final track in next.tracks)
          if (known.add(track.key)) track,
      ];
      setState(() {
        _page += 1;
        _tracks.addAll(added);
        _loadingMore = false;
        _hasMore = added.isNotEmpty && _hasMoreAfter(_tracks.length);
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

  void _playFrom(int index) {
    if (_tracks.isEmpty) return;
    HapticFeedback.lightImpact();
    final info = _detail?.info;
    context.read<DiscoverProvider>().playTracks(
          _tracks,
          index,
          contextName: (info != null && info.name.isNotEmpty)
              ? info.name
              : widget.title,
        );
  }

  /// 把当前歌单导入本地列表（同名列表复用）。
  Future<void> _importPlaylist() async {
    final detail = _detail;
    if (detail == null) return;
    final l10n = _l10n(context);
    if (_tracks.isEmpty) {
      M3ESnackbar.show(context, message: l10n.playlistImportEmpty);
      return;
    }
    try {
      final result = await context.read<DiscoverProvider>().importDetailToLibrary(
            DiscoverDetail(
              info: detail.info,
              tracks: List<DiscoverTrack>.of(_tracks),
            ),
            fallbackName: widget.title,
          );
      if (!mounted) return;
      M3ESnackbar.show(
        context,
        message: result.added > 0
            ? l10n.libraryImportSuccess(result.added)
            : l10n.playlistAlreadyContains,
      );
    } catch (_) {
      if (!mounted) return;
      M3ESnackbar.show(context, message: l10n.discoverLoadFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        automaticallyImplyLeading: true,
        actions: [
          if (widget.importable && detail != null && _tracks.isNotEmpty)
            M3EIconButton(
              variant: M3EIconButtonVariant.standard,
              tooltip: _l10n(context).playlistImportToMine,
              icon: const Icon(Icons.download_rounded),
              onPressed: _importPlaylist,
            ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final l10n = _l10n(context);
    if (_loading) {
      return const Center(child: M3ELoadingIndicator());
    }
    final detail = _detail;
    if (_failed || detail == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.discoverLoadFailed,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 12),
            M3EButton.filled(
              onPressed: _load,
              child: Text(l10n.discoverRetry),
            ),
          ],
        ),
      );
    }
    if (_tracks.isEmpty) {
      return Center(
        child: Text(
          l10n.discoverNoContent,
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
            SliverToBoxAdapter(child: _buildHeader(context, detail)),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              sliver: SliverFixedExtentList.builder(
                // 行高 + 行距：固定 extent，长歌单滚动条拖动一次定位。
                itemExtent: TrackRow.extent + cardList.gap,
                itemCount: _tracks.length,
                itemBuilder: (context, index) {
                  final isLast = index == _tracks.length - 1;
                  return Column(
                    children: [
                      DiscoverTrackTile(
                        track: _tracks[index],
                        position: calculateCardPosition(index, _tracks.length),
                        onTap: () => _playFrom(index),
                      ),
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

  Widget _buildHeader(BuildContext context, DiscoverDetail detail) {
    final l10n = _l10n(context);
    final theme = Theme.of(context);
    final info = detail.info;
    final cover = info.coverUrl ?? widget.coverUrl;
    // 分页加载中显示平台总数；无总数（榜单）时退回已加载数量。
    final int trackCount = info.trackCount > 0 ? info.trackCount : _tracks.length;
    final subtitleParts = <String>[
      if (info.author.isNotEmpty) l10n.discoverPlaylistAuthor(info.author),
      if (info.playCount > 0) l10n.discoverPlayCount(info.playCountText),
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
                              Icons.queue_music_rounded,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ColoredBox(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.queue_music_rounded,
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
                      info.name.isEmpty ? widget.title : info.name,
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
          if ((info.description ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              info.description!.trim(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: M3EButton.icon(
              style: M3EButtonStyle.filled,
              onPressed: () => _playFrom(0),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(l10n.playAll),
            ),
          ),
        ],
      ),
    );
  }
}
