import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/discover.dart';
import '../l10n/app_localizations.dart';
import '../pages/discover_tracks_page.dart';
import '../providers/discover_provider.dart';
import '../providers/paged_list_controller.dart';
import 'library_cover.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 资料页「歌单」tab：平台选择 + 歌单搜索 / 标签筛选 / 歌单列表（分页）。
class DiscoverPlaylistsTab extends StatefulWidget {
  const DiscoverPlaylistsTab({super.key});

  @override
  State<DiscoverPlaylistsTab> createState() => _DiscoverPlaylistsTabState();
}

class _DiscoverPlaylistsTabState extends State<DiscoverPlaylistsTab>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  List<DiscoverTag> _hotTags = const [];
  List<DiscoverTagCategory> _tagCategories = const [];

  String _selectedTag = '';
  String _query = '';
  late final PagedListController<DiscoverPlaylist> _paged;

  /// 当前已加载数据的平台（切换平台时重置并重载）。
  String? _loadedSourceKey;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _paged = PagedListController<DiscoverPlaylist>(
      fetchPage: _fetchPlaylistPage,
      keyOf: (playlist) => playlist.id,
    )..addListener(_onPagedChanged);
    if (kIsWeb) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureSourceLoaded());
  }

  void _onPagedChanged() {
    if (mounted) setState(() {});
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
    _paged.removeListener(_onPagedChanged);
    _paged.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
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

  /// 从歌单列表直接导入：拉取详情并存入本地同名列表。
  Future<void> _importPlaylist(DiscoverPlaylist playlist) async {
    final l10n = _l10n(context);
    try {
      final detail = await _provider.loadPlaylistDetail(playlist.id, 1);
      if (!mounted) return;
      final result = await _provider.importDetailToLibrary(
        detail,
        fallbackName: playlist.name,
      );
      if (!mounted) return;
      if (result.total == 0) {
        M3ESnackbar.show(context, message: l10n.playlistImportEmpty);
        return;
      }
      M3ESnackbar.show(
        context,
        message: result.added > 0
            ? l10n.libraryImportSuccess(result.added)
            : l10n.playlistAlreadyContains,
      );
    } on DiscoverFailure {
      if (!mounted) return;
      M3ESnackbar.show(context, message: l10n.discoverLoadFailed);
    } catch (_) {
      if (!mounted) return;
      M3ESnackbar.show(context, message: l10n.discoverLoadFailed);
    }
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
    HapticFeedback.lightImpact();
    final provider = _provider;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiscoverTracksPage(
          title: playlist.name,
          coverUrl: playlist.coverUrl,
          importable: true,
          loader: () => provider.loadPlaylistDetail(playlist.id, 1),
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
          loader: () => provider.loadPlaylistDetail(input, 1),
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
    if (kIsWeb) return const SizedBox.shrink();
    final provider = context.watch<DiscoverProvider>();
    // 渠道无发现能力时资料页会隐藏本 tab，这里兜底（切换渠道的瞬间）。
    if (!provider.hasDiscoverSource || !provider.supportsPlaylists) {
      return const SizedBox.shrink();
    }
    if (_loadedSourceKey != provider.channelKey) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureSourceLoaded());
    }
    final l10n = _l10n(context);
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 12, bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 歌单（搜索 / 链接打开）
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.queue_music_rounded,
                    size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.discoverPlaylists,
                    // 标题用正文色，强调色只给图标。
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: theme.colorScheme.onSurface),
                  ),
                ),
                M3EIconButton(
                  variant: M3EIconButtonVariant.standard,
                  tooltip: l10n.discoverOpenPlaylist,
                  icon: const Icon(Icons.link_rounded),
                  onPressed: _openLinkDialog,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: M3ETextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              placeholder: l10n.discoverPlaylistSearchHint,
              leading: const Icon(Icons.search_rounded),
              trailing: _searchController.text.isNotEmpty
                  ? M3EIconButton(
                      variant: M3EIconButtonVariant.standard,
                      icon: const Icon(Icons.clear_rounded),
                      tooltip: l10n.clearSearch,
                      onPressed: _clearSearch,
                    )
                  : null,
              onChanged: (_) => setState(() {}),
              onSubmitted: _submitSearch,
              textInputAction: TextInputAction.search,
            ),
          ),
          const SizedBox(height: 8),
          _buildTagChips(l10n),
          const SizedBox(height: 8),
          _buildPlaylistArea(l10n, theme),
        ],
      ),
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

  Widget _buildPlaylistArea(AppLocalizations l10n, ThemeData theme) {
    final items = _paged.items;
    if (_paged.isLoading && items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: M3ELoadingIndicator()),
      );
    }
    if (_paged.failed) {
      return Padding(
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
            M3EButton.text(
              onPressed: _reload,
              child: Text(l10n.discoverRetry),
            ),
          ],
        ),
      );
    }
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Text(
          _query.isEmpty ? l10n.discoverNoContent : l10n.discoverSearchEmpty,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (final playlist in items)
            _playlistCard(theme, l10n, playlist),
          if (_paged.hasMore)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: M3EButton.text(
                onPressed: _paged.isLoadingMore ? null : _paged.loadMore,
                child: Text(l10n.discoverLoadMore),
              ),
            ),
        ],
      ),
    );
  }

  Widget _playlistCard(
    ThemeData theme,
    AppLocalizations l10n,
    DiscoverPlaylist playlist,
  ) {
    final subtitle = [
      if (playlist.author.isNotEmpty) playlist.author,
      if (playlist.trackCount > 0)
        l10n.playlistTrackCount(playlist.trackCount),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
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
                children: [
                  Text(
                    playlist.name,
                    style: theme.textTheme.titleSmall,
                    maxLines: 2,
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
            M3EIconButton(
              variant: M3EIconButtonVariant.standard,
              tooltip: l10n.playlistImportToMine,
              icon: const Icon(Icons.download_rounded),
              onPressed: () => unawaited(_importPlaylist(playlist)),
            ),
            Icon(Icons.chevron_right_rounded,
                color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
