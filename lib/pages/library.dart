import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/source.dart' show SourceDescriptor;
import '../l10n/app_localizations.dart';
import '../providers/discover_provider.dart';
import '../providers/search_provider.dart';
import '../providers/sources_provider.dart';
import '../utils/responsive.dart';
import '../utils/scroll_to_top.dart';
import '../widgets/discover_layout.dart';
import '../widgets/discover_leaderboards_tab.dart';
import '../widgets/discover_playlists_tab.dart';
import '../widgets/empty_state.dart';
import '../widgets/library_channel_selector.dart';
import '../widgets/library_search_tab.dart';
import '../widgets/shell_page_visibility.dart';
import '../widgets/settings/settings_sheet.dart';
import '../widgets/shell_reselect.dart';

/// 发现页 tab 标识（可见性随当前渠道能力变化，不用下标表示）。
enum _LibraryTab { search, leaderboards, playlists }

/// 资料库页：
/// - 「搜索 / 热榜 / 歌单」三个 tab；全局只有一个当前渠道；
/// - 顶部渠道下拉在所有 tab（含搜索）左侧常显，同时决定热榜 / 歌单与搜索；
/// - 当前渠道不支持搜索时隐藏搜索 tab；热榜 / 歌单按渠道能力隐藏；
/// - 个人内容（播放历史 / 我的列表 / 导入收藏）在收藏页。
class Library extends StatefulWidget {
  const Library({super.key, this.reselect, this.showSearchRequest});

  /// 壳层「重复点击底栏 / 导航轨资料库目的地」的请求通道：
  /// 当前渲染 tab 的列表回到顶部。
  final ShellReselectSignal? reselect;

  /// 壳层「顶栏全局搜索要看全部结果」的请求通道：切到搜索 tab 并回到顶部。
  ///
  /// 为什么需要：搜索结果与「热榜 / 歌单」是同一页的三个 tab，顶栏只切目的地
  /// 时页面会停在用户上次停留的 tab（可能看不到刚搜的结果）。
  final ShellReselectSignal? showSearchRequest;

  @override
  State<Library> createState() => _LibraryState();
}

class _LibraryState extends State<Library> {
  /// 用户选中的 tab（默认搜索）；隐藏是临时的，不覆盖该意图。
  _LibraryTab _tab = _LibraryTab.search;

  /// 当前渲染的 tab（选中项被隐藏时是第一个可见 tab）：重复点击回顶按它取列表。
  /// build 期写入，不触发重建。
  _LibraryTab _renderedTab = _LibraryTab.search;

  /// 各 tab 列表的滚动控制器。由页面持有（重复点击资料库要按当前 tab 回顶），
  /// 下传给 tab 子组件；子组件在未注入时仍可自建（独立挂载 / 测试）。
  final ScrollController _searchResultsController = ScrollController();
  final ScrollController _leaderboardsController = ScrollController();
  final ScrollController _playlistsController = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.reselect?.addListener(_handleReselect);
    widget.showSearchRequest?.addListener(_handleShowSearchRequest);
  }

  @override
  void didUpdateWidget(covariant Library oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reselect != widget.reselect) {
      oldWidget.reselect?.removeListener(_handleReselect);
      widget.reselect?.addListener(_handleReselect);
    }
    if (oldWidget.showSearchRequest != widget.showSearchRequest) {
      oldWidget.showSearchRequest?.removeListener(_handleShowSearchRequest);
      widget.showSearchRequest?.addListener(_handleShowSearchRequest);
    }
  }

  /// 顶栏搜索「查看全部结果」：切到搜索 tab（用户意图明确），并回到列表顶部。
  void _handleShowSearchRequest() {
    if (_tab != _LibraryTab.search) {
      setState(() => _tab = _LibraryTab.search);
    }
    animateScrollToTop(_searchResultsController);
  }

  @override
  void dispose() {
    widget.reselect?.removeListener(_handleReselect);
    widget.showSearchRequest?.removeListener(_handleShowSearchRequest);
    _searchResultsController.dispose();
    _leaderboardsController.dispose();
    _playlistsController.dispose();
    super.dispose();
  }

  /// 壳层重复点击「资料库」目的地：当前渲染 tab 的列表回到顶部
  /// （列表未挂载 / 已在顶部 = 空操作）。
  void _handleReselect() {
    animateScrollToTop(switch (_renderedTab) {
      _LibraryTab.search => _searchResultsController,
      _LibraryTab.leaderboards => _leaderboardsController,
      _LibraryTab.playlists => _playlistsController,
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 可见性门控：资料页在壳层常驻，隐藏时放弃订阅（见 ShellPageVisibility）。
    final visible = ShellPageVisibility.maybeVisibleOf(context) ?? true;
    final sources = visible
        ? context.watch<SourcesProvider>()
        : context.read<SourcesProvider>();
    final discover = visible
        ? context.watch<DiscoverProvider>()
        : context.read<DiscoverProvider>();
    final search = visible
        ? context.watch<SearchProvider>()
        : context.read<SearchProvider>();

    // 仅启用项可被选中/展示；停用项保留在「音源管理」页以便再次启用。
    final enabledChannels = [
      for (final entry in sources.channels)
        if (entry.enabled) entry,
    ];

    SourceDescriptor? current;
    for (final entry in enabledChannels) {
      if (entry.key == discover.channelKey) {
        current = entry;
        break;
      }
    }

    // 渠道失效（被停用 / 脚本删除）时校正；音源尚未初始化 / 脚本仍在激活时，
    // 保存的脚本渠道暂时不在 enabledChannels 里：此时不能 fallback，否则会
    // 覆盖用户偏好。
    final needsFallback =
        current == null &&
        enabledChannels.isNotEmpty &&
        sources.initialized &&
        !sources.isActivating;
    if (needsFallback) {
      final target = enabledChannels.first;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.read<DiscoverProvider>().selectChannel(target.key);
      });
    }

    // 全部渠道停用：没有任何可展示的渠道，保留原来的设置引导。
    if (enabledChannels.isEmpty) {
      return ResponsivePageContainer(
        pageType: ResponsivePageType.browse,
        // 发现页全宽自适应：不再受 browse 的 1600 桌面上限约束。
        maxWidth: double.infinity,
        alignment: Alignment.topCenter,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: EmptyState(
              icon: Icons.source_rounded,
              message: l10n.libraryNoChannels,
              action: M3EButton.text(
                onPressed: () => showSettingsSheet(context),
                child: Text(l10n.settingsTitle),
              ),
            ),
          ),
        ),
      );
    }

    // 资料页独立挂载 / 测试时也把当前渠道同步给搜索：全局只允许一个渠道，
    // 不依赖组合根是否已接线。切换渠道在 _selectChannel 里同步调用。
    final currentKey = current?.key;
    if (currentKey != null && search.activeSourceKey != currentKey) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.read<SearchProvider>().setActiveSource(currentKey);
      });
    }

    // 当前渠道对应的发现能力（渠道不匹配时按降级处理，避免闪现旧渠道数据）。
    final discoverActive =
        current != null &&
        current.discoverable &&
        discover.channelKey == current.key;
    final visibleTabs = <_LibraryTab>[
      // 搜索 tab 跟随当前渠道：渠道不支持搜索就隐藏（Ctrl+F 仍可打开）。
      if (current != null && current.capabilities.search) _LibraryTab.search,
      if (discoverActive && discover.supportsLeaderboards)
        _LibraryTab.leaderboards,
      if (discoverActive && discover.supportsPlaylists) _LibraryTab.playlists,
    ];

    // 顶部工具行与三个 tab 共用页边距：渠道下拉、tab、搜索栏和内容栏
    // 都从同一条 gutter 起排。
    final gutter = discoverGutterOf(context);
    final multiChannel = enabledChannels.length >= 2;
    final showTabBar = visibleTabs.length >= 2;
    final selectedIndex = _indexOf(visibleTabs);

    if (visibleTabs.isEmpty) {
      // 当前渠道既不能搜索也没有发现内容：顶部渠道下拉仍保留（可切到其它
      // 渠道），正文只提示当前渠道没有内容，不误报「所有渠道都已停用」。
      return ResponsivePageContainer(
        pageType: ResponsivePageType.browse,
        // 发现页全宽自适应：不再受 browse 的 1600 桌面上限约束。
        maxWidth: double.infinity,
        alignment: Alignment.topCenter,
        child: Column(
          children: [
            _topBar(
              l10n: l10n,
              channels: sources.channels,
              selectedKey: discover.channelKey,
              visibleTabs: const [],
              selectedIndex: 0,
              multiChannel: multiChannel,
              showTabBar: false,
              gutter: gutter,
              onSelected: (key) => _selectChannel(key, enabledChannels),
            ),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: EmptyState(
                    icon: Icons.explore_off_rounded,
                    message: l10n.discoverChannelUnavailable,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final renderedTab = visibleTabs[selectedIndex];
    // 布局期写入（不触发重建）：重复点击回顶要滚「真正在渲染」的那个列表。
    _renderedTab = renderedTab;

    return ResponsivePageContainer(
      pageType: ResponsivePageType.browse,
      // 发现页全宽自适应：不再受 browse 的 1600 桌面上限约束。
      maxWidth: double.infinity,
      alignment: Alignment.topCenter,
      child: Column(
        children: [
          _topBar(
            l10n: l10n,
            channels: sources.channels,
            selectedKey: discover.channelKey,
            visibleTabs: visibleTabs,
            selectedIndex: selectedIndex,
            multiChannel: multiChannel,
            showTabBar: showTabBar,
            gutter: gutter,
            onSelected: (key) => _selectChannel(key, enabledChannels),
          ),
          Expanded(
            child: showTabBar
                ? M3ETabsView(
                    selectedIndex: selectedIndex,
                    onTabSelected: (index) =>
                        setState(() => _tab = visibleTabs[index]),
                    children: [
                      for (final tab in visibleTabs)
                        KeyedSubtree(
                          key: ValueKey(tab),
                          child: _tabContent(tab),
                        ),
                    ],
                  )
                : _tabContent(visibleTabs.first),
          ),
        ],
      ),
    );
  }

  /// 顶部工具行：渠道下拉在所有 tab（含搜索）左侧常显，tab 在右。
  ///
  /// 渠道只有 1 个时下拉框不渲染（[LibraryChannelSelector] 自己返回空盒），
  /// 单行布局保持不变。
  Widget _topBar({
    required AppLocalizations l10n,
    required List<SourceDescriptor> channels,
    required String selectedKey,
    required List<_LibraryTab> visibleTabs,
    required int selectedIndex,
    required bool multiChannel,
    required bool showTabBar,
    required double gutter,
    required ValueChanged<String> onSelected,
  }) {
    final hasTopBar = multiChannel || showTabBar;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        hasTopBar ? 8 : 0,
        gutter,
        hasTopBar ? 4 : 0,
      ),
      child: Row(
        children: [
          LibraryChannelSelector(
            channels: channels,
            selectedKey: selectedKey,
            onSelected: onSelected,
          ),
          if (showTabBar) ...[
            if (multiChannel) const SizedBox(width: 12),
            Expanded(
              child: M3ETabs(
                // 次 tab：图标在文案左侧同一行、行高 48；渠道下拉框与
                // 内容页共用这一行分组切换（不是顶层导航）。
                variant: M3ETabsVariant.secondary,
                // 触摸端等分铺满剩余宽；桌面按自然宽度靠左排列，
                // 不把三个 tab 拉成三块大留白。
                alignment: isDesktopPlatform()
                    ? M3ETabsAlignment.leading
                    : M3ETabsAlignment.fill,
                tabs: [for (final tab in visibleTabs) _tabSpec(l10n, tab)],
                selectedIndex: selectedIndex,
                onTabSelected: (index) =>
                    setState(() => _tab = visibleTabs[index]),
              ),
            ),
          ] else if (multiChannel)
            const Spacer(),
        ],
      ),
    );
  }

  /// 选中 tab 在可见列表中的下标。
  ///
  /// 用户选中的 tab 被隐藏时先渲染第一个可见 tab，但**不覆盖用户意图**：
  /// 隐藏多是临时的（脚本尚未加载完 / 切到无搜索能力的渠道），条件恢复后
  /// 仍回到选中的 tab（默认「搜索」）。
  int _indexOf(List<_LibraryTab> visibleTabs) {
    final index = visibleTabs.indexOf(_tab);
    return index >= 0 ? index : 0;
  }

  void _selectChannel(String key, List<SourceDescriptor> enabledChannels) {
    SourceDescriptor? entry;
    for (final candidate in enabledChannels) {
      if (candidate.key == key) {
        entry = candidate;
        break;
      }
    }
    if (entry == null) return;
    // 全局只有一个当前渠道：发现内容与搜索一起切；搜索侧会清空旧结果并按
    // 当前关键词在新渠道重搜（不支持搜索的渠道只清空，由空态兜底）。
    context.read<DiscoverProvider>().selectChannel(entry.key);
    context.read<SearchProvider>().setActiveSource(entry.key);
  }

  Widget _tabContent(_LibraryTab tab) => switch (tab) {
    _LibraryTab.search => LibrarySearchTab(
      controller: _searchResultsController,
    ),
    _LibraryTab.leaderboards => DiscoverLeaderboardsTab(
      controller: _leaderboardsController,
    ),
    _LibraryTab.playlists => DiscoverPlaylistsTab(
      controller: _playlistsController,
    ),
  };

  M3ETab _tabSpec(AppLocalizations l10n, _LibraryTab tab) => switch (tab) {
    _LibraryTab.search => _buildTab(
      icon: Icons.search_rounded,
      label: l10n.libraryTabSearch,
    ),
    _LibraryTab.leaderboards => _buildTab(
      icon: Icons.leaderboard_rounded,
      label: l10n.libraryTabLeaderboards,
    ),
    _LibraryTab.playlists => _buildTab(
      icon: Icons.queue_music_rounded,
      label: l10n.libraryTabPlaylists,
    ),
  };

  /// 单个 tab：桌面端图标 + 文案，触摸端只留图标（文案走无障碍名）。
  ///
  /// 触摸端去掉文案：窄屏上「渠道下拉框 + 三 tab」挤在一行，文案会被压到
  /// 逐字换行 / 截断；桌面窗口富余、文案与图标同行也更有可读性，保持原样。
  M3ETab _buildTab({required IconData icon, required String label}) {
    final showLabel = isDesktopPlatform();
    return M3ETab(
      icon: Icon(icon),
      label: showLabel ? label : null,
      semanticLabel: label,
    );
  }
}
