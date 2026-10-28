/// 下载任务队列：全局严格串行、单 worker、FIFO 的唯一实现。
///
/// 为什么独立成模块：下载编排（取链 / 落盘 / 落库）与「谁先谁后、排队 /
/// 取消 / 重试」是两件事。此前单曲下载直接跑、批量在服务里顺序 await，
/// 分项（歌词 / 封面）又会与音频并发写同一条记录；进度还和记录变化挤在
/// 一个 [ChangeNotifier] 里，页面为了 10Hz 进度被迫整页重建。
///
/// 现在：
/// - 队列只在任务增删 / 状态变化时通知（页面只重建任务区）；
/// - 进度由 [DownloadTask] 自己通知并做 100ms 合并（首个分片 / 100% /
///   终态立即送达）；系统通知的 500ms 节流仍由通知 presenter 负责；
/// - 严格串行让同名 `.part` 竞争与分项记录的并发覆盖自然消失；
/// - **不持久化队列**：失败任务只在本进程内可重试，重启只保留既有的
///   `.part` 清扫，不做断点续传或队列恢复。
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../domain/models/failure.dart';
import '../../domain/models/track.dart';

/// 下载任务种类：完整音频 / 单独歌词 / 单独封面。
enum DownloadTaskKind { audio, lyrics, cover }

/// 任务状态。
enum DownloadTaskStatus { queued, running, completed, failed, cancelled }

/// 单条下载任务的实时进度（UI 消费；值相等不重复通知）。
class DownloadProgress {
  const DownloadProgress({required this.receivedBytes, this.totalBytes});

  final int receivedBytes;

  /// 响应头 Content-Length；未知时为 null（进度不可量化）。
  final int? totalBytes;

  /// 0..1；总大小未知时为 null。
  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0.0, 1.0);
  }

  /// 百分比 0..100；总大小未知时为 null。
  int? get percent {
    final value = fraction;
    return value == null ? null : (value * 100).round();
  }

  @override
  bool operator ==(Object other) =>
      other is DownloadProgress &&
      other.receivedBytes == receivedBytes &&
      other.totalBytes == totalBytes;

  @override
  int get hashCode => Object.hash(receivedBytes, totalBytes);

  @override
  String toString() => 'DownloadProgress($receivedBytes/$totalBytes)';
}

/// 一条下载任务（可监听：进度 / 状态 / 失败原因都在这里，队列不转发进度）。
///
/// 任务对象由 [DownloadService] 创建、[DownloadQueue] 驱动；UI 只读状态，
/// 更新方法仅下载编排使用。
class DownloadTask extends ChangeNotifier {
  DownloadTask({
    required this.track,
    required this.kind,
    required this.quality,
    this.includeLyrics = true,
    this.includeCover = true,
    this.batchIndex,
    this.batchTotal,
    String? key,
  }) : key = key ?? keyFor(track, kind);

  /// 任务键：音频 = `track.id.uri`；分项 = `<key>#lyrics` / `<key>#cover`。
  final String key;

  final Track track;
  final DownloadTaskKind kind;

  /// 本次下载音质（LX 标识）；歌词 / 封面任务为空串。
  final String quality;

  final bool includeLyrics;
  final bool includeCover;

  /// 批量位置（从 1 起；非批量 / 通知不可用时为 null）。
  final int? batchIndex;
  final int? batchTotal;

  /// 任务键约定（服务与测试共用，避免各处手拼后缀）。
  static String keyFor(Track track, DownloadTaskKind kind) => switch (kind) {
    DownloadTaskKind.audio => track.id.uri,
    DownloadTaskKind.lyrics => '${track.id.uri}#lyrics',
    DownloadTaskKind.cover => '${track.id.uri}#cover',
  };

  /// UI 进度合并窗口：快速分片（尤其缓存直拷）间隔远小于 100ms，按字节
  /// 通知会让监听页每秒重建几十次；首个分片 / 100% / 终态不等窗口。
  static const int progressNotifyIntervalMs = 100;

  DownloadTaskStatus _status = DownloadTaskStatus.queued;
  DownloadProgress _progress = const DownloadProgress(receivedBytes: 0);
  SourceFailure? _failure;
  int? _lastProgressNotifiedAt;
  Completer<void> _completion = Completer<void>();

  DownloadTaskStatus get status => _status;

  DownloadProgress get progress => _progress;

  SourceFailure? get failure => _failure;

  /// 排队中或进行中（失败 / 完成 / 取消都不算）。
  bool get isActive =>
      _status == DownloadTaskStatus.queued ||
      _status == DownloadTaskStatus.running;

  /// 任务完成 / 失败 / 取消时完成；失败与取消以错误完成。
  Future<void> get done => _completion.future;

  /// 任务开始执行（队列调用）。
  void markRunning() {
    if (_status != DownloadTaskStatus.queued) return;
    _status = DownloadTaskStatus.running;
    notifyListeners();
  }

  /// 任务成功（队列调用）。
  void markCompleted() {
    if (!isActive) return;
    _status = DownloadTaskStatus.completed;
    notifyListeners();
    if (!_completion.isCompleted) _completion.complete();
  }

  /// 任务失败：保留任务供重试（音频），并让等待方收到同一失败。
  void markFailed(SourceFailure failure) {
    if (!isActive) return;
    _failure = failure;
    _status = DownloadTaskStatus.failed;
    notifyListeners();
    if (!_completion.isCompleted) _completion.completeError(failure);
  }

  /// 任务取消（排队取消 / 运行中取消同一条路径）。
  void markCancelled() {
    if (!isActive) return;
    _status = DownloadTaskStatus.cancelled;
    notifyListeners();
    if (!_completion.isCompleted) {
      _completion.completeError(_cancelledFailure);
    }
  }

  /// 进度上报（仅下载编排调用）：首个 / 100% 立即通知，其余按 100ms 合并。
  void reportProgress(
    int receivedBytes,
    int? totalBytes, {
    required int nowMs,
  }) {
    if (_status != DownloadTaskStatus.running) return;
    final complete =
        totalBytes != null && totalBytes > 0 && receivedBytes >= totalBytes;
    final last = _lastProgressNotifiedAt;
    if (last != null && !complete && nowMs - last < progressNotifyIntervalMs) {
      return;
    }
    final next = DownloadProgress(
      receivedBytes: receivedBytes,
      totalBytes: totalBytes,
    );
    if (_progress == next) return;
    _lastProgressNotifiedAt = nowMs;
    _progress = next;
    notifyListeners();
  }

  /// 重试前复位（队列内部使用；失败任务重新排队时复用同一对象）。
  void resetForRetry() {
    _status = DownloadTaskStatus.queued;
    _progress = const DownloadProgress(receivedBytes: 0);
    _failure = null;
    _lastProgressNotifiedAt = null;
    _completion = Completer<void>();
  }

  static const SourceFailure _cancelledFailure = SourceFailure(
    kind: FailureKind.cancelled,
    message: '下载已取消',
    l10nKey: 'downloadCancelled',
  );
}

/// 任务执行器：由下载服务注入（队列不感知取链 / 文件 / 数据库）。
typedef DownloadTaskRunner = Future<void> Function(DownloadTask task);

/// 严格串行 FIFO 下载队列（单 worker；不持久化，重启即清空）。
class DownloadQueue extends ChangeNotifier {
  DownloadQueue(this._runner);

  final DownloadTaskRunner _runner;

  /// 活跃 + 失败任务（完成 / 取消立即移除；失败保留供重试）。
  final List<DownloadTask> _tasks = <DownloadTask>[];

  /// 排队 / 运行中任务（键 → 任务），用于同 key 去重与取消。
  final Map<String, DownloadTask> _active = <String, DownloadTask>{};

  /// 失败任务（键 → 任务），与 [_tasks] 同步维护。
  final Map<String, DownloadTask> _failed = <String, DownloadTask>{};

  final Queue<DownloadTask> _pending = Queue<DownloadTask>();
  bool _workerScheduled = false;

  /// 运行中 + 排队中 + 失败任务（running 在前，其次按入队顺序）。
  List<DownloadTask> get tasks => List.unmodifiable(<DownloadTask>[
    for (final task in _tasks)
      if (task.status == DownloadTaskStatus.running) task,
    for (final task in _tasks)
      if (task.status == DownloadTaskStatus.queued) task,
    for (final task in _tasks)
      if (task.status == DownloadTaskStatus.failed) task,
  ]);

  /// 按 key 查任务：优先活跃，其次失败（本地数据页据此呈现重试态）。
  DownloadTask? taskFor(String key) => _active[key] ?? _failed[key];

  /// 入队：同步进入等待列表；同 key 已有排队 / 运行任务时返回同一 future。
  ///
  /// 失败 / 取消任务再入队时替换为新任务（同一对象则原地复位）。完成 /
  /// 取消后任务从队列移除，失败任务保留供重试。
  Future<void> enqueue(DownloadTask task) {
    final active = _active[task.key];
    if (active != null) return active.done;

    final previous = _failed.remove(task.key);
    if (previous != null) {
      _tasks.remove(previous);
      if (!identical(previous, task)) previous.dispose();
    }
    if (!identical(previous, task) &&
        task.status != DownloadTaskStatus.queued) {
      task.resetForRetry();
    } else if (identical(previous, task)) {
      task.resetForRetry();
    }
    if (!_tasks.contains(task)) _tasks.add(task);
    _active[task.key] = task;
    _pending.add(task);
    notifyListeners();
    _scheduleWorker();
    return task.done;
  }

  /// 取消排队中的任务；已在运行（或没有任务）返回 false（由服务取消 dio）。
  bool cancelQueued(String key) {
    final task = _active[key];
    if (task == null || task.status != DownloadTaskStatus.queued) return false;
    _pending.remove(task);
    _active.remove(key);
    _tasks.remove(task);
    task.markCancelled();
    notifyListeners();
    return true;
  }

  /// 移除失败任务（不重试）。
  void dismiss(String key) {
    final task = _failed.remove(key);
    if (task == null) return;
    _tasks.remove(task);
    notifyListeners();
  }

  /// 清空全部失败任务。
  void clearFailed() {
    if (_failed.isEmpty) return;
    for (final task in _failed.values) {
      _tasks.remove(task);
    }
    _failed.clear();
    notifyListeners();
  }

  void _scheduleWorker() {
    if (_workerScheduled) return;
    _workerScheduled = true;
    scheduleMicrotask(() {
      unawaited(_drain());
    });
  }

  /// 单 worker：一次只跑一个任务；排队期间新入队的任务在同一循环里消费。
  Future<void> _drain() async {
    try {
      while (_pending.isNotEmpty) {
        final task = _pending.removeFirst();
        if (task.status != DownloadTaskStatus.queued) continue;
        task.markRunning();
        notifyListeners();
        try {
          await _runner(task);
          if (task.status == DownloadTaskStatus.running) task.markCompleted();
        } catch (e) {
          if (task.status != DownloadTaskStatus.running) continue;
          if (e is SourceFailure && e.kind == FailureKind.cancelled) {
            task.markCancelled();
          } else {
            task.markFailed(e is SourceFailure ? e : SourceFailure.from(e));
          }
        } finally {
          _active.remove(task.key);
          if (task.status == DownloadTaskStatus.failed &&
              task.kind == DownloadTaskKind.audio) {
            // 音频失败保留在失败区，等待用户重试 / 移除。
            _failed[task.key] = task;
          } else {
            // 完成 / 取消 / 分项失败：调用方（页面 / snackbar）已收到结果，
            // 不在队列里留下不可操作的条目。
            _tasks.remove(task);
          }
          notifyListeners();
        }
      }
    } finally {
      _workerScheduled = false;
      if (_pending.isNotEmpty) _scheduleWorker();
    }
  }

  @override
  void dispose() {
    for (final task in _tasks) {
      task.dispose();
    }
    _tasks.clear();
    _active.clear();
    _failed.clear();
    _pending.clear();
    super.dispose();
  }
}
