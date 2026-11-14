import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import '../providers/playback_provider.dart';
import '../services/library/playlist_batch_create.dart';
import 'add_to_playlist_sheet.dart' show showPlaylistNameDialog;

/// 队列「存为列表」：新建一个列表，按队列存储顺序批量加入。
///
/// 入口只有播放器「更多」菜单；动作本体放在这里，
/// 避免菜单与队列两处各写一遍「创建 → 批量写入 → 失败回滚」。
/// 失败（创建成功但批量写入失败）删除刚建的空列表，不在侧栏留下半成品；
/// 重复键由存储层跳过，结果只报 added / skipped。
Future<void> saveQueueAsPlaylist(
  BuildContext context,
  List<Track> queue,
) async {
  final provider = context.read<LibraryProvider?>();
  if (provider == null || queue.isEmpty) return;
  final l10n = AppLocalizations.of(context)!;
  final contextName = context
      .read<PlaybackProvider?>()
      ?.snapshot
      .context
      ?.name
      ?.trim();
  final name = await showPlaylistNameDialog(
    context,
    title: l10n.playlistCreate,
    confirmLabel: l10n.playlistCreateConfirm,
    existingNames: [for (final item in provider.playlists) item.name],
    initialValue: (contextName ?? '').isEmpty
        ? l10n.queuePlaylistDefaultName
        : contextName!,
  );
  if (name == null || !context.mounted) return;
  try {
    final result = await createPlaylistWithRollback<({int added})>(
      name: name,
      createPlaylist: provider.createPlaylist,
      write: (playlistId) async {
        final addedAt = DateTime.now().millisecondsSinceEpoch;
        final outcome = await provider.addTracksToPlaylist(playlistId, [
          for (final track in queue)
            PlaylistTrack.fromTrack(track, addedAt: addedAt),
        ]);
        if (outcome.isFailure) {
          throw PlaylistBatchWriteException(outcome.error);
        }
        return (added: outcome.changed);
      },
      deletePlaylist: (playlistId) async {
        await provider.deletePlaylist(playlistId);
      },
    );
    if (!context.mounted) return;
    M3ESnackbar.show(
      context,
      message: l10n.queueSavedAsPlaylist(
        name,
        result.added,
        queue.length - result.added,
      ),
    );
  } catch (_) {
    if (context.mounted) {
      M3ESnackbar.show(context, message: l10n.queueSaveFailed);
    }
  }
}
