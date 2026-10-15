import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/download.dart' show DownloadedTrack, kLocalSourceKey;
import '../domain/models/library.dart';
import '../l10n/app_localizations.dart';
import '../utils/responsive.dart';
import 'swipe_reveal_row.dart';
import 'track_row.dart';

/// 合集曲目列表脚手架：常显可拖动滚动条 + 固定行高懒加载列表
/// （排序模式换长按重排列表），列表为空时展示调用方给的空态。
///
/// 收藏 / 自建列表 / 播放历史 / 本地歌曲四种合集的列表体共用这一份实现：
/// 滚动条参数、列表内边距、`itemExtent`（行高 + 行距）与行距补白只有这里
/// 一份；调用方只提供可见行、行 key、行内容与空态形状。
class CollectionTrackList<T> extends StatelessWidget {
  const CollectionTrackList({
    super.key,
    required this.controller,
    required this.rows,
    required this.keyOf,
    required this.itemBuilder,
    required this.empty,
    this.onReorder,
  });

  /// 列表上下内边距（水平走页面响应式留白）。
  static const double verticalPadding = 8;

  /// 当前合集的滚动控制器（常显滚动条 + 拖动定位共用）。
  final ScrollController controller;

  /// 可见行：顺序即播放队列顺序。
  final List<T> rows;

  /// 行稳定 key：合集切换 / 删除 / 导入后列表原地刷新，不整段重建、
  /// 不丢滚动位置。同一列表内必须唯一。
  final Key Function(T row) keyOf;

  /// 行内容（点播 / 多选 / 左滑等语义在调用方）；行距由脚手架补齐。
  final Widget Function(BuildContext context, T row, int index) itemBuilder;

  /// 无可见行时的空态：合集为空还是被搜索条件过滤掉，由调用方决定形状。
  final Widget empty;

  /// 非空 = 排序模式：长按行内任意位置拖动落位（`from`/`to` 为
  /// 「直接移动」语义，曲目落在目标下标）。
  final void Function(int from, int to)? onReorder;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return empty;
    final horizontalPadding =
        context.layoutType(ResponsivePageType.browse).horizontalPadding;
    final gap = TrackRow.gapOf(context);
    final padding = EdgeInsets.fromLTRB(
      horizontalPadding,
      verticalPadding,
      horizontalPadding,
      verticalPadding,
    );
    final onReorder = this.onReorder;
    return Scrollbar(
      controller: controller,
      thumbVisibility: true,
      interactive: true,
      child: onReorder == null
          ? ListView.builder(
              controller: controller,
              padding: padding,
              itemExtent: TrackRow.extent + gap,
              itemCount: rows.length,
              itemBuilder: (context, index) => KeyedSubtree(
                key: keyOf(rows[index]),
                child: _buildRow(context, index, gap),
              ),
            )
          : ReorderableListView.builder(
              scrollController: controller,
              padding: padding,
              itemExtent: TrackRow.extent + gap,
              buildDefaultDragHandles: false,
              itemCount: rows.length,
              onReorderItem: onReorder,
              itemBuilder: (context, index) =>
                  ReorderableDelayedDragStartListener(
                key: keyOf(rows[index]),
                index: index,
                child: _buildRow(context, index, gap),
              ),
            ),
    );
  }

  /// 行内容 + 行距补白（M3E 卡片列表的内行间距）。
  Widget _buildRow(BuildContext context, int index, double gap) {
    return Padding(
      padding: EdgeInsets.only(bottom: gap),
      child: itemBuilder(context, rows[index], index),
    );
  }
}

/// 合集曲目行：固定行高行 + 多选勾选 + （给了动作时的）左滑外壳。
///
/// 四种合集的行走同一形状；点播 / 多选 / 动作语义（图标、文案、回调）
/// 都在调用方，这里只组装 [TrackRow] 与 [SwipeRevealRow]。
class CollectionTrackRow extends StatelessWidget {
  const CollectionTrackRow({
    super.key,
    required this.title,
    this.artist = '',
    this.coverUrl,
    this.trailingText,
    this.trailing,
    required this.position,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.swipeActions,
  });

  final String title;
  final String artist;
  final String? coverUrl;

  /// 行尾元信息（时长等），未知时传 null 不占位。
  final String? trailingText;

  /// 行尾插槽（排序把手 / 缓存标记等）。
  final Widget? trailing;

  /// 行在列表中的位置（首末外侧大圆角；由 `calculateCardPosition` 算）。
  final M3ECardPosition position;

  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 左滑动作；null / 空 = 无左滑（多选与排序模式）。
  final List<M3EListSwipeAction>? swipeActions;

  @override
  Widget build(BuildContext context) {
    final row = TrackRow(
      title: title,
      artist: artist,
      coverUrl: coverUrl,
      trailingText: trailingText,
      trailing: trailing,
      selected: selected,
      position: position,
      onTap: onTap,
      onLongPress: onLongPress,
    );
    final actions = swipeActions;
    if (actions == null || actions.isEmpty) return row;
    return SwipeRevealRow(actions: actions, child: row);
  }
}

/// 合集列表的合集空态：图标 + 文案 + 可选动作（本地歌曲的导入入口）。
class CollectionEmptyState extends StatelessWidget {
  const CollectionEmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;

  /// 空态下的补充入口（如「导入本地歌曲」）。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final action = this.action;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: 16),
              action,
            ],
          ],
        ),
      ),
    );
  }
}

/// 搜索无结果空态：合集本身有内容，只是被搜索条件过滤掉。
class CollectionSearchEmpty extends StatelessWidget {
  const CollectionSearchEmpty({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        message,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 本地歌曲行：下载 / 导入副本，或命中完整音频缓存的曲目（缓存 = 已下载）。
///
/// 缓存行保留原曲身份（`sourceKey` / `songId` / `raw`），播放走正常解析
/// （命中缓存即 `file://` 离线播放）；删除是「清缓存」，不动下载记录。
class CollectionLocalSong {
  const CollectionLocalSong.download(this.record)
      : history = null,
        cachedSizeBytes = null;

  const CollectionLocalSong.cached(this.history,
      {required this.cachedSizeBytes})
      : record = null;

  final DownloadedTrack? record;
  final PlayHistoryEntry? history;

  /// 缓存行展示用体积（多音质变体取最大）；下载行为 null。
  final int? cachedSizeBytes;

  /// 是否缓存行（无下载 / 导入记录）。
  bool get isCached => record == null;

  /// 是否本地导入（就地引用）。
  bool get isImported => record?.imported ?? false;

  /// 稳定行 key。
  String get key => record?.key ?? '${history!.sourceKey}:${history!.songId}';

  String get title => record?.title ?? history!.title;

  String get artist => record?.artist ?? history!.artist;

  int? get durationMs =>
      record != null ? record!.durationMs : history!.durationMs;

  /// 行封面地址：下载副本优先本地封面文件，缓存行用历史里的原图地址。
  String? get artworkUri {
    final record = this.record;
    if (record != null) return record.artworkUri?.toString();
    return history!.coverUrl;
  }

  /// 播放 / 收藏用的曲目快照（下载副本 = local 源；缓存行 = 原曲）。
  PlaylistTrack toPlaylistTrack({required int addedAt}) => record != null
      ? record!.toPlaylistTrack(addedAt: addedAt)
      : PlaylistTrack.fromHistoryEntry(history!, addedAt: addedAt);

  /// 收藏键（下载副本 = local 音源；缓存行 = 原曲键）。
  ({String sourceKey, String songId}) get favoriteKey => record != null
      ? (sourceKey: kLocalSourceKey, songId: record!.localSongId)
      : (sourceKey: history!.sourceKey, songId: history!.songId);
}

/// 一条左滑动作的描述：图标 + 文案 + 回调；[destructive] 表达「移除类」
/// （filled + error 配色，对齐 M3E 列表示例的删除动作）。
class CollectionSwipeAction {
  const CollectionSwipeAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool destructive;
}

/// 把动作描述编译成 [M3EListSwipeAction]（胶囊渲染在 [SwipeRevealRow]）。
///
/// 图标用 tooltip 承担无障碍语义：纯图标在窄胶囊里不容易自解释。
List<M3EListSwipeAction> collectionSwipeActions(
  BuildContext context,
  List<CollectionSwipeAction> actions,
) {
  final scheme = Theme.of(context).colorScheme;
  return [
    for (final action in actions)
      M3EListSwipeAction(
        icon: Tooltip(message: action.label, child: Icon(action.icon)),
        isPrimary: action.destructive,
        backgroundColor: action.destructive ? scheme.error : null,
        foregroundColor: action.destructive ? scheme.onError : null,
        onPressed: action.onPressed,
      ),
  ];
}

/// 收藏 / 自建列表曲目行的左滑动作：加入列表 + 换源（非本地曲目）+
/// 移除类（自建列表「从本列表移除」/ 收藏「取消收藏」）。
///
/// 动作构成 / 图标 / 文案在这一份实现；写入动作（含「谁被移除」）由调用方给，
/// 回调可以是异步写入（模块负责 fire-and-forget）。
List<M3EListSwipeAction> collectionTrackRowSwipeActions(
  BuildContext context, {
  required AppLocalizations l10n,
  required PlaylistTrack track,
  required bool isFavorites,
  required bool isCustom,
  required int? playlistId,
  required Future<void> Function() onCopy,
  required Future<void> Function() onSwap,
  required Future<void> Function() onRemoveFromPlaylist,
  required Future<void> Function() onRemoveFromFavorites,
}) {
  return collectionSwipeActions(context, [
    CollectionSwipeAction(
      icon: Icons.playlist_add_rounded,
      label: l10n.addToPlaylist,
      onPressed: () => unawaited(onCopy()),
    ),
    if (playlistId != null && track.sourceKey != kLocalSourceKey)
      CollectionSwipeAction(
        icon: Icons.swap_horiz_rounded,
        label: l10n.sourceSwap,
        onPressed: () => unawaited(onSwap()),
      ),
    if (isCustom && playlistId != null)
      CollectionSwipeAction(
        icon: Icons.playlist_remove_rounded,
        label: l10n.playlistRemoveTrack,
        destructive: true,
        onPressed: () => unawaited(onRemoveFromPlaylist()),
      )
    else if (isFavorites)
      CollectionSwipeAction(
        icon: Icons.delete_rounded,
        label: l10n.favoriteRemove,
        destructive: true,
        onPressed: () => unawaited(onRemoveFromFavorites()),
      ),
  ]);
}

/// 播放历史行的左滑动作：加入列表 + 换源（非本地记录）+ 删除单条。
List<M3EListSwipeAction> collectionHistoryRowSwipeActions(
  BuildContext context, {
  required AppLocalizations l10n,
  required PlayHistoryEntry entry,
  required Future<void> Function() onCopy,
  required Future<void> Function() onSwap,
  required Future<void> Function() onDelete,
}) {
  return collectionSwipeActions(context, [
    CollectionSwipeAction(
      icon: Icons.playlist_add_rounded,
      label: l10n.addToPlaylist,
      onPressed: () => unawaited(onCopy()),
    ),
    if (entry.sourceKey != kLocalSourceKey)
      CollectionSwipeAction(
        icon: Icons.swap_horiz_rounded,
        label: l10n.sourceSwap,
        onPressed: () => unawaited(onSwap()),
      ),
    CollectionSwipeAction(
      icon: Icons.delete_rounded,
      label: l10n.historyDeleteEntry,
      destructive: true,
      onPressed: () => unawaited(onDelete()),
    ),
  ]);
}

/// 本地歌曲行的左滑动作：加入列表 + 收藏开关 + 删除（文案按记录来源区分：
/// 缓存行清缓存 / 导入项只移出列表 / 下载副本删文件）。
List<M3EListSwipeAction> localSongRowSwipeActions(
  BuildContext context, {
  required AppLocalizations l10n,
  required bool isFavorite,
  required bool isCached,
  required bool isImported,
  required Future<void> Function() onCopy,
  required Future<void> Function() onToggleFavorite,
  required Future<void> Function() onDelete,
}) {
  return collectionSwipeActions(context, [
    CollectionSwipeAction(
      icon: Icons.playlist_add_rounded,
      label: l10n.addToPlaylist,
      onPressed: () => unawaited(onCopy()),
    ),
    CollectionSwipeAction(
      icon: isFavorite
          ? Icons.heart_broken_rounded
          : Icons.favorite_border_rounded,
      label: isFavorite ? l10n.favoriteRemove : l10n.favoriteAdd,
      onPressed: () => unawaited(onToggleFavorite()),
    ),
    CollectionSwipeAction(
      icon: Icons.delete_rounded,
      label: isCached
          ? l10n.localSongsCachedRemove
          : isImported
              ? l10n.localSongsRemove
              : l10n.downloadDelete,
      destructive: true,
      onPressed: () => unawaited(onDelete()),
    ),
  ]);
}
