import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/artist.dart';
import '../domain/models/catalog.dart' show SearchKind;
import '../domain/ports/source_registry.dart';
import '../l10n/app_localizations.dart';
import '../pages/artist_page.dart';
import '../providers/search_provider.dart';
import '../services/haptics.dart';
import '../theme/m3e_context.dart';
import '../utils/duration_text.dart';
import '../utils/responsive.dart';
import 'artist_row.dart';
import 'desktop_layout.dart';
import 'track_actions_menu.dart';
import 'track_menu_tile.dart';
import 'track_row.dart';
import 'track_table_header.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本页而不注册 delegate，
/// 此时回退到简体中文，保证与中文正式环境文案一致（正式 App 恒有 delegate）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 搜索结果区：类型分段（单曲 / 歌手 / 歌词）+ 各类型的结果列表与音源分页。
///
/// 结果行是收藏页同形的 [TrackRow]（点击播放；操作菜单收藏 / 加入列表，
/// 与 `TrackMenuTile` 同一份动作域：触摸端行尾 ⋮、桌面端行表面右键），
/// 歌手类型用 [ArtistRow]（点击进歌手页）；分段按渠道能力位显隐（脚本源
/// 只有单曲）。
class SearchSection extends StatefulWidget {
  const SearchSection({super.key, this.controller});

  /// 结果列表滚动控制器（宿主页面注入：重复点击底栏资料库时回顶）；
  /// 为空时自建（独立挂载 / 测试）。
  final ScrollController? controller;

  @override
  State<SearchSection> createState() => _SearchSectionState();
}

class _SearchSectionState extends State<SearchSection> {
  /// 自带控制器：宿主未注入时使用（随 State 释放）。
  ScrollController? _ownedController;

  /// 结果列表滚动控制器（常显滚动条，支持手拖定位）。
  ScrollController get _controller =>
      widget.controller ?? (_ownedController ??= ScrollController());

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 表格列的判定用窗口宽 − 实际栏宽（判据唯一在 DesktopLayout，见
    // desktop_layout.dart）：不随页面结构（页内栏 / 面板）漂移。
    final layout = DesktopLayout.of(context);
    return Consumer<SearchProvider>(
      builder: (context, searchProvider, child) {
        final l10n = _l10n(context);
        final horizontalPadding =
            context.layoutType(ResponsivePageType.browse).horizontalPadding;
        final results = searchProvider.filteredResults;
        final artistResults = searchProvider.artistResults;
        final isArtistKind = searchProvider.searchKind == SearchKind.artist;
        final isLyricKind = searchProvider.searchKind == SearchKind.lyric;
        final lyricResults = searchProvider.lyricResults;
        final itemCount = isArtistKind
            ? artistResults.length
            : isLyricKind
                ? lyricResults.length
                : results.length;
        final failure = searchProvider.failure;
        final kinds = searchProvider.supportedSearchKinds;
        // 宽屏表格列只在单曲段生效：歌手 / 歌词段的行结构不同（头像行 /
        // 歌词片段副标题），不给它们套表格。
        final tableColumns =
            !isArtistKind && !isLyricKind && layout.tableColumns;

        return Column(
          children: [
            // 结果页顶部无独立栏（搜索框自身即状态），只留少量间距。
            const SizedBox(height: 8),

            // 类型分段：仅在有多个可选类型且搜索已激活时显示。
            if (searchProvider.isSearchActive && kinds.length > 1)
              Padding(
                padding: EdgeInsets.fromLTRB(
                    horizontalPadding, 0, horizontalPadding, 8),
                child: _buildKindSwitch(l10n, searchProvider, kinds),
              ),

            if (searchProvider.isSearching)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: M3EProgressIndicator.linear(),
              ),

            if (failure != null) _buildErrorView(l10n, searchProvider),

            // 表格列表头固定在滚动区之上：列标题不随结果滚走，列与行内
            // 列同宽同左缘（TrackTableHeader 内部复刻行的留白结构）。
            if (tableColumns && itemCount > 0)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                child: const TrackTableHeader(),
              ),

            Expanded(
              child: Scrollbar(
                controller: _controller,
                thumbVisibility: true,
                interactive: true,
                child: CustomScrollView(
                  controller: _controller,
                  slivers: [
                    if (itemCount == 0 &&
                        !searchProvider.isSearching &&
                        failure == null)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: _buildEmptyResultsView(l10n, searchProvider),
                      )
                    else if (isArtistKind)
                      SliverPadding(
                        padding:
                            EdgeInsets.symmetric(horizontal: horizontalPadding),
                        sliver: _ArtistResultsList(
                          items: artistResults,
                          onItemTap: (artist) =>
                              unawaited(_openArtist(searchProvider, artist)),
                        ),
                      )
                    else
                      SliverPadding(
                        padding:
                            EdgeInsets.symmetric(horizontal: horizontalPadding),
                        sliver: _SearchResultsList(
                          // 歌词类型：条目带 `lyric_snippet`（行副标题显示命中片段）。
                          items: isLyricKind ? lyricResults : results,
                          onItemTap: (item) => searchProvider.playItem(item),
                          tableColumns: tableColumns,
                        ),
                      ),

                    // 音源搜索分页：列表尾部按钮加载下一页
                    if (itemCount > 0 &&
                        searchProvider.hasSelectedSource &&
                        (searchProvider.hasMore ||
                            searchProvider.isLoadingMore))
                      _buildLoadMoreFooter(l10n, searchProvider),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 类型分段（单曲 / 歌手 / 歌词）：M3E 分段按钮需要紧约束铺满
  /// （内部 `Positioned.fill`，放松约束会塌成零宽）。
  Widget _buildKindSwitch(
    AppLocalizations l10n,
    SearchProvider searchProvider,
    List<SearchKind> kinds,
  ) {
    return SizedBox(
      width: double.infinity,
      child: M3ESegmentedButton<SearchKind>(
        segments: [
          for (final kind in kinds)
            M3ESegment<SearchKind>(
              value: kind,
              label: _kindLabel(l10n, kind),
            ),
        ],
        selected: {searchProvider.searchKind},
        onSelectionChanged: (selection) {
          // 单选：M3E 语义下重按已选中项不会清空。
          if (selection.isNotEmpty) {
            searchProvider.selectSearchKind(selection.first);
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

  /// 打开歌手页（歌手条目 → 平台内歌手 id）。
  Future<void> _openArtist(
      SearchProvider searchProvider, ArtistSummary artist) {
    return showArtistPage(
      context,
      searchProvider.sourceKey,
      artist.id,
      fallbackName: artist.name,
    );
  }

  /// 搜索失败提示：本地化标题 + 原始错误详情 + 重试（重新提交当前关键词）。
  Widget _buildErrorView(AppLocalizations l10n, SearchProvider searchProvider) {
    final theme = Theme.of(context);
    final query = searchProvider.searchQuery;
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
              Expanded(
                child: Text(
                  l10n.searchFailed,
                  style: context.typeScale.titleSmall.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
              M3EButton.icon(
                style: M3EButtonStyle.text,
                onPressed: query.trim().isEmpty
                    ? null
                    : () => searchProvider.submitSearch(query),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(l10n.retry),
              ),
            ],
          ),
          if ((searchProvider.failure?.message ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 28, right: 8),
              child: Text(
                // 归一化失败的 message（平台/边界给出的可读说明），
                // 不是原始异常字符串（见 SearchProvider.failure 注释）。
                searchProvider.failure!.message,
                style: context.typeScale.bodySmall.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 结果列表尾部的「加载更多」（音源分页；加载中显示进度圈）。
  Widget _buildLoadMoreFooter(
    AppLocalizations l10n,
    SearchProvider searchProvider,
  ) {
    final total = searchProvider.totalResults;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: Center(
          child: searchProvider.isLoadingMore
              ? const SizedBox(
                  width: 28,
                  height: 28,
                  child: M3EProgressIndicator.circular(
                    size: 28,
                    strokeWidth: 2.5,
                  ),
                )
              : M3EButton.icon(
                  style: M3EButtonStyle.outlined,
                  onPressed: searchProvider.loadMore,
                  icon: const Icon(Icons.expand_more_rounded),
                  label: Text(
                    total != null
                        ? l10n.searchLoadMoreWithTotal(total)
                        : l10n.searchLoadMore,
                  ),
                ),
        ),
      ),
    );
  }

  /// 空状态区分：未选择/无可用音源，与「已选音源但无结果」（展示音源名）。
  Widget _buildEmptyResultsView(
    AppLocalizations l10n,
    SearchProvider searchProvider,
  ) {
    final theme = Theme.of(context);
    final selectedSourceName = _selectedSourceName(searchProvider);
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

  /// 当前选中音源的显示名；选中的 key 不在可选列表中（未选择/已失效）时为 null。
  String? _selectedSourceName(SearchProvider searchProvider) {
    for (final option in searchProvider.sourceOptions) {
      if (option.key == searchProvider.sourceKey) {
        return option.name;
      }
    }
    return null;
  }
}

/// 歌手结果列表：固定行高（[ArtistRow]，点击进歌手页），懒构建。
class _ArtistResultsList extends StatelessWidget {
  final List<ArtistSummary> items;
  final void Function(ArtistSummary artist)? onItemTap;

  const _ArtistResultsList({required this.items, this.onItemTap});

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
      itemExtent: ArtistRow.extent + gap,
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
            onTap: onItemTap == null
                ? null
                : () {
                    HapticsService.lightImpact();
                    onItemTap!(artist);
                  },
          ),
        );
      },
    );
  }
}

/// 搜索结果列表：固定行高（收藏页同款 [TrackRow] 行），懒构建。
class _SearchResultsList extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final void Function(Map<String, dynamic>)? onItemTap;

  /// 宽屏表格列（桌面宽屏的单曲段）：行内改表格布局，与表头列同源。
  final bool tableColumns;

  const _SearchResultsList({
    required this.items,
    this.onItemTap,
    this.tableColumns = false,
  });

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
        TrackRow.extentOf(context, tableColumns: tableColumns) + gap;
    return SliverFixedExtentList.builder(
      // 行高 + 行距：固定 extent，长列表滚动条拖动一次定位。
      itemExtent: itemExtent,
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return Padding(
          padding: EdgeInsets.only(bottom: gap),
          child: _SearchResultTile(
            key: ValueKey(item['id']),
            item: item,
            index: index,
            count: items.length,
            tableColumns: tableColumns,
            onTap: onItemTap == null ? null : () => onItemTap!(item),
          ),
        );
      },
    );
  }
}

/// 搜索结果行：点击播放；操作菜单收藏 / 加入列表（与 `TrackMenuTile` 共用
/// [trackRowActionMenuForSearchItem]，条目 / 图标 / 语义全 App 一致）。
///
/// 入口分平台：触摸端行尾常显 ⋮；桌面端不渲染 ⋮，行表面右键在落点弹菜单
/// （[showTrackActionsMenuAtPointer]）。行内容直接在 [TrackRow] 上构建
/// （单列 / 表格两种版式共用），不走 `FavoriteTrackTile` 适配层：表格列
/// 版式适配层不支持。
class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    super.key,
    required this.item,
    required this.index,
    required this.count,
    required this.onTap,
    this.tableColumns = false,
  });

  final Map<String, dynamic> item;
  final int index;
  final int count;
  final VoidCallback? onTap;

  /// 宽屏表格列（见 `DesktopLayout.tableColumns`）。
  final bool tableColumns;

  @override
  Widget build(BuildContext context) {
    final onTap = this.onTap;
    final rowTap = onTap == null
        ? null
        : () {
            HapticsService.lightImpact();
            onTap();
          };
    final menu = trackRowActionMenuForSearchItem(context, item);
    if (tableColumns) {
      return _buildTableRow(context, rowTap: rowTap, menu: menu);
    }
    return _buildSingleColumnRow(context, rowTap: rowTap, menu: menu);
  }

  /// 单列行（非宽屏 / 触摸端）：封面 + 标题 + 歌手 / 歌词片段副标题。
  Widget _buildSingleColumnRow(
    BuildContext context, {
    required VoidCallback? rowTap,
    required TrackRowActionMenu menu,
  }) {
    // 歌手链接能力位（同一平台固定）：内置平台为真时逐个歌手名可点。
    final sourceKey = item['source']?.toString() ?? '';
    final artistTapsEnabled = sourceKey.isNotEmpty &&
        context.select<SourceRegistry?, bool>(
          (registry) =>
              registry?.byKey(sourceKey)?.capabilities.artist ?? false,
        );
    // 歌词命中片段优先做副标题（此时不渲染歌手链接：副标题让位给歌词）。
    final snippet = item['lyric_snippet']?.toString() ?? '';
    final artistLinks = snippet.isEmpty
        ? _artistLinksOf(context, item, tapsEnabled: artistTapsEnabled)
        : null;
    return TrackRow(
      title: item['name']?.toString() ?? '',
      artist: snippet.isEmpty ? _artistOf(item) : snippet,
      artists: artistLinks,
      coverUrl: _coverUrlOf(item),
      trailingText: durationText(_durationMsOf(item)),
      position: calculateCardPosition(index, count),
      onTap: rowTap,
      onSecondaryTap: _onSecondaryTap(context, menu),
      trailing: _trailing(context, menu),
    );
  }

  /// 宽屏表格行：标题 + 艺术家 / 专辑 / 时长列（列宽走默认规范，与表头同源）。
  Widget _buildTableRow(
    BuildContext context, {
    required VoidCallback? rowTap,
    required TrackRowActionMenu menu,
  }) {
    final artist = _artistDisplayOf(item);
    return TrackRow(
      title: item['name']?.toString() ?? '',
      // 表格模式标题格不渲染副标题，artist 只用于行的无障碍文案。
      artist: artist,
      coverUrl: _coverUrlOf(item),
      columns: TrackRowColumns(
        artist: artist,
        album: _albumNameOf(item),
        duration: durationText(_durationMsOf(item)) ?? '',
      ),
      position: calculateCardPosition(index, count),
      onTap: rowTap,
      onSecondaryTap: _onSecondaryTap(context, menu),
      trailing: _trailing(context, menu),
    );
  }

  /// 行尾插槽：触摸端常显 ⋮；桌面端无 ⋮（入口改为行表面右键）。
  Widget? _trailing(BuildContext context, TrackRowActionMenu menu) {
    if (isDesktopPlatform()) return null;
    return TrackActionsMenu(
      entries: menu.entries,
      onSelected: menu.onSelected,
      semanticLabel: _l10n(context).trackActionsTooltip,
    );
  }

  /// 桌面行表面右键 = 同一份菜单（在落点弹出）；触摸端不接次级手势。
  void Function(Offset globalPosition)? _onSecondaryTap(
    BuildContext context,
    TrackRowActionMenu menu,
  ) {
    if (!isDesktopPlatform()) return null;
    return (globalPosition) => showTrackActionsMenuAtPointer(
          context: context,
          globalPosition: globalPosition,
          entries: menu.entries,
          onSelected: menu.onSelected,
        );
  }

  /// 首位艺术家；无艺术家信息返回空串（[TrackRow] 据此隐藏副标题行）。
  String _artistOf(Map<String, dynamic> item) {
    final artists = item['artists'];
    if (artists is List && artists.isNotEmpty && artists[0] is Map) {
      final name = artists[0]['name'];
      if (name is String) return name;
    }
    return '';
  }

  /// 表格列用的歌手显示名：与行内逐名副标题同口径（多名以「、」连接）；
  /// 没有可用名字时返回空串（列留空，不显示占位符）。
  String _artistDisplayOf(Map<String, dynamic> item) {
    final artists = item['artists'];
    if (artists is! List) return '';
    final names = <String>[];
    for (final entry in artists) {
      if (entry is! Map) continue;
      final name = entry['name']?.toString() ?? '';
      if (name.isNotEmpty) names.add(name);
    }
    return names.join('、');
  }

  /// 专辑名（`album.name`）；缺失返回空串（列留空，不显示占位符）。
  String _albumNameOf(Map<String, dynamic> item) {
    final album = item['album'];
    if (album is Map) return album['name']?.toString() ?? '';
    return '';
  }

  /// 逐名可点的歌手链接：条目带平台内 id 且渠道能力位为真时返回；
  /// 否则返回 null（[TrackRow] 退化为整串纯文本副标题）。
  ///
  /// [tapsEnabled] 由 build 里的能力位 select 传入（组件不认具体 provider 的
  /// 惯例在此保持：链接的打开动作是页面级 API）。
  List<TrackRowArtist>? _artistLinksOf(
    BuildContext context,
    Map<String, dynamic> item, {
    required bool tapsEnabled,
  }) {
    final sourceKey = item['source']?.toString() ?? '';
    if (!tapsEnabled || sourceKey.isEmpty) return null;
    final raw = item['artists'];
    if (raw is! List || raw.isEmpty) return null;
    final links = <TrackRowArtist>[];
    var hasId = false;
    for (final entry in raw) {
      if (entry is! Map) continue;
      final name = entry['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final id = entry['id']?.toString() ?? '';
      if (id.isNotEmpty) hasId = true;
      links.add(TrackRowArtist(
        name: name,
        onTap: id.isEmpty
            ? null
            : () => unawaited(
                  showArtistPage(
                    context,
                    sourceKey,
                    id,
                    fallbackName: name,
                  ),
                ),
      ));
    }
    // 没有任何一位带 id 时保持整串纯文本（避免半可点半不可点的割裂行）。
    return hasId ? links : null;
  }

  /// 封面地址：曲目图优先，其次专辑图。
  String? _coverUrlOf(Map<String, dynamic> item) {
    final images = item['images'];
    if (images is List && images.isNotEmpty && images[0] is Map) {
      final url = images[0]['url'];
      if (url is String && url.isNotEmpty) return url;
    }
    final album = item['album'];
    if (album is Map) {
      final albumImages = album['images'];
      if (albumImages is List &&
          albumImages.isNotEmpty &&
          albumImages[0] is Map) {
        final url = albumImages[0]['url'];
        if (url is String && url.isNotEmpty) return url;
      }
    }
    return null;
  }

  /// 时长（毫秒）；缺失 / 非法时返回 null（行尾不占位）。
  int? _durationMsOf(Map<String, dynamic> item) {
    final value = item['duration_ms'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
}
