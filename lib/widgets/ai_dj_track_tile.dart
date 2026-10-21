import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/ai_dj.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import '../utils/responsive.dart';
import 'card_list_surface.dart';
import 'library_cover.dart';
import 'track_actions_menu.dart';

/// AI 推荐卡（「今日推荐」列表项）：封面 + 歌名/歌手 + AI 理由 + 操作菜单。
///
/// 为什么不用 [TrackRow]：推荐理由是可换行的第二行信息，行高不固定；
/// 表面仍走共享的 [CardListSurface]（M3E 列表规范 + 弹簧 morph），
/// 与全 App 列表保持同一形状语言。
///
/// 操作入口分平台：触摸端行尾常显 ⋮（[TrackActionsMenu]）；桌面端不渲染
/// ⋮，行表面右键在落点弹同一份菜单（[showTrackActionsMenuAtPointer]）。
/// 收藏收进菜单（与 `TrackMenuTile` 同一契约）：收藏态用「实心 ♥ +
/// 取消收藏」图标 + 文案表达。
class AiDjTrackTile extends StatelessWidget {
  const AiDjTrackTile({
    super.key,
    required this.index,
    required this.count,
    required this.item,
    required this.onPlay,
    required this.onReplace,
    required this.onNotInterested,
    required this.onMoreLikeThis,
    this.isCurrent = false,
    this.busy = false,
    this.replacing = false,
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

  /// 「多来点这种」：加入下一批种子。
  final VoidCallback onMoreLikeThis;

  /// 当前播放曲目（标题走 primary 强调）。
  final bool isCurrent;

  /// 生成中：行内操作禁用。
  final bool busy;

  /// 该行正在「换一首」：只在本行显示小进度。
  final bool replacing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final track = item.track;
    final artist = track.artistLabel;
    final sourceName = item.resolvedSourceName;
    final reason = item.source.reason;
    final actionMenu = _aiDjActionMenu(
      context,
      item: item,
      onReplace: onReplace,
      onNotInterested: onNotInterested,
      onMoreLikeThis: onMoreLikeThis,
    );

    Widget surface = CardListSurface(
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
                if (artist.isNotEmpty || sourceName.isNotEmpty)
                  Text(
                    [
                      if (artist.isNotEmpty) artist,
                      if (sourceName.isNotEmpty) sourceName,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                if (replacing)
                  Text(
                    AppLocalizations.of(context)!.aiDjReplacing,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
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
          // 触摸端行尾 ⋮ 常显；桌面端入口是行表面右键，不再渲染 ⋮。
          if (!isDesktopPlatform() && actionMenu != null && !replacing)
            TrackActionsMenu(
              compact: true,
              enabled: !busy,
              semanticLabel: AppLocalizations.of(context)!.aiDjItemActions,
              entries: actionMenu.entries,
              onSelected: actionMenu.onSelected,
            )
          else if (replacing)
            const SizedBox(
              width: 32,
              height: 32,
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: M3ELoadingIndicator(),
                ),
              ),
            ),
        ],
      ),
    );

    // 桌面：行表面右键在落点弹同一份菜单。生成中（busy）行内操作禁用，
    // 右键与 ⋮ 一致不可开（[TrackActionsMenu.enabled] 的同一语义）。
    if (isDesktopPlatform() && !busy && !replacing && actionMenu != null) {
      final _AiDjActionMenu menu = actionMenu;
      surface = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: (details) => showTrackActionsMenuAtPointer(
          context: context,
          globalPosition: details.globalPosition,
          entries: menu.entries,
          onSelected: menu.onSelected,
        ),
        child: surface,
      );
    }
    return surface;
  }
}

/// AI 推荐行的菜单定义（条目 + 选中处理）：触摸端 ⋮ 与桌面右键共用同一份。
class _AiDjActionMenu {
  const _AiDjActionMenu({required this.entries, required this.onSelected});

  /// 菜单条目（收藏 / 换一首 / 不感兴趣）。
  final List<M3EMenuEntry> entries;

  /// 条目选中回调（值与条目的 `value` 对应）。
  final ValueChanged<Object?> onSelected;
}

/// 构建 AI 推荐行的菜单定义：收藏（开关态）/ 换一首 / 不感兴趣。
///
/// 为什么是函数而不是包装组件：菜单的呈现面分平台（触摸端常显 ⋮ / 桌面
/// 右键落点），条目与选中处理必须两种入口共用一份。[LibraryProvider] 缺失
/// 时返回 null（不提供收藏动作，调用方也不渲染入口）。
_AiDjActionMenu? _aiDjActionMenu(
  BuildContext context, {
  required ResolvedRecommendation item,
  required VoidCallback onReplace,
  required VoidCallback onNotInterested,
  required VoidCallback onMoreLikeThis,
}) {
  final l10n = AppLocalizations.of(context)!;
  // 订阅收窄到「收藏版本」：菜单只显示收藏开关态，历史写入（每首歌一次）
  // 不应让全部行的菜单重建；Provider 实例用 read 取。
  context.select<LibraryProvider?, int>(
    (provider) => provider?.favoritesRevision ?? -1,
  );
  final library = context.read<LibraryProvider?>();
  if (library == null) return null;
  final Track track = item.track;
  final favorite = library.isFavorite(track.id.sourceKey, track.id.id);
  return _AiDjActionMenu(
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
        label: l10n.aiDjMoreLikeThis,
        leading: const Icon(Icons.auto_awesome_rounded),
        value: 'moreLikeThis',
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
        case 'moreLikeThis':
          onMoreLikeThis();
        case 'notInterested':
          onNotInterested();
      }
    },
  );
}
