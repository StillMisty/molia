import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/discover.dart';
import '../l10n/app_localizations.dart';
import '../pages/discover_tracks_page.dart';
import '../providers/discover_provider.dart';
import '../services/haptics.dart';
import '../theme/m3e_context.dart';
import 'discover_layout.dart';
import 'empty_state.dart';
import 'm3e_page_route.dart';
import 'scoped_cover_image.dart';
import 'shell_page_visibility.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 资料页「热榜」tab：当前渠道的榜单磁贴（点击进入榜单曲目页）。
///
/// 渠道可能有 30+ 榜单，全部直接铺开——热榜本身就是「挑一个榜看」，折叠
/// 反而多一步；磁贴网格交给 sliver 懒构建，手机 2 列、宽屏按内容宽加列
/// （全宽最多 6 列），没有展开 / 收起入口。磁贴不伪造排名数字：左侧 56dp
/// 榜单封面（平台轻量接口优先，失败用首曲封面 / 平台色占位）+ 榜单名。
class DiscoverLeaderboardsTab extends StatefulWidget {
  const DiscoverLeaderboardsTab({super.key, this.controller});

  /// 内容滚动控制器（宿主页面注入：重复点击底栏资料库时回顶）；
  /// 为空时自建（独立挂载 / 测试）。
  final ScrollController? controller;

  @override
  State<DiscoverLeaderboardsTab> createState() =>
      _DiscoverLeaderboardsTabState();
}

class _DiscoverLeaderboardsTabState extends State<DiscoverLeaderboardsTab>
    with AutomaticKeepAliveClientMixin {
  /// 自带控制器：宿主未注入时使用（随 State 释放）。
  ScrollController? _ownedController;

  ScrollController get _controller =>
      widget.controller ?? (_ownedController ??= ScrollController());

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  void _openBoard(DiscoverLeaderboard board) {
    HapticsService.lightImpact();
    final provider = context.read<DiscoverProvider>();
    final cachedCover = provider.leaderboardCoverOf(board);
    Navigator.of(context).push(
      M3EPageRoute<void>(
        builder: (_) => DiscoverTracksPage(
          title: board.name,
          coverUrl: cachedCover,
          // 磁贴通常已经在按需加载封面：复用同一个 future，头部就绪后更新，
          // 不为了封面阻塞曲目首屏。缓存未命中时这里再发起一次轻量请求。
          coverFuture: cachedCover == null
              ? provider.loadLeaderboardCover(board)
              : null,
          loader: (_) async {
            final tracks = await provider.loadLeaderboardTracks(board.bangid);
            return DiscoverDetail(
              info: DiscoverPlaylist(
                id: board.id,
                name: board.name,
                coverUrl: cachedCover,
              ),
              tracks: tracks,
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 可见性门控：隐藏的常驻 tab 不订阅（见 ShellPageVisibility）。
    final provider = ShellPageVisibility.maybeVisibleOf(context) ?? true
        ? context.watch<DiscoverProvider>()
        : context.read<DiscoverProvider>();
    // 渠道无发现能力时资料页会隐藏本 tab，这里兜底（切换渠道的瞬间）。
    if (!provider.hasDiscoverSource || !provider.supportsLeaderboards) {
      return const SizedBox.shrink();
    }
    final l10n = _l10n(context);
    final boards = provider.leaderboards;

    return LayoutBuilder(
      builder: (context, constraints) {
        final gutter = discoverGutterOf(context);
        final contentWidth = discoverContentWidthOf(
          context,
          constraints.maxWidth,
        );
        final columns = discoverLeaderboardColumns(contentWidth);
        // 可见标题已交给 tab 名，网格仍要有分组语义：读屏进入列表时先读
        // 到「热榜」，否则只剩一串孤立的榜单按钮。
        return Semantics(
          container: true,
          label: l10n.discoverLeaderboards,
          child: Scrollbar(
            controller: _controller,
            thumbVisibility: true,
            interactive: true,
            child: CustomScrollView(
              controller: _controller,
              slivers: [
                if (boards.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        gutter,
                        discoverPageTopPadding + 4,
                        gutter,
                        16,
                      ),
                      child: EmptyState(
                        icon: Icons.leaderboard_rounded,
                        message: l10n.discoverNoContent,
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      gutter,
                      discoverPageTopPadding,
                      gutter,
                      0,
                    ),
                    sliver: SliverGrid.builder(
                      key: const Key('discoverLeaderboardGrid'),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: discoverGridGap,
                        mainAxisSpacing: discoverGridGap,
                        mainAxisExtent: discoverLeaderboardTileExtentOf(
                          context,
                        ),
                      ),
                      itemCount: boards.length,
                      itemBuilder: (context, index) =>
                          _leaderboardTile(context, boards[index]),
                    ),
                  ),
                const SliverToBoxAdapter(
                  child: SizedBox(height: discoverPageBottomPadding),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _leaderboardTile(BuildContext context, DiscoverLeaderboard board) {
    return M3ECard(
      variant: M3ECardVariant.filled,
      onPressed: () => _openBoard(board),
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          _LeaderboardCover(key: ValueKey(board.id), board: board),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              board.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.typeScale.titleSmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// 榜单磁贴封面：平台轻量封面优先，失败 / 缺失时用平台色 + 榜单图标占位。
///
/// 只在磁贴进入 SliverGrid 可见区时发起请求（每个 State 一个 future），
/// 结果由 `DiscoverProvider` 按 board.id 缓存；同一榜单详情页复用缓存。
class _LeaderboardCover extends StatefulWidget {
  const _LeaderboardCover({super.key, required this.board});

  final DiscoverLeaderboard board;

  @override
  State<_LeaderboardCover> createState() => _LeaderboardCoverState();
}

class _LeaderboardCoverState extends State<_LeaderboardCover> {
  late final Future<String?> _cover;

  @override
  void initState() {
    super.initState();
    _cover = context.read<DiscoverProvider>().loadLeaderboardCover(
      widget.board,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 56,
      child: FutureBuilder<String?>(
        future: _cover,
        builder: (context, snapshot) {
          final url = snapshot.data;
          final placeholder = _placeholder(context);
          if (snapshot.connectionState != ConnectionState.done ||
              url == null ||
              url.isEmpty) {
            return placeholder;
          }
          final size = 56.0;
          return ScopedCoverImage(
            url: url,
            width: size,
            height: size,
            fit: BoxFit.cover,
            borderRadius: BorderRadius.circular(10),
            memCacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                .round(),
            placeholder: placeholder,
            errorWidget: placeholder,
          );
        },
      ),
    );
  }

  /// 平台色占位：只使用 ColorScheme 角色（不硬编码平台品牌色）。
  Widget _placeholder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (widget.board.id
        .split('__')
        .first) {
      'wy' => (scheme.primaryContainer, scheme.onPrimaryContainer),
      'tx' => (scheme.secondaryContainer, scheme.onSecondaryContainer),
      'kg' => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      'kw' => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
      'mg' => (scheme.primaryContainer, scheme.onPrimaryContainer),
      'bili' => (scheme.secondaryContainer, scheme.onSecondaryContainer),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: Icon(Icons.leaderboard_rounded, color: foreground, size: 24),
      ),
    );
  }
}
