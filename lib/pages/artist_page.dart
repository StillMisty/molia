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
import '../utils/responsive.dart';
import '../widgets/detail_page/detail_cover_header.dart';
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
      emptyIcon: Icons.person_rounded,
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

  Widget _buildHeader(
    BuildContext context,
    AppLocalizations l10n,
    ArtistDetail artist,
    int trackCount,
  ) {
    final description = artist.description.trim();
    return DetailCoverHeader(
      coverKey: const Key('artistHeaderAvatar'),
      coverUrl: artist.avatarUrl,
      shape: DetailCoverShape.circle,
      fallbackIcon: Icons.person_rounded,
      title: _titleOf(artist),
      subtitle: l10n.artistSongCount(trackCount),
      description: description.isEmpty ? null : description,
      viewerSubtitle: artist.name,
      viewerFileNameBase: artist.name,
      action: DetailPlayAllSplitButton(
        key: const Key('artistPlayAll'),
        onPlay: () => _playFrom(0),
        onShuffle: () => unawaited(_playShuffled()),
        onAddToLibrary: () =>
            unawaited(_handoff.addToLibrary(context, _collection.items)),
      ),
    );
  }
}
