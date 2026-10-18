import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/ai_dj_provider.dart';
import '../providers/search_provider.dart';
import 'ai_dj_carousel.dart';
import 'app_search_bar.dart';
import 'search_section.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 发现页「搜索」tab：搜索框 + 搜索结果。
class LibrarySearchTab extends StatefulWidget {
  const LibrarySearchTab({super.key, this.controller});

  /// 结果列表滚动控制器（宿主页面注入：重复点击底栏资料库时回顶）；
  /// 为空时由 [SearchSection] 自建。
  final ScrollController? controller;

  @override
  State<LibrarySearchTab> createState() => _LibrarySearchTabState();
}

class _LibrarySearchTabState extends State<LibrarySearchTab>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final searchProvider = Provider.of<SearchProvider>(context, listen: false);
    _searchController.text = searchProvider.searchQuery;
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final searchProvider = Provider.of<SearchProvider>(context, listen: false);
    // 仅在文本真正变化时回写，避免与 provider 形成回环
    if (_searchController.text != searchProvider.searchQuery) {
      searchProvider.updateSearchQuery(_searchController.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 拆分 Consumer 监听，提高性能
    return Consumer<SearchProvider>(
      builder: (context, searchProvider, child) {
        final isSearchActive = searchProvider.isSearchActive;

        // AI 推歌开启时，下方空占位让位给推荐流（推荐流自身有引导卡 / 骨架 /
        // 错误卡）；关闭时保留「输入关键词搜索歌曲」占位。
        final aiDjEnabled = context.select<AiDjProvider?, bool>(
          (provider) => provider?.enabled ?? false,
        );

        // provider 清空搜索时同步清空输入框（须等构建结束再动控制器）
        if (!isSearchActive && _searchController.text.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _searchController.clear();
          });
        }

        return Column(
          children: [
            Padding(
              // 横向边距由搜索栏自己管（16 → 聚焦 12 弹性展开），这里只留纵向。
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: AppSearchBar(
                controller: _searchController,
                focusNode: _searchFocusNode,
                hintText: _l10n(context).searchHint,
                margin: 16,
                focusedMargin: 12,
                expandOnFocus: true,
                onSubmitted: (value) {
                  searchProvider.submitSearch(value);
                  _searchFocusNode.unfocus();
                },
              ),
            ),
            // 浏览态：AI 推歌推荐流（搜索激活时让位给结果区）。
            if (!isSearchActive) const AiDjCarousel(),
            Expanded(
              child: RepaintBoundary(
                child: isSearchActive
                    ? SearchSection(controller: widget.controller)
                    : (aiDjEnabled
                        ? const SizedBox.shrink()
                        : _buildIdle(context)),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 未搜索时的空态：提示输入关键词。
  Widget _buildIdle(BuildContext context) {
    final l10n = _l10n(context);
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_rounded,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              l10n.searchIdleHint,
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
}
