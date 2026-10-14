/// 下载管理页：进行中任务 / 批量下载 / 文件维护（.part 清扫、孤儿文件）。
///
/// 从设置 › 数据与存储进入。**明确不做断点续传**：平台直链多为一次性
/// 签名地址，失败后重下比续传可靠（页面内说明）。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/playback_provider.dart';
import '../services/download/download_service.dart';
import '../services/notification_service.dart';
import '../utils/track_cache_label.dart';
import '../widgets/settings/settings_tiles.dart';
import 'downloads_page.dart';

class DownloadsManagePage extends StatefulWidget {
  const DownloadsManagePage({super.key});

  @override
  State<DownloadsManagePage> createState() => _DownloadsManagePageState();
}

class _DownloadsManagePageState extends State<DownloadsManagePage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final downloads = context.watch<DownloadService?>();
    final queue = context.select<PlaybackProvider, List<Track>>(
      (provider) => provider.snapshot.queue,
    );
    final tasks = downloads?.activeTasks ?? const [];

    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.downloadsManageTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
          // 进行中任务：进度 + 取消。
          SettingsSectionCard(
            title: l10n.downloadsActiveSection,
            children: [
              if (tasks.isEmpty)
                SettingsInfoTile(
                  key: const Key('downloadsActiveEmpty'),
                  icon: Icons.check_circle_rounded,
                  title: l10n.downloadsActiveEmpty,
                  subtitle: '',
                )
              else ...[
                SettingsInfoTile(
                  icon: Icons.downloading_rounded,
                  title: l10n.downloadsActiveCount(tasks.length),
                  subtitle: '',
                ),
                for (final (track, progress) in tasks)
                  SettingsNavTile(
                    key: Key('downloadsActive_${track.id.uri}'),
                    icon: Icons.music_note_rounded,
                    title: track.title,
                    subtitle: progress.percent == null
                        ? formatCacheBytes(progress.receivedBytes)
                        : l10n.downloadProgressPercent(progress.percent!),
                    onTap: () => downloads?.cancelTrack(track),
                  ),
              ],
            ],
          ),
          const SizedBox(height: kSettingsSectionSpacing),
          // 批量下载：当前队列（跳过已下载与本地曲目）。
          SettingsSectionCard(
            title: l10n.downloadsBatchSection,
            children: [
              SettingsNavTile(
                key: const Key('downloadsBatchQueueItem'),
                icon: Icons.playlist_add_rounded,
                title: l10n.downloadsBatchQueue,
                subtitle: l10n.downloadsBatchQueueSubtitle(queue.length),
                onTap: _busy || downloads == null || queue.isEmpty
                    ? null
                    : () => unawaited(_batchDownload(downloads, queue)),
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
              FutureBuilder<String?>(
                future: downloads?.rootPath(),
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
          const SizedBox(height: kSettingsSectionSpacing),
          SettingsSectionCard(
            children: [
              SettingsNavTile(
                key: const Key('downloadsOpenLibraryItem'),
                icon: Icons.library_music_rounded,
                title: l10n.downloadsOpenLibrary,
                subtitle: '',
                onTap: () => unawaited(showDownloadsPage(context)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _batchDownload(
    DownloadService downloads,
    List<Track> queue,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    _showMessage(l10n.downloadsBatchStarted(queue.length));
    try {
      final (done, failed) = await downloads.downloadBatch(queue);
      if (!mounted) return;
      _showMessage(l10n.downloadsBatchDone(done, failed));
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

  Future<void> _cleanupOrphans(DownloadService downloads) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.downloadsCleanupOrphans,
        content: Text(l10n.downloadsCleanupOrphansSubtitle),
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
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final count = await downloads.deleteOrphanFiles();
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
