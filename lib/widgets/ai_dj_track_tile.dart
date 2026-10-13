import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/ai_dj.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import 'card_list_surface.dart';
import 'icon_swap.dart';
import 'library_cover.dart';

/// AI 推荐卡（「今日推荐」列表项）：封面 + 歌名/歌手 + AI 理由 + 行内操作。
///
/// 为什么不用 [TrackRow]：推荐理由是可换行的第二行信息，行高不固定；
/// 表面仍走共享的 [CardListSurface]（M3E 列表规范 + 弹簧 morph），
/// 与全 App 列表保持同一形状语言。
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
    this.inQueue = false,
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

  /// 已在播放队列（显示「队列中」标记）。
  final bool inQueue;

  /// 生成中：行内操作禁用。
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
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
          LibraryCoverThumb(url: track.artwork?.uri.toString(), size: 48),
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
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (inQueue && !isCurrent) ...[
                  const SizedBox(height: 2),
                  Text(
                    l10n.aiDjInQueue,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          _FavoriteAction(track: track, enabled: !busy),
          M3EMenu.entries(
            position: M3EMenuAnchorPosition.bottomEnd,
            anchorBuilder: (context, open) => M3EIconButton(
              variant: M3EIconButtonVariant.standard,
              size: M3EIconButtonSize.sm,
              visualSize: const Size(40, 40),
              icon: const Icon(Icons.more_vert_rounded),
              tooltip: l10n.aiDjItemActions,
              onPressed: busy ? null : open,
            ),
            onSelected: (value) {
              switch (value) {
                case 'replace':
                  onReplace();
                case 'notInterested':
                  onNotInterested();
              }
            },
            entries: [
              M3EMenuEntry(label: l10n.aiDjReplaceItem, value: 'replace'),
              M3EMenuEntry(
                label: l10n.aiDjNotInterested,
                value: 'notInterested',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 收藏（喜欢 = 反馈回流）按钮：与播放页同一契约（实心/空心 + primary）。
class _FavoriteAction extends StatelessWidget {
  const _FavoriteAction({required this.track, required this.enabled});

  final Track track;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryProvider?>();
    if (library == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final favorite = library.isFavorite(track.id.sourceKey, track.id.id);
    final scheme = Theme.of(context).colorScheme;
    return M3EIconButton(
      variant: M3EIconButtonVariant.standard,
      size: M3EIconButtonSize.sm,
      visualSize: const Size(40, 40),
      icon: IconSwap<bool>(
        value: favorite,
        builder: (context, favorite) => Icon(
          favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          color: favorite ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
      tooltip: favorite ? l10n.favoriteRemove : l10n.favoriteAdd,
      onPressed: enabled ? () => library.toggleFavoriteTrack(track) : null,
    );
  }
}
