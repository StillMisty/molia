/// 收藏页动作编排：播放 / 排序落位 / 批量写入 / 下载 / 导出 / 本地歌曲。
///
/// 页面只负责在当前点击时组装端口与回调；这里不持有 State，也不在 build
/// 里读 provider。所有对话框、底栏提示与平台动作都保留原来的语义。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/download.dart'
    show DownloadedTrack, kLocalSourceKey;
import '../../domain/models/library.dart';
import '../../domain/models/library_browse.dart';
import '../../domain/models/track.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_providers.dart';
import '../../providers/collection_actions.dart';
import '../../providers/collection_batch_download_adapter.dart';
import '../../providers/collection_io_commands.dart';
import '../../providers/collection_presenter.dart';
import '../../providers/collection_session.dart';
import '../../providers/favorites_view_model.dart';
import '../../providers/discover_provider.dart';
import '../../providers/library_outcome.dart';
import '../../providers/library_provider.dart';
import '../../providers/lyrics_provider.dart';
import '../../providers/playlist_batch_download.dart';
import '../../providers/sync_provider.dart';
import '../../services/download/download_manager.dart';
import '../../services/download/download_records.dart';
import '../../services/download/download_requests.dart';
import '../../services/haptics.dart';
import '../../services/notification_service.dart';
import '../../services/playlist/playlist_import_service.dart';
import '../../services/save_as.dart';
import '../../widgets/labels/download_failure_label.dart';
import '../../widgets/labels/save_as_label.dart';
import '../../widgets/collection_handoff.dart';
import '../../widgets/collection_track_list.dart';
import '../../widgets/cover_picker_sheet.dart';
import '../../widgets/download_data_saver_guard.dart';
import '../../widgets/playlist_sheets.dart';
import '../../widgets/row_actions.dart';
import '../../widgets/track_row.dart';
import '../../widgets/track_row_actions.dart';
import '../source_swap_page.dart';
import 'favorites_import.dart';
import 'favorites_local_actions.dart';

/// 写结果上报：失败时由页面弹统一提示。
typedef FavoritesMutationReporter = void Function(
  LibraryMutationOutcome outcome,
);

/// 从当前合集可见行的 [index] 起播（随机播放传 [shuffle]）。
Future<void> playFavoritesView({
  required CollectionActions actions,
  required CollectionView view,
  required int index,
  bool shuffle = false,
}) => actions.play(view, startIndex: index, shuffle: shuffle);

/// 拖动排序落位：列表重建 / 持久化顺序在动作模块。
Future<void> reorderFavoritesTracks({
  required CollectionActions actions,
  required CollectionView view,
  required int from,
  required int to,
  required FavoritesMutationReporter reportMutation,
}) async {
  HapticsService.lightImpact();
  reportMutation(await actions.reorder(view, from, to));
}

/// 清空播放历史（先确认）。
Future<void> confirmClearFavoritesHistory({
  required BuildContext context,
  required AppLocalizations l10n,
  required Future<LibraryMutationOutcome> Function() clearHistory,
  required FavoritesMutationReporter reportMutation,
}) async {
  final confirmed = await M3EDialog.show<bool>(
    context,
    dialog: M3EDialog(
      title: l10n.historyClear,
      content: Text(l10n.historyClearConfirm),
      actions: [
        M3EButton.text(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.cancel),
        ),
        M3EButton.filled(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.historyClear),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    reportMutation(await clearHistory());
  }
}

/// 多选写入的统一收口：会话只在成功时清空选择，失败保留选择并提示。
Future<void> applyFavoritesSelection({
  required CollectionSession session,
  required CollectionView view,
  required Future<LibraryMutationOutcome> Function(List<CollectionRow> rows)
  write,
  required FavoritesMutationReporter reportMutation,
}) async {
  reportMutation(await session.applySelection(view, write));
}

/// 多选收藏 / 取消收藏：加 / 删意图由当前收藏状态推导。
Future<void> setFavoritesSelectionFavorite({
  required CollectionSession session,
  required CollectionActions actions,
  required CollectionView view,
  required FavoritesMutationReporter reportMutation,
}) => applyFavoritesSelection(
  session: session,
  view: view,
  write: (rows) =>
      actions.setFavorite(rows, change: actions.favoriteChange(rows)),
  reportMutation: reportMutation,
);

Future<void> removeFavoritesSelectionFromPlaylist({
  required CollectionSession session,
  required CollectionActions actions,
  required CollectionView view,
  required FavoritesMutationReporter reportMutation,
}) => applyFavoritesSelection(
  session: session,
  view: view,
  write: (rows) => actions.removeFromPlaylist(view, rows),
  reportMutation: reportMutation,
);

Future<void> deleteFavoritesSelectionHistory({
  required CollectionSession session,
  required CollectionActions actions,
  required CollectionView view,
  required FavoritesMutationReporter reportMutation,
}) => applyFavoritesSelection(
  session: session,
  view: view,
  write: actions.deleteHistory,
  reportMutation: reportMutation,
);

/// 多选「加入列表」：写入成功才清空选择。
Future<void> copyFavoritesSelectionToPlaylist({
  required CollectionSession session,
  required CollectionActions actions,
  required CollectionView view,
}) async {
  final copied = await actions.copyToLibrary(view, session.selectedRows(view));
  if (copied) session.clearSelection();
}

/// 选中行里「现在就能下载」的曲目（本地 / 已下载 / 进行中都不算）。
List<Track> favoritesDownloadableTracks({
  required CollectionView view,
  required List<CollectionRow> selectedRows,
  required LibraryProvider provider,
  required DownloadRequests requests,
}) {
  if (!view.isCustom && !view.isFavorites) return const [];
  final tracks = [
    for (final row in selectedRows)
      if (row is TrackCollectionRow) row.track,
  ];
  final actionable = PlaylistBatchDownloadAction.downloadableRows(
    tracks,
    toTrack: provider.trackFromPlaylistTrack,
    statusOf: requests.statusOf,
  );
  return [for (final row in actionable) provider.trackFromPlaylistTrack(row)];
}

/// 多选下载。
Future<void> downloadFavoritesSelection({
  required BuildContext context,
  required AppLocalizations l10n,
  required CollectionView view,
  required List<CollectionRow> selectedRows,
  required LibraryProvider provider,
  required DownloadRequests requests,
  required CollectionSession session,
  required CollectionIoCommands Function() ioCommands,
  required bool Function() isActive,
}) async {
  final tracks = favoritesDownloadableTracks(
    view: view,
    selectedRows: selectedRows,
    provider: provider,
    requests: requests,
  );
  if (tracks.isEmpty) return;
  await runFavoritesBatchDownload(
    context: context,
    l10n: l10n,
    ioCommands: ioCommands,
    tracks: tracks,
    isActive: isActive,
    onSucceeded: () {
      if (isActive()) session.clearSelection();
    },
  );
}

/// 「下载全部」：当前合集的曲目。
Future<void> downloadFavoritesPlaylist({
  required BuildContext context,
  required AppLocalizations l10n,
  required CollectionView view,
  required LibraryProvider provider,
  required CollectionIoCommands Function() ioCommands,
  required bool Function() isActive,
}) async {
  if (view.tracks.isEmpty) return;
  await runFavoritesBatchDownload(
    context: context,
    l10n: l10n,
    ioCommands: ioCommands,
    tracks: [
      for (final track in view.tracks) provider.trackFromPlaylistTrack(track),
    ],
    isActive: isActive,
  );
}

/// 批量下载的统一反馈：命令返回类型化结果，这里只负责提示。
Future<void> runFavoritesBatchDownload({
  required BuildContext context,
  required AppLocalizations l10n,
  required CollectionIoCommands Function() ioCommands,
  required List<Track> tracks,
  required bool Function() isActive,
  void Function()? onSucceeded,
}) async {
  final outcome = await ioCommands().downloadTracks(
    tracks: tracks,
    confirm: () => confirmDownloadOnDataSaver(context),
    onStarted: onSucceeded,
    onEnqueued: (enqueued) {
      if (!context.mounted || !isActive()) return;
      M3ESnackbar.show(
        context,
        message: enqueued == 0
            ? l10n.downloadsNothingToAdd
            : l10n.downloadsQueued(enqueued),
      );
    },
  );
  if (!context.mounted || !isActive()) return;
  switch (outcome) {
    case CollectionBatchDownloadFinished(
      :final enqueued,
      :final done,
      :final failed,
    ):
      if (enqueued == 0) return;
      M3ESnackbar.show(context, message: l10n.downloadsBatchDone(done, failed));
    case CollectionBatchDownloadFailed(:final error):
      final message = downloadFailureMessage(l10n, error);
      if (message != null) {
        M3ESnackbar.show(context, message: message);
      }
    case CollectionBatchDownloadCancelled():
      break;
  }
}

/// 导出列表：M3U8 / Molia 备份。
Future<void> exportFavoritesPlaylist({
  required WidgetRef ref,
  required BuildContext context,
  required AppLocalizations l10n,
  required PlaylistInfo playlist,
  required CollectionView view,
  required FavoritesIoCommandsFactory ioCommands,
  required bool Function() isActive,
}) async {
  final SyncProvider? sync = ref.read(syncProvider);
  final format = await showPlaylistExportSheet(
    context,
    moliaAvailable: sync != null,
  );
  if (!context.mounted || !isActive() || format == null) return;
  final SaveAs? saveAs = ref.read(saveAsProvider);
  final outcome = await ioCommands(sync: sync, saveAs: saveAs).exportPlaylist(
    playlist: playlist,
    displayName: view.displayName,
    tracks: view.tracks,
    format: switch (format) {
      PlaylistExportFormat.m3u8 => CollectionExportFormat.m3u8,
      PlaylistExportFormat.molia => CollectionExportFormat.molia,
    },
    dialogTitle: switch (format) {
      PlaylistExportFormat.m3u8 => l10n.playlistExportM3u8,
      PlaylistExportFormat.molia => l10n.playlistExportMolia,
    },
  );
  if (!context.mounted || !isActive()) return;
  switch (outcome) {
    case CollectionExportSaved(
      :final displayPath,
      :final kind,
      :final missingFiles,
    ):
      M3ESnackbar.show(
        context,
        message: playlistExportMessage(l10n, kind, displayPath, missingFiles),
      );
    case CollectionExportFailed():
      M3ESnackbar.show(context, message: l10n.playlistExportFailed);
    case CollectionExportCancelled():
      break;
  }
}

/// 列表详情（名称 / 分组）编辑。
Future<void> editFavoritesPlaylistDetails({
  required BuildContext context,
  required PlaylistInfo playlist,
  required List<PlaylistInfo> playlists,
  required LibraryProvider provider,
  required bool Function() isActive,
  required VoidCallback onSaved,
}) async {
  final existingNames = [
    for (final item in playlists)
      if (item.id != playlist.id && !item.isFavorites) item.name,
  ];
  final saved = await showPlaylistDetailsSheet(
    context,
    playlist: playlist,
    existingNames: existingNames,
    onSave: (name, folder) async {
      final outcome = await provider.updatePlaylistDetails(
        playlist.id,
        name: name,
        // 描述编辑入口已移除；保留已有值，避免改名 / 改组时把旧描述抹掉。
        description: playlist.description,
        folder: folder,
      );
      return !outcome.isFailure;
    },
  );
  if (saved == true && isActive()) onSaved();
}

/// 更换列表封面。
Future<void> changeFavoritesPlaylistCover({
  required BuildContext context,
  required PlaylistInfo playlist,
  required LibraryProvider provider,
  required bool Function() isActive,
}) async {
  final key = await provider.ensurePlaylistCoverKey(playlist.id);
  if (!context.mounted || !isActive() || key == null) return;
  await showCoverPickerSheet(
    context,
    playlistCoverKey: key,
    fileNameBase: playlist.name,
    onPlaylistCoverChanged: (hasCover) async {
      await provider.setPlaylistCoverKey(playlist.id, hasCover ? key : null);
    },
  );
}

/// 曲库分组起播：队列组装 / 洗牌 / 触感 / 上下文名都在 TrackHandoff。
Future<void> playFavoritesBrowseTracks({
  required WidgetRef ref,
  required BuildContext context,
  required List<BrowseTrack> tracks,
  required String contextName,
  required math.Random? random,
  bool shuffle = false,
  int startIndex = 0,
}) async {
  if (tracks.isEmpty) return;
  final library = ref.read(libraryProvider);
  final handoff = TrackHandoffCollectionHandoff(context, random: random);
  await handoff.play(
    [
      for (final track in tracks)
        library.trackFromPlaylistTrack(
          track.toPlaylistTrack(addedAt: 0, playlistId: 0),
        ),
    ],
    startIndex: startIndex.clamp(0, tracks.length - 1),
    shuffle: shuffle,
    contextName: contextName,
  );
}

/// 曲库分组「加入列表」。
Future<void> addFavoritesBrowseToLibrary({
  required BuildContext context,
  required List<BrowseTrack> tracks,
}) async {
  if (tracks.isEmpty) return;
  final handoff = TrackHandoffCollectionHandoff(context);
  await handoff.addToLibrary(
    [
      for (final track in tracks)
        track.toPlaylistTrack(addedAt: 0, playlistId: 0),
    ],
    includeFavorites: true,
    includeHistory: false,
  );
}

/// 曲库换源入口（与行动作的换源共用页面）。
Future<void> swapFavoritesBrowseTrack({
  required WidgetRef ref,
  required BuildContext context,
  required BrowseTrack track,
  required LyricsProvider lyrics,
}) async {
  final library = ref.read(libraryProvider);
  await showSourceSwapPage(
    context,
    seed: library.trackFromPlaylistTrack(track.toPlaylistTrack(addedAt: 0)),
    lyricsProvider: lyrics,
  );
}

/// 行动作接线：投影器决定构成，动作载荷由 [CollectionActions.rowCommands]
/// 按行变体归一；页面只保留「哪些动作」的投影，具体流程都在这里。
List<RowAction> buildFavoritesRowActions({
  required BuildContext context,
  required WidgetRef ref,
  required AppLocalizations l10n,
  required CollectionSession session,
  required CollectionView view,
  required CollectionRow row,
  required CollectionActions actions,
  required bool Function() isActive,
}) {
  final primary = buildCollectionRowActions(
    l10n: l10n,
    specs: session.rowActionsFor(row, view),
    wiring: _favoritesActionWiring(
      context: context,
      ref: ref,
      l10n: l10n,
      view: view,
      row: row,
      actions: actions,
      isActive: isActive,
    ),
  );
  // 智能列表行只保留播放 / 收藏 / 加入列表（文件不见再加定位 / 移除），
  // 不追加下载 / 评论等在线动作。
  if (view.isSmartList) return primary;
  return mergeRowActions(
    primary,
    trackCommonActions(context, _favoritesDomainTrack(ref, row)),
  );
}

CollectionRowActionWiring _favoritesActionWiring({
  required BuildContext context,
  required WidgetRef ref,
  required AppLocalizations l10n,
  required CollectionView view,
  required CollectionRow row,
  required CollectionActions actions,
  required bool Function() isActive,
}) {
  final commands = actions.rowCommands(view, row);
  final swap = commands.swap;
  final localSong = commands.localSong;
  final localRecord = row is LocalSongCollectionRow ? row.song.record : null;
  Future<void> Function()? reported(
    Future<LibraryMutationOutcome> Function()? write,
  ) => write == null
      ? null
      : () async {
          final outcome = await write();
          if (outcome.isFailure && context.mounted && isActive()) {
            M3ESnackbar.show(context, message: l10n.operationFailed);
          }
        };
  return CollectionRowActionWiring(
    onCopy: commands.copy,
    onSwap: swap == null
        ? null
        : () => showSourceSwapPage(
            context,
            seed: swap.track,
            lyricsProvider: ref.read(lyricsProvider.notifier),
            playlistId: swap.playlistId,
            historyKey: swap.historyKey,
          ),
    onRemoveFromPlaylist: reported(commands.removeFromPlaylist),
    onRemoveFromFavorites: reported(commands.removeFromFavorites),
    onToggleFavorite: reported(commands.toggleFavorite),
    onDeleteHistory: reported(commands.deleteHistory),
    onDeleteLocalSong: localSong == null
        ? null
        : () => deleteFavoritesLocalSong(
            context: context,
            l10n: l10n,
            song: localSong,
            actions: actions,
            notification: ref.read(notificationServiceProvider),
            isActive: isActive,
          ),
    onEditLocalTitle: localRecord == null
        ? null
        : () => editFavoritesLocalTitle(
            context: context,
            l10n: l10n,
            record: localRecord,
            service: ref.read(localMetadataServiceProvider),
            notifications: ref.read(notificationServiceProvider),
            isActive: isActive,
          ),
    onLocateLocalFile: localRecord?.isMissing == true
        ? () => locateFavoritesLocalFile(
            l10n: l10n,
            record: localRecord!,
            manager: ref.read(downloadManagerProvider),
            notifications: ref.read(notificationServiceProvider),
            isActive: isActive,
          )
        : null,
    onRefreshLocalInfo: localRecord == null
        ? null
        : () => refreshFavoritesLocalMetadata(
            l10n: l10n,
            record: localRecord,
            manager: ref.read(downloadManagerProvider),
            notifications: ref.read(notificationServiceProvider),
            isActive: isActive,
          ),
    isFavorite: commands.isFavorite,
    localSongCached: commands.localSongCached,
    localSongImported: commands.localSongImported,
  );
}

/// 合集行 → 领域曲目（公共动作的能力位 / 平台 id 需要领域形状）。
Track _favoritesDomainTrack(WidgetRef ref, CollectionRow row) {
  final library = ref.read(libraryProvider);
  return switch (row) {
    TrackCollectionRow(:final track) => library.trackFromPlaylistTrack(track),
    HistoryCollectionRow(:final entry) => library.trackFromHistoryEntry(entry),
    LocalSongCollectionRow(:final song) => library.trackFromPlaylistTrack(
      song.toPlaylistTrack(addedAt: 0),
    ),
  };
}

/// 收藏页当前点击时的合集 I/O 命令工厂。
CollectionIoCommands buildFavoritesIoCommands(
  WidgetRef ref,
  BuildContext context, {
  DiscoverProvider? discover,
  DownloadRequests? requests,
  SyncProvider? sync,
  SaveAs? saveAs,
}) {
  final provider = ref.read(libraryProvider);
  final DownloadRecords? records = ref.read(downloadRecordsProvider);
  const files = FilePickerCollectionPlaylistFiles();
  return CollectionIoCommands(
    filePicker: files,
    fileReader: files,
    importService: PlaylistImportService(
      localImporter: DownloadRecordsPlaylistLocalImporter(
        records,
        ref.read(downloadManagerProvider),
      ),
      resolver: LibraryPlaylistKeyResolver(provider, records),
    ),
    importTarget: LibraryProviderPlaylistImportTarget(provider),
    playlistNames: () => [for (final item in provider.playlists) item.name],
    reviewImport: (plan) async =>
        (await showPlaylistImportReviewSheet(context, plan: plan)) == true,
    linkImporter: discover == null
        ? null
        : DiscoverCollectionLinkImporter(discover),
    exportLibrary: LibraryProviderCollectionExportLibrary(provider, records),
    backup: sync == null ? null : SyncCollectionPlaylistBackup(sync),
    saver: saveAs == null ? null : SaveAsCollectionExportSaver(saveAs),
    downloader: requests == null
        ? null
        : RequestsCollectionBatchDownloader(requests),
  );
}

/// 消费一次「定位当前播放曲目」结果：滚动到目标行 / 给底栏提示。
void applyFavoritesLocateResult({
  required BuildContext context,
  required AppLocalizations l10n,
  required FavoritesLocateResult? result,
  required ScrollController controller,
  required TrackRowSurface surface,
  required void Function(String message) showMessage,
}) {
  if (result == null) return;
  switch (result.kind) {
    case FavoritesLocateKind.noTrack:
      showMessage(l10n.favoritesLocateNoTrack);
    case FavoritesLocateKind.missing:
      showMessage(l10n.favoritesLocateMissing);
    case FavoritesLocateKind.reveal:
      final index = result.index;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        CollectionTrackList.revealIndex(
          context,
          controller,
          index: index,
          surface: surface,
        );
      });
  }
}

/// 本地歌曲行对应的下载 / 导入记录（非 local 源或没有记录 = null）。
DownloadedTrack? findFavoritesLocalRecord(
  DownloadRecords? records,
  BrowseTrack track,
) {
  if (track.sourceKey != kLocalSourceKey) return null;
  for (final record in records?.downloads ?? const <DownloadedTrack>[]) {
    if (record.localSongId == track.songId) return record;
  }
  return null;
}

/// 曲库行「从文件刷新信息」：重读标签并提示结果。
Future<void> refreshFavoritesBrowseLocal({
  required WidgetRef ref,
  required BuildContext context,
  required AppLocalizations l10n,
  required DownloadedTrack? record,
  required bool Function() isActive,
}) async {
  if (record == null) return;
  final DownloadManager? manager = ref.read(downloadManagerProvider);
  final NotificationService? notifications = ref.read(
    notificationServiceProvider,
  );
  final updated = await manager?.refreshLocalMetadata(record);
  if (!context.mounted || !isActive()) return;
  notifications?.showSnackBar(
    updated == null ? l10n.localTitleFailed : l10n.localInfoUpdated,
  );
}
