import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/search_provider.dart';
import 'search_section.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 发现页「搜索」tab：搜索框 + 搜索结果。
class LibrarySearchTab extends StatefulWidget {
  const LibrarySearchTab({super.key});

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
    // Add listener to sync text field with provider state
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
    // Only update provider if text actually changed to avoid loops
    if (_searchController.text != searchProvider.searchQuery) {
      searchProvider.updateSearchQuery(_searchController.text);
    }
  }

  void _clearSearch(SearchProvider searchProvider) {
    HapticFeedback.lightImpact();
    _searchController.clear();
    searchProvider.clearSearch();
    _searchFocusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 拆分 Consumer 监听，提高性能
    return Consumer<SearchProvider>(
      builder: (context, searchProvider, child) {
        final isSearchActive = searchProvider.isSearchActive;

        // Sync controller if provider clears search
        if (!isSearchActive && _searchController.text.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _searchController.clear();
          });
        }

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: M3ETextField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                placeholder: _l10n(context).searchHint,
                leading: const Icon(Icons.search_rounded),
                trailing: _searchController.text.isNotEmpty
                    ? M3EIconButton(
                        variant: M3EIconButtonVariant.standard,
                        icon: const Icon(Icons.clear_rounded),
                        tooltip: _l10n(context).clearSearch,
                        onPressed: () => _clearSearch(searchProvider),
                      )
                    : null,
                onChanged: (value) {
                  setState(() {});
                },
                onSubmitted: (value) {
                  searchProvider.submitSearch(value);
                  _searchFocusNode.unfocus();
                },
                textInputAction: TextInputAction.search,
              ),
            ),
            Expanded(
              child: RepaintBoundary(
                child: isSearchActive
                    ? const SearchSection()
                    : _buildIdle(context),
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

