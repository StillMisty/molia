/// 下载请求：单曲 / 歌词 / 封面 / 批量下载的资格判定、入队、等待终态与
/// 类型化结果。
///
/// 为什么收在一层：曲目菜单、来源分享、本地数据页、批量下载回答的都是同一个
/// 问题——「现在能不能下、下完 / 失败 / 取消怎么算」。规则与等待方式分散时，
/// 「入口能点但一点就提示已下载」「分享入口漏掉活动任务」「某个入口把取消
/// 当成失败提示」只是时间问题。UI 只表达「下载这首歌 / 这段歌词 / 这张封面」，
/// 由本模块返回 [DownloadOutcome]；页面只按类型渲染，不再自己拿任务句柄
/// `await task.done`。
///
/// 本模块不碰下载管道：入队、队列、记录装配与文件布局仍由 `DownloadManager`
/// 的实现（`DownloadService`）与 `DownloadRecords` 负责。
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
  // 初始化前 supported 为 false：入口先隐藏，记录就绪后由 DownloadRequests
  // 通知重算。
  if (!supported) return DownloadIntentStatus.unsupported;
  if (records.recordForTrack(track)?.hasAudio ?? false) {
    return DownloadIntentStatus.alreadyDownloaded;
  }
  if (task?.isActive ?? false) return DownloadIntentStatus.active;
  return DownloadIntentStatus.ready;
}

/// 一次下载请求的终态。
///
/// sealed：四个入口只按类型渲染，新增分支时编译器会提示所有调用点；UI 不再
/// 自己判断 `supported` / 已下载 / 活动任务 / 取消异常。
sealed class DownloadOutcome {
  const DownloadOutcome();
}

/// 已有音频记录（不重复入队）。
final class DownloadAlreadyDownloaded extends DownloadOutcome {
  const DownloadAlreadyDownloaded(this.record);

  final DownloadedTrack record;
}

/// 已有排队 / 运行中的任务，且调用方选择不等待（`waitForActive: false`）。
final class DownloadActive extends DownloadOutcome {
  const DownloadActive(this.task);

  final DownloadTask task;
}

/// 不能下载；[reason] 走既有 `downloadFailureLabel` 映射，不新增文案。
final class DownloadUnsupported extends DownloadOutcome {
  const DownloadUnsupported(this.reason);

  final SourceFailure reason;
}

/// 完成。[record] 是落库后的记录；分项下载在极端情况下可能尚未读到记录。
final class DownloadCompleted extends DownloadOutcome {
  const DownloadCompleted({this.record});

  final DownloadedTrack? record;
}

/// 失败：错误对象原样保留，调用方仍走 `downloadFailureMessage` 映射。
final class DownloadFailed extends DownloadOutcome {
  const DownloadFailed(this.error);

  final Object error;
}

/// 用户取消（各入口静默）。[task] 只用于排查，不参与渲染。
final class DownloadCancelled extends DownloadOutcome {
  const DownloadCancelled({this.task});

  final DownloadTask? task;
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

/// 下载请求入口（Provider 注册；UI 只依赖本类，不直接读记录 / 任务做资格
/// 判断，也不自己等待任务完成）。
class DownloadRequests extends ChangeNotifier {
  DownloadRequests({required this._downloads, required this._records}) {
    _downloads.addListener(_forward);
    _downloads.taskChanges.addListener(_forward);
    _records.addListener(_forward);
  }

  final DownloadManager _downloads;
  final DownloadRecords _records;

  /// 记录 / 能力位 / 任务结构变化都会影响入口可见性：统一转成一次通知，
  /// 页面用 `select` 订阅一个同步状态即可，不需要分别监听三个源。
  late final VoidCallback _forward = notifyListeners;

  /// 入口可见性快照；与 [requestAudio] 共用 [downloadIntentStatusOf]。
  DownloadIntentStatus statusOf(Track track) => downloadIntentStatusOf(
    track,
    records: _records,
    supported: _downloads.supported,
    task: _downloads.taskForTrack(track),
  );

  /// 表达「下载这首歌」并等待终态。
  ///
  /// [quality] 为空时用 `DownloadManager.defaultQualityFor`（偏好音质 ×
  /// 曲目可用音质）；显式传入时保持调用方的选择（本地数据页音质单选）。
  ///
  /// [waitForActive] 为 true 时，已有活动任务也会等它结束再返回；本地数据页
  /// 只提示「正在下载」并保持原行为，传 false 即刻拿到 [DownloadActive]。
  /// [onStarted] 在真正入队 / 加入已有任务时触发（只用来发「已开始」类回执，
  /// 终态仍走返回值）。
  Future<DownloadOutcome> requestAudio(
    Track track, {
    String? quality,
    bool includeLyrics = true,
    bool includeCover = true,
    bool waitForActive = true,
    void Function(DownloadTask task, {required bool joined})? onStarted,
  }) async {
    try {
      await _downloads.ready;
      switch (statusOf(track)) {
        case DownloadIntentStatus.unsupported:
          return DownloadUnsupported(_unsupportedReasonOf(track)!);
        case DownloadIntentStatus.alreadyDownloaded:
          // statusOf 刚判定有音频记录，这里同步再读一次不会出现空值。
          return DownloadAlreadyDownloaded(_records.recordForTrack(track)!);
        case DownloadIntentStatus.active:
          final task = _downloads.taskForTrack(track)!;
          onStarted?.call(task, joined: true);
          if (!waitForActive) return DownloadActive(task);
          final settled = await _settleAudio(track, task);
          return settled;
        case DownloadIntentStatus.ready:
          final selected = quality ?? _downloads.defaultQualityFor(track);
          final task = await _downloads.enqueueDownload(
            track,
            quality: selected.isEmpty ? null : selected,
            includeLyrics: includeLyrics,
            includeCover: includeCover,
          );
          onStarted?.call(task, joined: false);
          final settled = await _settleAudio(track, task);
          return settled;
      }
    } catch (error) {
      return _failureOutcome(error);
    }
  }

  /// 单独下载歌词（不入音频队列，与 [requestAudio] 同一套终态）。
  Future<DownloadOutcome> requestLyrics(Track track) =>
      _requestPart(track, DownloadTaskKind.lyrics);

  /// 单独下载封面（不入音频队列，与 [requestAudio] 同一套终态）。
  Future<DownloadOutcome> requestCover(Track track) =>
      _requestPart(track, DownloadTaskKind.cover);

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

  /// 音频任务终态：成功回读记录，失败 / 取消归一成类型化结果。
  Future<DownloadOutcome> _settleAudio(Track track, DownloadTask task) async {
    try {
      await task.done;
    } catch (error) {
      return _failureOutcome(error, task: task);
    }
    return DownloadCompleted(record: _records.recordForTrack(track));
  }

  Future<DownloadOutcome> _requestPart(
    Track track,
    DownloadTaskKind kind,
  ) async {
    try {
      await _downloads.ready;
      final unsupported = _unsupportedReasonOf(track);
      if (unsupported != null) return DownloadUnsupported(unsupported);
      switch (kind) {
        case DownloadTaskKind.audio:
          throw ArgumentError('音频下载请使用 requestAudio');
        case DownloadTaskKind.lyrics:
          await _downloads.downloadLyrics(track);
        case DownloadTaskKind.cover:
          await _downloads.downloadCover(track);
      }
      return DownloadCompleted(record: _records.recordForTrack(track));
    } catch (error) {
      return _failureOutcome(error);
    }
  }

  /// 取消是正常终态（各入口静默），其余错误保持原对象交给文案映射。
  DownloadOutcome _failureOutcome(Object error, {DownloadTask? task}) {
    if (error is SourceFailure && error.kind == FailureKind.cancelled) {
      return DownloadCancelled(task: task);
    }
    return DownloadFailed(error);
  }

  SourceFailure? _unsupportedReasonOf(Track track) {
    if (track.id.sourceKey == kLocalSourceKey ||
        track.origin == TrackOrigin.localFile) {
      return downloadLocalTrackFailure;
    }
    if (!_downloads.supported) return downloadUnsupportedFailure;
    return null;
  }

  @override
  void dispose() {
    _downloads.removeListener(_forward);
    _downloads.taskChanges.removeListener(_forward);
    _records.removeListener(_forward);
    super.dispose();
  }
}
