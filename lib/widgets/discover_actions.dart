import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/discover.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/discover_provider.dart';
import '../providers/library_provider.dart';
import 'add_to_library.dart';
import 'track_menu_tile.dart';
import 'track_row.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 收藏 / 取消收藏：成功只靠图标态反馈；失败必须提示，否则按钮看起来
/// 「点了没反应」（仓库异常已在 provider 边界收口成 outcome）。
Future<void> toggleDiscoverFavorite(
  BuildContext context,
  DiscoverTrack track,
) async {
  final outcome = await context.read<DiscoverProvider>().toggleFavorite(track);
  if (!context.mounted || !outcome.isFailure) return;
  M3ESnackbar.show(context, message: _l10n(context).operationFailed);
}

/// 「加入列表」流程：与收藏页共用 [addTracksToLibraryTarget]（选择目标 →
/// 写入 → 解析新建列表名 → 反馈提示）。
Future<void> addDiscoverTrackToPlaylist(
  BuildContext context,
  DiscoverTrack track,
) {
  final discover = context.read<DiscoverProvider>();
  final library = context.read<LibraryProvider>();
  return addTracksToLibraryTarget(
    context,
    provider: library,
    tracks: [discover.toPlaylistTrack(track)],
  );
}

/// 发现曲目行：点击播放；菜单支持收藏 / 加入列表（[TrackMenuTile] 的
/// 发现域适配层：只把 DiscoverProvider 的状态与写入流程接上去）。
///
/// 只订阅本行的收藏态（`select`），避免曲目长列表因 provider 任意通知整表重建。
class DiscoverTrackTile extends StatelessWidget {
  final DiscoverTrack track;

  /// 列表内位置（首末行外侧圆角）。
  final M3ECardPosition position;

  final VoidCallback onTap;

  /// 宽屏表格列规范（桌面宽内容列表传入）：非空 = 表格档，与表头同源；
  /// null = 双行档（逐像素不变）。
  final TrackRowColumnSpec? tableSpec;

  const DiscoverTrackTile({
    super.key,
    required this.track,
    required this.position,
    required this.onTap,
    this.tableSpec,
  });

  @override
  Widget build(BuildContext context) {
    final favorite = context.select<DiscoverProvider, bool>(
      (provider) => provider.isFavorite(track),
    );
    return TrackMenuTile(
      row: TrackRowModel(
        title: track.title,
        artist: track.artist,
        coverUrl: track.coverUrl,
        durationMs: track.durationMs,
        album: track.album,
        trackId: TrackId(track.sourceKey, track.songId),
      ),
      surface: TrackRowSurface(tableSpec: tableSpec),
      position: position,
      onTap: onTap,
      favorite: favorite,
      onToggleFavorite: () => toggleDiscoverFavorite(context, track),
      onAddToPlaylist: () => addDiscoverTrackToPlaylist(context, track),
    );
  }
}
