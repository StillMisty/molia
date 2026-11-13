/// 缺文件探测：空闲批量检查本地音频是否还在，写入 `missingAt` / `mtimeMs`。
///
/// 为什么独立成服务：探测只做「存在 + 大小」，不能读标签、不能进 build；
/// 触发点（下载记录就绪 / 扫描后 / 手动检查 / 重定位后）分散在组合根与页面，
/// 统一在这里串行化，避免扫描与探测互相覆盖文件状态。
library;

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../../data/downloads/download_storage.dart';
import '../../data/downloads/downloads_repository.dart';
import '../../domain/models/download.dart';
import '../download/download_records.dart';

/// 一轮探测结果。
class MissingProbeResult {
  const MissingProbeResult({required this.checked, required this.changed});

  final int checked;
  final int changed;
}

class MissingFileProbe {
  MissingFileProbe({
    required this.records,
    required this.repository,
    required this.storage,
    DateTime Function()? clock,
    this.batchSize = 200,
    this.concurrency = 4,
  }) : _clock = clock ?? DateTime.now;

  final DownloadRecords records;
  final DownloadsRepository repository;
  final DownloadStorage storage;
  final DateTime Function() _clock;
  final int batchSize;
  final int concurrency;
  final Logger _logger = Logger('molia.missing_file_probe');

  bool _running = false;

  /// 探测全部有音频的记录；[onProgress] 只用于手动检查的进度文案。
  ///
  /// 已在运行时不并发启动第二次（扫描 / 启动 / 手动共用一个串行入口）。
  Future<MissingProbeResult> probeAll({
    void Function(int checked)? onProgress,
  }) async {
    if (_running) return const MissingProbeResult(checked: 0, changed: 0);
    _running = true;
    try {
      final targets = [
        for (final record in records.downloads)
          if (record.hasAudio) record,
      ];
      var checked = 0;
      var changed = 0;
      for (var start = 0; start < targets.length; start += batchSize) {
        final end = (start + batchSize).clamp(0, targets.length);
        final batch = targets.sublist(start, end);
        for (var i = 0; i < batch.length; i += concurrency) {
          final chunk = batch.sublist(
            i,
            (i + concurrency).clamp(0, batch.length),
          );
          final results = await Future.wait(chunk.map(_probeOne));
          for (final record in results) {
            checked++;
            if (record != null) changed++;
          }
          onProgress?.call(checked);
        }
      }
      if (changed > 0) _logger.info('本地文件状态变化 $changed 条');
      return MissingProbeResult(checked: checked, changed: changed);
    } finally {
      _running = false;
    }
  }

  /// 单条探测；状态没变返回 null（不写库、不通知）。
  Future<DownloadedTrack?> _probeOne(DownloadedTrack record) async {
    final path = record.filePath;
    if (path == null || path.isEmpty) return null;
    final exists = await storage.fileExists(path);
    if (!exists) {
      // 整块根目录不可用（外接盘拔出 / 网络卷离线）时不把整库标缺失：
      // 父目录也不存在就当作「暂时读不到」，保留原状态。
      final parent = p.dirname(path);
      if (!await storage.directoryExists(parent)) return null;
      if (record.isMissing) return null;
      final missingAt = _clock().millisecondsSinceEpoch;
      await repository.setFileProbe(
        originSourceKey: record.originSourceKey,
        originSongId: record.originSongId,
        mtimeMs: record.mtimeMs,
        missing: true,
        missingAt: missingAt,
      );
      final updated = record.copyWith(missingAt: missingAt);
      records.put(updated);
      return updated;
    }
    final mtime = await storage.fileMtime(path);
    final size = await storage.fileSize(path);
    if (!record.isMissing &&
        record.mtimeMs == mtime &&
        (size <= 0 || record.sizeBytes == size)) {
      return null; // 无变化：不写库、不通知
    }
    await repository.setFileProbe(
      originSourceKey: record.originSourceKey,
      originSongId: record.originSongId,
      mtimeMs: mtime,
      missing: false,
      missingAt: 0,
      sizeBytes: size > 0 ? size : null,
    );
    final updated = record.copyWith(
      mtimeMs: mtime,
      sizeBytes: size > 0 ? size : null,
      clearMissingAt: true,
    );
    records.put(updated);
    return updated;
  }
}
