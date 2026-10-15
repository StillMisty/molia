import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/artist.dart';
import '../domain/models/catalog.dart' show SearchKind;
import '../domain/ports/source_registry.dart';
import '../l10n/app_localizations.dart';
import '../pages/artist_page.dart';
import '../providers/library_provider.dart';
import '../providers/search_provider.dart';
import '../utils/duration_text.dart';
import '../utils/responsive.dart';
import 'add_to_library.dart';
import 'artist_row.dart';
import 'track_menu_tile.dart';
import 'track_row.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本页而不注册 delegate，
/// 此时回退到简体中文，保证与中文正式环境文案一致（正式 App 恒有 delegate）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 搜索结果区：类型分段（单曲 / 歌手 / 歌词）+ 各类型的结果列表与音源分页。
///
/// 结果行与发现详情页共用 [TrackMenuTile]（点击播放；行尾菜单收藏 / 加入
/// 列表），歌手类型用 [ArtistRow]（点击进歌手页）；分段按渠道能力位显隐
/// （脚本源只有单曲）。
class SearchSection extends StatefulWidget {
  const SearchSection({super.key});

  @override
  State<SearchSection> createState() => _SearchSectionState();
}

class _SearchSectionState extends State<SearchSection> {
  /// 结果区滚动控制器（常显滚动条，支持手拖定位）。
  final ScrollController _resultsScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _resultsScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SearchProvider>(
      builder: (context, searchProvider, child) {
        final l10n = _l10n(context);
        final horizontalPadding =
            context.layoutType(ResponsivePageType.browse).horizontalPadding;
        final results = searchProvider.filteredResults;
        final artistResults = searchProvider.artistResults;
        final isArtistKind =
            searchProvider.searchKind == SearchKind.artist;
        final itemCount = isArtistKind ? artistResults.length : results.length;
        final error = searchProvider.errorMessage;
        final kinds = searchProvider.supportedSearchKinds;

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

            if (error != null) _buildErrorView(l10n, searchProvider),

            Expanded(
              child: Scrollbar(
                controller: _resultsScrollController,
                thumbVisibility: true,
                interactive: true,
                child: CustomScrollView(
                  controller: _resultsScrollController,
                  slivers: [
                    if (itemCount == 0 &&
                        !searchProvider.isSearching &&
                        error == null)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: _buildEmptyResultsView(l10n, searchProvider),
                      )
                    else if (isArtistKind)
                      SliverPadding(
                        padding: EdgeInsets.symmetric(
                            horizontal: horizontalPadding),
                        sliver: _ArtistResultsList(
                          items: artistResults,
                          onItemTap: (artist) =>
                              unawaited(_openArtist(searchProvider, artist)),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: EdgeInsets.symmetric(
                            horizontal: horizontalPadding),
                        sliver: _SearchResultsList(
                          items: results,
                          onItemTap: (item) => searchProvider.playItem(item),
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
  Future<void> _openArtist(SearchProvider searchProvider, ArtistSummary artist) {
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
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: theme.colorScheme.error),
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
          Padding(
            padding: const EdgeInsets.only(left: 28, right: 8),
            child: Text(
              searchProvider.errorMessage ?? '',
              style: theme.textTheme.bodySmall?.copyWith(
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
              hasSelectedSource ? Icons.search_off_rounded : Icons.source_rounded,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              hasSelectedSource
                  ? l10n.noResultsFound
                  : l10n.searchNoSourcesTitle,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              selectedSourceName != null
                  ? l10n.searchNoResultsInSource(selectedSourceName)
                  : l10n.searchNoSourcesHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
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
                    HapticFeedback.lightImpact();
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

  const _SearchResultsList({
    required this.items,
    this.onItemTap,
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
    return SliverFixedExtentList.builder(
      // 行高 + 行距：固定 extent，长列表滚动条拖动一次定位。
      itemExtent: TrackRow.extent + gap,
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
            onTap: onItemTap == null ? null : () => onItemTap!(item),
          ),
        );
      },
    );
  }
}

/// 搜索结果行（[TrackMenuTile] 的搜索域适配层）：
/// 点击播放；行尾菜单收藏 / 加入列表（菜单形状与发现详情页一致）。
class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    super.key,
    required this.item,
    required this.index,
    required this.count,
    required this.onTap,
  });

  final Map<String, dynamic> item;
  final int index;
  final int count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    // 只订阅本行的收藏态：长列表不因 provider 任意通知整表重建。
    final favorite = context.select<LibraryProvider?, bool>(
      (provider) => provider?.isFavoriteSearchItem(item) ?? false,
    );
    // 歌手链接能力位（同一平台固定）：内置平台为真时逐个歌手名可点。
    final sourceKey = item['source']?.toString() ?? '';
    final artistTapsEnabled = sourceKey.isNotEmpty &&
        context.select<SourceRegistry?, bool>(
          (registry) =>
              registry?.byKey(sourceKey)?.capabilities.artist ?? false,
        );
    final artistLinks = _artistLinksOf(
      context,
      item,
      tapsEnabled: artistTapsEnabled,
    );
    return TrackMenuTile(
      title: item['name']?.toString() ?? '',
      artist: _artistOf(item),
      artists: artistLinks,
      coverUrl: _coverUrlOf(item),
      trailingText: durationText(_durationMsOf(item)),
      position: calculateCardPosition(index, count),
      onTap: onTap == null
          ? null
          : () {
              HapticFeedback.lightImpact();
              onTap!();
            },
      favorite: favorite,
      onToggleFavorite: () => unawaited(_toggleFavorite(context, l10n)),
      onAddToPlaylist: () => unawaited(_addToPlaylist(context)),
    );
  }

  /// 收藏 / 取消收藏：结果列表只需 snackbar 确认（菜单文案已表达当前状态）。
  Future<void> _toggleFavorite(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    final library = context.read<LibraryProvider?>();
    if (library == null) return;
    final favorite = await library.toggleFavoriteSearchItem(item);
    if (favorite == null || !context.mounted) return;
    M3ESnackbar.show(
      context,
      message: favorite ? l10n.favoriteAdd : l10n.favoriteRemove,
    );
  }

  /// 加入列表：与收藏页 / 发现页共用同一目标选择与反馈流程。
  Future<void> _addToPlaylist(BuildContext context) async {
    final library = context.read<LibraryProvider?>();
    if (library == null) return;
    final track = library.playlistTrackFromSearchItem(item);
    if (track == null) return;
    await addTracksToLibraryTarget(
      context,
      provider: library,
      tracks: [track],
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

  /// 封面地址：曲目图优先，其次专辑图（与旧的网格卡片同一取法）。
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
