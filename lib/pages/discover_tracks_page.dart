import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/discover.dart';
import '../l10n/app_localizations.dart';
import '../providers/discover_provider.dart';
import '../providers/paged_list_controller.dart';
import '../services/haptics.dart';
import '../theme/m3e_context.dart';
import '../widgets/app_network_image.dart';
import '../widgets/cover_tap_target.dart';
import '../widgets/cover_viewer.dart';
import '../widgets/desktop_layout.dart';
import '../widgets/discover_actions.dart';
import '../widgets/paged_track_collection.dart';
import '../widgets/track_handoff.dart';
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
  /// 分页集合：首屏 / 加载更多 / 失败 / 在途守卫 / 跨页去重 / 页实体都在
  /// 控制器内。
  late final PagedTrackCollection<DiscoverDetail, DiscoverTrack> _collection;

  /// 播放 / 加入列表的唯一编排（洗牌、上下文名、触感都在模块内）。
  final TrackHandoff _handoff = const TrackHandoff();

  @override
  void initState() {
    super.initState();
    _collection = PagedTrackCollection<DiscoverDetail, DiscoverTrack>(
      // 平台分页边界会重复返回（忽略 page 时重复整表）：按曲目 key 跨页去重。
      keyOf: (track) => track.key,
      loadPage: _fetchPage,
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _collection.dispose();
    super.dispose();
  }

  /// 取一页曲目。
  ///
  /// 「还有下一页」以平台曲目总数（`info.trackCount`）为准：无总数信息
  /// （榜单 / 部分平台）即单页加载。`loaded` = 本次请求前已累计的条数 +
  /// 本页条数（取数发生在控制器追加之前），达到总数即结束；平台忽略 page
  /// 重复返回整表时，控制器按「本页去重后无新增」兜底停住（防死循环）。
  Future<PagedTrackPage<DiscoverDetail, DiscoverTrack>> _fetchPage(
    int page,
  ) async {
    final detail = await widget.loader(page);
    final total = detail.info.trackCount;
    final loaded = _collection.items.length + detail.tracks.length;
    return PagedTrackPage(
      entity: detail,
      items: detail.tracks,
      hasMore: total > 0 && loaded < total,
      total: total,
    );
  }

  /// 首屏 / 失败重试（在途请求由控制器过期丢弃）。
  Future<void> _load() => _collection.loadFirstPage();

  /// 播放（[index] 为起始下标；上下文名先取歌单名，缺失回退入口标题）。
  void _playFrom(int index) {
    final tracks = _collection.items;
    if (tracks.isEmpty) return;
    unawaited(
      _handoff.play(
        context,
        context.read<DiscoverProvider>().domainTracksOf(tracks),
        startIndex: index,
        contextName: _collection.entity?.info.name,
        fallbackContextName: widget.title,
      ),
    );
  }

  /// 「随机播放全部」：先落 shuffle 模式再装载（洗牌顺序依赖装载前模式），
  /// 起点在已加载曲目内随机；与收藏页 / 歌手页同一约定。
  Future<void> _playShuffled() {
    final tracks = _collection.items;
    if (tracks.isEmpty) return Future.value();
    return _handoff.play(
      context,
      context.read<DiscoverProvider>().domainTracksOf(tracks),
      shuffle: true,
      contextName: _collection.entity?.info.name,
      fallbackContextName: widget.title,
    );
  }

  /// 把当前歌单导入本地列表（同名列表复用）。
  Future<void> _importPlaylist() async {
    final detail = _collection.entity;
    final tracks = _collection.items;
    if (detail == null) return;
    final l10n = _l10n(context);
    if (tracks.isEmpty) {
      M3ESnackbar.show(context, message: l10n.playlistImportEmpty);
      return;
    }
    try {
      final result = await context
          .read<DiscoverProvider>()
          .importDetailToLibrary(
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
      valueListenable: _collection,
      // 分页状态是不可变值：整页（含 AppBar 导入动作）按最新快照重建。
      builder: (context, state, _) => Scaffold(
        appBar: M3EAppBar.top(
          title: Text(widget.title, overflow: TextOverflow.ellipsis),
          automaticallyImplyLeading: true,
          actions: [
            if (widget.importable &&
                _collection.entity != null &&
                state.items.isNotEmpty)
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
    // 表格列判定用窗口宽 − 实际栏宽（判据唯一在 DesktopLayout）；行高按档
    // 取 M3E 列表 token（表格单行 56 / 非表格双行 72），与共享正文同源。
    final tableColumns = DesktopLayout.of(context).tableColumns;
    return PagedTrackCollectionBody<DiscoverTrack>(
      state: state,
      tableColumns: tableColumns,
      // 表头钉在滚动视口顶部（封面头部滚走后列标题仍在）。
      pinnedTableHeader: true,
      headerBuilder: (context, state) {
        final detail = _collection.entity;
        // 列表态必有实体（与曲目同一响应写入）；空值只为类型收窄。
        if (detail == null) return const SizedBox.shrink();
        return _buildHeader(context, detail, state.items.length);
      },
      rowBuilder: (context, index, count, columns) {
        final track = _collection.items[index];
        return DiscoverTrackTile(
          track: track,
          position: calculateCardPosition(index, count),
          tableSpec: columns ? TrackRowColumnSpec.standard : null,
          onTap: () => _playFrom(index),
        );
      },
      onRetry: () => unawaited(_load()),
      onLoadMore: () => unawaited(_collection.loadMore()),
      emptyText: l10n.discoverNoContent,
      failureText: l10n.discoverLoadFailed,
      retryText: l10n.discoverRetry,
    );
  }

  /// 头部封面：方形裁切；有图时点击看原图 / 保存原图。
  Widget _buildHeaderCover(
    BuildContext context,
    AppLocalizations l10n,
    DiscoverPlaylist info,
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
                // 头部只有 96dp：按容器解码封面，避免按原图尺寸解码。
                memCacheWidth:
                    (96 * MediaQuery.of(context).devicePixelRatio).round(),
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
    );
    if (cover == null || cover.isEmpty) return image;
    final name = info.name.isEmpty ? widget.title : info.name;
    return CoverTapTarget(
      key: const Key('discoverHeaderCover'),
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
            subtitle: name,
            fileNameBase: name,
          ),
        );
      },
      child: image,
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
              _buildHeaderCover(context, l10n, info, cover, theme),
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
