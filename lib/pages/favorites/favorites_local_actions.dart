/// 收藏页本地歌曲动作：删除 / 改标题 / 刷新标签 / 重定位 / 核对缓存。
///
/// 与 [FavoritesActions] 分开是为了让下载、播放与列表写入的编排保持聚焦；
/// 这里只处理「设备本地文件」这一组低频动作。
library;

import 'package:file_picker/file_picker.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/download.dart' show DownloadedTrack;
import '../../domain/models/local_cache_index.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/collection_actions.dart';
import '../../providers/collection_presenter.dart';
import '../../providers/collection_session.dart';
import '../../providers/local_songs_collection.dart';
import '../../providers/library_provider.dart';
import '../../services/cache_service.dart';
import '../../services/download/download_manager.dart';
import '../../services/local/local_metadata_service.dart';
import '../../services/local_cache_index_store.dart';
import '../../services/notification_service.dart';
import '../../theme/m3e_context.dart';
import '../../widgets/settings/settings_tiles.dart';

/// 本地删除的反馈：缓存行沿用原提示（写入中 / 无缓存），失败统一提示。
void reportFavoritesLocalDelete({
  required BuildContext context,
  required AppLocalizations l10n,
  required CollectionLocalDeleteOutcome outcome,
  required NotificationService? notification,
}) {
  for (final item in outcome.items) {
    switch (item.status) {
      case CollectionLocalDeleteStatus.skipped:
        notification?.showSnackBar(
          item.skippedFiles > 0
              ? l10n.trackInfoCachePlaying
              : l10n.trackCacheEmpty,
        );
      case CollectionLocalDeleteStatus.deleted:
      case CollectionLocalDeleteStatus.removed:
      case CollectionLocalDeleteStatus.cleared:
      case CollectionLocalDeleteStatus.failed:
      case CollectionLocalDeleteStatus.unavailable:
        break;
    }
  }
  if (outcome.hasFailure) {
    M3ESnackbar.show(context, message: l10n.operationFailed);
  }
}

/// 本地歌曲多选删除：下载副本删文件、导入项只移除记录、缓存行清缓存
/// （统一确认一次；全部处理完才清空选择）。
Future<void> deleteFavoritesSelectedLocalSongs({
  required BuildContext context,
  required AppLocalizations l10n,
  required CollectionView view,
  required CollectionSession session,
  required CollectionActions actions,
  required NotificationService? notification,
  required bool Function() isActive,
}) async {
  final selected = actions.localSongsOf(session.selectedRows(view));
  if (selected.isEmpty || !actions.localDataAvailable) return;
  final confirmed = await _confirmDeleteLocalSongs(
    context: context,
    l10n: l10n,
    selected: selected,
  );
  if (confirmed != true || !context.mounted || !isActive()) return;
  final outcome = await actions.deleteLocalSongs(selected);
  if (!context.mounted || !isActive()) return;
  reportFavoritesLocalDelete(
    context: context,
    l10n: l10n,
    outcome: outcome,
    notification: notification,
  );
  session.clearSelection();
}

/// 本地歌曲单条删除（行动作入口：触摸端 ⋮ / 桌面右键）：先确认再按行
/// 来源删（下载副本删文件、导入项只移出列表、缓存行清缓存）。
Future<void> deleteFavoritesLocalSong({
  required BuildContext context,
  required AppLocalizations l10n,
  required CollectionLocalSong song,
  required CollectionActions actions,
  required NotificationService? notification,
  required bool Function() isActive,
}) async {
  if (!actions.localDataAvailable) return;
  final confirmed = await _confirmDeleteLocalSongs(
    context: context,
    l10n: l10n,
    selected: [song],
  );
  if (confirmed != true || !context.mounted || !isActive()) return;
  final outcome = await actions.deleteLocalSongs([song]);
  if (!context.mounted || !isActive()) return;
  reportFavoritesLocalDelete(
    context: context,
    l10n: l10n,
    outcome: outcome,
    notification: notification,
  );
}

/// 删除确认：按选中项构成给文案（全导入 = 只移出列表；全缓存 = 清缓存；
/// 混合 = 三者都说明）。
Future<bool?> _confirmDeleteLocalSongs({
  required BuildContext context,
  required AppLocalizations l10n,
  required List<CollectionLocalSong> selected,
}) {
  final anyCached = selected.any((song) => song.isCached);
  final anyDownloaded = selected.any(
    (song) => !song.isCached && !song.isImported,
  );
  final anyImported = selected.any((song) => song.isImported);
  final String title;
  final String content;
  if (anyCached && !anyDownloaded && !anyImported) {
    title = l10n.localSongsCachedRemove;
    content = l10n.localSongsCachedRemoveConfirm;
  } else if (anyCached) {
    title = l10n.downloadDelete;
    content = l10n.localSongsMixedRemoveConfirm;
  } else if (anyImported && !anyDownloaded) {
    title = l10n.localSongsRemove;
    content = l10n.localSongsRemoveConfirm;
  } else if (anyImported) {
    title = l10n.downloadDelete;
    content = l10n.downloadDeleteConfirmMixed;
  } else {
    title = l10n.downloadDelete;
    content = l10n.downloadDeleteConfirm;
  }
  return M3EDialog.show<bool>(
    context,
    dialog: M3EDialog(
      title: title,
      content: Text(content),
      actions: [
        M3EButton.text(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.cancel),
        ),
        M3EButton.filled(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.delete),
        ),
      ],
    ),
  );
}

/// 只改标题：先尝试写文件标签；格式不支持 / 失败 / 文件不见时再让用户
/// 选择「只在 Molia 中修改」。
Future<void> editFavoritesLocalTitle({
  required BuildContext context,
  required AppLocalizations l10n,
  required DownloadedTrack record,
  required LocalMetadataService? service,
  required NotificationService? notifications,
  required bool Function() isActive,
}) async {
  if (service == null) return;
  final controller = TextEditingController(text: record.title);
  final title = await M3EDialog.show<String>(
    context,
    dialog: M3EDialog(
      title: l10n.localTitleEdit,
      content: SizedBox(
        width: settingsDialogWidth(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            M3ETextField(
              controller: controller,
              autofocus: true,
              maxLength: 200,
              label: l10n.localTitleEdit,
            ),
            const SizedBox(height: kSettingsSmallSpacing),
            Text(
              l10n.localTitleNote,
              style: context.typeScale.bodySmall.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        M3EButton.text(
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
          child: Text(l10n.cancelButton),
        ),
        M3EButton.text(
          onPressed: () =>
              Navigator.of(context, rootNavigator: true).pop(controller.text),
          child: Text(l10n.save),
        ),
      ],
    ),
  );
  controller.dispose();
  if (title == null || !context.mounted || !isActive()) return;
  var status = await service.editTitle(record, title);
  if (status == LocalTitleEditStatus.invalidTitle) {
    notifications?.showSnackBar(l10n.localTitleInvalid);
    return;
  }
  if (status == LocalTitleEditStatus.appOnlyRequired &&
      context.mounted &&
      isActive()) {
    final appOnly = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.localTitleMoliaOnly,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: Text(l10n.localTitleMoliaOnlyNote),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
            child: Text(l10n.cancelButton),
          ),
          M3EButton.text(
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(true),
            child: Text(l10n.localTitleMoliaOnly),
          ),
        ],
      ),
    );
    if (appOnly != true || !isActive()) return;
    status = await service.editTitle(record, title, appOnly: true);
  }
  if (!isActive()) return;
  if (status == LocalTitleEditStatus.written) {
    notifications?.showSnackBar(l10n.localTitleUpdated);
  } else if (status == LocalTitleEditStatus.failed) {
    notifications?.showErrorSnackBar(l10n.localTitleFailed);
  }
}

/// 显式「从文件刷新信息」：重读标签并覆盖展示元数据；扫描不会自动调用。
Future<void> refreshFavoritesLocalMetadata({
  required AppLocalizations l10n,
  required DownloadedTrack record,
  required DownloadManager? manager,
  required NotificationService? notifications,
  required bool Function() isActive,
}) async {
  final updated = await manager?.refreshLocalMetadata(record);
  if (!isActive()) return;
  if (updated == null) {
    notifications?.showErrorSnackBar(l10n.localTitleFailed);
    return;
  }
  notifications?.showSnackBar(l10n.save);
}

/// 重定位：选一个可读音频文件，身份 / 引用保持不变。
Future<void> locateFavoritesLocalFile({
  required AppLocalizations l10n,
  required DownloadedTrack record,
  required DownloadManager? manager,
  required NotificationService? notifications,
  required bool Function() isActive,
}) async {
  if (manager == null) return;
  String? path;
  try {
    final files = await FilePicker.pickFiles(type: FileType.audio);
    path = files.singleOrNull?.path;
  } catch (_) {
    path = null;
  }
  if (path == null || path.isEmpty) return;
  final result = await manager.relocate(record, path);
  if (!isActive()) return;
  switch (result) {
    case LocalRelocateResult.relocated:
      notifications?.showSnackBar(l10n.localFileRelocated);
    case LocalRelocateResult.unsupportedFormat:
      notifications?.showErrorSnackBar(l10n.localFileMissing);
    case LocalRelocateResult.fileMissing:
      notifications?.showErrorSnackBar(l10n.localFileMissing);
  }
}

/// 显式核对本地缓存：当前播放历史只作为元数据候选，缓存目录确认存在
/// 完整文件的曲目才补索引；同时清理索引里已无缓存文件的行。
Future<void> checkFavoritesLocalCache({
  required BuildContext context,
  required AppLocalizations l10n,
  required LocalCacheIndexStore? index,
  required CacheService? cache,
  required LibraryProvider library,
  required bool Function() isActive,
}) async {
  if (index == null || cache == null) return;
  final candidates = [
    for (final entry in library.history)
      LocalCacheIndexEntry.fromHistoryEntry(entry),
  ];
  try {
    await index.reconcile(
      candidates: candidates,
      scanCache: cache.audioCacheCompleteIndexOrNull,
    );
  } catch (e) {
    debugPrint('[Favorites] 核对本地缓存失败: $e');
    if (!context.mounted || !isActive()) return;
    M3ESnackbar.show(context, message: l10n.operationFailed);
    return;
  }
  if (!context.mounted || !isActive()) return;
  M3ESnackbar.show(context, message: l10n.localCacheCheckDone);
}
