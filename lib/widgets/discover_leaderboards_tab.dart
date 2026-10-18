import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/discover.dart';
import '../l10n/app_localizations.dart';
import '../pages/discover_tracks_page.dart';
import '../providers/discover_provider.dart';
import '../services/haptics.dart';
import 'empty_state.dart';
import 'icon_swap.dart';
import 'shell_page_visibility.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 榜单 chip 云的列距 / 行距：装箱计算与 `Wrap` 渲染必须是同一个值。
const double _chipGap = 8;

/// 装箱用的宽度余量：吸收亚像素舍入，避免估计刚好卡在行宽边界时被真身挤到
/// 下一行。
const double _chipWidthSlack = 1;

/// 折叠态 chip 云可见的前缀长度（纯函数，只算宽度不建树）。
///
/// 为什么折叠时不渲染（而不是渲染后用 `ClipRect` 裁掉）：被裁掉的 chip 仍在
/// 语义树与键盘焦点顺序里，会出现焦点落在看不见的 chip 上的可访问性问题。
/// 策略只服务本 tab，公开是为了让单测直接钉装箱边界。
int chipCloudVisibleCount({
  required List<double> widths,
  required double availableWidth,
  required double gap,
  int maxRows = 2,
}) {
  var row = 1;
  var used = 0.0;
  var count = 0;
  for (final width in widths) {
    // 单个 chip 宽过一行时会被真身省略号截断，装箱按可用宽封顶。
    final w = width <= availableWidth ? width : availableWidth;
    if (used > 0 && used + gap + w > availableWidth) {
      if (row == maxRows) break;
      row++;
      used = w;
    } else {
      used = used > 0 ? used + gap + w : w;
    }
    count++;
  }
  return count;
}

/// chip 宽度的保守上界：真身 = 起始内边距 + 文字 + 末尾内边距
/// （内边距取 [M3EChipTheme] 的 token，不另写字面量），再留余量吸收亚像素
/// 舍入——真身只会更窄，「放得下」的装箱结论不会因实测宽度而失效。
double _estimateChipWidth({
  required String label,
  required M3EChipTheme chipTheme,
  required TextStyle labelStyle,
  required TextScaler textScaler,
  required TextDirection textDirection,
}) {
  final painter = TextPainter(
    text: TextSpan(text: label, style: labelStyle),
    textDirection: textDirection,
    textScaler: textScaler,
    maxLines: 1,
  )..layout();
  return (chipTheme.startPadding(
                type: M3EChipType.assist,
                hasLeading: false,
                hasAvatar: false,
              ) +
              painter.width +
              chipTheme.endPaddingFor(hasTrailing: false))
          .ceilToDouble() +
      _chipWidthSlack;
}

/// 资料页「热榜」tab：当前渠道的榜单 chips（点击进入榜单曲目页）。
///
/// chip 云默认最多两行（渠道可能有 30+ 榜单），溢出部分由下方的「展开全部」
/// 入口就地展开 / 收起（折叠态只构建可见前缀，见 [chipCloudVisibleCount]）。
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

  /// chip 云是否已展开（折叠态只渲染两行内放得下的榜单）。
  bool _expanded = false;

  /// 展开态所属渠道：换渠道后回到折叠（新渠道的榜单是另一批）。
  String? _expandedChannelKey;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  void _toggleExpanded(String channelKey) {
    HapticsService.lightImpact();
    setState(() {
      _expanded = !_expanded;
      _expandedChannelKey = channelKey;
    });
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
    // 换渠道回到折叠态；build 期写入，不触发重建。
    if (_expandedChannelKey != provider.channelKey) {
      _expanded = false;
      _expandedChannelKey = provider.channelKey;
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
              child: LayoutBuilder(
                builder: (context, constraints) => _buildChipCloud(
                  context: context,
                  l10n: l10n,
                  boards: boards,
                  availableWidth: constraints.maxWidth,
                ),
              ),
            ),
    );
  }

  /// 榜单 chip 云：折叠态最多两行 + 末尾「展开全部」，展开态全部榜单 + 「收起」。
  ///
  /// 槽位复用 `M3EChipGroup`（方向键在 chip 间移动 + 组语义标签），组内只有
  /// 真正渲染出来的 chip，焦点顺序与视觉顺序一致。
  Widget _buildChipCloud({
    required BuildContext context,
    required AppLocalizations l10n,
    required List<DiscoverLeaderboard> boards,
    required double availableWidth,
  }) {
    final m3e = M3ETheme.of(context);
    final chipTheme = m3e.chipTheme;
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    double estimate(String label) => _estimateChipWidth(
          label: label,
          chipTheme: chipTheme,
          labelStyle: m3e.typeScale.labelLarge,
          textScaler: textScaler,
          textDirection: textDirection,
        );

    // 折叠态放得下的前缀：与当前是否展开无关。
    final collapsedCount = chipCloudVisibleCount(
      widths: [for (final board in boards) estimate(board.name)],
      availableWidth: availableWidth,
      gap: _chipGap,
    );
    // 折叠态是否有剩余（决定入口是否出现）。
    final hasOverflow = collapsedCount < boards.length;
    final visibleCount = _expanded ? boards.length : collapsedCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        M3EChipGroup(
          groupLabel: l10n.discoverLeaderboards,
          child: Wrap(
            spacing: _chipGap,
            runSpacing: _chipGap,
            children: [
              for (final board in boards.take(visibleCount))
                M3EChip(
                  label: board.name,
                  onPressed: () => _openBoard(board),
                ),
            ],
          ),
        ),
        // 入口只在真有折叠内容时出现（全部放得下就没有它，也就没有空入口）。
        if (hasOverflow)
          M3EButton.icon(
            style: M3EButtonStyle.text,
            // 同一按钮槽位换图标，过渡走共享的 IconSwap 配方。
            icon: IconSwap<bool>(
              value: _expanded,
              builder: (context, expanded) => Icon(
                expanded
                    ? Icons.unfold_less_rounded
                    : Icons.unfold_more_rounded,
              ),
            ),
            label:
                Text(_expanded ? l10n.discoverShowLess : l10n.discoverShowAll),
            onPressed: () => _toggleExpanded(
              context.read<DiscoverProvider>().channelKey,
            ),
          ),
      ],
    );
  }
}
