import 'dart:async';
import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/discover.dart';
import '../l10n/app_localizations.dart';
import '../models/play_mode.dart';
import '../providers/discover_provider.dart';
import '../providers/paged_list_controller.dart';
import '../services/haptics.dart';
import '../theme/m3e_context.dart';
import '../utils/responsive.dart';
import '../widgets/app_network_image.dart';
import '../widgets/desktop_layout.dart';
import '../widgets/discover_actions.dart';
import '../widgets/track_row.dart';
import '../widgets/track_table_header.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 详情曲目加载器：按页取（平台不支持分页时忽略 page、一次返回全部，
/// 首末页判定见 [DiscoverTracksPage]）。
typedef DiscoverTracksLoader = Future<DiscoverDetail> Function(int page);

/// 发现详情页（热榜 / 歌单共用）：
/// - 头部：封面、名称、作者 / 播放量 / 曲目数、简介；
/// - 曲目：播放全部 / 单曲播放 / 收藏 / 加入列表。
///
/// 性能：曲目列表懒构建 + 固定行高（`TrackRow.extentOf` + 行距），
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
  /// 最近一次响应的头部信息（由取数回调写入，控制器通知触发重建）。
  DiscoverDetail? _detail;

  /// 分页状态机：首屏 / 加载更多 / 失败 / 在途守卫 / 跨页去重都在控制器内。
  late final PagedListController<DiscoverTrack> _paged;

  /// 曲目区滚动控制器（常显滚动条，支持手拖定位）。
  final ScrollController _listController = ScrollController();

  /// 随机播放起点用（与收藏页同一做法：可见列表内随机取一首起播）。
  final math.Random _shuffleRandom = math.Random();

  @override
  void initState() {
    super.initState();
    _paged = PagedListController<DiscoverTrack>(
      // 平台分页边界会重复返回（忽略 page 时重复整表）：按曲目 key 跨页去重。
      keyOf: (track) => track.key,
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

  /// 取一页曲目。
  ///
  /// 「还有下一页」以平台曲目总数（`info.trackCount`）为准：无总数信息
  /// （榜单 / 部分平台）即单页加载。`loaded` = 本次请求前已累计的条数 +
  /// 本页条数（取数发生在控制器追加之前），达到总数即结束；平台忽略 page
  /// 重复返回整表时，控制器按「本页去重后无新增」兜底停住（防死循环）。
  Future<PagedResult<DiscoverTrack>> _fetchPage(int page) async {
    final detail = await widget.loader(page);
    _detail = detail;
    final total = detail.info.trackCount;
    final loaded = _paged.state.items.length + detail.tracks.length;
    return PagedResult(
      items: detail.tracks,
      hasMore: total > 0 && loaded < total,
      total: total,
    );
  }

  /// 首屏 / 失败重试（在途请求由控制器过期丢弃）。
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

  void _playFrom(int index) {
    final tracks = _paged.state.items;
    if (tracks.isEmpty) return;
    HapticsService.lightImpact();
    final info = _detail?.info;
    context.read<DiscoverProvider>().playTracks(
          tracks,
          index,
          contextName:
              (info != null && info.name.isNotEmpty) ? info.name : widget.title,
        );
  }

  /// 「随机播放全部」：先落 shuffle 模式再装载（洗牌顺序依赖装载前模式），
  /// 起点在已加载曲目内随机；与收藏页 / 歌手页同一约定。
  Future<void> _playShuffled() async {
    final tracks = _paged.state.items;
    if (tracks.isEmpty) return;
    HapticsService.lightImpact();
    final info = _detail?.info;
    await context.read<DiscoverProvider>().playTracks(
          tracks,
          _shuffleRandom.nextInt(tracks.length),
          contextName:
              (info != null && info.name.isNotEmpty) ? info.name : widget.title,
          mode: PlayMode.shuffle,
        );
  }

  /// 把当前歌单导入本地列表（同名列表复用）。
  Future<void> _importPlaylist() async {
    final detail = _detail;
    final tracks = _paged.state.items;
    if (detail == null) return;
    final l10n = _l10n(context);
    if (tracks.isEmpty) {
      M3ESnackbar.show(context, message: l10n.playlistImportEmpty);
      return;
    }
    try {
      final result =
          await context.read<DiscoverProvider>().importDetailToLibrary(
                DiscoverDetail(
                  info: detail.info,
                  tracks: List<DiscoverTrack>.of(tracks),
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
    return ValueListenableBuilder<PagedListState<DiscoverTrack>>(
      valueListenable: _paged,
      // 分页状态是不可变值：整页（含 AppBar 导入动作）按最新快照重建。
      builder: (context, state, _) => Scaffold(
        appBar: M3EAppBar.top(
          title: Text(widget.title, overflow: TextOverflow.ellipsis),
          automaticallyImplyLeading: true,
          actions: [
            if (widget.importable && _detail != null && state.items.isNotEmpty)
              M3EIconButton(
                variant: M3EIconButtonVariant.standard,
                semanticLabel: _l10n(context).playlistImportToMine,
                icon: const Icon(Icons.download_rounded),
                onPressed: _importPlaylist,
              ),
          ],
        ),
        body: _buildBody(context, state),
      ),
    );
  }

  Widget _buildBody(BuildContext context, PagedListState<DiscoverTrack> state) {
    final l10n = _l10n(context);
    if (state.isLoading) {
      return const Center(child: M3ELoadingIndicator());
    }
    final detail = _detail;
    if (state.failed || detail == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.discoverLoadFailed,
              style: context.typeScale.bodyLarge,
            ),
            const SizedBox(height: 12),
            M3EButton.filled(
              onPressed: () => unawaited(_load()),
              child: Text(l10n.discoverRetry),
            ),
          ],
        ),
      );
    }
    final tracks = state.items;
    if (state.isEmpty) {
      return Center(
        child: Text(
          l10n.discoverNoContent,
          style: context.typeScale.bodyMedium.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final cardList = M3ETheme.of(context).listTheme.cardList;
    final horizontalPadding = context.horizontalPadding;
    // 表格列判定用窗口宽 − 实际栏宽（判据唯一在 DesktopLayout）；行高按档
    // 取 M3E 列表 token（表格单行 56 / 非表格双行 72）。
    final tableColumns = DesktopLayout.of(context).tableColumns;
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
              child: _buildHeader(context, detail, tracks.length),
            ),
            // 表头钉在滚动视口顶部（封面头部滚走后列标题仍在），与行内
            // 列同宽同左缘；表面色遮挡滚过其下的行。
            if (tableColumns)
              SliverPersistentHeader(
                pinned: true,
                delegate: _PinnedTableHeaderDelegate(
                  extent: TrackTableHeader.extentOf(context),
                  background: Theme.of(context).colorScheme.surface,
                  horizontalPadding: horizontalPadding,
                ),
              ),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              sliver: SliverFixedExtentList.builder(
                // 行高 + 行距：固定 extent，长歌单滚动条拖动一次定位。
                itemExtent: TrackRow.extentOf(
                      context,
                      tableColumns: tableColumns,
                    ) +
                    cardList.gap,
                itemCount: tracks.length,
                itemBuilder: (context, index) {
                  final isLast = index == tracks.length - 1;
                  final track = tracks[index];
                  return Column(
                    children: [
                      DiscoverTrackTile(
                        track: track,
                        position: calculateCardPosition(index, tracks.length),
                        tableSpec:
                            tableColumns ? TrackRowColumnSpec.standard : null,
                        onTap: () => _playFrom(index),
                      ),
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

  /// 底部加载更多：加载中显示进度圈；失败给重试按钮（不自动重试）。
  Widget _buildLoadMoreFooter(
    BuildContext context,
    AppLocalizations l10n,
    PagedListState<DiscoverTrack> state,
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
    DiscoverDetail detail,
    int loadedCount,
  ) {
    final l10n = _l10n(context);
    final theme = Theme.of(context);
    final info = detail.info;
    final cover = info.coverUrl ?? widget.coverUrl;
    // 分页加载中显示平台总数；无总数（榜单）时退回已加载数量。
    final int trackCount = info.trackCount > 0 ? info.trackCount : loadedCount;
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
          if ((info.description ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              info.description!.trim(),
              style: context.typeScale.bodySmall.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            // 播放全部 = 主操作 + 尾部菜单（随机播放全部）；导入到我的列表
            // 仍在 AppBar 的图标键上，两者不重复。
            child: M3ESplitButton<String>(
              key: const Key('discoverTracksPlayAll'),
              label: l10n.playAll,
              leadingIcon: Icons.play_arrow_rounded,
              style: M3EButtonStyle.filled,
              onPressed: () => _playFrom(0),
              items: [
                M3ESplitButtonItem<String>(
                  value: 'shuffle',
                  child: Text(l10n.playAllShuffled),
                ),
              ],
              onSelected: (value) {
                if (value == 'shuffle') unawaited(_playShuffled());
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 钉住的表格表头（发现详情页）：列标题固定在滚动视口顶部，封面头部滚走
/// 后行内列仍有标题可对照；[ColoredBox] 用页面表面色遮挡滚过其下的行。
///
/// extent 由 [TrackTableHeader.extentOf] 按主题 + 系统文字缩放算出，不写死
/// 行高（大字号下不裁切）。子组件在 [build] 内按可比较的字段构造：
/// widget 实例比较恒不相等，起不到去重作用。
class _PinnedTableHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedTableHeaderDelegate({
    required this.extent,
    required this.background,
    required this.horizontalPadding,
  });

  final double extent;
  final Color background;

  /// 列表横向页边距（与行列表同值）：表头列缘据此与行内列对齐。
  final double horizontalPadding;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) =>
      ColoredBox(
        color: background,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: const TrackTableHeader(),
        ),
      );

  @override
  bool shouldRebuild(covariant _PinnedTableHeaderDelegate oldDelegate) =>
      oldDelegate.extent != extent ||
      oldDelegate.background != background ||
      oldDelegate.horizontalPadding != horizontalPadding;
}
