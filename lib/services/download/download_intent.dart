/// 单曲下载意图：资格判定、默认音质、已有记录 / 活动任务的唯一入口。
///
/// 为什么收在一层：曲目菜单、来源分享、本地数据页、批量下载都要预检
/// `supported` / 本地曲目 / 已下载 / 进行中，再各自翻译失败。规则分散时，
/// 「菜单还能点但一点就提示已下载」或「分享入口漏掉活动任务」只是时间问题。
/// UI 只表达「我要下载这首歌」，由本模块返回类型化结果。
///
/// 本模块不碰下载管道：真正入队仍走 `DownloadManager`，记录 / 任务读取仍是
/// `DownloadRecords` / `DownloadTask` 的既有语义。
library;

import 'package:flutter/foundation.dart';

import '../../domain/models/download.dart';
import '../../domain/models/failure.dart';
import '../../domain/models/track.dart';
import 'download_manager.dart';
import 'download_queue.dart';
import 'download_records.dart';

/// 本地曲目不能下载（下载只服务在线音源）。
const SourceFailure downloadLocalTrackFailure = SourceFailure(
  kind: FailureKind.unsupported,
  message: '本地曲目无需下载',
  l10nKey: 'downloadLocalTrack',
);

/// 下载目录不可用（平台无文件系统 / 目录解析失败）。
const SourceFailure downloadUnsupportedFailure = SourceFailure(
  kind: FailureKind.unsupported,
  message: '当前平台不支持下载',
  l10nKey: 'downloadUnsupported',
);

/// 下载入口的同步快照（只用于渲染入口 / 状态，不承载失败文案）。
enum DownloadIntentStatus {
  /// 可以开始。
  ready,

  /// 已有音频记录。
  alreadyDownloaded,

  /// 已有排队 / 运行中的音频任务。
  active,

  /// 平台不支持或本地曲目。
  unsupported,
}

/// 单曲下载资格的唯一实现（单曲入口与批量候选共用）。
///
/// [task] 必须是当前曲目的音频任务（`DownloadManager.taskForTrack`）；
/// 失败任务不算 active——重新入队会替换它，与既有重试语义一致。
DownloadIntentStatus downloadIntentStatusOf(
  Track track, {
  required DownloadRecords records,
  required bool supported,
  DownloadTask? task,
}) {
  if (track.id.sourceKey == kLocalSourceKey ||
      track.origin == TrackOrigin.localFile) {
    return DownloadIntentStatus.unsupported;
  }
  // 初始化前 supported 为 false：入口先隐藏，记录就绪后由 launcher 通知重算。
  if (!supported) return DownloadIntentStatus.unsupported;
  if (records.recordForTrack(track)?.hasAudio ?? false) {
    return DownloadIntentStatus.alreadyDownloaded;
  }
  if (task?.isActive ?? false) return DownloadIntentStatus.active;
  return DownloadIntentStatus.ready;
}

/// 一次单曲下载意图的终态。
///
/// sealed：四个入口只按类型渲染，新增拦截原因时编译器会提示所有分支；
/// UI 不再自己判断 `supported` / 已下载 / active。
sealed class DownloadStartResult {
  const DownloadStartResult();
}

/// 已入队（任务对象可继续等待完成 / 失败）。
final class DownloadStarted extends DownloadStartResult {
  const DownloadStarted(this.task);

  final DownloadTask task;
}

/// 已有音频记录（不重复入队）。
final class DownloadAlreadyDownloaded extends DownloadStartResult {
  const DownloadAlreadyDownloaded(this.record);

  final DownloadedTrack record;
}

/// 已有排队 / 运行中的任务（不重复入队）。
final class DownloadAlreadyActive extends DownloadStartResult {
  const DownloadAlreadyActive(this.task);

  final DownloadTask task;
}

/// 不能下载；[reason] 走既有 `downloadFailureLabel` 映射，不新增文案。
final class DownloadUnsupported extends DownloadStartResult {
  const DownloadUnsupported(this.reason);

  final SourceFailure reason;
}

/// 批量下载意图的结果（跳过规则由 `DownloadManager.downloadBatch` 唯一实现）。
final class DownloadBatchStart {
  const DownloadBatchStart({
    required this.enqueued,
    required this.done,
    required this.failed,
  });

  /// 实际新入队数（0 = 没有候选）。
  final int enqueued;

  /// 成功数（取消不计入成功 / 失败）。
  final int done;

  /// 失败数（失败音频任务留在管理页失败区可重试）。
  final int failed;
}

/// 下载意图入口（Provider 注册；UI 只依赖本类，不直接读记录 / 任务做资格判断）。
class DownloadLauncher extends ChangeNotifier {
  DownloadLauncher({required this._downloads, required this._records}) {
    _downloads.addListener(_forward);
    _downloads.taskChanges.addListener(_forward);
    _records.addListener(_forward);
  }

  final DownloadManager _downloads;
  final DownloadRecords _records;

  /// 记录 / 能力位 / 任务结构变化都会影响入口可见性：统一转成一次通知，
  /// 页面用 `select` 订阅一个同步状态即可，不需要分别监听三个源。
  late final VoidCallback _forward = notifyListeners;

  /// 入口可见性快照；与 [start] 共用 [downloadIntentStatusOf]。
  DownloadIntentStatus statusOf(Track track) => downloadIntentStatusOf(
    track,
    records: _records,
    supported: _downloads.supported,
    task: _downloads.taskForTrack(track),
  );

  /// 表达「下载这首歌」：先等记录就绪，再判定资格 / 选默认音质 / 入队。
  ///
  /// [quality] 为空时用 `DownloadManager.defaultQualityFor`（偏好音质 ×
  /// 曲目可用音质）；显式传入时保持调用方的选择（本地数据页音质单选）。
  /// 不等待下载完成：调用方据结果渲染，再自行 await `task.done`。
  Future<DownloadStartResult> start(Track track, {String? quality}) async {
    await _downloads.ready;
    switch (statusOf(track)) {
      case DownloadIntentStatus.unsupported:
        return DownloadUnsupported(_unsupportedReasonOf(track));
      case DownloadIntentStatus.alreadyDownloaded:
        // statusOf 刚判定有音频记录，这里同步再读一次不会出现空值。
        return DownloadAlreadyDownloaded(_records.recordForTrack(track)!);
      case DownloadIntentStatus.active:
        return DownloadAlreadyActive(_downloads.taskForTrack(track)!);
      case DownloadIntentStatus.ready:
        final selected = quality ?? _downloads.defaultQualityFor(track);
        final task = await _downloads.enqueueDownload(
          track,
          quality: selected.isEmpty ? null : selected,
        );
        return DownloadStarted(task);
    }
  }

  /// 批量表达下载意图：候选过滤 / 入队 / 结果统计仍由下载服务唯一实现，
  /// 页面不再先调 `batchCandidates` 再调 `downloadBatch`。
  Future<DownloadBatchStart> startBatch(
    Iterable<Track> tracks, {
    void Function(int enqueued)? onEnqueued,
  }) async {
    await _downloads.ready;
    if (!_downloads.supported) throw downloadUnsupportedFailure;
    var enqueued = 0;
    final (done, failed) = await _downloads.downloadBatch(
      tracks,
      onEnqueued: (count) {
        enqueued = count;
        onEnqueued?.call(count);
      },
    );
    return DownloadBatchStart(enqueued: enqueued, done: done, failed: failed);
  }

  SourceFailure _unsupportedReasonOf(Track track) {
    if (track.id.sourceKey == kLocalSourceKey ||
        track.origin == TrackOrigin.localFile) {
      return downloadLocalTrackFailure;
    }
    return downloadUnsupportedFailure;
  }

  @override
  void dispose() {
    _downloads.removeListener(_forward);
    _downloads.taskChanges.removeListener(_forward);
    _records.removeListener(_forward);
    super.dispose();
  }
}
