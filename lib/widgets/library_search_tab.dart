import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/ai_dj_provider.dart';
import '../providers/discover_provider.dart';
import '../providers/search_assist_controller.dart';
import '../providers/search_provider.dart';
import '../theme/motion_policy.dart';
import 'adaptive_layout.dart';
import 'ai_dj_carousel.dart';
import 'channel_search_bar.dart';
import 'cross_fade_swap.dart';
import 'discover_layout.dart';
import 'empty_state.dart';
import 'search_assist_panel.dart';
import 'search_section.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 发现页「搜索」tab：搜索框 + 搜索结果。
class LibrarySearchTab extends StatefulWidget {
  const LibrarySearchTab({super.key, this.controller, this.focusNode});

  /// 结果列表滚动控制器（宿主页面注入：重复点击底栏资料库时回顶）；
  /// 为空时由 [SearchSection] 自建。
  final ScrollController? controller;

  /// 搜索输入框焦点节点（宿主页面注入：重复点击「资料库」时聚焦搜索框）。
  ///
  /// 为空时自建；注入时生命周期归宿主，本组件只负责监听焦点。
  final FocusNode? focusNode;

  @override
  State<LibrarySearchTab> createState() => _LibrarySearchTabState();
}

class _LibrarySearchTabState extends State<LibrarySearchTab>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _searchController = TextEditingController();
  late final FocusNode _searchFocusNode;
  late final bool _ownsSearchFocusNode;
  late final SearchInputBinding _searchInput;
  late final SearchProvider _searchProvider;
  late final SearchAssistController _assist;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _ownsSearchFocusNode = widget.focusNode == null;
    _searchFocusNode =
        widget.focusNode ?? FocusNode(debugLabel: 'librarySearchField');
    _searchProvider = Provider.of<SearchProvider>(context, listen: false);
    _searchInput = SearchInputBinding(
      session: _searchProvider.session,
      controller: _searchController,
    );
    _assist = SearchAssistController(
      search: _searchProvider,
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
    if (_ownsSearchFocusNode) _searchFocusNode.dispose();
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
    // Consumer 只订阅搜索会话；AI 开关与 gutter 用 select 单独订阅，避免整页跟随重建。
    return Consumer<SearchProvider>(
      builder: (context, searchProvider, child) {
        final session = searchProvider.session;
        final isSearchActive = session.isActive;

        // AI 推歌开启时，下方空占位让位给推荐流（推荐流自身有引导卡 / 骨架 /
        // 错误卡）；关闭时保留「输入关键词搜索歌曲」占位。
        final aiDjEnabled = context.select<AiDjProvider?, bool>(
          (provider) => provider?.enabled ?? false,
        );
        // 短横屏（手机横屏）纵向只够「搜索条 + 结果」：AI 推歌轮播固定
        // 198 高，连头带间距 ~256，塞进来会把搜索页挤爆；此时不渲染轮播，
        // AI 内容仍可从 AI 推歌页进入。
        final shortViewport = AdaptiveLayoutScope.of(context).isShortViewport;
        final gutter = discoverGutterOf(context);

        return Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _handleKey,
          child: Column(
            children: [
              Padding(
                // 与内容栏同一 gutter；条内不再放渠道控件（页面顶部已有
                // 唯一渠道选择），搜索 tab 与 Ctrl+F 共用同一条胶囊。
                padding: EdgeInsets.fromLTRB(
                  gutter,
                  discoverPageTopPadding,
                  gutter,
                  discoverSectionGap,
                ),
                child: ChannelSearchBar(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  hintText: _l10n(context).searchHint,
                  // 无 chip 变体：胶囊 / 高度 / 清除键 / 焦点环与 Ctrl+F 同源，
                  // 渠道控件留在页面顶部，搜索 tab 切来切去不会多出一个入口。
                  showChannelChip: false,
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
              // 浏览态：AI 推歌推荐流（搜索激活时让位给结果区；短横屏不渲染，
              // 见上方 shortViewport 的纵向预算说明）。
              //
              // 用 AnimatedSize 收起而不是直接拔掉：轮播占 198 + 间距，搜索激活
              // 时整块突然消失会让下方输入区向上跳约 256dp。减弱动效时
              // `effectDurationOf` 归零，等价于原来的硬切。
              if (!shortViewport)
                AnimatedSize(
                  duration: effectDurationOf(context, M3EMotion.short4),
                  curve: M3EMotion.emphasized,
                  alignment: Alignment.topCenter,
                  clipBehavior: Clip.hardEdge,
                  child: isSearchActive
                      ? const SizedBox(width: double.infinity)
                      : const AiDjCarousel(),
                ),
              Expanded(
                child: RepaintBoundary(
                  // 浏览态 ↔ 结果态是整块内容换身份：CrossFadeSwap 保留旧层
                  // 做离场，不会出现中间一帧空白。
                  child: CrossFadeSwap(
                    value: isSearchActive,
                    child: isSearchActive
                        ? SearchSection(
                            controller: widget.controller,
                            assist: _assist,
                          )
                        : (aiDjEnabled && !shortViewport
                              ? const SizedBox.shrink()
                              : _buildIdle(context)),
                  ),
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
