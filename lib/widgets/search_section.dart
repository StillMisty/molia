import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import '../providers/search_provider.dart';
import '../utils/responsive.dart';
import 'app_network_image.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本页而不注册 delegate，
/// 此时回退到简体中文，保证与中文正式环境文案一致（正式 App 恒有 delegate）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

class SearchSection extends StatefulWidget {
  const SearchSection({super.key});

  @override
  State<SearchSection> createState() => _SearchSectionState();
}

class _SearchSectionState extends State<SearchSection> {
  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SearchProvider>(
      builder: (context, searchProvider, child) {
        final l10n = _l10n(context);
        final browseLayout = context.layoutType(ResponsivePageType.browse);
        final gridCrossAxisCount = context.adaptiveColumns(
          minTileWidth: browseLayout.defaultMinTileWidth,
          min: 3,
          max: 6,
        );
        final horizontalPadding = browseLayout.horizontalPadding;
        final results = searchProvider.filteredResults;
        final error = searchProvider.errorMessage;

        return Column(
          children: [
            // 结果页不再有独立顶栏（搜索框自身即状态），仅保留少量间距。
            const SizedBox(height: 8),

            // Loading indicator
            if (searchProvider.isSearching)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: M3EProgressIndicator.linear(),
              ),

            // Error banner with a retry action
            if (error != null) _buildErrorView(l10n, searchProvider),

            // Search results using CustomScrollView for potential future sliver integration
            Expanded(
                child: CustomScrollView(
              slivers: [
                if (results.isEmpty &&
                    !searchProvider.isSearching &&
                    error == null)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _buildEmptyResultsView(l10n, searchProvider),
                  )
                else
                  SliverPadding(
                    padding:
                        EdgeInsets.symmetric(horizontal: horizontalPadding),
                    sliver: _SearchResultsGrid(
                      items: results,
                      gridCrossAxisCount: gridCrossAxisCount,
                      onItemTap: (item) => searchProvider.playItem(item),
                    ),
                  ),

                // 音源搜索分页：列表尾部按钮加载下一页
                if (results.isNotEmpty &&
                    searchProvider.hasSelectedSource &&
                    (searchProvider.hasMore || searchProvider.isLoadingMore))
                  _buildLoadMoreFooter(l10n, searchProvider),
              ],
            )),
          ],
        );
      },
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

/// 搜索结果网格：展示封面/名称/类型，点击交给 SearchProvider 播放。
/// （原 LibraryGrid 的内联精简版，去掉了长按外链与默认播放分支。）
class _SearchResultsGrid extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final int gridCrossAxisCount;
  final void Function(Map<String, dynamic>)? onItemTap;

  const _SearchResultsGrid({
    required this.items,
    required this.gridCrossAxisCount,
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
            child: Text(AppLocalizations.of(context)!.noItemsFound),
          ),
        ),
      );
    }

    return SliverGrid(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final item = items[index];
          return _SearchResultItem(
            key: ValueKey(item['id']),
            item: item,
            onTap: onItemTap != null ? () => onItemTap!(item) : null,
          );
        },
        childCount: items.length,
      ),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: gridCrossAxisCount,
        childAspectRatio: 0.75,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
    );
  }
}

class _SearchResultItem extends StatelessWidget {
  final Map<String, dynamic> item;
  final VoidCallback? onTap;

  const _SearchResultItem({
    super.key,
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider?>();
    final favorite = library?.isFavoriteSearchItem(item) ?? false;
    final l10n = _l10n(context);

    // 长按结果项弹出菜单（收藏/取消收藏）；锚点即结果项本身。
    return M3EMenu.entries(
      position: M3EMenuAnchorPosition.bottomEnd,
      anchorBuilder: (context, open) => GestureDetector(
        key: key,
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.lightImpact();
                onTap!();
              },
        onLongPress: () {
          HapticFeedback.lightImpact();
          open();
        },
        child: _buildTile(context),
      ),
      onSelected: (value) async {
        if (value != 'favorite' || library == null) return;
        final result = await library.toggleFavoriteSearchItem(item);
        if (result == null || !context.mounted) return;
        M3ESnackbar.show(
          context,
          message: result ? l10n.favoriteAdd : l10n.favoriteRemove,
        );
      },
      entries: [
        M3EMenuEntry(
          label: favorite ? l10n.favoriteRemove : l10n.favoriteAdd,
          value: 'favorite',
        ),
      ],
    );
  }

  Widget _buildTile(BuildContext context) {
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final pixelRatio = MediaQuery.of(context).devicePixelRatio;
                    final cacheSize = constraints.maxWidth > 0
                        ? (constraints.maxWidth * pixelRatio).round()
                        : null;
                    final imageUrl = _imageUrlOf(item);
                    if (imageUrl == null) {
                      return DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                        ),
                        child: const Center(
                          child: Icon(Icons.music_note_rounded, size: 40),
                        ),
                      );
                    }
                    return AppNetworkImage(
                      url: imageUrl,
                      width: double.infinity,
                      memCacheWidth: cacheSize,
                      memCacheHeight: cacheSize,
                      fit: BoxFit.cover,
                      fallbackColor: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      fallbackIconSize: 40,
                    );
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            item['name']?.toString() ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // 结果标题是正文内容，不用强调色（强调色只留给交互/选中）。
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w500,
                ),
          ),
          Text(
            _getItemSubtitle(context, item),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
      ],
    );
  }

  String? _imageUrlOf(Map<String, dynamic> item) {
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

  String _getItemSubtitle(BuildContext context, Map<String, dynamic> item) {
    switch (item['type']) {
      case 'playlist':
        return AppLocalizations.of(context)!.playlistType;
      case 'album':
        if (item['artists'] != null && item['artists'].isNotEmpty) {
          return '${AppLocalizations.of(context)!.albumType} • ${item['artists'][0]['name']}';
        }
        return AppLocalizations.of(context)!.albumType;
      case 'track':
        if (item['artists'] != null && item['artists'].isNotEmpty) {
          return '${AppLocalizations.of(context)!.songType} • ${item['artists'][0]['name']}';
        }
        return AppLocalizations.of(context)!.songType;
      case 'artist':
        return AppLocalizations.of(context)!.artistType;
      default:
        return item['type']?.toString() ?? '';
    }
  }
}
