import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/track.dart';
import '../providers/library_provider.dart';
import 'track_menu_tile.dart';
import 'track_row.dart';

/// 曲目行（行尾 ⋮ 菜单：收藏 / 加入列表）的收藏域适配层。
///
/// 与 [TrackMenuTile] 的分工：行渲染、菜单形状与桌面行表面右键入口都在
/// [TrackMenuTile]，本组件只负责「行内容从哪来、收藏态怎么订阅」。歌手页 /
/// 专辑页共用 [FavoriteTrackTile.track]：
/// - [FavoriteTrackTile.track]：领域曲目（歌手页 / 专辑页），标题 / 歌手
///   标签（[Track.artistLabel]）/ 封面 / 时长全部取领域值；
/// - 默认构造：行数据（[TrackRowModel]）与收藏源由调用方注入（`favoriteOf`
///   里做 `context.select`）；搜索结果行因表格列版式自建 [TrackRow]，不走
///   本层。
///
/// 收藏态一律在本组件 build 里 `select`（每行一个订阅）；不能挪到
/// SliverList 的 itemBuilder 中直接 select（会整表重建并触发断言）。
class FavoriteTrackTile extends StatelessWidget {
  /// 领域曲目构造（歌手页 / 专辑页共用）。
  factory FavoriteTrackTile.track({
    Key? key,
    required Track track,
    String? fallbackCoverUrl,
    required M3ECardPosition position,
    required VoidCallback onTap,
    required VoidCallback onToggleFavorite,
    required VoidCallback onAddToPlaylist,
    TrackRowSurface surface = const TrackRowSurface(),
  }) {
    return FavoriteTrackTile(
      key: key,
      row: TrackRowModel(
        title: track.title,
        artist: track.artistLabel,
        coverUrl: track.artwork?.uri.toString() ?? fallbackCoverUrl,
        durationMs: track.duration?.inMilliseconds,
        album: track.album ?? '',
        trackId: track.id,
      ),
      surface: surface,
      position: position,
      onTap: onTap,
      favoriteOf: (context) => favoriteOfTrack(context, track),
      onToggleFavorite: onToggleFavorite,
      onAddToPlaylist: onAddToPlaylist,
    );
  }

  /// 通用构造：行数据与收藏源由调用方注入。
  const FavoriteTrackTile({
    super.key,
    required this.row,
    required this.position,
    this.surface = const TrackRowSurface(),
    this.onTap,
    required this.favoriteOf,
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

  /// 本行收藏态（在 build 内以 `context.select` 订阅）。
  final bool Function(BuildContext context) favoriteOf;

  /// 收藏 / 取消收藏。
  final VoidCallback onToggleFavorite;

  /// 加入列表（收藏 / 历史 / 自建列表，流程由调用方注入）。
  final VoidCallback onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    return TrackMenuTile(
      row: row,
      surface: surface,
      position: position,
      onTap: onTap,
      favorite: favoriteOf(context),
      onToggleFavorite: onToggleFavorite,
      onAddToPlaylist: onAddToPlaylist,
    );
  }
}

/// 领域曲目的收藏态（歌手页 / 专辑页共用；每行一个 `select` 订阅）。
bool favoriteOfTrack(BuildContext context, Track track) =>
    context.select<LibraryProvider?, bool>(
      (library) =>
          library?.isFavorite(track.id.sourceKey, track.id.id) ?? false,
    );
