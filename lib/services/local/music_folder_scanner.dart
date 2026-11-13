/// 音乐文件夹扫描器：递归枚举、增量判定、取消、缺文件标记。
///
/// 边界：只读文件头（标签由导入端口负责），不复制 / 移动 / 重命名 / 删除
/// 用户文件；事件监听只是「重新扫描」的触发器，不是真相来源。
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../download/download_file_layout.dart';
import '../../domain/models/download.dart';

/// 扫描目标（生产由下载服务适配；测试注入假实现）。
abstract interface class LocalScanTarget {
  /// 当前全部导入记录（增量判定与缺文件标记的输入）。
  Future<List<DownloadedTrack>> listImported();

  /// 新文件：读标签 → 建记录（生成 / 复用 `localKey`）。
  Future<void> importFile(
    String path, {
    required int sizeBytes,
    required int mtimeMs,
  });

  /// 已有文件变化：只刷新技术字段，不覆盖用户改过的标题。
  Future<void> refreshFile(
    DownloadedTrack record, {
    required int sizeBytes,
    required int mtimeMs,
  });

  /// 确认文件不见（根目录成功枚举之后才调用）。
  Future<void> markMissing(DownloadedTrack record);
}

class FolderScanOutcome {
  const FolderScanOutcome({
    this.added = 0,
    this.updated = 0,
    this.skipped = 0,
    this.cancelled = false,
    this.unavailable = false,
  });

  final int added;
  final int updated;
  final int skipped;
  final bool cancelled;
  final bool unavailable;

  FolderScanOutcome copyWith({
    int? added,
    int? updated,
    int? skipped,
    bool? cancelled,
  }) => FolderScanOutcome(
    added: added ?? this.added,
    updated: updated ?? this.updated,
    skipped: skipped ?? this.skipped,
    cancelled: cancelled ?? this.cancelled,
    unavailable: unavailable,
  );
}

class ScanProgress {
  const ScanProgress({required this.processed, required this.directory});

  final int processed;
  final String directory;
}

class ScanCancellation {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// 30 秒一次也不该出现的深度上限：防御坏链接 / 异常目录树。
const int kMaxScanDepth = 32;

class MusicFolderScanner {
  MusicFolderScanner({
    required this.target,
    String Function(String path)? pathKey,
    DateTime Function()? clock,
  }) : _pathKey = pathKey ?? _defaultPathKey,
       _clock = clock ?? DateTime.now;

  final LocalScanTarget target;

  /// 平台大小写规则（Windows / macOS 不敏感；Linux / Android 敏感）。
  /// 只用于比较，存库保留原始大小写。
  final String Function(String path) _pathKey;
  final DateTime Function() _clock;

  static String _defaultPathKey(String path) {
    final normalized = p.normalize(path);
    return Platform.isWindows || Platform.isMacOS
        ? normalized.toLowerCase()
        : normalized;
  }

  /// 扫描一个根目录；[onProgress] 节流到 100ms。
  Future<FolderScanOutcome> scan(
    String root, {
    ScanCancellation? cancellation,
    void Function(ScanProgress progress)? onProgress,
  }) async {
    final rootDir = Directory(root);
    if (!await rootDir.exists()) {
      return const FolderScanOutcome(unavailable: true);
    }
    final imported = await target.listImported();
    final byPath = <String, DownloadedTrack>{
      for (final record in imported)
        if (record.filePath != null && record.filePath!.isNotEmpty)
          _pathKey(record.filePath!): record,
    };
    final seen = <String>{};
    final visitedDirs = <String>{};
    var added = 0;
    var updated = 0;
    var skipped = 0;
    var cancelled = false;
    var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);

    Future<void> report(String directory) async {
      final now = _clock();
      if (now.difference(lastProgress).inMilliseconds < 100) return;
      lastProgress = now;
      onProgress?.call(
        ScanProgress(
          processed: added + updated + skipped,
          directory: directory,
        ),
      );
    }

    Future<void> processFile(String path) async {
      final extension = p.extension(path).toLowerCase().replaceFirst('.', '');
      if (!DownloadFileLayout.audioExtensions.contains(extension)) {
        skipped++;
        return;
      }
      String canonical;
      try {
        canonical = _pathKey(await File(path).resolveSymbolicLinks());
      } catch (_) {
        skipped++;
        return;
      }
      if (!seen.add(canonical)) {
        skipped++; // 同一文件的链接 + 真实路径
        return;
      }
      FileStat stat;
      try {
        stat = await File(canonical).stat();
      } catch (_) {
        skipped++;
        return;
      }
      final size = stat.size;
      if (size <= 0) {
        skipped++;
        return;
      }
      final mtime = stat.modified.millisecondsSinceEpoch;
      final existing = byPath[canonical];
      try {
        if (existing == null) {
          await target.importFile(canonical, sizeBytes: size, mtimeMs: mtime);
          added++;
        } else if (existing.mtimeMs != mtime ||
            existing.sizeBytes != size ||
            existing.isMissing) {
          await target.refreshFile(existing, sizeBytes: size, mtimeMs: mtime);
          updated++;
        } else {
          // 未变化：不读标签、不写库。
          return;
        }
      } catch (_) {
        skipped++;
        return;
      }
      await report(p.dirname(canonical));
    }

    Future<void> walk(Directory directory, int depth) async {
      if (cancelled || cancellation?.isCancelled == true) {
        cancelled = true;
        return;
      }
      if (depth > kMaxScanDepth) {
        skipped++;
        return;
      }
      String canonical;
      try {
        canonical = _pathKey(await directory.resolveSymbolicLinks());
      } catch (_) {
        // 权限 / 坏链接：跳过子树，不中止整轮。
        skipped++;
        return;
      }
      if (!visitedDirs.add(canonical)) {
        skipped++; // 目录符号链接环
        return;
      }
      List<FileSystemEntity> entries;
      try {
        entries = await directory.list(followLinks: false).toList();
      } catch (_) {
        skipped++;
        return;
      }
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final entity in entries) {
        if (cancelled || cancellation?.isCancelled == true) {
          cancelled = true;
          return;
        }
        final name = p.basename(entity.path);
        if (name.startsWith('.')) {
          skipped++;
          continue;
        }
        if (entity is Directory) {
          await walk(entity, depth + 1);
          continue;
        }
        if (entity is Link) {
          // 文件链接当文件处理；目录链接按目标类型递归。
          try {
            final resolved = await entity.resolveSymbolicLinks();
            final stat = await FileStat.stat(resolved);
            if (stat.type == FileSystemEntityType.directory) {
              await walk(Directory(resolved), depth + 1);
              continue;
            }
            await processFile(resolved);
          } catch (_) {
            skipped++;
          }
          continue;
        }
        await processFile(entity.path);
      }
    }

    await walk(rootDir, 0);
    if (cancelled) {
      return FolderScanOutcome(
        added: added,
        updated: updated,
        skipped: skipped,
        cancelled: true,
      );
    }
    // 根目录完整枚举成功后才标记「不再存在」的导入记录；整卷离线时已经在
    // 上面按 unavailable 返回，不会把整个库标缺失。
    final rootKey = _pathKey(p.normalize(root));
    for (final entry in byPath.entries) {
      if (seen.contains(entry.key)) continue;
      final path = entry.value.filePath;
      if (path == null) continue;
      final key = _pathKey(p.normalize(path));
      if (key == rootKey) continue;
      if (!key.startsWith(
        rootKey.endsWith(p.separator) ? rootKey : '$rootKey${p.separator}',
      )) {
        continue;
      }
      try {
        await target.markMissing(entry.value);
      } catch (_) {
        skipped++;
      }
    }
    return FolderScanOutcome(added: added, updated: updated, skipped: skipped);
  }
}
