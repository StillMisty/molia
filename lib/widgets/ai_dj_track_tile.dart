import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/ai_dj.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import 'card_list_surface.dart';
import 'library_cover.dart';
import 'track_actions_menu.dart';

/// AI 推荐卡（「今日推荐」列表项）：封面 + 歌名/歌手 + AI 理由 + ⋮ 操作。
///
/// 为什么不用 [TrackRow]：推荐理由是可换行的第二行信息，行高不固定；
/// 表面仍走共享的 [CardListSurface]（M3E 列表规范 + 弹簧 morph），
/// 与全 App 列表保持同一形状语言。
///
/// 收藏收进行尾 ⋮ 菜单（与 `TrackMenuTile` 同一契约）：行尾只保留一个动作，
/// 收藏态用「实心 ♥ + 取消收藏」图标 + 文案表达。
class AiDjTrackTile extends StatelessWidget {
  const AiDjTrackTile({
    super.key,
    required this.index,
    required this.count,
    required this.item,
    required this.onPlay,
    required this.onReplace,
    required this.onNotInterested,
    this.isCurrent = false,
    this.busy = false,
  });

  /// 列表位置（决定卡片静止形状）。
  final int index;
  final int count;

  final ResolvedRecommendation item;

  /// 点整行：播放这一首（已在队列则跳转）。
  final VoidCallback onPlay;

  /// 「换一首」：重新生成并原位替换。
  final VoidCallback onReplace;

  /// 「不感兴趣」：从列表移除（可撤销）。
  final VoidCallback onNotInterested;

  /// 当前播放曲目（标题走 primary 强调）。
  final bool isCurrent;

  /// 生成中：行内操作禁用。
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final track = item.track;
    final artist = track.artists
        .map((artist) => artist.name)
        .where((name) => name.isNotEmpty)
        .join(', ');
    final reason = item.source.reason;

    return CardListSurface(
      position: calculateCardPosition(index, count),
      onPressed: busy ? null : onPlay,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      semanticLabel: [track.title, artist, reason]
          .where((part) => part.isNotEmpty)
          .join(', '),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          LibraryCoverThumb(url: track.artwork?.uri.toString(), size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    // 强调色只给「正在播放」这一状态。
                    color: isCurrent ? scheme.primary : scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (artist.isNotEmpty)
                  Text(
                    artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                if (reason.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    reason,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          _RowActionsMenu(
            item: item,
            enabled: !busy,
            onReplace: onReplace,
            onNotInterested: onNotInterested,
          ),
        ],
      ),
    );
  }
}

/// 行尾 ⋮ 菜单：收藏（开关态）/ 换一首 / 不感兴趣。
///
/// 单独包一层是把 [LibraryProvider] 的订阅限制在菜单内——收藏变化只重建
/// 菜单，不整表重建。
class _RowActionsMenu extends StatelessWidget {
  const _RowActionsMenu({
    required this.item,
    required this.enabled,
    required this.onReplace,
    required this.onNotInterested,
  });

  final ResolvedRecommendation item;
  final bool enabled;
  final VoidCallback onReplace;
  final VoidCallback onNotInterested;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final library = context.watch<LibraryProvider?>();
    if (library == null) return const SizedBox.shrink();
    final Track track = item.track;
    final favorite = library.isFavorite(track.id.sourceKey, track.id.id);
    return TrackActionsMenu(
      compact: true,
      enabled: enabled,
      tooltip: l10n.aiDjItemActions,
      entries: [
        M3EMenuEntry(
          label: favorite ? l10n.favoriteRemove : l10n.favoriteAdd,
          leading: Icon(
            favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          ),
          value: 'favorite',
        ),
        M3EMenuEntry(
          label: l10n.aiDjReplaceItem,
          leading: const Icon(Icons.refresh_rounded),
          value: 'replace',
        ),
        M3EMenuEntry(
          label: l10n.aiDjNotInterested,
          leading: const Icon(Icons.visibility_off_rounded),
          value: 'notInterested',
        ),
      ],
      onSelected: (value) {
        switch (value) {
          case 'favorite':
            library.toggleFavoriteTrack(track);
          case 'replace':
            onReplace();
          case 'notInterested':
            onNotInterested();
        }
      },
    );
  }
}
