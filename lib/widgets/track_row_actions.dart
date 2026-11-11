/// 曲目公共动作扩展器：加入队列 / 下载 / 评论 / 专辑 / 歌手。
///
/// 所有曲目菜单（搜索结果、发现详情、专辑 / 歌手、收藏合集、队列）都从这里
/// 追加同一组动作，避免「某个入口少一条评论 / 专辑」的漂移。动作只在能力位
/// 成立时构造：菜单里看得到的条目一定可执行（见 [RowAction] 的约定）。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/source.dart';
import '../domain/models/track.dart';
import '../domain/ports/source_registry.dart';
import '../l10n/app_localizations.dart';
import '../providers/comments_provider.dart';
import '../providers/playback_provider.dart';
import '../services/download/download_intent.dart';
import '../utils/download_failure_label.dart';
import 'download_data_saver_guard.dart';
import 'row_actions.dart';
import 'track_actions.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 公共动作（按能力位过滤；顺序 = 菜单顺序）。
///
/// [includeAddToQueue] 只在队列行传 false：队列里「把已在队列的歌再加入
/// 队列」没有意义，而且队列行的动作已经由队列编辑命令承担。
List<RowAction> trackCommonActions(
  BuildContext context,
  Track track, {
  bool includeAddToQueue = true,
}) {
  final l10n = _l10n(context);
  final actions = <RowAction>[];

  if (includeAddToQueue) {
    // 无当前曲目 = 没有队列可加入（产品约定：入口直接隐藏）。
    final canEnqueue = context.select<PlaybackProvider?, bool>(
      (provider) => provider?.hasTrack ?? false,
    );
    if (canEnqueue) {
      actions.add(
        RowAction(
          icon: Icons.playlist_play_rounded,
          label: l10n.addToQueue,
          onPressed: () => unawaited(_enqueueTrack(context, track)),
        ),
      );
    }
  }

  // 入口可见性也由意图层给出：本地 / 已下载 / 进行中统一隐藏，UI 不再
  // 分别读 supported / DownloadRecords / DownloadTask。
  final canDownload = context.select<DownloadLauncher?, bool>(
    (launcher) => launcher?.statusOf(track) == DownloadIntentStatus.ready,
  );
  if (canDownload) {
    actions.add(
      RowAction(
        icon: Icons.download_rounded,
        label: l10n.downloadAction,
        onPressed: () => unawaited(_downloadTrack(context, track)),
      ),
    );
  }

  final capabilities = context.select<SourceRegistry?, SourceCapabilities?>(
    (registry) => registry?.byKey(track.id.sourceKey)?.capabilities,
  );
  final supportsComments = context.select<CommentsProvider?, bool>(
    (comments) => comments?.supports(track) ?? false,
  );
  if (supportsComments) {
    actions.add(
      RowAction(
        icon: Icons.forum_rounded,
        label: l10n.commentsTitle,
        onPressed: () => unawaited(openTrackComments(context, track: track)),
      ),
    );
  }
  if (track.platformAlbumId != null && (capabilities?.collection ?? false)) {
    actions.add(
      RowAction(
        icon: Icons.album_rounded,
        label: l10n.trackInfoAlbum,
        onPressed: () => unawaited(openTrackAlbum(context, track: track)),
      ),
    );
  }
  if (platformArtistOf(track) != null && (capabilities?.artist ?? false)) {
    actions.add(
      RowAction(
        icon: Icons.person_rounded,
        label: l10n.trackInfoArtist,
        onPressed: () => unawaited(openTrackArtist(context, track: track)),
      ),
    );
  }
  return actions;
}

/// 合并动作：主入口自己的动作（收藏 / 加入列表 / 队列编辑）在前，
/// [extra] 公共动作居中，移除 / 删除类保持最后（菜单顺序全 App 一致）。
List<RowAction> mergeRowActions(
  List<RowAction> primary,
  List<RowAction> extra,
) {
  final tail = [
    for (final action in primary)
      if (action.destructive) action,
    for (final action in extra)
      if (action.destructive) action,
  ];
  return [
    for (final action in primary)
      if (!action.destructive) action,
    for (final action in extra)
      if (!action.destructive) action,
    ...tail,
  ];
}

/// 加入队列：只在已有当前曲目时可达（入口已按能力位隐藏）。
Future<void> _enqueueTrack(BuildContext context, Track track) async {
  final playback = context.read<PlaybackProvider?>();
  if (playback == null || !playback.hasTrack) return;
  final l10n = _l10n(context);
  try {
    await playback.enqueueDomainTracks([track]);
    if (context.mounted) {
      M3ESnackbar.show(context, message: l10n.addedToQueue);
    }
  } catch (_) {
    if (context.mounted) {
      M3ESnackbar.show(context, message: l10n.operationFailed);
    }
  }
}

/// 直接按默认音质下载：保留省流确认，成功 / 失败都有回执。
///
/// 与本地数据页不同，菜单入口不跳页：入队后立即确认一句，失败在任务结束时
/// 补提示。`DownloadTask.done` 挂在 unawaited 外层时必须自行 catch，
/// 否则失败任务会变成未处理异步错误。
Future<void> _downloadTrack(BuildContext context, Track track) async {
  final launcher = context.read<DownloadLauncher?>();
  if (launcher == null) return;
  final l10n = _l10n(context);
  if (!await confirmDownloadOnDataSaver(context)) return;
  if (!context.mounted) return;
  final DownloadStartResult result;
  try {
    result = await launcher.start(track);
  } catch (error) {
    final message = downloadFailureMessage(l10n, error);
    if (message != null && context.mounted) {
      M3ESnackbar.show(context, message: message);
    }
    return;
  }
  switch (result) {
    case DownloadStarted(:final task):
      if (context.mounted) {
        M3ESnackbar.show(context, message: l10n.downloadStarted);
      }
      try {
        await task.done;
      } catch (error) {
        if (!context.mounted) return;
        final message = downloadFailureMessage(l10n, error);
        if (message != null) {
          M3ESnackbar.show(context, message: message);
        }
      }
    case DownloadAlreadyDownloaded():
      if (context.mounted) {
        M3ESnackbar.show(context, message: l10n.downloadAlreadyExists);
      }
    case DownloadAlreadyActive():
      if (context.mounted) {
        M3ESnackbar.show(context, message: l10n.downloadStatusDownloading);
      }
    case DownloadUnsupported(:final reason):
      if (context.mounted) {
        M3ESnackbar.show(context, message: downloadFailureLabel(l10n, reason));
      }
  }
}
