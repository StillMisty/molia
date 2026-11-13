import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/ai_dj_provider.dart';
import '../providers/discover_provider.dart';
import '../providers/search_assist_controller.dart';
import '../providers/search_provider.dart';
import '../services/search_history_store.dart';
import 'ai_dj_carousel.dart';
import 'app_search_bar.dart';
import 'discover_layout.dart';
import 'empty_state.dart';
import 'search_assist_panel.dart';
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
  late final SearchInputBinding _searchInput;
  late final SearchProvider _searchProvider;
  late final SearchAssistController _assist;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _searchProvider = Provider.of<SearchProvider>(context, listen: false);
    _searchInput = SearchInputBinding(
      session: _searchProvider.session,
      controller: _searchController,
    );
    _assist = SearchAssistController(
      search: _searchProvider,
      // 仓库生命周期归组合根（Provider 树），宿主只消费。
      history: context.read<SearchHistoryStore>(),
      hotKeywords: () =>
          context.read<DiscoverProvider?>()?.hotSearches ?? const [],
    );
    _searchFocusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() => _assist.setFocused(_searchFocusNode.hasFocus);

  @override
  void dispose() {
    _searchFocusNode.removeListener(_onFocusChanged);
    _assist.dispose();
    _searchInput.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// 辅助建议可见时接管 ↑↓ / Enter；结果面的键盘模型保持不变。
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_assist.value.showSuggestions) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _assist.moveHighlight(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _assist.moveHighlight(-1);
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        !_searchController.value.composing.isValid) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      if (_assist.selectHighlighted()) return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 拆分 Consumer 监听，提高性能
    return Consumer<SearchProvider>(
      builder: (context, searchProvider, child) {
        final session = searchProvider.session;
        final isSearchActive = session.isActive;

        // AI 推歌开启时，下方空占位让位给推荐流（推荐流自身有引导卡 / 骨架 /
        // 错误卡）；关闭时保留「输入关键词搜索歌曲」占位。
        final aiDjEnabled = context.select<AiDjProvider?, bool>(
          (provider) => provider?.enabled ?? false,
        );
        final gutter = discoverGutterOf(context);

        return Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _handleKey,
          child: Column(
            children: [
              Padding(
                // 搜索栏自己管横向边距：空闲时与内容栏同 gutter，聚焦时
                // 向两侧弹性展开 4px（保留原有手感），这里只留纵向。
                padding: const EdgeInsets.only(
                  top: discoverPageTopPadding,
                  bottom: discoverSectionGap,
                ),
                child: AppSearchBar(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  hintText: _l10n(context).searchHint,
                  constraints: discoverSearchBarConstraints(context),
                  margin: gutter,
                  focusedMargin: gutter > 4 ? gutter - 4 : 0,
                  expandOnFocus: true,
                  onSubmitted: (value) {
                    _searchProvider.submitSearch(value);
                    _searchFocusNode.unfocus();
                  },
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: gutter),
                child: SearchAssistPanel(controller: _assist),
              ),
              // 浏览态：AI 推歌推荐流（搜索激活时让位给结果区）。
              if (!isSearchActive) const AiDjCarousel(),
              Expanded(
                child: RepaintBoundary(
                  child: isSearchActive
                      ? SearchSection(
                          controller: widget.controller,
                          assist: _assist,
                        )
                      : (aiDjEnabled
                            ? const SizedBox.shrink()
                            : _buildIdle(context)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 未搜索时的空态：提示输入关键词（共享 EmptyState 配方）。
  Widget _buildIdle(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: EmptyState(
          icon: Icons.search_rounded,
          message: _l10n(context).searchIdleHint,
        ),
      ),
    );
  }
}
