import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/source_script.dart';
import '../l10n/app_localizations.dart';
import '../providers/discover_provider.dart';
import '../providers/search_provider.dart';
import '../providers/sources_provider.dart';
import '../utils/responsive.dart';
import '../widgets/discover_leaderboards_tab.dart';
import '../widgets/discover_playlists_tab.dart';
import '../widgets/library_channel_selector.dart';
import '../widgets/library_search_tab.dart';

/// 发现页 tab 标识（可见性随当前渠道能力变化，不用下标表示）。
enum _LibraryTab { search, leaderboards, playlists }

/// 发现页（内置平台发现）：
/// - 顶部为统一渠道下拉框 +「搜索 / 热榜 / 歌单」三个 tab；
/// - 渠道集合 = 可搜索源 + 内置发现平台并集（顺序/启停在「音源管理」页维护），
///   搜索、热榜、歌单全部跟随同一个渠道；
/// - 渠道不支持某个 tab 时自动隐藏（脚本扩展源 / any-listen 无热榜/歌单；
///   无脚本时内置平台不可搜索）；
/// - 个人内容（播放历史 / 我的列表 / 导入收藏夹）在收藏页。
class Library extends StatefulWidget {
  const Library({super.key});

  @override
  State<Library> createState() => _LibraryState();
}

class _LibraryState extends State<Library> {
  /// 用户选中的 tab（默认搜索）；隐藏是临时的，不覆盖该意图。
  _LibraryTab _tab = _LibraryTab.search;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Web 不支持音源，仅保留搜索（无渠道选择）。
    if (kIsWeb) {
      return ResponsivePageContainer(
        pageType: ResponsivePageType.browse,
        alignment: Alignment.topCenter,
        child: const LibrarySearchTab(),
      );
    }

    final sources = context.watch<SourcesProvider>();
    final discover = context.watch<DiscoverProvider>();
    final search = context.watch<SearchProvider>();

    // 仅启用项可被选中/展示；停用项保留在「音源管理」页以便再次启用。
    final enabledChannels = [
      for (final entry in sources.channels)
        if (entry.enabled) entry,
    ];

    SourceEntry? current;
    for (final entry in enabledChannels) {
      if (entry.key == discover.channelKey) {
        current = entry;
        break;
      }
    }

    // 渠道失效（被停用 / 脚本删除）或初始搜索源与渠道不一致时校正。
    // 在 post-frame 执行，避免在 build 中修改 provider 状态。
    final needsFallback = current == null && enabledChannels.isNotEmpty;
    final needsSearchSync = current != null &&
        current.canSearch &&
        search.sourceKey != current.key;
    if (needsFallback || needsSearchSync) {
      final target = needsFallback ? enabledChannels.first : current!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (needsFallback) {
          context.read<DiscoverProvider>().selectChannel(target.key);
        }
        if (target.canSearch) {
          context.read<SearchProvider>().selectSource(target.key);
        }
      });
    }

    // 当前渠道对应的发现能力（渠道不匹配时按降级处理，避免闪现旧渠道数据）。
    final discoverActive = current != null &&
        current.discoverable &&
        discover.channelKey == current.key;
    final visibleTabs = <_LibraryTab>[
      if (current != null && current.canSearch) _LibraryTab.search,
      if (discoverActive && discover.supportsLeaderboards)
        _LibraryTab.leaderboards,
      if (discoverActive && discover.supportsPlaylists) _LibraryTab.playlists,
    ];

    if (visibleTabs.isEmpty) {
      return ResponsivePageContainer(
        pageType: ResponsivePageType.browse,
        alignment: Alignment.topCenter,
        child: _buildEmptyState(l10n),
      );
    }

    final selectedIndex = _indexOf(visibleTabs);

    return ResponsivePageContainer(
      pageType: ResponsivePageType.browse,
      alignment: Alignment.topCenter,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                LibraryChannelSelector(
                  channels: sources.channels,
                  selectedKey: discover.channelKey,
                  onSelected: (key) => _selectChannel(key, enabledChannels),
                ),
                if (visibleTabs.length >= 2) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: M3ETabs(
                      tabs: [for (final tab in visibleTabs) _tabSpec(l10n, tab)],
                      selectedIndex: selectedIndex,
                      onTabSelected: (index) =>
                          setState(() => _tab = visibleTabs[index]),
                    ),
                  ),
                ] else
                  const Spacer(),
              ],
            ),
          ),
          Expanded(
            child: visibleTabs.length >= 2
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

  /// 选中 tab 在可见列表中的下标。
  ///
  /// 用户选中的 tab 被隐藏时先渲染第一个可见 tab，但**不覆盖用户意图**：
  /// 隐藏多是临时的（脚本尚未加载完 / 切到无搜索能力的渠道），条件恢复后
  /// 仍回到选中的 tab（默认「搜索」）。
  int _indexOf(List<_LibraryTab> visibleTabs) {
    final index = visibleTabs.indexOf(_tab);
    return index >= 0 ? index : 0;
  }

  void _selectChannel(String key, List<SourceEntry> enabledChannels) {
    SourceEntry? entry;
    for (final candidate in enabledChannels) {
      if (candidate.key == key) {
        entry = candidate;
        break;
      }
    }
    if (entry == null) return;
    context.read<DiscoverProvider>().selectChannel(entry.key);
    if (entry.canSearch) {
      context.read<SearchProvider>().selectSource(entry.key);
    }
  }

  Widget _tabContent(_LibraryTab tab) => switch (tab) {
        _LibraryTab.search => const LibrarySearchTab(),
        _LibraryTab.leaderboards => const DiscoverLeaderboardsTab(),
        _LibraryTab.playlists => const DiscoverPlaylistsTab(),
      };

  M3ETab _tabSpec(AppLocalizations l10n, _LibraryTab tab) => switch (tab) {
        _LibraryTab.search => M3ETab(
            icon: const Icon(Icons.search_rounded),
            label: l10n.libraryTabSearch,
          ),
        _LibraryTab.leaderboards => M3ETab(
            icon: const Icon(Icons.leaderboard_rounded),
            label: l10n.libraryTabLeaderboards,
          ),
        _LibraryTab.playlists => M3ETab(
            icon: const Icon(Icons.queue_music_rounded),
            label: l10n.libraryTabPlaylists,
          ),
      };

  Widget _buildEmptyState(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.source_rounded,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              l10n.libraryNoChannels,
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
