import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import 'add_to_library.dart';
import 'track_actions_menu.dart';
import 'track_row.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 曲目行尾 ⋮ 菜单（「收藏 / 加入列表」）的唯一实现：行本体 [TrackMenuTile]
/// 与自建行（队列 / 搜索结果）共用同一份条目、图标、语义与领域接线。
///
/// 三种构造：
/// - 通用构造：收藏态与两条动作由调用方注入（发现域 / 收藏域适配层）——
///   组件不认具体 provider，避免把 DiscoverProvider 焊进共享件；
/// - [TrackRowActionsMenu.track] / [TrackRowActionsMenu.searchItem]：领域
///   构造，收藏订阅（每行一个 `select`，只重建菜单不重建整表）与写入流程
///   （收藏切换 + snackbar、加入列表走统一目标弹层）收进菜单自身，自建行
///   不再各抄一份。
///
/// 桌面增强对所有构造一致：套 [HoverReveal]，⋮ 随**整行** hover / 键盘焦点
/// 显现，触摸端恒显（[HoverReveal] 非桌面原样返回）；[controller] 是行表面
/// 右键（[TrackRow.onSecondaryTap]）打开同一份菜单的句柄，由行的 State 持有。
class TrackRowActionsMenu extends StatelessWidget {
  /// 通用构造：收藏态与两条动作由调用方注入。
  const TrackRowActionsMenu({
    super.key,
    required this.favorite,
    required this.onToggleFavorite,
    required this.onAddToPlaylist,
    this.controller,
  })  : track = null,
        searchItem = null;

  /// 领域曲目（队列等自建行）：收藏态订阅与写入走 LibraryProvider。
  const TrackRowActionsMenu.track({
    super.key,
    required Track this.track,
    this.controller,
  })  : favorite = false,
        onToggleFavorite = null,
        onAddToPlaylist = null,
        searchItem = null;

  /// 搜索结果项（Map 域自建行，item 由 SearchProvider 生成、含 `_sourceTrack`）。
  const TrackRowActionsMenu.searchItem({
    super.key,
    required Map<String, dynamic> item,
    this.controller,
  })  : favorite = false,
        onToggleFavorite = null,
        onAddToPlaylist = null,
        track = null,
        searchItem = item;

  /// 是否已收藏（决定菜单文案与图标）；领域构造下由行内订阅得出。
  final bool favorite;

  /// 收藏 / 取消收藏（通用构造必填；领域构造下由 LibraryProvider 接线）。
  final VoidCallback? onToggleFavorite;

  /// 加入列表（通用构造必填；领域构造下由 LibraryProvider 接线）。
  final VoidCallback? onAddToPlaylist;

  /// 领域曲目；非空时菜单自己做收藏订阅与写入。
  final Track? track;

  /// 搜索结果项；非空时菜单自己做收藏订阅与写入。
  final Map<String, dynamic>? searchItem;

  /// 行尾 ⋮ 的外部打开句柄（行表面右键）；null = 仅锚点按钮可开。
  final TrackActionsMenuController? controller;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final Track? track = this.track;
    final Map<String, dynamic>? searchItem = this.searchItem;
    final bool favorite;
    final VoidCallback? onToggleFavorite;
    final VoidCallback? onAddToPlaylist;
    if (track != null) {
      favorite = context.select<LibraryProvider?, bool>(
        (provider) =>
            provider?.isFavorite(track.id.sourceKey, track.id.id) ?? false,
      );
      onToggleFavorite = () => unawaited(_toggleTrackFavorite(context, track));
      onAddToPlaylist = () => unawaited(_addTrackToPlaylist(context, track));
    } else if (searchItem != null) {
      favorite = context.select<LibraryProvider?, bool>(
        (provider) => provider?.isFavoriteSearchItem(searchItem) ?? false,
      );
      onToggleFavorite =
          () => unawaited(_toggleSearchItemFavorite(context, searchItem));
      onAddToPlaylist =
          () => unawaited(_addSearchItemToPlaylist(context, searchItem));
    } else {
      favorite = this.favorite;
      onToggleFavorite = this.onToggleFavorite;
      onAddToPlaylist = this.onAddToPlaylist;
    }
    return HoverReveal(
      child: TrackActionsMenu(
        controller: controller,
        tooltip: l10n.trackActionsTooltip,
        entries: [
          M3EMenuEntry(
            label: favorite ? l10n.favoriteRemove : l10n.favoriteAdd,
            leading: Icon(
              favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            ),
            value: 'favorite',
          ),
          M3EMenuEntry(
            label: l10n.addToPlaylist,
            leading: const Icon(Icons.playlist_add_rounded),
            value: 'add',
          ),
        ],
        onSelected: (value) {
          switch (value) {
            case 'favorite':
              onToggleFavorite?.call();
            case 'add':
              onAddToPlaylist?.call();
          }
        },
      ),
    );
  }
}

/// 领域曲目收藏切换：菜单文案已表达状态，反馈只留 snackbar 确认。
Future<void> _toggleTrackFavorite(BuildContext context, Track track) async {
  final library = context.read<LibraryProvider?>();
  if (library == null) return;
  final favorite = await library.toggleFavoriteTrack(track);
  if (!context.mounted) return;
  final l10n = _l10n(context);
  M3ESnackbar.show(
    context,
    message: favorite ? l10n.favoriteAdd : l10n.favoriteRemove,
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

/// 搜索结果项收藏切换；无法识别来源曲目时静默忽略。
Future<void> _toggleSearchItemFavorite(
  BuildContext context,
  Map<String, dynamic> item,
) async {
  final library = context.read<LibraryProvider?>();
  if (library == null) return;
  final favorite = await library.toggleFavoriteSearchItem(item);
  if (favorite == null || !context.mounted) return;
  final l10n = _l10n(context);
  M3ESnackbar.show(
    context,
    message: favorite ? l10n.favoriteAdd : l10n.favoriteRemove,
  );
}

/// 搜索结果项加入列表；无法识别来源曲目时静默忽略。
Future<void> _addSearchItemToPlaylist(
  BuildContext context,
  Map<String, dynamic> item,
) async {
  final library = context.read<LibraryProvider?>();
  if (library == null) return;
  final track = library.playlistTrackFromSearchItem(item);
  if (track == null) return;
  await addTracksToLibraryTarget(
    context,
    provider: library,
    tracks: [track],
  );
}

/// 曲目行（行渲染 + 行尾 ⋮ 菜单）：点击播放 + 行尾 ⋮ 菜单。
///
/// 收藏域（歌手页 / 专辑页）经 [FavoriteTrackTile] 适配层使用；发现详情页
/// 直接使用。菜单固定「收藏 / 加入列表」两条动作——各入口的语义本来就相同，
/// 差异只在领域对象上，因此收藏态与写入流程都由调用方注入：
/// - 收藏态用 `select` 订阅后传入（组件不认具体 provider，避免把
///   DiscoverProvider / LibraryProvider 焊进共享件，也避免整表重建）；
/// - 行尾元信息（时长）由调用方按数据可得性传入，未知传 null 不占位。
///
/// 菜单本体（条目 / 桌面 hover 显现 / 右键打开）见 [TrackRowActionsMenu]，
/// 本组件只负责把行内容与行尾插槽接起来；⋮ 的外部打开句柄必须与行同生命
/// 周期（建在 build 里每次重建都会注册一份新回调），所以本组件是 Stateful。
class TrackMenuTile extends StatefulWidget {
  const TrackMenuTile({
    super.key,
    required this.title,
    required this.artist,
    this.artists,
    this.coverUrl,
    this.trailingText,
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

  /// 行尾元信息（时长）；未知传 null 不占位。
  final String? trailingText;

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
  State<TrackMenuTile> createState() => _TrackMenuTileState();
}

class _TrackMenuTileState extends State<TrackMenuTile> {
  /// 行尾 ⋮ 的外部打开句柄（行表面右键 → 同一份菜单）。
  final TrackActionsMenuController _menu = TrackActionsMenuController();

  @override
  Widget build(BuildContext context) {
    return TrackRow(
      title: widget.title,
      artist: widget.artist,
      artists: widget.artists,
      coverUrl: widget.coverUrl,
      trailingText: widget.trailingText,
      position: widget.position,
      onTap: widget.onTap,
      // 右键只在桌面接线（[TrackRow] 内部判定），触摸端无次级手势。
      onSecondaryTap: _menu.open,
      trailing: TrackRowActionsMenu(
        controller: _menu,
        favorite: widget.favorite,
        onToggleFavorite: widget.onToggleFavorite,
        onAddToPlaylist: widget.onAddToPlaylist,
      ),
    );
  }
}
