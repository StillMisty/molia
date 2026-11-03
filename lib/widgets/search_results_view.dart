import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/artist.dart';
import '../domain/models/catalog.dart' show SearchKind;
import '../l10n/app_localizations.dart';
import '../providers/search_provider.dart';
import '../services/haptics.dart';
import '../theme/m3e_context.dart';
import '../theme/motion_policy.dart';
import '../utils/responsive.dart';
import 'artist_row.dart';
import 'desktop_layout.dart';
import 'key_claim_scope.dart';
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
typedef OpenSearchArtist = Future<void> Function(
  String sourceKey,
  String artistId, {
  String? fallbackName,
});

/// 遮罩预览里的一个可高亮条目（跳过分组标题）。
sealed class SearchPreviewItem {
  const SearchPreviewItem({required this.sourceKey});

  final String sourceKey;

  /// 行身份（跨刷新 / 分组插入时按它保留高亮）。
  String get key;
}

final class SearchPreviewTrack extends SearchPreviewItem {
  const SearchPreviewTrack({required this.row, required super.sourceKey});

  final SearchRow row;

  @override
  String get key => 'track:${row.id.uri}';
}

final class SearchPreviewArtist extends SearchPreviewItem {
  const SearchPreviewArtist({required this.artist, required super.sourceKey});

  final ArtistSummary artist;

  @override
  String get key => 'artist:$sourceKey:${artist.id}';
}

/// 遮罩预览的唯一投影：遮罩高亮索引与渲染列表共用同一份顺序。
class SearchPreview {
  const SearchPreview({required this.items, required this.totalItems});

  /// 扁平高亮顺序（单渠道最多 [SearchResultsView.maxDockedPreviewRows] 行）。
  final List<SearchPreviewItem> items;

  /// 当前渠道的完整结果数（不是预览截断后的数量）。
  final int totalItems;
}

/// 搜索结果面：单曲 / 歌手 / 歌词三类结果在一个模块里完成映射与状态呈现。
///
/// 全局只有一个搜索渠道，所以结果面最多一个来源分组：
/// - 页面版：类型分段 + 宽屏表格列 + 触底自动分页；
/// - 遮罩版：最多预览 8 行，以「查看全部结果」出口收尾；当前渠道不支持
///   搜索时显示专用空态。
///
/// 行映射、失败 / 空态与键盘高亮都在这里维护；宿主只传 [variant] 与导航回调。
class SearchResultsView extends StatefulWidget {
  const SearchResultsView({
    super.key,
    required this.variant,
    required this.onPlay,
    this.onOpenArtist,
    this.onOpenAllResults,
    this.controller,
    this.highlightedKey,
  }) : assert(
         variant != SearchResultsVariant.page || onOpenArtist != null,
         '页面版式需要 onOpenArtist（歌手行与行内歌手链接的导航出口）',
       ),
       assert(
         variant != SearchResultsVariant.docked || onOpenAllResults != null,
         '遮罩版式需要 onOpenAllResults（面板底部的完整结果出口）',
       );

  /// 遮罩就地预览的最大行数：更长的列表交给「查看全部结果」后的资料库。
  static const int maxDockedPreviewRows = 8;

  final SearchResultsVariant variant;

  /// 单曲 / 歌词行点击：播放语义归宿主。
  final void Function(SearchRow row) onPlay;

  /// 页面版式的歌手导航。
  final OpenSearchArtist? onOpenArtist;

  /// 遮罩版式的「查看全部结果」。
  final VoidCallback? onOpenAllResults;

  /// 页面版式的滚动控制器（宿主注入：底栏重复点击回顶）；为空时自建。
  final ScrollController? controller;

  /// 遮罩高亮行身份（见 [SearchPreviewItem.key]）；页面版可不传。
  final String? highlightedKey;

  /// 当前渠道在当前搜索类型下的唯一分组（无渠道 / 不支持该类型时为 null）。
  static SearchSourceGroup<Object>? groupOf(SearchProvider search) =>
      switch (search.searchKind) {
        SearchKind.song =>
          search.songGroups.isEmpty ? null : search.songGroups.first,
        SearchKind.artist =>
          search.artistGroups.isEmpty ? null : search.artistGroups.first,
        SearchKind.lyric =>
          search.lyricGroups.isEmpty ? null : search.lyricGroups.first,
      };

  /// 生成遮罩预览的唯一纯函数：遮罩控制高亮与渲染列表都读它，避免索引漂移。
  static SearchPreview previewFor(SearchProvider search) {
    final group = groupOf(search);
    if (group == null) {
      return const SearchPreview(items: [], totalItems: 0);
    }
    final items = <SearchPreviewItem>[];
    switch (search.searchKind) {
      case SearchKind.song || SearchKind.lyric:
        for (final row in (group as SearchSourceGroup<SearchRow>).items.take(
          maxDockedPreviewRows,
        )) {
          items.add(SearchPreviewTrack(row: row, sourceKey: group.source.key));
        }
      case SearchKind.artist:
        for (final artist
            in (group as SearchSourceGroup<ArtistSummary>).items.take(
              maxDockedPreviewRows,
            )) {
          items.add(
            SearchPreviewArtist(artist: artist, sourceKey: group.source.key),
          );
        }
    }
    return SearchPreview(
      items: List.unmodifiable(items),
      totalItems: group.items.length,
    );
  }

  @override
  State<SearchResultsView> createState() => _SearchResultsViewState();
}

class _SearchResultsViewState extends State<SearchResultsView> {
  /// 宿主未注入时自建（独立挂载 / 测试），随 State 释放。
  ScrollController? _ownedController;

  ScrollController get _pageController =>
      widget.controller ?? (_ownedController ??= ScrollController());

  /// 高亮行的 GlobalKey：结果到达 / 键盘移动后自动滚入视野。
  final Map<String, GlobalKey> _highlightKeys = {};
  String? _lastEnsuredKey;

  @override
  void didUpdateWidget(covariant SearchResultsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.highlightedKey != widget.highlightedKey) {
      _lastEnsuredKey = null;
    }
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  GlobalKey _itemKey(String key) =>
      _highlightKeys.putIfAbsent(key, GlobalKey.new);

  /// 高亮变化后把行滚入视野；减弱动效时直接跳转。
  void _scheduleEnsureHighlighted() {
    final key = widget.highlightedKey;
    if (key == null || key == _lastEnsuredKey) return;
    _lastEnsuredKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _highlightKeys[key]?.currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: effectDurationOf(context, M3EMotion.short4),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final search = context.watch<SearchProvider>();
    return switch (widget.variant) {
      SearchResultsVariant.page => _buildPage(context, search),
      SearchResultsVariant.docked =>
        // 当前渠道不支持搜索时，即使还没输入关键词也要显示专用空态；
        // 可搜索且无词时结果面留空（只留搜索条）。
        !search.isSearchActive && search.hasActiveSearchSource
            ? const SizedBox.shrink()
            : _buildDocked(context, search),
    };
  }

  Widget _buildPage(BuildContext context, SearchProvider search) {
    final l10n = _l10n(context);
    final layout = DesktopLayout.of(context);
    final horizontalPadding = context
        .layoutType(ResponsivePageType.browse)
        .horizontalPadding;
    final group = SearchResultsView.groupOf(search);
    final itemCount = group?.items.length ?? 0;
    final failure = group?.failure;
    final showEmptyState =
        itemCount == 0 && !search.isSearchBusy && failure == null;
    final kinds = search.supportedSearchKinds;
    final tableColumns =
        search.searchKind == SearchKind.song &&
        layout.tableColumns &&
        group != null &&
        group.items.isNotEmpty;
    final controller = _pageController;
    final scrollView = CustomScrollView(
      controller: controller,
      slivers: [
        if (showEmptyState)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _pageEmptyView(l10n, search),
          )
        else
          ..._singleGroupSlivers(
            context,
            l10n,
            search,
            group,
            horizontalPadding: horizontalPadding,
            tableColumns: tableColumns,
          ),
      ],
    );

    final content = Column(
      children: [
        const SizedBox(height: 8),
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
        if (search.isSearchBusy)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: M3EProgressIndicator.linear(),
          ),
        // 首屏失败才占顶部错误条；追加页失败只停底部页脚。
        if (failure != null && (group?.items.isEmpty ?? true))
          _failure(
            context,
            l10n,
            compact: false,
            detail: failure.message,
            horizontalPadding: horizontalPadding,
            onRetry: () => search.retry(group!.source.key),
          ),
        if (tableColumns)
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
              hasMore: group?.hasMore ?? false,
              failed: failure != null && (group?.items.isEmpty ?? true),
              isLoadingMore: group?.isLoadingMore ?? false,
              loadMoreFailed: group?.loadMoreFailed ?? false,
              onLoadMore: () {
                final sourceKey = group?.source.key;
                if (sourceKey != null) search.loadMore(sourceKey);
              },
              child: scrollView,
            ),
          ),
        ),
      ],
    );

    // 页面版没有模态登记：焦点进入结果区（行 / 分段）时让全局快捷键让位，
    // Space 激活行、方向键交给焦点遍历。
    return KeyClaimScope(child: content);
  }

  List<Widget> _singleGroupSlivers(
    BuildContext context,
    AppLocalizations l10n,
    SearchProvider search,
    SearchSourceGroup<Object>? group, {
    required double horizontalPadding,
    required bool tableColumns,
  }) {
    if (group == null) return const [];
    final isArtistKind = search.searchKind == SearchKind.artist;
    final slivers = <Widget>[];
    if (group.items.isNotEmpty) {
      final rows = group.items;
      slivers.add(
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: isArtistKind
              ? _ArtistResultsSliver(
                  items: rows.cast<ArtistSummary>(),
                  onTap: (artist) => unawaited(
                    widget.onOpenArtist!(
                      group.source.key,
                      artist.id,
                      fallbackName: artist.name,
                    ),
                  ),
                )
              : _TrackResultsSliver(
                  items: rows.cast<SearchRow>(),
                  onPlay: widget.onPlay,
                  onOpenArtist: widget.onOpenArtist,
                  artistLinksEnabled: group.source.capabilities.artist,
                  surface: TrackRowSurface(
                    showFocusRing: true,
                    showFocusFill: true,
                    tableSpec: tableColumns
                        ? TrackRowColumnSpec.standard
                        : null,
                  ),
                ),
        ),
      );
    }
    if (group.items.isNotEmpty &&
        (group.isLoadingMore || group.loadMoreFailed)) {
      slivers.add(
        SliverToBoxAdapter(
          child: PagedListFooter(
            isLoadingMore: group.isLoadingMore,
            loadMoreFailed: group.loadMoreFailed,
            onRetry: () => search.retry(group.source.key),
            failureLabel: l10n.searchLoadMoreFailed,
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              16,
              horizontalPadding,
              32,
            ),
          ),
        ),
      );
    }
    return slivers;
  }

  /// 空状态区分：无可用来源 / 当前渠道不支持搜索 / 未输入 / 当前渠道无结果。
  Widget _pageEmptyView(AppLocalizations l10n, SearchProvider search) {
    final theme = Theme.of(context);
    final IconData icon;
    final String title;
    String? hint;
    final unsupported =
        !search.hasActiveSearchSource && search.activeSourceKey.isNotEmpty;
    if (unsupported) {
      icon = Icons.search_off_rounded;
      title = l10n.searchChannelUnsupported;
    } else if (!search.hasSearchableSources) {
      icon = Icons.source_rounded;
      title = l10n.searchNoSourcesTitle;
      hint = l10n.searchNoSourcesHint;
    } else if (!search.hasActiveSearchSource) {
      icon = Icons.search_off_rounded;
      title = l10n.searchChannelUnsupported;
    } else if (!search.isSearchActive) {
      icon = Icons.search_rounded;
      title = l10n.searchIdleHint;
    } else {
      icon = Icons.search_off_rounded;
      final sourceName = search.activeSource?.displayName;
      title = l10n.noResultsFound;
      if (sourceName != null) hint = l10n.searchNoResultsInSource(sourceName);
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: context.typeScale.titleMedium,
            ),
            if (hint != null) ...[
              const SizedBox(height: 8),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: context.typeScale.bodyMedium.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDocked(BuildContext context, SearchProvider search) {
    final l10n = _l10n(context);
    final kinds = search.supportedSearchKinds;
    final group = SearchResultsView.groupOf(search);
    final preview = SearchResultsView.previewFor(search);
    final anyFailure = group?.failure != null;
    final showEmpty =
        preview.totalItems == 0 && !search.isSearchBusy && !anyFailure;
    final currentKeys = {for (final item in preview.items) item.key};
    _highlightKeys.removeWhere((key, _) => !currentKeys.contains(key));
    _scheduleEnsureHighlighted();

    return _panel(
      context,
      child: SingleChildScrollView(
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
            if (search.isSearchBusy && preview.items.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: M3EProgressIndicator.linear(),
              ),
            if (!showEmpty && group?.failure != null)
              _failure(
                context,
                l10n,
                compact: true,
                detail: group!.failure!.message,
                onRetry: () => search.retry(group.source.key),
              ),
            if (!showEmpty && preview.items.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var index = 0; index < preview.items.length; index++)
                      _dockedItem(
                        context,
                        l10n,
                        preview.items[index],
                        index,
                        preview.items.length,
                      ),
                  ],
                ),
              ),
            if (showEmpty) _dockedEmptyView(context, l10n, search),
            // 有结果才给「查看全部结果」：零结果时它无处可去。
            if (preview.totalItems > 0) _dockedFooter(l10n),
          ],
        ),
      ),
    );
  }

  Widget _dockedItem(
    BuildContext context,
    AppLocalizations l10n,
    SearchPreviewItem item,
    int index,
    int count,
  ) {
    final selected = item.key == widget.highlightedKey;
    final key = _itemKey(item.key);
    return switch (item) {
      SearchPreviewTrack(:final row) => Padding(
        key: key,
        padding: EdgeInsets.only(bottom: TrackRow.gapOf(context)),
        child: _SearchResultTile(
          key: ValueKey(row.id.uri),
          row: row,
          index: index,
          count: count,
          surface: const TrackRowSurface(
            showFocusRing: true,
            showFocusFill: true,
          ),
          showArtistLinks: false,
          selected: selected,
          onTap: widget.onPlay,
          onOpenArtist: null,
        ),
      ),
      SearchPreviewArtist(:final artist) => Padding(
        key: key,
        padding: EdgeInsets.only(bottom: ArtistRow.gapOf(context)),
        child: ArtistRow(
          key: ValueKey(artist.id),
          name: artist.name,
          avatarUrl: artist.avatarUrl,
          subtitle: artist.songCount == null
              ? null
              : l10n.artistSongCount(artist.songCount!),
          position: calculateCardPosition(index, count),
          selected: selected,
          showFocusRing: true,
          showFocusFill: true,
          onTap: () {
            HapticsService.lightImpact();
            widget.onOpenAllResults!();
          },
        ),
      ),
    };
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

  /// 空态：当前渠道不支持搜索 / 全应用无来源 / 当前渠道无结果。
  Widget _dockedEmptyView(
    BuildContext context,
    AppLocalizations l10n,
    SearchProvider search,
  ) {
    final theme = Theme.of(context);
    final sourceName = search.activeSource?.displayName;
    final unsupported =
        !search.hasActiveSearchSource && search.activeSourceKey.isNotEmpty;
    final noSources = !search.hasSearchableSources && !unsupported;
    final title = unsupported
        ? l10n.searchChannelUnsupported
        : (noSources ? l10n.searchNoSourcesTitle : l10n.noResultsFound);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Center(
        heightFactor: 1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: context.typeScale.bodyMedium.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (noSources) ...[
              const SizedBox(height: 4),
              Text(
                l10n.searchNoSourcesHint,
                textAlign: TextAlign.center,
                style: context.typeScale.bodySmall.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ] else if (!unsupported && sourceName != null) ...[
              const SizedBox(height: 4),
              Text(
                l10n.searchNoResultsInSource(sourceName),
                textAlign: TextAlign.center,
                style: context.typeScale.bodySmall.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
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

  /// 类型分段（单曲 / 歌手 / 歌词）：M3E 分段按钮需要紧约束铺满。
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

  /// 搜索失败提示：本地化标题 + 每来源独立重试。
  Widget _failure(
    BuildContext context,
    AppLocalizations l10n, {
    required bool compact,
    required VoidCallback onRetry,
    double horizontalPadding = 16,
    String? detail,
  }) {
    final theme = Theme.of(context);
    final retry = M3EButton.icon(
      style: M3EButtonStyle.text,
      onPressed: onRetry,
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
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
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
      padding: EdgeInsets.fromLTRB(horizontalPadding, 0, horizontalPadding, 8),
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
          if ((detail ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 28, right: 8),
              child: Text(
                // 归一化失败的 message（平台 / 边界给出的可读说明），
                // 不是原始异常字符串。
                detail!,
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
    final itemExtent =
        TrackRow.extentOf(context, tableColumns: surface.isTable) + gap;
    return SliverFixedExtentList.builder(
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
            showFocusRing: true,
            showFocusFill: true,
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
/// 入口分平台：触摸端行尾常显 ⋮；桌面端不渲染 ⋮，行表面右键在落点弹菜单。
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
    this.selected = false,
  });

  final SearchRow row;
  final int index;
  final int count;

  /// 行呈现口径（见 `DesktopLayout.tableColumns`）。
  final TrackRowSurface surface;

  /// 是否把逐名歌手渲染成歌手页链接（页面版式；遮罩版式保持纯文本）。
  final bool showArtistLinks;

  /// 遮罩键盘高亮（与当前曲目高亮同一套 selected 观感）。
  final bool selected;

  final void Function(SearchRow row) onTap;
  final OpenSearchArtist? onOpenArtist;

  @override
  Widget build(BuildContext context) {
    final actions = trackRowActionMenuForTrack(context, row.track);
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
        selected: selected,
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

  /// 单列副标题的首位歌手；无歌手信息时用「未知歌手」兜底。
  String _singleArtistOf(BuildContext context) {
    final name = row.primaryArtistName;
    return name.isEmpty ? _l10n(context).unknownArtist : name;
  }

  /// 逐名可点的歌手链接：条目带平台内 id 且渠道能力位为真时返回。
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
    return hasId ? links : null;
  }
}
