import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/discover.dart';
import '../l10n/app_localizations.dart';
import '../providers/discover_provider.dart';
import 'add_to_playlist_sheet.dart';
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

/// 「加入列表」流程：加载我的列表 → 底部弹层选择目标（收藏/历史/自建）→ 写入并反馈。
Future<void> addDiscoverTrackToPlaylist(
  BuildContext context,
  DiscoverTrack track,
) async {
  final provider = context.read<DiscoverProvider>();
  final l10n = _l10n(context);

  await provider.refreshPlaylists();
  if (!context.mounted) return;
  final selection = await showAddToPlaylistSheet(
    context,
    playlists: provider.playlists,
    onCreate: provider.createPlaylist,
  );
  if (selection == null || !context.mounted) return;
  switch (selection.kind) {
    case AddToPlaylistTargetKind.favorites:
      final added = await provider.addToFavorites(track);
      if (!context.mounted) return;
      M3ESnackbar.show(
        context,
        message: added
            ? l10n.playlistAddedTo(l10n.favoritesPlaylistName)
            : l10n.playlistAlreadyContains,
      );
    case AddToPlaylistTargetKind.history:
      await provider.addToHistory(track);
      if (!context.mounted) return;
      M3ESnackbar.show(
        context,
        message: l10n.playlistAddedTo(l10n.libraryHistory),
      );
    case AddToPlaylistTargetKind.playlist:
      final playlistId = selection.playlistId!;
      final added = await provider.addToPlaylist(playlistId, track);
      if (!context.mounted) return;
      // 新建的列表可能尚未进入 provider 缓存，强制刷新后再取显示名。
      await provider.refreshPlaylists();
      if (!context.mounted) return;
      var name = '';
      for (final playlist in provider.playlists) {
        if (playlist.id == playlistId) {
          name = playlist.name;
          break;
        }
      }
      M3ESnackbar.show(
        context,
        message:
            added ? l10n.playlistAddedTo(name) : l10n.playlistAlreadyContains,
      );
  }
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
