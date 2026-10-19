import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/discover.dart';
import '../l10n/app_localizations.dart';
import '../pages/discover_tracks_page.dart';
import '../providers/discover_provider.dart';
import '../services/haptics.dart';
import 'empty_state.dart';
import 'shell_page_visibility.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 榜单 chip 云的列距 / 行距。
const double _chipGap = 8;

/// 资料页「热榜」tab：当前渠道的榜单 chips（点击进入榜单曲目页）。
///
/// 渠道可能有 30+ 榜单，全部直接铺开——热榜本身就是「挑一个榜看」，折叠
/// 反而多一步；chip 云交给 `Wrap` 自然换行，没有展开 / 收起入口。
class DiscoverLeaderboardsTab extends StatefulWidget {
  const DiscoverLeaderboardsTab({super.key, this.controller});

  /// 内容滚动控制器（宿主页面注入：重复点击底栏资料库时回顶）；
  /// 为空时自建（独立挂载 / 测试）。
  final ScrollController? controller;

  @override
  State<DiscoverLeaderboardsTab> createState() =>
      _DiscoverLeaderboardsTabState();
}

class _DiscoverLeaderboardsTabState extends State<DiscoverLeaderboardsTab>
    with AutomaticKeepAliveClientMixin {
  /// 自带控制器：宿主未注入时使用（随 State 释放）。
  ScrollController? _ownedController;

  ScrollController get _controller =>
      widget.controller ?? (_ownedController ??= ScrollController());

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  void _openBoard(DiscoverLeaderboard board) {
    HapticsService.lightImpact();
    final provider = context.read<DiscoverProvider>();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiscoverTracksPage(
          title: board.name,
          loader: (_) async {
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
    // 可见性门控：隐藏的常驻 tab 不订阅（见 ShellPageVisibility）。
    final provider = ShellPageVisibility.maybeVisibleOf(context) ?? true
        ? context.watch<DiscoverProvider>()
        : context.read<DiscoverProvider>();
    // 渠道无发现能力时资料页会隐藏本 tab，这里兜底（切换渠道的瞬间）。
    if (!provider.hasDiscoverSource || !provider.supportsLeaderboards) {
      return const SizedBox.shrink();
    }
    final l10n = _l10n(context);
    final boards = provider.leaderboards;

    return SingleChildScrollView(
      controller: _controller,
      padding: const EdgeInsets.only(top: 12, bottom: 32),
      child: boards.isEmpty
          // 滚动内容里的空态版式：页面对齐的 16/16 外边距。
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: EmptyState(
                icon: Icons.leaderboard_rounded,
                message: l10n.discoverNoContent,
              ),
            )
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: M3EChipGroup(
                groupLabel: l10n.discoverLeaderboards,
                child: Wrap(
                  spacing: _chipGap,
                  runSpacing: _chipGap,
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
    );
  }
}
