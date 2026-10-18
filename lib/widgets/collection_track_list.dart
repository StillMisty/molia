import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/download.dart' show DownloadedTrack, kLocalSourceKey;
import '../domain/models/library.dart';
import '../l10n/app_localizations.dart';
import '../utils/responsive.dart';
import 'swipe_reveal_row.dart';
import 'track_actions_menu.dart';
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
    this.tableColumns = false,
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

  /// 行内是否给表格列（调用方按行是否传 `TrackRowColumns` 给同一档）：
  /// `itemExtent` 据此取哪一档行高（表格单行 56 / 单列双行 72，见
  /// `TrackRow.extentOf`）；与行渲染差一档会让滚动条拇指与拖动定位失准。
  final bool tableColumns;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return empty;
    final horizontalPadding =
        context.layoutType(ResponsivePageType.browse).horizontalPadding;
    final gap = TrackRow.gapOf(context);
    final itemExtent =
        TrackRow.extentOf(context, tableColumns: tableColumns) + gap;
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
              itemExtent: itemExtent,
              itemCount: rows.length,
              itemBuilder: (context, index) => KeyedSubtree(
                key: keyOf(rows[index]),
                child: _buildRow(context, index, gap),
              ),
            )
          : ReorderableListView.builder(
              scrollController: controller,
              padding: padding,
              itemExtent: itemExtent,
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

/// 合集曲目行：固定行高行 + 多选勾选 + （给了动作时的）管理入口。
///
/// 四种合集的行走同一形状；点播 / 多选 / 动作语义（图标、文案、回调）
/// 都在调用方，这里只组装 [TrackRow]：触摸端动作渲染成 [SwipeRevealRow]
/// 左滑胶囊；桌面端不装左滑外壳，行表面右键在落点弹同一组动作的菜单。
class CollectionTrackRow extends StatelessWidget {
  const CollectionTrackRow({
    super.key,
    required this.title,
    this.artist = '',
    this.coverUrl,
    this.columns,
    this.trailingText,
    this.trailing,
    required this.position,
    this.selected = false,
    this.onTap,
    this.onTapWithModifiers,
    this.onLongPress,
    this.actions,
  });

  final String title;
  final String artist;
  final String? coverUrl;

  /// 宽屏表格列（桌面宽内容列表传入）：行内改表格布局，列宽与表头同源；
  /// null = 单列布局（逐像素不变）。
  final TrackRowColumns? columns;

  /// 行尾元信息（时长等），未知时传 null 不占位。
  final String? trailingText;

  /// 行尾插槽（排序把手 / 缓存标记等）。
  final Widget? trailing;

  /// 行在列表中的位置（首末外侧大圆角；由 `calculateCardPosition` 算）。
  final M3ECardPosition position;

  final bool selected;
  final VoidCallback? onTap;

  /// 桌面「带修饰键的点击」：Ctrl / Shift 在点击瞬间读取后交给调用方解释；
  /// 非空时替代 [onTap]（普通点击同样从这里进，由调用方落回既有语义）。
  /// 只有桌面平台注入（见收藏页），触摸端不注入、行为与 [onTap] 一致。
  final void Function(bool ctrl, bool shift)? onTapWithModifiers;

  final VoidCallback? onLongPress;

  /// 行动作描述；null / 空 = 无动作（多选与排序模式：触摸端无左滑、
  /// 桌面端也没有右键菜单）。
  final List<CollectionRowAction>? actions;

  @override
  Widget build(BuildContext context) {
    final tapWithModifiers = onTapWithModifiers;
    final rowActions = actions ?? const <CollectionRowAction>[];
    // 桌面端入口是行表面右键：同一组动作编译成菜单条目，`value` 记动作下标，
    // 选中后回读对应回调。菜单在落点弹出（靠边由 M3E placer 处理）。
    final onSecondaryTap = isDesktopPlatform() && rowActions.isNotEmpty
        ? (Offset tapPosition) => showTrackActionsMenuAtPointer(
              context: context,
              globalPosition: tapPosition,
              entries: [
                for (var index = 0; index < rowActions.length; index++)
                  M3EMenuEntry(
                    label: rowActions[index].label,
                    leading: Icon(rowActions[index].icon),
                    isDestructive: rowActions[index].destructive,
                    value: index,
                  ),
              ],
              onSelected: (value) {
                if (value is int) rowActions[value].onPressed();
              },
            )
        : null;
    final row = TrackRow(
      title: title,
      artist: artist,
      coverUrl: coverUrl,
      columns: columns,
      trailingText: trailingText,
      trailing: trailing,
      selected: selected,
      position: position,
      // 修饰键在点击回调里读：行只在列表数据变化时重建，按下 Ctrl 本身
      // 不会触发重建；build 时读会把「上一次构建」的按键状态固化到点击上。
      onTap: tapWithModifiers == null
          ? onTap
          : () => tapWithModifiers(
                HardwareKeyboard.instance.isControlPressed,
                HardwareKeyboard.instance.isShiftPressed,
              ),
      onLongPress: onLongPress,
      onSecondaryTap: onSecondaryTap,
    );
    if (rowActions.isEmpty) return row;
    // 桌面不再有鼠标左滑：动作已挂在行表面右键，不装左滑外壳。
    if (isDesktopPlatform()) return row;
    return SwipeRevealRow(
      actions: collectionSwipeActions(context, rowActions),
      child: row,
    );
  }
}

/// 搜索无结果空态：合集本身有内容，只是被搜索条件过滤掉（合集为空的
/// 图标版空态见 `widgets/empty_state.dart`）。
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
  const CollectionLocalSong.download(this.record) : history = null;

  const CollectionLocalSong.cached(this.history) : record = null;

  final DownloadedTrack? record;
  final PlayHistoryEntry? history;

  /// 是否缓存行（无下载 / 导入记录）。
  bool get isCached => record == null;

  /// 是否本地导入（就地引用）。
  bool get isImported => record?.imported ?? false;

  /// 稳定行 key。
  String get key => record?.key ?? '${history!.sourceKey}:${history!.songId}';

  String get title => record?.title ?? history!.title;

  String get artist => record?.artist ?? history!.artist;

  /// 专辑名：下载 / 导入副本取记录快照，缓存行沿用播放历史。
  String get album => record?.album ?? history!.album;

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

/// 一条行动作的描述（触摸端左滑胶囊 / 桌面右键菜单共用）：图标 + 文案 +
/// 回调；[destructive] 表达「移除类」（触摸端 filled + error 配色，桌面端
/// 菜单条目走 error 语义，对齐 M3E 列表示例的删除动作）。
class CollectionRowAction {
  const CollectionRowAction({
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

/// 把动作描述编译成 [M3EListSwipeAction]（触摸端左滑胶囊，渲染在
/// [SwipeRevealRow]）；桌面端右键菜单条目直接取动作描述，不经过这里
/// （菜单只要图标 + 文案，不需要配色）。
///
/// 图标用 `semanticLabel` 承担无障碍语义：纯图标在窄胶囊里不容易自解释，
/// 提示气泡则不做（口径见 docs/architecture.md §6「按钮选型」）。
List<M3EListSwipeAction> collectionSwipeActions(
  BuildContext context,
  List<CollectionRowAction> actions,
) {
  final scheme = Theme.of(context).colorScheme;
  return [
    for (final action in actions)
      M3EListSwipeAction(
        icon: Icon(action.icon, semanticLabel: action.label),
        isPrimary: action.destructive,
        backgroundColor: action.destructive ? scheme.error : null,
        foregroundColor: action.destructive ? scheme.onError : null,
        onPressed: action.onPressed,
      ),
  ];
}

/// 收藏 / 自建列表曲目行的动作（触摸端左滑胶囊 / 桌面右键菜单共用）：
/// 加入列表 + 换源（非本地曲目）+ 移除类（自建列表「从本列表移除」/
/// 收藏「取消收藏」）。
///
/// 动作构成 / 图标 / 文案在这一份实现；写入动作（含「谁被移除」）由调用方给，
/// 回调可以是异步写入（模块负责 fire-and-forget）。
List<CollectionRowAction> collectionTrackRowActions({
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
  return [
    CollectionRowAction(
      icon: Icons.playlist_add_rounded,
      label: l10n.addToPlaylist,
      onPressed: () => unawaited(onCopy()),
    ),
    if (playlistId != null && track.sourceKey != kLocalSourceKey)
      CollectionRowAction(
        icon: Icons.swap_horiz_rounded,
        label: l10n.sourceSwap,
        onPressed: () => unawaited(onSwap()),
      ),
    if (isCustom && playlistId != null)
      CollectionRowAction(
        icon: Icons.playlist_remove_rounded,
        label: l10n.playlistRemoveTrack,
        destructive: true,
        onPressed: () => unawaited(onRemoveFromPlaylist()),
      )
    else if (isFavorites)
      CollectionRowAction(
        icon: Icons.delete_rounded,
        label: l10n.favoriteRemove,
        destructive: true,
        onPressed: () => unawaited(onRemoveFromFavorites()),
      ),
  ];
}

/// 播放历史行的动作（触摸端左滑胶囊 / 桌面右键菜单共用）：加入列表 +
/// 换源（非本地记录）+ 删除单条。
List<CollectionRowAction> collectionHistoryRowActions({
  required AppLocalizations l10n,
  required PlayHistoryEntry entry,
  required Future<void> Function() onCopy,
  required Future<void> Function() onSwap,
  required Future<void> Function() onDelete,
}) {
  return [
    CollectionRowAction(
      icon: Icons.playlist_add_rounded,
      label: l10n.addToPlaylist,
      onPressed: () => unawaited(onCopy()),
    ),
    if (entry.sourceKey != kLocalSourceKey)
      CollectionRowAction(
        icon: Icons.swap_horiz_rounded,
        label: l10n.sourceSwap,
        onPressed: () => unawaited(onSwap()),
      ),
    CollectionRowAction(
      icon: Icons.delete_rounded,
      label: l10n.historyDeleteEntry,
      destructive: true,
      onPressed: () => unawaited(onDelete()),
    ),
  ];
}

/// 本地歌曲行的动作（触摸端左滑胶囊 / 桌面右键菜单共用）：加入列表 +
/// 收藏开关 + 删除（文案按记录来源区分：缓存行清缓存 / 导入项只移出列表 /
/// 下载副本删文件）。
List<CollectionRowAction> localSongRowActions({
  required AppLocalizations l10n,
  required bool isFavorite,
  required bool isCached,
  required bool isImported,
  required Future<void> Function() onCopy,
  required Future<void> Function() onToggleFavorite,
  required Future<void> Function() onDelete,
}) {
  return [
    CollectionRowAction(
      icon: Icons.playlist_add_rounded,
      label: l10n.addToPlaylist,
      onPressed: () => unawaited(onCopy()),
    ),
    CollectionRowAction(
      icon: isFavorite
          ? Icons.heart_broken_rounded
          : Icons.favorite_border_rounded,
      label: isFavorite ? l10n.favoriteRemove : l10n.favoriteAdd,
      onPressed: () => unawaited(onToggleFavorite()),
    ),
    CollectionRowAction(
      icon: Icons.delete_rounded,
      label: isCached
          ? l10n.localSongsCachedRemove
          : isImported
              ? l10n.localSongsRemove
              : l10n.downloadDelete,
      destructive: true,
      onPressed: () => unawaited(onDelete()),
    ),
  ];
}
