import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/discover.dart';
import '../providers/discover_provider.dart';
import '../providers/library_provider.dart';
import 'add_to_library.dart';
import 'track_menu_tile.dart';

/// 收藏 / 取消收藏：图标态本身即反馈，不弹提示。
Future<void> toggleDiscoverFavorite(
  BuildContext context,
  DiscoverTrack track,
) async {
  await context.read<DiscoverProvider>().toggleFavorite(track);
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

  const DiscoverTrackTile({
    super.key,
    required this.track,
    required this.position,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final favorite = context.select<DiscoverProvider, bool>(
      (provider) => provider.isFavorite(track),
    );
    return TrackMenuTile(
      title: track.title,
      artist: track.artist,
      coverUrl: track.coverUrl,
      position: position,
      onTap: onTap,
      favorite: favorite,
      onToggleFavorite: () => toggleDiscoverFavorite(context, track),
      onAddToPlaylist: () => addDiscoverTrackToPlaylist(context, track),
    );
  }
}
