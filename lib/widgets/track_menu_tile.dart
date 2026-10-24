import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import '../utils/responsive.dart';
import 'add_to_library.dart';
import 'favorite_action.dart';
import 'row_actions.dart';
import 'track_row.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 曲目行操作动作：行本体 [TrackMenuTile] 与自建行（队列 / 搜索结果）共用
/// 同一份动作、图标、语义与领域接线。
///
/// 只造动作、不碰呈现：触摸端 ⋮ / 桌面右键的编译都在 `row_actions.dart`，
/// 各入口因此共用一份定义，而不是各抄一套菜单条目。
///
/// 通用构造：收藏态与两条动作由调用方注入（发现域 / 收藏域适配层）——
/// 组件不认具体 provider，避免把 DiscoverProvider 焊进共享件。
List<RowAction> trackRowActionMenu(
  BuildContext context, {
  required bool favorite,
  required VoidCallback onToggleFavorite,
  required VoidCallback onAddToPlaylist,
}) {
  final l10n = _l10n(context);
  final heart = FavoriteHeart(favorite: favorite);
  return [
    RowAction(
      icon: heart.icon,
      label: heart.label(l10n),
      onPressed: onToggleFavorite,
    ),
    RowAction(
      icon: Icons.playlist_add_rounded,
      label: l10n.addToPlaylist,
      onPressed: onAddToPlaylist,
    ),
  ];
}

/// 领域曲目（队列 / 搜索结果等自建行）：收藏态订阅与写入流程（收藏切换 +
/// snackbar、加入列表走统一目标弹层）收在这里，自建行不再各抄一份。
///
/// 订阅是逐行的（每行一个 `select`，只影响本行）——调用方按行调用即可，
/// 不要在列表层调用后透传。
List<RowAction> trackRowActionMenuForTrack(
  BuildContext context,
  Track track,
) {
  final favorite = context.select<LibraryProvider?, bool>(
    (provider) =>
        provider?.isFavorite(track.id.sourceKey, track.id.id) ?? false,
  );
  return trackRowActionMenu(
    context,
    favorite: favorite,
    // 菜单行：成功也确认一句（动作藏在弹层里，弹层关闭后需要回执）。
    onToggleFavorite: () => unawaited(toggleLibraryFavorite(context, track)),
    onAddToPlaylist: () => unawaited(_addTrackToPlaylist(context, track)),
  );
}

/// 领域曲目加入列表：与收藏页 / 发现页共用统一目标选择与反馈流程。
Future<void> _addTrackToPlaylist(BuildContext context, Track track) async {
  final library = context.read<LibraryProvider?>();
  if (library == null) return;
  await addTracksToLibraryTarget(
    context,
    provider: library,
    tracks: [
      PlaylistTrack.fromTrack(
        track,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ],
  );
}

/// 曲目行（行渲染 + 操作菜单入口）：点击播放。
///
/// 入口分平台：触摸端行尾常显 ⋮（[RowActionMenuButton]）；桌面端不渲染 ⋮，
/// 行表面右键在落点弹同一份菜单（[rowActionsAtPointer]）。
///
/// 收藏域（歌手页 / 专辑页）经 [FavoriteTrackTile] 适配层使用；发现详情页
/// 直接使用。菜单固定「收藏 / 加入列表」两条动作——各入口的语义本来就相同，
/// 差异只在领域对象上，因此收藏态与写入流程都由调用方注入：
/// - 收藏态用 `select` 订阅后传入（组件不认具体 provider，避免把
///   DiscoverProvider / LibraryProvider 焊进共享件，也避免整表重建）；
/// - 行内容走 [TrackRowModel]（时长由 [TrackRow] 统一格式化）。
///
/// 动作定义见 [trackRowActionMenu]。
class TrackMenuTile extends StatelessWidget {
  const TrackMenuTile({
    super.key,
    required this.row,
    required this.position,
    this.surface = const TrackRowSurface(),
    required this.onTap,
    required this.favorite,
    required this.onToggleFavorite,
    required this.onAddToPlaylist,
  });

  /// 行数据（标题 / 歌手 / 封面 / 时长 / 当前曲目身份）。
  final TrackRowModel row;

  /// 列表内位置（首末行外侧圆角）。
  final M3ECardPosition position;

  /// 列表表面的呈现口径（表格规范 / 封面尺寸 / 勾选策略）。
  final TrackRowSurface surface;

  /// 点击整行；null 为不可点（如缺少可播放曲目的结果项）。
  final VoidCallback? onTap;

  /// 是否已收藏（决定菜单文案与图标）。
  final bool favorite;

  /// 收藏 / 取消收藏。
  final VoidCallback onToggleFavorite;

  /// 加入列表（收藏 / 历史 / 自建列表，流程由调用方注入）。
  final VoidCallback onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    final actions = trackRowActionMenu(
      context,
      favorite: favorite,
      onToggleFavorite: onToggleFavorite,
      onAddToPlaylist: onAddToPlaylist,
    );
    return TrackRow(
      model: row,
      surface: surface,
      position: position,
      onTap: onTap,
      onSecondaryTap: rowActionsAtPointer(context, actions),
      // 触摸端行尾 ⋮ 常显；桌面端入口是行表面右键，不再渲染 ⋮。
      trailing: isDesktopPlatform()
          ? null
          : RowActionMenuButton(
              actions: actions,
              semanticLabel: _l10n(context).trackActionsTooltip,
            ),
    );
  }
}
