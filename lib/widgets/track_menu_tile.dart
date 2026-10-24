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
import 'playback_selectors.dart';
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
  return [
    RowAction(
      icon: favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      label: favorite ? l10n.favoriteRemove : l10n.favoriteAdd,
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
    onToggleFavorite: () => unawaited(_toggleTrackFavorite(context, track)),
    onAddToPlaylist: () => unawaited(_addTrackToPlaylist(context, track)),
  );
}

/// 领域曲目收藏切换：菜单文案已表达状态，反馈只留 snackbar 确认。
Future<void> _toggleTrackFavorite(BuildContext context, Track track) async {
  final library = context.read<LibraryProvider?>();
  if (library == null) return;
  final outcome = await library.toggleFavoriteTrack(track);
  if (!context.mounted) return;
  final l10n = _l10n(context);
  // 写失败不能报「已收藏 / 已取消」：菜单的下次打开仍按 provider 缓存的真实态渲染。
  M3ESnackbar.show(
    context,
    message: outcome.isFailure
        ? l10n.operationFailed
        : outcome.isFavorite
            ? l10n.favoriteAdd
            : l10n.favoriteRemove,
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
/// - 行尾元信息（时长）由调用方按数据可得性传入，未知传 null 不占位。
///
/// 动作定义见 [trackRowActionMenu]。
class TrackMenuTile extends StatelessWidget {
  const TrackMenuTile({
    super.key,
    required this.title,
    required this.artist,
    this.artists,
    this.coverUrl,
    this.columns,
    this.trailingText,
    this.trackId,
    required this.position,
    required this.onTap,
    required this.favorite,
    required this.onToggleFavorite,
    required this.onAddToPlaylist,
  });

  final String title;
  final String artist;

  /// 逐名可点的歌手（搜索结果行传入；空则退化为纯文本 [artist]）。
  final List<TrackRowArtist>? artists;

  final String? coverUrl;

  /// 宽屏表格列（桌面宽内容列表传入）：行内改表格布局，列宽与表头同源；
  /// null = 单列布局（逐像素不变）。
  final TrackRowColumns? columns;

  /// 行尾元信息（时长）；未知传 null 不占位。
  final String? trailingText;

  /// 行身份（收藏域 / 发现域适配层传入）：用于逐行订阅「是否当前曲目」。
  /// null = 不订阅（独立测试 / 没有曲目身份的通用行）。
  final TrackId? trackId;

  /// 列表内位置（首末行外侧圆角）。
  final M3ECardPosition position;

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
    final TrackId? trackId = this.trackId;
    final CurrentTrackState current = trackId == null
        ? (isCurrent: false, isPlaying: false)
        : selectCurrentTrackState(context, trackId);
    return TrackRow(
      title: title,
      artist: artist,
      artists: artists,
      coverUrl: coverUrl,
      columns: columns,
      trailingText: trailingText,
      isCurrent: current.isCurrent,
      isPlaying: current.isPlaying,
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
