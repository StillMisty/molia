/// 下载管理页：任务队列（运行 / 等待 / 失败重试）/ 批量下载 / 文件维护。
///
/// 从设置 › 数据与存储进入。口径：
/// - 全局严格串行（单 worker FIFO），页面只展示可操作的任务，**不展示已
///   完成列表**（已完成在收藏 › 本地歌曲）；
/// - 批量下载只负责入队，页面不锁；失败音频任务留在失败区可重试；
/// - **明确不做断点续传与队列跨重启恢复**：平台直链多为一次性签名地址，
///   重启后只保留既有的 `.part` 清扫（页面内说明）。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../domain/models/failure.dart';
import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import '../providers/playback_provider.dart';
import '../services/download/download_service.dart';
import '../services/notification_service.dart';
import '../theme/m3e_context.dart';
import '../utils/download_failure_label.dart';
import '../utils/download_task_label.dart';
import '../utils/source_quality_label.dart';
import '../widgets/download_data_saver_guard.dart';
import '../widgets/settings/settings_subpage.dart';
import '../widgets/settings/settings_tiles.dart';

/// 等待任务列表最多展示多少行，其余折叠成「还有 N 首等待中」。
const int _maxQueuedRows = 20;

class DownloadsManagePage extends StatefulWidget {
  const DownloadsManagePage({super.key});

  @override
  State<DownloadsManagePage> createState() => _DownloadsManagePageState();
}

class _DownloadsManagePageState extends State<DownloadsManagePage> {
  /// 维护动作（清扫 / 补发布 / 孤儿删除）单独占用，不影响下载操作。
  bool _busy = false;

  /// 下载根目录 Future：只在服务实例变化时重建，记录 / 任务变化不重新解析。
  DownloadService? _rootService;
  Future<String?>? _rootPath;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final downloads = context.read<DownloadService?>();
    if (!identical(downloads, _rootService)) {
      _rootService = downloads;
      _rootPath = downloads?.rootPath() ?? Future<String?>.value();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final downloads = context.watch<DownloadService?>();
    final queueLength = context.select<PlaybackProvider, int>(
      (provider) => provider.snapshot.queue.length,
    );

    return SettingsSubPage(
      title: l10n.downloadsManageTitle,
      children: [
        _buildTasksSection(l10n, downloads),
        const SizedBox(height: kSettingsSectionSpacing),
        // 批量下载：当前队列（跳过已下载与本地曲目）。只入队，不阻塞页面。
        SettingsSectionCard(
          title: l10n.downloadsBatchSection,
          children: [
            SettingsNavTile(
              key: const Key('downloadsBatchQueueItem'),
              icon: Icons.playlist_add_rounded,
              title: l10n.downloadsBatchQueue,
              subtitle: l10n.downloadsBatchQueueSubtitle(queueLength),
              onTap: downloads == null ||
                      !downloads.supported ||
                      queueLength == 0
                  ? null
                  : () {
                      final queue =
                          context.read<PlaybackProvider>().snapshot.queue;
                      unawaited(_batchDownload(downloads, queue));
                    },
            ),
            SettingsNavTile(
              key: const Key('downloadsBatchPlaylistItem'),
              icon: Icons.queue_music_rounded,
              title: l10n.downloadsBatchPlaylist,
              subtitle: l10n.downloadsBatchPlaylistSubtitle,
              onTap: downloads == null || !downloads.supported
                  ? null
                  : () => unawaited(_pickPlaylist()),
            ),
            SettingsInfoTile(
              icon: Icons.info_rounded,
              title: l10n.downloadsNoResume,
              subtitle: '',
            ),
          ],
        ),
        const SizedBox(height: kSettingsSectionSpacing),
        // 文件维护：半成品清扫 + 孤儿文件回收 + 下载目录展示。
        SettingsSectionCard(
          title: l10n.downloadsMaintenanceSection,
          children: [
            SettingsNavTile(
              key: const Key('downloadsCleanupPartsItem'),
              icon: Icons.cleaning_services_rounded,
              title: l10n.downloadsCleanupParts,
              subtitle: l10n.downloadsCleanupPartsSubtitle,
              onTap: _busy || downloads == null
                  ? null
                  : () => unawaited(_cleanupParts(downloads)),
            ),
            SettingsNavTile(
              key: const Key('downloadsCleanupOrphansItem'),
              icon: Icons.delete_sweep_rounded,
              title: l10n.downloadsCleanupOrphans,
              subtitle: l10n.downloadsCleanupOrphansSubtitle,
              isDestructive: true,
              onTap: _busy || downloads == null
                  ? null
                  : () => unawaited(_cleanupOrphans(downloads)),
            ),
            // 公共目录补发布只在 Android 有语义（其余平台下载根目录本身
            // 就是公共目录）。
            if (downloads?.publisherSupported ?? false)
              SettingsNavTile(
                key: const Key('downloadsPublishPublicItem'),
                icon: Icons.public_rounded,
                title: l10n.downloadsPublishPublic,
                subtitle: l10n.downloadsPublishPublicSubtitle,
                onTap: _busy || downloads == null
                    ? null
                    : () => unawaited(_publishPublic(downloads)),
              ),
            FutureBuilder<String?>(
              future: _rootPath,
              builder: (context, snapshot) => SettingsInfoTile(
                key: const Key('downloadsRootInfoItem'),
                icon: Icons.folder_rounded,
                title: l10n.downloadLocationInfo,
                subtitle: downloads?.supported == false
                    ? l10n.downloadLocationUnsupported
                    : snapshot.data ?? l10n.cacheUsageComputing,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 任务区只订阅队列结构（增删 / 状态），每行再单独订阅自己的进度。
  Widget _buildTasksSection(AppLocalizations l10n, DownloadService? downloads) {
    if (downloads == null) {
      return SettingsSectionCard(
        title: l10n.downloadsTasksSection,
        children: [
          SettingsInfoTile(
            key: const Key('downloadsTasksEmpty'),
            icon: Icons.check_circle_rounded,
            title: l10n.downloadsNoTasks,
            subtitle: '',
          ),
        ],
      );
    }
    return ListenableBuilder(
      listenable: downloads.taskChanges,
      builder: (context, _) {
        final groups = downloads.taskGroups;
        final running = groups.running;
        final queued = groups.queued;
        final failed = groups.failed;
        final visibleQueued = queued.take(_maxQueuedRows).toList();
        final hiddenQueued = queued.length - visibleQueued.length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSectionCard(
              title: l10n.downloadsTasksSection,
              children: [
                if (running.isEmpty && queued.isEmpty)
                  SettingsInfoTile(
                    key: const Key('downloadsTasksEmpty'),
                    icon: Icons.check_circle_rounded,
                    title: l10n.downloadsNoTasks,
                    subtitle: '',
                  )
                else ...[
                  if (queued.length > 1)
                    SettingsNavTile(
                      key: const Key('downloadsCancelAllItem'),
                      icon: Icons.playlist_remove_rounded,
                      title: l10n.downloadsCancelAll,
                      subtitle: '',
                      isDestructive: true,
                      onTap: () => _cancelQueued(downloads),
                    ),
                  for (final task in [...running, ...visibleQueued])
                    _taskTile(l10n, downloads, task),
                  if (hiddenQueued > 0)
                    SettingsInfoTile(
                      key: const Key('downloadsWaitingMore'),
                      icon: Icons.hourglass_bottom_rounded,
                      title: l10n.downloadsWaitingMore(hiddenQueued),
                      subtitle: '',
                    ),
                ],
              ],
            ),
            if (failed.isNotEmpty) ...[
              const SizedBox(height: kSettingsSectionSpacing),
              SettingsSectionCard(
                title: l10n.downloadsFailedSection,
                children: [
                  SettingsNavTile(
                    key: const Key('downloadsRetryAllItem'),
                    icon: Icons.refresh_rounded,
                    title: l10n.downloadsRetryAll,
                    subtitle: '',
                    onTap: () => _retryAll(downloads, failed),
                  ),
                  for (final task in failed) _failedTile(l10n, downloads, task),
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  /// 单条运行 / 等待任务：行内只订阅任务自身的进度与状态。
  Widget _taskTile(
    AppLocalizations l10n,
    DownloadService downloads,
    DownloadTask task,
  ) {
    return ListenableBuilder(
      listenable: task,
      builder: (context, _) {
        final running = task.status == DownloadTaskStatus.running;
        final status = downloadTaskStatusLabel(l10n, task);
        final quality = task.quality.isEmpty
            ? ''
            : sourceQualityLabel(l10n, task.quality);
        return SettingsInfoTile(
          key: Key('downloadsTask_${task.key}'),
          icon: running ? Icons.downloading_rounded : Icons.schedule_rounded,
          title: task.track.title,
          subtitle: [
            status,
            quality,
          ].where((part) => part.isNotEmpty).join(' · '),
          trailing: M3EIconButton(
            key: Key('downloadsTaskCancel_${task.key}'),
            variant: M3EIconButtonVariant.standard,
            icon: const Icon(Icons.close_rounded),
            semanticLabel: l10n.downloadCancel,
            onPressed: task.isActive
                ? () => downloads.cancelTrack(task.track)
                : null,
          ),
        );
      },
    );
  }

  /// 失败任务：失败原因 + 重试 + 移除（顶部另有「全部重试」）。
  Widget _failedTile(
    AppLocalizations l10n,
    DownloadService downloads,
    DownloadTask task,
  ) {
    return ListenableBuilder(
      listenable: task,
      builder: (context, _) {
        final reason = downloadTaskStatusLabel(l10n, task);
        return SettingsInfoTile(
          key: Key('downloadsFailed_${task.key}'),
          icon: Icons.error_outline_rounded,
          title: task.track.title,
          subtitle: reason,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              M3EIconButton(
                key: Key('downloadsFailedRetry_${task.key}'),
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(Icons.refresh_rounded),
                semanticLabel: l10n.downloadsRetry,
                onPressed: () =>
                    unawaited(_retryTask(downloads, task, notifyFailure: true)),
              ),
              M3EIconButton(
                key: Key('downloadsFailedRemove_${task.key}'),
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(Icons.close_rounded),
                semanticLabel: l10n.downloadsRemove,
                onPressed: () => downloads.dismissTask(task),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 批量下载：省流确认 → 一次性入队 → 立即提示；页面不锁。
  Future<void> _batchDownload(
    DownloadService downloads,
    List<Track> queue,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final candidates = downloads.batchCandidates(queue);
    if (candidates.isEmpty) {
      _showMessage(l10n.downloadsNothingToAdd);
      return;
    }
    if (!await confirmDownloadOnDataSaver(context) || !mounted) return;
    try {
      final (done, failed) = await downloads.downloadBatch(
        [for (final candidate in candidates) candidate.track],
        onEnqueued: (enqueued) {
          if (!mounted) return;
          _showMessage(
            enqueued == 0
                ? l10n.downloadsNothingToAdd
                : l10n.downloadsQueued(enqueued),
          );
        },
      );
      if (!mounted) return;
      _showMessage(l10n.downloadsBatchDone(done, failed));
    } on SourceFailure catch (failure) {
      if (!mounted || failure.kind == FailureKind.cancelled) return;
      _showMessage(downloadFailureLabel(l10n, failure));
    } catch (_) {
      if (mounted) _showMessage(l10n.downloadFailed(''));
    }
  }

  /// 选择歌单 → 批量下载（跳过已下载与本地曲目）。
  Future<void> _pickPlaylist() async {
    final l10n = AppLocalizations.of(context)!;
    final library = context.read<LibraryProvider?>();
    final downloads = context.read<DownloadService?>();
    if (library == null || downloads == null) return;
    final playlists = library.playlists;
    if (playlists.isEmpty) {
      _showMessage(l10n.downloadsEmpty);
      return;
    }
    final navigator = Navigator.of(context, rootNavigator: true);
    final picked = await M3EDialog.show<PlaylistInfo>(
      context,
      dialog: M3EDialog(
        title: l10n.downloadsPickPlaylist,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final playlist in playlists)
                  M3EListItem(
                    key: Key('downloadsPlaylist_${playlist.id}'),
                    leading: const Icon(Icons.queue_music_rounded),
                    headline: playlist.isFavorites
                        ? l10n.favoritesPlaylistName
                        : playlist.name,
                    onTap: () => navigator.pop(playlist),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(),
            child: Text(l10n.cancel),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final tracks = await library.loadPlaylistTracks(picked.id);
    if (!mounted) return;
    final domainTracks = [
      for (final track in tracks) library.trackFromPlaylistTrack(track),
    ];
    await _batchDownload(downloads, domainTracks);
  }

  /// 重试单条失败任务（失败再次落回失败区，并提示原因）。
  Future<void> _retryTask(
    DownloadService downloads,
    DownloadTask task, {
    required bool notifyFailure,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await downloads.retryTask(task);
    } on SourceFailure catch (failure) {
      if (!notifyFailure || !mounted || failure.kind == FailureKind.cancelled) {
        return;
      }
      _showMessage(downloadFailureLabel(l10n, failure));
    } catch (_) {
      if (!notifyFailure || !mounted) return;
      _showMessage(l10n.downloadFailed(''));
    }
  }

  /// 全部重试：逐条重新入队（队列仍然严格串行）。
  void _retryAll(DownloadService downloads, List<DownloadTask> failed) {
    for (final task in failed) {
      unawaited(_retryTask(downloads, task, notifyFailure: false));
    }
  }

  /// 取消全部等待任务（运行中的由行内取消按钮处理）。
  void _cancelQueued(DownloadService downloads) {
    for (final task in downloads.taskGroups.queued) {
      downloads.cancelTrack(task.track);
    }
  }

  /// 补发布：把还没有公共副本的下载拷进系统「下载」目录（Android）。
  Future<void> _publishPublic(DownloadService downloads) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      final (published, failed) = await downloads.publishMissingPublicCopies();
      if (!mounted) return;
      _showMessage(l10n.downloadsPublishPublicDone(published, failed));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cleanupParts(DownloadService downloads) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      final count = await downloads.cleanupIncompleteDownloads();
      if (!mounted) return;
      _showMessage(l10n.downloadsCleanupPartsDone(count));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 孤儿清理：先扫描可识别文件并展示数量 / 前几个文件名，确认后再删。
  Future<void> _cleanupOrphans(DownloadService downloads) async {
    final l10n = AppLocalizations.of(context)!;
    final orphans = await downloads.orphanFiles();
    if (!mounted) return;
    if (orphans.isEmpty) {
      _showMessage(l10n.downloadsCleanupOrphansNone);
      return;
    }
    final navigator = Navigator.of(context, rootNavigator: true);
    final names = [for (final path in orphans.take(5)) p.basename(path)];
    final scheme = Theme.of(context).colorScheme;
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.downloadsCleanupOrphans,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.downloadsCleanupOrphansConfirm(orphans.length)),
              if (names.isNotEmpty) ...[
                const SizedBox(height: kSettingsSmallSpacing),
                Text(
                  names.join('\n'),
                  style: context.typeScale.bodySmall.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (orphans.length > names.length) ...[
                const SizedBox(height: kSettingsSmallSpacing),
                Text(
                  l10n.downloadsCleanupOrphansMore(
                    orphans.length - names.length,
                  ),
                  style: context.typeScale.bodySmall.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => navigator.pop(true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final count = await downloads.deleteOrphanFiles(paths: orphans);
      if (!mounted) return;
      _showMessage(l10n.downloadsCleanupOrphansDone(count));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    final notifications = context.read<NotificationService?>();
    if (notifications != null) {
      notifications.showSnackBar(message);
    } else {
      M3ESnackbar.show(context, message: message);
    }
  }
}
