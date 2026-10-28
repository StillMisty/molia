/// 下载任务状态文案：管理页任务行与本地数据页音频状态共用。
///
/// 页面只负责布局，状态词与进度格式统一在这里，避免两处各拼一套。
library;

import '../l10n/app_localizations.dart';
import '../services/download/download_queue.dart';
import 'download_failure_label.dart';
import 'track_local_data_label.dart';

/// 任务状态的用户可见文案（进行中带百分比 / 失败带原因）。
String downloadTaskStatusLabel(AppLocalizations l10n, DownloadTask task) {
  return switch (task.status) {
    DownloadTaskStatus.queued => l10n.downloadStatusQueued,
    DownloadTaskStatus.running => _runningLabel(l10n, task.progress),
    DownloadTaskStatus.failed => switch (task.failure) {
      final failure? => downloadFailureLabel(l10n, failure),
      null => l10n.downloadStatusNotDownloaded,
    },
    DownloadTaskStatus.completed => l10n.downloadStatusDownloaded,
    DownloadTaskStatus.cancelled => l10n.downloadCancelled,
  };
}

String _runningLabel(AppLocalizations l10n, DownloadProgress progress) {
  final percent = progress.percent;
  return percent == null
      ? '${l10n.downloadStatusDownloading} · '
            '${formatCacheBytes(progress.receivedBytes)}'
      : '${l10n.downloadStatusDownloading} · '
            '${l10n.downloadProgressPercent(percent)}';
}
