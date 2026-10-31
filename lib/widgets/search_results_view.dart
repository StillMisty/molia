import 'dart:async';
import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/artist.dart';
import '../domain/models/catalog.dart' show SearchKind;
import '../l10n/app_localizations.dart';
import '../providers/search_provider.dart';
import '../services/haptics.dart';
import '../theme/m3e_context.dart';
import '../utils/responsive.dart';
import 'artist_row.dart';
import 'desktop_layout.dart';
import 'paged_list_auto_load.dart';
import 'row_actions.dart';
import 'track_menu_tile.dart';
import 'track_row.dart';
import 'track_table_header.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本组件而不注册 delegate，
/// 此时回退到简体中文，保证与中文正式环境文案一致（正式 App 恒有 delegate）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 搜索结果面的两种宿主形态。
enum SearchResultsVariant {
  /// 资料库搜索结果页：分段 + 表头 + sliver 列表 + 触底分页。
  page,

  /// 桌面全局搜索遮罩：限高面板 + 预览行 + 「查看全部结果」出口。
  docked,
}

/// 打开歌手的页面级动作（导航归宿主：本模块不 import 页面）。
///
/// 参数与 `showArtistPage` 同序，宿主直接转交即可；`fallbackName` 用于
/// 歌手详情尚未返回时的标题。
typedef OpenSearchArtist = Future<void> Function(
  String sourceKey,
  String artistId, {
  String? fallbackName,
});

/// 搜索结果面：单曲 / 歌手 / 歌词三类结果在一个模块里完成映射与状态呈现。
///
/// 为什么收成一个模块：资料库搜索结果页与桌面全局搜索遮罩展示的是同一份
/// [SearchProvider] 状态、同一套 [SearchRow] → [TrackRowModel] 映射。两份实现
/// 曾各自维护分段 / 失败 / 空态，并已出现漂移（遮罩行没有操作菜单、歌手名
/// 没有「未知歌手」兜底）。现在两种版式只差「列表怎么滚动」与「结果交给谁」：
/// 宿主只传 [variant] 与导航回调，行映射、状态文案、能力位判据都留在这里。
///
/// 版式差异：
/// - [SearchResultsVariant.page]：整块是 `Column`（分段 / 表头 / 滚动列表），
///   宽屏表格与触底分页只在单曲段启用；
/// - [SearchResultsVariant.docked]：自绘面板 chrome，最多预览
///   [maxDockedPreviewRows] 行，不分页，底部固定「查看全部结果」出口。
///
/// 两种版式共用行级交互：点击触感、收藏 / 加入列表菜单（触摸端行尾 ⋮、
/// 桌面端行表面右键）。歌手链接只在页面版式提供：遮罩里行内再开一个二级页
/// 会与遮罩路由的关闭顺序打架（页面版式直接进歌手页）。
class SearchResultsView extends StatefulWidget {
  const SearchResultsView({
    super.key,
    required this.variant,
    required this.onPlay,
    this.onOpenArtist,
    this.onOpenAllResults,
    this.controller,
  }) : assert(
         variant != SearchResultsVariant.page || onOpenArtist != null,
         '页面版式需要 onOpenArtist（歌手行与行内歌手链接的导航出口）',
       ),
       assert(
         variant != SearchResultsVariant.docked || onOpenAllResults != null,
         '遮罩版式需要 onOpenAllResults（面板底部的完整结果出口）',
       );

  /// 遮罩就地预览的最大行数：更长的列表交给「查看全部结果」后的资料库
  /// 目的地（面板不是全量结果页，堆太多行会把出口挤出视野）。
  static const int maxDockedPreviewRows = 8;

  final SearchResultsVariant variant;

  /// 单曲 / 歌词行点击：播放语义归宿主（搜索结果整体进队列、从该行开始）。
  final void Function(SearchRow row) onPlay;

  /// 页面版式的歌手导航（歌手行与行内歌手链接共用）。
  final OpenSearchArtist? onOpenArtist;

  /// 遮罩版式的「查看全部结果」：宿主负责先关遮罩再切目的地。
  final VoidCallback? onOpenAllResults;

  /// 页面版式的滚动控制器（宿主注入：底栏重复点击回顶）；为空时自建。
  final ScrollController? controller;

  @override
  State<SearchResultsView> createState() => _SearchResultsViewState();
}

class _SearchResultsViewState extends State<SearchResultsView> {
  /// 宿主未注入时自建（独立挂载 / 测试），随 State 释放。
  ScrollController? _ownedController;

  ScrollController get _pageController =>
      widget.controller ?? (_ownedController ??= ScrollController());

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final search = context.watch<SearchProvider>();
    return switch (widget.variant) {
      SearchResultsVariant.page => _buildPage(context, search),
      SearchResultsVariant.docked =>
        search.isSearchActive
            ? _buildDocked(context, search)
            // 无关键词：结果面留空（只留搜索条）——打开遮罩就是为了输入，
            // 一行「输入关键词搜索歌曲」的引导是多余的。
            : const SizedBox.shrink(),
    };
  }

  // ---------------------------------------------------------------------------
  // 页面版式（资料库搜索结果页）
  // ---------------------------------------------------------------------------

  Widget _buildPage(BuildContext context, SearchProvider search) {
    final l10n = _l10n(context);
    // 表格列的判定用窗口宽 − 实际栏宽（判据唯一在 DesktopLayout）：
    // 不随页面结构（页内栏 / 面板）漂移。
    final layout = DesktopLayout.of(context);
    final horizontalPadding = context
        .layoutType(ResponsivePageType.browse)
        .horizontalPadding;
    final results = search.filteredResults;
    final artistResults = search.artistResults;
    final lyricResults = search.lyricResults;
    final kind = search.searchKind;
    final isArtistKind = kind == SearchKind.artist;
    final isLyricKind = kind == SearchKind.lyric;
    final itemCount = isArtistKind
        ? artistResults.length
        : isLyricKind
        ? lyricResults.length
        : results.length;
    final failure = search.failure;
    final kinds = search.supportedSearchKinds;
    // 宽屏表格列只在单曲段生效：歌手 / 歌词段的行结构不同（头像行 /
    // 歌词片段副标题），不给它们套表格。
    final tableColumns = kind == SearchKind.song && layout.tableColumns;
    final controller = _pageController;

    return Column(
      children: [
        // 结果页顶部无独立栏（搜索框自身即状态），只留少量间距。
        const SizedBox(height: 8),

        // 类型分段：仅在有多个可选类型且搜索已激活时显示。
        if (search.isSearchActive && kinds.length > 1)
          Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              0,
              horizontalPadding,
              8,
            ),
            child: _kindSwitch(l10n, search, kinds),
          ),

        if (search.isSearching)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: M3EProgressIndicator.linear(),
          ),

        // 有结果时的加载更多失败只停底部；没有结果才占顶部错误条。
        if (failure != null && itemCount == 0)
          _failure(context, l10n, search, compact: false),

        // 表格列表头固定在滚动区之上：列标题不随结果滚走，列与行内
        // 列同宽同左缘（TrackTableHeader 内部复刻行的留白结构）。
        if (tableColumns && itemCount > 0)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            child: const TrackTableHeader(),
          ),

        Expanded(
          child: Scrollbar(
            controller: controller,
            thumbVisibility: true,
            interactive: true,
            child: PagedListAutoLoad(
              hasMore: search.hasMore,
              // 首屏失败：顶部错误条负责恢复；加载更多失败只停底部。
              failed: failure != null && itemCount == 0,
              isLoadingMore: search.isLoadingMore,
              loadMoreFailed: search.loadMoreFailed,
              onLoadMore: search.loadMore,
              child: CustomScrollView(
                controller: controller,
                slivers: [
                  if (itemCount == 0 && !search.isSearching && failure == null)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _pageEmptyView(l10n, search),
                    )
                  else if (isArtistKind)
                    SliverPadding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalPadding,
                      ),
                      sliver: _ArtistResultsSliver(
                        items: artistResults,
                        onTap: (artist) => unawaited(
                          widget.onOpenArtist!(
                            search.sourceKey,
                            artist.id,
                            fallbackName: artist.name,
                          ),
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalPadding,
                      ),
                      sliver: _TrackResultsSliver(
                        // 歌词类型：行的 [SearchRow.lyricSnippet] 做副标题。
                        items: isLyricKind ? lyricResults : results,
                        onPlay: widget.onPlay,
                        onOpenArtist: widget.onOpenArtist,
                        // 歌手链接能力位来自 SearchProvider 的同一份分段
                        // 判据（渠道是否有歌手能力）；脚本源保持纯文本。
                        artistLinksEnabled: kinds.contains(SearchKind.artist),
                        surface: TrackRowSurface(
                          tableSpec: tableColumns
                              ? TrackRowColumnSpec.standard
                              : null,
                        ),
                      ),
                    ),

                  // 触底自动取下一页；页脚只承担加载中 / 失败重试。
                  if (itemCount > 0 &&
                      search.hasSelectedSource &&
                      (search.isLoadingMore || search.loadMoreFailed))
                    SliverToBoxAdapter(
                      child: PagedListFooter(
                        isLoadingMore: search.isLoadingMore,
                        loadMoreFailed: search.loadMoreFailed,
                        onRetry: search.loadMore,
                        failureLabel: l10n.searchLoadMoreFailed,
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 空状态区分：未选择/无可用音源，与「已选音源但无结果」（展示音源名）。
  Widget _pageEmptyView(AppLocalizations l10n, SearchProvider search) {
    final theme = Theme.of(context);
    final selectedSourceName = _selectedSourceName(search);
    final hasSelectedSource = selectedSourceName != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasSelectedSource
                  ? Icons.search_off_rounded
                  : Icons.source_rounded,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              hasSelectedSource
                  ? l10n.noResultsFound
                  : l10n.searchNoSourcesTitle,
              style: context.typeScale.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              selectedSourceName != null
                  ? l10n.searchNoResultsInSource(selectedSourceName)
                  : l10n.searchNoSourcesHint,
              textAlign: TextAlign.center,
              style: context.typeScale.bodyMedium.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 当前选中音源的显示名；选中的 key 不在可选列表中（未选择/已失效）时
  /// 为 null。
  String? _selectedSourceName(SearchProvider search) {
    for (final option in search.sourceChannels) {
      if (option.key == search.sourceKey) return option.displayName;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 遮罩版式（桌面全局搜索）
  // ---------------------------------------------------------------------------

  Widget _buildDocked(BuildContext context, SearchProvider search) {
    final l10n = _l10n(context);
    final kinds = search.supportedSearchKinds;
    final isArtistKind = search.searchKind == SearchKind.artist;
    final isLyricKind = search.searchKind == SearchKind.lyric;
    final results = isLyricKind ? search.lyricResults : search.filteredResults;
    final artists = isArtistKind
        ? search.artistResults
        : const <ArtistSummary>[];
    final itemCount = isArtistKind ? artists.length : results.length;
    // 就地预览只取前 N 行：空态 / 失败 / 页脚仍按真实结果数判定（有结果
    // 才给「查看全部结果」），只有行渲染被截断。
    final previewCount = math.min(
      itemCount,
      SearchResultsView.maxDockedPreviewRows,
    );
    final failure = search.failure;

    return _panel(
      context,
      child: SingleChildScrollView(
        // 不接 PrimaryScrollController：面板与页面里的主列表互不干扰。
        primary: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (kinds.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: _kindSwitch(l10n, search, kinds),
              ),
            if (search.isSearching)
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: M3EProgressIndicator.linear(),
              ),
            // 分页失败只影响完整结果页的底部；预览面板仍可看已加载结果。
            if (failure != null && itemCount == 0)
              _failure(context, l10n, search, compact: true),
            if (itemCount > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var index = 0; index < previewCount; index++)
                      isArtistKind
                          ? _dockedArtistRow(
                              context,
                              l10n,
                              artists[index],
                              index,
                              previewCount,
                            )
                          : _dockedTrackRow(
                              context,
                              results[index],
                              index,
                              previewCount,
                            ),
                  ],
                ),
              )
            else if (!search.isSearching && failure == null)
              _dockedEmptyView(context, l10n, search),
            // 有结果才给「查看全部结果」：零结果时它无处可去（空态文案已说明）。
            if (itemCount > 0) _dockedFooter(l10n),
          ],
        ),
      ),
    );
  }

  /// 结果面板底：颜色与圆角取包内 docked 结果面同一套 token。
  Widget _panel(BuildContext context, {required Widget child}) {
    final m3e = M3ETheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: m3e.searchViewTheme.containedContainerColor(m3e.colorScheme),
        borderRadius: M3EShapes.radiusExtraLarge,
      ),
      child: ClipRRect(borderRadius: M3EShapes.radiusExtraLarge, child: child),
    );
  }

  /// 单曲 / 歌词预览行：[TrackRow] 紧凑单列（遮罩不套宽屏表格列）。
  ///
  /// 行映射与页面版式共用 [_SearchResultTile]；差异只有「不渲染歌手链接」
  /// 与面板行距。操作菜单（桌面右键）与未知歌手兜底在两种版式一致。
  Widget _dockedTrackRow(
    BuildContext context,
    SearchRow row,
    int index,
    int count,
  ) {
    return Padding(
      padding: EdgeInsets.only(bottom: TrackRow.gapOf(context)),
      child: _SearchResultTile(
        key: ValueKey(row.id.uri),
        row: row,
        index: index,
        count: count,
        surface: const TrackRowSurface(),
        showArtistLinks: false,
        onTap: widget.onPlay,
        onOpenArtist: null,
      ),
    );
  }

  /// 歌手预览行：点击交给「查看全部结果」，而不是直接进歌手页。
  ///
  /// 遮罩是根导航器上的自建 route：先开歌手页会叠在遮罩上，关闭顺序与
  /// 遮罩的 Esc / 焦点复位互相打架；完整歌手结果页已有进歌手页的链接，
  /// 面板不重复那套入口编排。
  Widget _dockedArtistRow(
    BuildContext context,
    AppLocalizations l10n,
    ArtistSummary artist,
    int index,
    int count,
  ) {
    return Padding(
      padding: EdgeInsets.only(bottom: ArtistRow.gapOf(context)),
      child: ArtistRow(
        key: ValueKey(artist.id),
        name: artist.name,
        avatarUrl: artist.avatarUrl,
        subtitle: artist.songCount == null
            ? null
            : l10n.artistSongCount(artist.songCount!),
        position: calculateCardPosition(index, count),
        onTap: () {
          HapticsService.lightImpact();
          widget.onOpenAllResults!();
        },
      ),
    );
  }

  /// 有词无结果：一句本地化提示；无可用音源时给音源引导标题
  /// （与资料库结果区同一套键，面板不再堆副标题）。
  Widget _dockedEmptyView(
    BuildContext context,
    AppLocalizations l10n,
    SearchProvider search,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        heightFactor: 1,
        child: Text(
          search.hasSelectedSource
              ? l10n.noResultsFound
              : l10n.searchNoSourcesTitle,
          style: context.typeScale.bodyMedium.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 底部出口：完整结果（分段 / 分页 / 歌手链接）在资料库目的地。
  Widget _dockedFooter(AppLocalizations l10n) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
    child: Center(
      heightFactor: 1,
      child: M3EButton.icon(
        style: M3EButtonStyle.text,
        onPressed: widget.onOpenAllResults,
        icon: const Icon(Icons.arrow_forward_rounded, size: 18),
        label: Text(l10n.viewAllResults),
      ),
    ),
  );

  // ---------------------------------------------------------------------------
  // 共用：分段 / 失败态
  // ---------------------------------------------------------------------------

  /// 类型分段（单曲 / 歌手 / 歌词）：M3E 分段按钮需要紧约束铺满
  /// （内部 `Positioned.fill`，放松约束会塌成零宽）。
  Widget _kindSwitch(
    AppLocalizations l10n,
    SearchProvider search,
    List<SearchKind> kinds,
  ) {
    return SizedBox(
      width: double.infinity,
      child: M3ESegmentedButton<SearchKind>(
        segments: [
          for (final kind in kinds)
            M3ESegment<SearchKind>(value: kind, label: _kindLabel(l10n, kind)),
        ],
        selected: {search.searchKind},
        onSelectionChanged: (selection) {
          // 单选：M3E 语义下重按已选中项不会清空。
          if (selection.isNotEmpty) {
            search.selectSearchKind(selection.first);
          }
        },
      ),
    );
  }

  String _kindLabel(AppLocalizations l10n, SearchKind kind) => switch (kind) {
    SearchKind.song => l10n.searchKindSongs,
    SearchKind.artist => l10n.searchKindArtists,
    SearchKind.lyric => l10n.searchKindLyrics,
  };

  /// 搜索失败提示：本地化标题 + 重试（重新提交当前关键词）。
  ///
  /// [compact] 是遮罩版式：面板窄、没有整页空间，只留一行标题 + 重试，
  /// 不重复页面版式的失败详情（完整结果页仍可看到 message）。
  Widget _failure(
    BuildContext context,
    AppLocalizations l10n,
    SearchProvider search, {
    required bool compact,
  }) {
    final theme = Theme.of(context);
    final query = search.searchQuery;
    final retry = M3EButton.icon(
      style: M3EButtonStyle.text,
      onPressed: query.trim().isEmpty ? null : () => search.submitSearch(query),
      icon: const Icon(Icons.refresh_rounded, size: 18),
      label: Text(l10n.retry),
    );
    final title = Text(
      l10n.searchFailed,
      maxLines: compact ? 1 : null,
      overflow: compact ? TextOverflow.ellipsis : null,
      style: context.typeScale.titleSmall.copyWith(
        color: theme.colorScheme.error,
      ),
    );
    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
        child: Row(
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 20,
              color: theme.colorScheme.error,
            ),
            const SizedBox(width: 8),
            Expanded(child: title),
            retry,
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 20,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(child: title),
              retry,
            ],
          ),
          if ((search.failure?.message ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 28, right: 8),
              child: Text(
                // 归一化失败的 message（平台/边界给出的可读说明），
                // 不是原始异常字符串（见 SearchProvider.failure 注释）。
                search.failure!.message,
                style: context.typeScale.bodySmall.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 页面版式的单曲 / 歌词结果 sliver：固定行高，懒构建。
class _TrackResultsSliver extends StatelessWidget {
  const _TrackResultsSliver({
    required this.items,
    required this.onPlay,
    required this.onOpenArtist,
    required this.artistLinksEnabled,
    required this.surface,
  });

  final List<SearchRow> items;
  final void Function(SearchRow row) onPlay;
  final OpenSearchArtist? onOpenArtist;

  /// 渠道是否有歌手能力：为真时逐名歌手渲染成歌手页链接。
  final bool artistLinksEnabled;

  /// 行呈现口径（桌面宽屏的单曲段给表格规范，与表头列同源）。
  final TrackRowSurface surface;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_l10n(context).noItemsFound),
          ),
        ),
      );
    }

    final gap = TrackRow.gapOf(context);
    // 行高按档取 token（表格单行 56 / 非表格双行 72），列表固定 extent。
    final itemExtent =
        TrackRow.extentOf(context, tableColumns: surface.isTable) + gap;
    return SliverFixedExtentList.builder(
      // 行高 + 行距：固定 extent，长列表滚动条拖动一次定位。
      itemExtent: itemExtent,
      itemCount: items.length,
      itemBuilder: (context, index) {
        final row = items[index];
        return Padding(
          padding: EdgeInsets.only(bottom: gap),
          child: _SearchResultTile(
            key: ValueKey(row.id.uri),
            row: row,
            index: index,
            count: items.length,
            surface: surface,
            showArtistLinks: artistLinksEnabled,
            onTap: onPlay,
            onOpenArtist: onOpenArtist,
          ),
        );
      },
    );
  }
}

/// 页面版式的歌手结果 sliver：固定行高（[ArtistRow]），懒构建。
class _ArtistResultsSliver extends StatelessWidget {
  const _ArtistResultsSliver({required this.items, required this.onTap});

  final List<ArtistSummary> items;
  final void Function(ArtistSummary artist) onTap;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_l10n(context).noItemsFound),
          ),
        ),
      );
    }

    final l10n = _l10n(context);
    final gap = ArtistRow.gapOf(context);
    return SliverFixedExtentList.builder(
      // 行高 + 行距：固定 extent，长列表滚动条拖动一次定位。
      itemExtent: ArtistRow.extentOf(context) + gap,
      itemCount: items.length,
      itemBuilder: (context, index) {
        final artist = items[index];
        return Padding(
          padding: EdgeInsets.only(bottom: gap),
          child: ArtistRow(
            key: ValueKey(artist.id),
            name: artist.name,
            avatarUrl: artist.avatarUrl,
            subtitle: artist.songCount == null
                ? null
                : l10n.artistSongCount(artist.songCount!),
            position: calculateCardPosition(index, items.length),
            onTap: () {
              HapticsService.lightImpact();
              onTap(artist);
            },
          ),
        );
      },
    );
  }
}

/// 搜索结果行：两种版式共用的 [SearchRow] → [TrackRowModel] 映射。
///
/// 入口分平台：触摸端行尾常显 ⋮；桌面端不渲染 ⋮，行表面右键在落点弹菜单
/// （[rowActionsAtPointer]）。动作定义与其它曲目行共用
/// [trackRowActionMenuForTrack]。
class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    super.key,
    required this.row,
    required this.index,
    required this.count,
    required this.surface,
    required this.showArtistLinks,
    required this.onTap,
    this.onOpenArtist,
  });

  final SearchRow row;
  final int index;
  final int count;

  /// 行呈现口径（见 `DesktopLayout.tableColumns`）。
  final TrackRowSurface surface;

  /// 是否把逐名歌手渲染成歌手页链接（页面版式；遮罩版式保持纯文本）。
  final bool showArtistLinks;

  final void Function(SearchRow row) onTap;
  final OpenSearchArtist? onOpenArtist;

  @override
  Widget build(BuildContext context) {
    final actions = trackRowActionMenuForTrack(context, row.track);
    // 歌手链接能力位（同一平台固定）：渠道有歌手能力时逐个歌手名可点。
    final sourceKey = row.id.sourceKey;
    final artistTapsEnabled = showArtistLinks && sourceKey.isNotEmpty;
    // 歌词命中片段优先做副标题（此时不渲染歌手链接：副标题让位给歌词）。
    final snippet = row.lyricSnippet ?? '';
    final artistLinks = snippet.isEmpty
        ? _artistLinksOf(context, tapsEnabled: artistTapsEnabled)
        : null;
    return TrackRow(
      model: TrackRowModel(
        title: row.title,
        artist: snippet.isEmpty ? _singleArtistOf(context) : snippet,
        artists: artistLinks,
        artistNames: [
          for (final artist in row.track.artists)
            if (artist.name.isNotEmpty) artist.name,
        ],
        coverUrl: row.coverUrl,
        durationMs: row.duration?.inMilliseconds,
        album: row.albumName,
        trackId: row.id,
      ),
      surface: surface,
      position: calculateCardPosition(index, count),
      onTap: () {
        HapticsService.lightImpact();
        onTap(row);
      },
      onSecondaryTap: rowActionsAtPointer(context, actions),
      trailing: _trailing(context, actions),
    );
  }

  /// 行尾插槽：触摸端常显 ⋮；桌面端无 ⋮（入口改为行表面右键）。
  Widget? _trailing(BuildContext context, List<RowAction> actions) {
    if (isDesktopPlatform()) return null;
    return RowActionMenuButton(
      actions: actions,
      semanticLabel: _l10n(context).trackActionsTooltip,
    );
  }

  /// 单列副标题的首位歌手；无歌手信息时用「未知歌手」兜底（旧口径）。
  String _singleArtistOf(BuildContext context) {
    final name = row.primaryArtistName;
    return name.isEmpty ? _l10n(context).unknownArtist : name;
  }

  /// 逐名可点的歌手链接：条目带平台内 id 且渠道能力位为真时返回；
  /// 否则返回 null（[TrackRow] 退化为整串纯文本副标题）。
  List<TrackRowArtist>? _artistLinksOf(
    BuildContext context, {
    required bool tapsEnabled,
  }) {
    final openArtist = onOpenArtist;
    final sourceKey = row.id.sourceKey;
    if (!tapsEnabled || openArtist == null || sourceKey.isEmpty) return null;
    final links = <TrackRowArtist>[];
    var hasId = false;
    for (final artist in row.track.artists) {
      final name = artist.name;
      if (name.isEmpty) continue;
      final id = artist.id ?? '';
      if (id.isNotEmpty) hasId = true;
      links.add(
        TrackRowArtist(
          name: name,
          onTap: id.isEmpty
              ? null
              : () => unawaited(openArtist(sourceKey, id, fallbackName: name)),
        ),
      );
    }
    // 没有任何一位带 id 时保持整串纯文本（避免半可点半不可点的割裂行）。
    return hasId ? links : null;
  }
}
