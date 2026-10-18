import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/discover.dart';
import '../l10n/app_localizations.dart';
import '../pages/discover_tracks_page.dart';
import '../providers/discover_provider.dart';
import '../providers/paged_list_controller.dart';
import '../services/haptics.dart';
import 'app_search_bar.dart';
import 'empty_state.dart';
import 'library_cover.dart';
import 'shell_page_visibility.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 资料页「歌单」tab：平台选择 + 歌单搜索 / 标签筛选 / 歌单列表（分页）。
class DiscoverPlaylistsTab extends StatefulWidget {
  const DiscoverPlaylistsTab({super.key, this.controller});

  /// 歌单列表滚动控制器（宿主页面注入：重复点击底栏资料库时回顶）；
  /// 为空时自建（独立挂载 / 测试）。
  final ScrollController? controller;

  @override
  State<DiscoverPlaylistsTab> createState() => _DiscoverPlaylistsTabState();
}

class _DiscoverPlaylistsTabState extends State<DiscoverPlaylistsTab>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  /// 自带控制器：宿主未注入时使用（随 State 释放）。
  ScrollController? _ownedController;

  /// 歌单列表滚动控制器（常显滚动条，支持手拖定位）。
  ScrollController get _scrollController =>
      widget.controller ?? (_ownedController ??= ScrollController());

  List<DiscoverTag> _hotTags = const [];
  List<DiscoverTagCategory> _tagCategories = const [];

  String _selectedTag = '';
  String _query = '';
  late final PagedListController<DiscoverPlaylist> _paged;

  /// 当前已加载数据的平台（切换平台时重置并重载）。
  String? _loadedSourceKey;

  /// 歌单卡片固定行高：卡片 72（封面 56 + 上下 8）+ 8 间距。
  static const double _playlistRowExtent = 80;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _paged = PagedListController<DiscoverPlaylist>(
      fetchPage: _fetchPlaylistPage,
      keyOf: (playlist) => playlist.id,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureSourceLoaded());
  }

  Future<PagedResult<DiscoverPlaylist>> _fetchPlaylistPage(int page) async {
    final provider = _provider;
    final result = _query.isEmpty
        ? await provider.loadPlaylists(_selectedTag, page)
        : await provider.searchPlaylists(_query, page);
    return PagedResult(
      items: result.playlists,
      // total 可能是平台占位值（mg/tx 为 99999）：以「本页是否满员」判断更多。
      hasMore: result.playlists.length >= result.limit &&
          (result.total <= 0 || page * result.limit < result.total),
      total: result.total,
    );
  }

  @override
  void dispose() {
    _paged.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _ownedController?.dispose();
    super.dispose();
  }

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
    // 首屏失败时由错误态的重试按钮兜底（不在滚动里自动恢复）；
    // 加载中 / 已到底 / 已加载更多失败等守卫由控制器持有。
    if (_paged.state.failed) return;
    unawaited(_paged.loadMore());
  }

  DiscoverProvider get _provider => context.read<DiscoverProvider>();

  void _ensureSourceLoaded() {
    if (!mounted) return;
    final provider = _provider;
    if (!provider.hasDiscoverSource) return;
    if (_loadedSourceKey == provider.channelKey) return;
    _loadedSourceKey = provider.channelKey;
    _hotTags = const [];
    _tagCategories = const [];
    _selectedTag = '';
    _query = '';
    _searchController.clear();
    _paged.reset();
    _loadTags();
    _paged.loadFirstPage();
  }

  Future<void> _loadTags() async {
    try {
      final result = await _provider.loadTags();
      if (!mounted) return;
      setState(() {
        _hotTags = result.hotTags;
        _tagCategories = result.categories;
      });
    } catch (_) {
      // 标签失败不阻塞「全部」歌单浏览；用户可重试或直接搜索。
    }
  }

  /// 重试 / 切换筛选条件：使在途请求过期后重新加载首屏。
  Future<void> _reload() async {
    _paged.reset();
    await _paged.loadFirstPage();
  }

  void _selectTag(String tagId) {
    if (_selectedTag == tagId) return;
    setState(() => _selectedTag = tagId);
    _reload();
  }

  void _submitSearch(String value) {
    final query = value.trim();
    if (query == _query) return;
    setState(() => _query = query);
    _reload();
  }

  void _clearSearch() {
    _searchController.clear();
    if (_query.isEmpty) return;
    setState(() => _query = '');
    _reload();
  }

  void _openPlaylist(DiscoverPlaylist playlist) {
    HapticsService.lightImpact();
    final provider = _provider;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiscoverTracksPage(
          title: playlist.name,
          coverUrl: playlist.coverUrl,
          importable: true,
          loader: (page) => provider.loadPlaylistDetail(playlist.id, page),
        ),
      ),
    );
  }

  Future<void> _openLinkDialog() async {
    final l10n = _l10n(context);
    final controller = TextEditingController();
    final input = await M3EDialog.show<String>(
      context,
      dialog: M3EDialog(
        title: l10n.discoverOpenPlaylist,
        content: M3ETextField(
          controller: controller,
          placeholder: l10n.discoverOpenPlaylistHint,
          autofocus: true,
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(l10n.discoverOpen),
          ),
        ],
      ),
    );
    if (!mounted || input == null || input.isEmpty) return;
    final provider = _provider;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiscoverTracksPage(
          title: l10n.discoverOpenPlaylist,
          importable: true,
          loader: (page) => provider.loadPlaylistDetail(input, page),
        ),
      ),
    );
  }

  Future<void> _showAllTags() async {
    final l10n = _l10n(context);
    final selected = await M3EBottomSheet.show<String>(
      context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
              child: Text(
                l10n.discoverAllTags,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                children: [
                  for (final category in _tagCategories) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Text(
                        category.name,
                        style: Theme.of(sheetContext).textTheme.titleSmall,
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final tag in category.tags)
                          M3EChip(
                            type: M3EChipType.filter,
                            label: tag.name,
                            selected: _selectedTag == tag.id,
                            onPressed: () =>
                                Navigator.of(sheetContext).pop(tag.id),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (selected != null) _selectTag(selected);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 可见性门控：隐藏的常驻 tab 不订阅（见 ShellPageVisibility）。
    final provider = ShellPageVisibility.maybeVisibleOf(context) ?? true
        ? context.watch<DiscoverProvider>()
        : context.read<DiscoverProvider>();
    // 渠道无发现能力时资料页会隐藏本 tab，这里兜底（切换渠道的瞬间）。
    if (!provider.hasDiscoverSource || !provider.supportsPlaylists) {
      return const SizedBox.shrink();
    }
    if (_loadedSourceKey != provider.channelKey) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureSourceLoaded());
    }
    return ValueListenableBuilder<PagedListState<DiscoverPlaylist>>(
      valueListenable: _paged,
      // 分页状态是不可变值：歌单区按最新快照重建（宿主注入的滚动控制器不变）。
      builder: (context, state, _) {
        final l10n = _l10n(context);
        final theme = Theme.of(context);
        return NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: Scrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            interactive: true,
            child: CustomScrollView(
              controller: _scrollController,
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: AppSearchBar(
                            controller: _searchController,
                            focusNode: _searchFocusNode,
                            hintText: l10n.discoverPlaylistSearchHint,
                            // 「打开歌单」也是「给一个歌单」的入口，放在搜索
                            // 行栏尾：入口跟随搜索行，不另占一行。
                            trailing: [
                              M3EIconButton(
                                variant: M3EIconButtonVariant.standard,
                                semanticLabel: l10n.discoverOpenPlaylist,
                                icon: const Icon(Icons.link_rounded),
                                onPressed: _openLinkDialog,
                              ),
                            ],
                            onChanged: (value) {
                              // 提交式搜索：仅当清空（清除键或手动删空）时回到全部歌单。
                              if (value.trim().isEmpty) _clearSearch();
                            },
                            onSubmitted: _submitSearch,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildTagChips(l10n),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
                ..._buildPlaylistSlivers(l10n, theme, state),
                const SliverToBoxAdapter(child: SizedBox(height: 32)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTagChips(AppLocalizations l10n) {
    if (_hotTags.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 40,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: M3EChipGroup(
          groupLabel: l10n.discoverHotTags,
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: M3EChip(
                  type: M3EChipType.filter,
                  label: l10n.discoverAll,
                  selected: _selectedTag.isEmpty,
                  onPressed: () => _selectTag(''),
                ),
              ),
              for (final tag in _hotTags)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: M3EChip(
                    type: M3EChipType.filter,
                    label: tag.name,
                    selected: _selectedTag == tag.id,
                    onPressed: () => _selectTag(tag.id),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: M3EChip(
                  label: l10n.discoverAllTags,
                  leading: const Icon(Icons.category_rounded, size: 18),
                  onPressed: _showAllTags,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildPlaylistSlivers(
    AppLocalizations l10n,
    ThemeData theme,
    PagedListState<DiscoverPlaylist> state,
  ) {
    final items = state.items;
    if (state.isLoading && items.isEmpty) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: M3ELoadingIndicator()),
          ),
        ),
      ];
    }
    if (state.failed) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.discoverLoadFailed,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                M3EIconButton(
                  key: const Key('discoverPlaylistsRetry'),
                  variant: M3EIconButtonVariant.standard,
                  icon: const Icon(Icons.refresh_rounded),
                  semanticLabel: l10n.discoverRetry,
                  onPressed: _reload,
                ),
              ],
            ),
          ),
        ),
      ];
    }
    if (items.isEmpty) {
      // 滚动内容里的空态版式：页面对齐的 16/16 外边距；主行动给能立刻
      // 脱困的动作（清搜索 / 回「全部」标签），无筛选时没有可执行动作。
      final searching = _query.isNotEmpty;
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: EmptyState(
              icon: searching
                  ? Icons.search_off_rounded
                  : Icons.queue_music_rounded,
              message: searching
                  ? l10n.discoverSearchEmpty
                  : l10n.discoverNoContent,
              action: searching || _selectedTag.isNotEmpty
                  ? M3EButton.text(
                      onPressed:
                          searching ? _clearSearch : () => _selectTag(''),
                      child: Text(
                        searching ? l10n.clearSearch : l10n.discoverAll,
                      ),
                    )
                  : null,
            ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverFixedExtentList.builder(
          // 固定行高（卡片 72 + 8 间距）：滚动条拇指与拖动定位精确。
          itemExtent: _playlistRowExtent,
          itemCount: items.length,
          itemBuilder: (context, index) =>
              _playlistCard(theme, l10n, items[index]),
        ),
      ),
      if (state.hasMore)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Center(
              child: M3EButton.icon(
                style: M3EButtonStyle.text,
                onPressed: state.isLoadingMore
                    ? null
                    : () => unawaited(_paged.loadMore()),
                icon: const Icon(Icons.expand_more_rounded),
                label: Text(l10n.discoverLoadMore),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _playlistCard(
    ThemeData theme,
    AppLocalizations l10n,
    DiscoverPlaylist playlist,
  ) {
    final subtitle = [
      if (playlist.author.isNotEmpty) playlist.author,
      if (playlist.trackCount > 0) l10n.playlistTrackCount(playlist.trackCount),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        height: 72,
        child: M3ECard(
          variant: M3ECardVariant.filled,
          onPressed: () => _openPlaylist(playlist),
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              LibraryCoverThumb(url: playlist.coverUrl, size: 56),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      playlist.name,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
