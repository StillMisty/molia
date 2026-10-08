import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/library.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import 'add_to_playlist_sheet.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 「加入列表」统一流程：我的收藏 / 播放历史 / 自建列表。
///
/// 收藏页（曲目/历史行、多选）与发现页共用这一份实现——选择目标、写入、
/// 解析新建列表名、反馈提示都在这里；调用方只提供规范化的 [PlaylistTrack]
/// 列表与是否展示收藏/历史选项。返回是否真正选择了目标（取消为 false）。
Future<bool> addTracksToLibraryTarget(
  BuildContext context, {
  required LibraryProvider provider,
  required List<PlaylistTrack> tracks,
  bool includeFavorites = true,
  bool includeHistory = true,
}) async {
  if (tracks.isEmpty) return false;
  final l10n = _l10n(context);

  await provider.refreshPlaylists();
  if (!context.mounted) return false;
  final selection = await showAddToPlaylistSheet(
    context,
    playlists: provider.customPlaylists,
    onCreate: provider.createPlaylist,
    includeFavorites: includeFavorites,
    includeHistory: includeHistory,
  );
  if (selection == null || !context.mounted) return false;

  int added;
  String name;
  switch (selection.kind) {
    case AddToPlaylistTargetKind.favorites:
      name = l10n.favoritesPlaylistName;
      added = await provider.addTracksToFavorites(tracks);
    case AddToPlaylistTargetKind.history:
      name = l10n.libraryHistory;
      added = await provider.addTracksToHistory(tracks);
    case AddToPlaylistTargetKind.playlist:
      final playlistId = selection.playlistId!;
      added = await provider.addTracksToPlaylist(playlistId, tracks);
      // 新建的列表可能尚未进入 provider 缓存，强制刷新后再取显示名。
      await provider.refreshPlaylists();
      if (!context.mounted) return false;
      name = '';
      for (final playlist in provider.customPlaylists) {
        if (playlist.id == playlistId) {
          name = playlist.name;
          break;
        }
      }
  }
  if (!context.mounted) return false;
  M3ESnackbar.show(
    context,
    message:
        added > 0 ? l10n.playlistAddedTo(name) : l10n.playlistAlreadyContains,
  );
  return true;
}
