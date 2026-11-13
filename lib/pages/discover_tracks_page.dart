import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/discover.dart';
import '../l10n/app_localizations.dart';
import '../providers/discover_provider.dart';
import '../providers/paged_list_controller.dart';
import '../widgets/desktop_layout.dart';
import '../widgets/detail_page/detail_cover_header.dart';
import '../widgets/discover_actions.dart';
import '../widgets/discover_tracks_skeleton.dart';
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

  /// 打开后才解析出的封面（榜单磁贴的按需封面）：不阻塞曲目首屏，
  /// 完成后再更新头部；失败 / 为空保持 [coverUrl] 或 fallback 图标。
  final Future<String?>? coverFuture;

  /// 与来源卡片一致的封面共享元素标签（歌单卡片 / 榜单磁贴生成）。
  ///
  /// 链接打开的详情没有来源端，保持 null 不参与 Hero。
  final Object? coverHeroTag;

  final DiscoverTracksLoader loader;

  /// 是否提供「导入到我的列表」（歌单支持；榜单不提供）。
  final bool importable;

  const DiscoverTracksPage({
    super.key,
    required this.title,
    required this.loader,
    this.coverUrl,
    this.coverFuture,
    this.coverHeroTag,
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
                key: const Key('discoverImportPlaylistButton'),
                variant: M3EIconButtonVariant.standard,
                semanticLabel: _l10n(context).playlistImportToMine,
                icon: const Icon(Icons.playlist_add_rounded),
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
      emptyIcon: Icons.playlist_play_rounded,
      failureText: l10n.discoverLoadFailed,
      retryText: l10n.discoverRetry,
      loadingBuilder: (context) => DiscoverTracksSkeleton(
        title: widget.title,
        tableColumns: tableColumns,
        coverUrl: widget.coverUrl,
        coverFuture: widget.coverFuture,
        coverHeroTag: widget.coverHeroTag,
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    DiscoverDetail detail,
    int loadedCount,
  ) {
    final l10n = _l10n(context);
    final info = detail.info;
    final fallbackCover = info.coverUrl ?? widget.coverUrl;
    // 分页加载中显示平台总数；无总数（榜单）时退回已加载数量。
    final int trackCount = info.trackCount > 0 ? info.trackCount : loadedCount;
    final subtitleParts = <String>[
      if (info.author.isNotEmpty) l10n.discoverPlaylistAuthor(info.author),
      if (info.playCount > 0) l10n.discoverPlayCount(info.playCountText),
      l10n.playlistTrackCount(trackCount),
    ];
    final description = (info.description ?? '').trim();

    Widget header(String? cover) => DetailCoverHeader(
      coverKey: const Key('discoverHeaderCover'),
      coverUrl: cover,
      shape: DetailCoverShape.square,
      fallbackIcon: Icons.queue_music_rounded,
      title: info.name.isEmpty ? widget.title : info.name,
      subtitle: subtitleParts.join(' · '),
      description: description.isEmpty ? null : description,
      // 查看器副标题 / 保存基名就是页标题（平台名缺失时已回退入口标题）。
      action: DetailPlayAllSplitButton(
        key: const Key('discoverTracksPlayAll'),
        onPlay: () => _playFrom(0),
        onShuffle: () => unawaited(_playShuffled()),
        // 导入到我的列表仍在 AppBar 的图标键上，头部不重复提供。
      ),
      heroTag: widget.coverHeroTag,
    );

    final coverFuture = widget.coverFuture;
    if (coverFuture == null) return header(fallbackCover);
    return FutureBuilder<String?>(
      future: coverFuture,
      initialData: fallbackCover,
      builder: (context, snapshot) => header(snapshot.data ?? fallbackCover),
    );
  }
}
