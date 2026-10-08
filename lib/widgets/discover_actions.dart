import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/discover.dart';
import '../l10n/app_localizations.dart';
import '../providers/discover_provider.dart';
import '../providers/library_provider.dart';
import 'add_to_library.dart';
import 'library_cover.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

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

/// 发现曲目行：点击播放；菜单支持收藏 / 加入列表。
class DiscoverTrackTile extends StatelessWidget {
  final DiscoverTrack track;
  final VoidCallback onTap;

  const DiscoverTrackTile({
    super.key,
    required this.track,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DiscoverProvider>();
    final l10n = _l10n(context);
    final favorite = provider.isFavorite(track);
    return M3EListItem(
      leading: LibraryCoverThumb(url: track.coverUrl),
      headline: track.title,
      supportingText: track.artist,
      onTap: onTap,
      trailing: M3EMenu.entries(
        position: M3EMenuAnchorPosition.bottomEnd,
        anchorBuilder: (context, open) => M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          icon: Icon(Icons.more_vert_rounded),
          onPressed: open,
        ),
        onSelected: (value) {
          switch (value) {
            case 'favorite':
              toggleDiscoverFavorite(context, track);
            case 'add':
              addDiscoverTrackToPlaylist(context, track);
          }
        },
        entries: [
          M3EMenuEntry(
            label: favorite ? l10n.favoriteRemove : l10n.favoriteAdd,
            value: 'favorite',
          ),
          M3EMenuEntry(
            label: l10n.addToPlaylist,
            value: 'add',
          ),
        ],
      ),
    );
  }
}
