import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/discover.dart';
import '../l10n/app_localizations.dart';
import '../pages/discover_tracks_page.dart';
import '../providers/discover_provider.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 资料页「热榜」tab：平台选择 + 榜单 chips（点击进入榜单曲目页）。
class DiscoverLeaderboardsTab extends StatefulWidget {
  const DiscoverLeaderboardsTab({super.key});

  @override
  State<DiscoverLeaderboardsTab> createState() => _DiscoverLeaderboardsTabState();
}

class _DiscoverLeaderboardsTabState extends State<DiscoverLeaderboardsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  void _openBoard(DiscoverLeaderboard board) {
    HapticFeedback.lightImpact();
    final provider = context.read<DiscoverProvider>();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiscoverTracksPage(
          title: board.name,
          loader: () async {
            final tracks = await provider.loadLeaderboardTracks(board.bangid);
            return DiscoverDetail(
              info: DiscoverPlaylist(id: board.id, name: board.name),
              tracks: tracks,
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final provider = context.watch<DiscoverProvider>();
    // 渠道无发现能力时资料页会隐藏本 tab，这里兜底（切换渠道的瞬间）。
    if (!provider.hasDiscoverSource || !provider.supportsLeaderboards) {
      return const SizedBox.shrink();
    }
    final l10n = _l10n(context);
    final theme = Theme.of(context);
    final boards = provider.leaderboards;

    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 12, bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.leaderboard_rounded,
                    size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  l10n.discoverLeaderboards,
                  // 标题用正文色，强调色只给图标。
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: theme.colorScheme.onSurface),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (boards.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Text(
                l10n.discoverNoContent,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: M3EChipGroup(
                groupLabel: l10n.discoverLeaderboards,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final board in boards)
                      M3EChip(
                        label: board.name,
                        onPressed: () => _openBoard(board),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
