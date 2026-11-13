/// 音乐文件夹扫描器：递归枚举、增量判定、取消、缺文件标记。
///
/// 边界：只读文件头（标签由导入端口负责），不复制 / 移动 / 重命名 / 删除
/// 用户文件；事件监听只是「重新扫描」的触发器，不是真相来源。
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../data/local_identity.dart';
import '../download/download_file_layout.dart';
import '../../domain/models/download.dart';

/// 扫描目标（生产由下载服务适配；测试注入假实现）。
/// 一个扫描批次里的单条变更。
sealed class LocalScanChange {
  const LocalScanChange();
}

final class LocalScanImport extends LocalScanChange {
  const LocalScanImport({
    required this.path,
    required this.sizeBytes,
    required this.mtimeMs,
  });

  final String path;
  final int sizeBytes;
  final int mtimeMs;
}

final class LocalScanRefresh extends LocalScanChange {
  const LocalScanRefresh({
    required this.record,
    required this.sizeBytes,
    required this.mtimeMs,
  });

  final DownloadedTrack record;
  final int sizeBytes;
  final int mtimeMs;
}

final class LocalScanMissing extends LocalScanChange {
  const LocalScanMissing(this.record);

  final DownloadedTrack record;
}

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

  /// 提交一个增量批次（≤200 条）：生产实现走同一条串行写队列。
  Future<void> commitBatch(List<LocalScanChange> changes);
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
    Stream<FileSystemEntity> Function(Directory directory)? lister,
  }) : _pathKey = pathKey ?? _defaultPathKey,
       _clock = clock ?? DateTime.now,
       _lister = lister ?? _defaultLister;

  final LocalScanTarget target;

  /// 目录枚举 seam（测试注入不可读根 / 权限失败）；默认流式枚举，不整树读入。
  final Stream<FileSystemEntity> Function(Directory directory) _lister;

  static Stream<FileSystemEntity> _defaultLister(Directory directory) =>
      directory.list(followLinks: false);

  /// 平台大小写规则（Windows / macOS 不敏感；Linux / Android 敏感）。
  /// 只用于比较，存库保留原始大小写。
  final String Function(String path) _pathKey;
  final DateTime Function() _clock;

  static String _defaultPathKey(String path) => localPathKey(path);

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
    final byStoredPath = <String, DownloadedTrack>{
      for (final record in imported)
        if (record.filePath != null && record.filePath!.isNotEmpty)
          _pathKey(record.filePath!): record,
    };
    // 已见过的路径同时记录「存储路径」与「解析后真实路径」：符号链接根 /
    // macOS `/private` 别名不会因为两边不同而重复导入或误标缺失。
    final seenStored = <String>{};
    final seenCanonical = <String>{};
    final visitedDirs = <String>{};
    var added = 0;
    var updated = 0;
    var skipped = 0;
    var cancelled = false;
    var rootFailed = false;
    var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
    final pending = <LocalScanChange>[];

    void report(String directory) {
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

    Future<void> flush() async {
      if (pending.isEmpty) return;
      final batch = List<LocalScanChange>.of(pending);
      pending.clear();
      try {
        await target.commitBatch(batch);
      } catch (_) {
        skipped += batch.length;
      }
    }

    Future<void> processFile(String storedPath) async {
      final extension = p
          .extension(storedPath)
          .toLowerCase()
          .replaceFirst('.', '');
      if (!DownloadFileLayout.audioExtensions.contains(extension)) {
        skipped++;
        return;
      }
      final storedKey = _pathKey(storedPath);
      String canonical;
      try {
        canonical = _pathKey(await File(storedPath).resolveSymbolicLinks());
      } catch (_) {
        skipped++;
        return;
      }
      if (!seenStored.add(storedKey) || !seenCanonical.add(canonical)) {
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
      final existing = byStoredPath[canonical] ?? byStoredPath[storedKey];
      if (existing == null) {
        // 保存第一次发现的路径，不替换成符号链接目标。
        pending.add(
          LocalScanImport(path: storedPath, sizeBytes: size, mtimeMs: mtime),
        );
        added++;
      } else if (existing.mtimeMs != mtime ||
          existing.sizeBytes != size ||
          existing.isMissing) {
        pending.add(
          LocalScanRefresh(record: existing, sizeBytes: size, mtimeMs: mtime),
        );
        updated++;
      } else {
        return; // 未变化：不读标签、不写库
      }
      if (pending.length >= 200) await flush();
      report(p.dirname(storedPath));
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
        if (depth == 0) rootFailed = true;
        skipped++;
        return;
      }
      if (!visitedDirs.add(canonical)) {
        skipped++; // 目录符号链接环
        return;
      }
      try {
        // 流式枚举：不把整棵树 / 整个目录读进列表；确定性交给文件系统
        // 自身顺序（同一目录树未变化时重复扫描结果一致）。
        await for (final entity in _lister(directory)) {
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
            try {
              final resolved = await entity.resolveSymbolicLinks();
              final stat = await FileStat.stat(resolved);
              if (stat.type == FileSystemEntityType.directory) {
                await walk(Directory(resolved), depth + 1);
              } else {
                await processFile(entity.path);
              }
            } catch (_) {
              skipped++;
            }
            continue;
          }
          await processFile(entity.path);
        }
      } catch (_) {
        // 根枚举失败：整轮作废，绝不把它的记录标缺失；子目录权限失败只
        // 跳过该子树。
        if (depth == 0) {
          rootFailed = true;
        } else {
          skipped++;
        }
      }
    }

    await walk(rootDir, 0);
    await flush();
    if (cancellation?.isCancelled == true) cancelled = true;
    if (cancelled) {
      return FolderScanOutcome(
        added: added,
        updated: updated,
        skipped: skipped,
        cancelled: true,
      );
    }
    if (rootFailed) {
      return FolderScanOutcome(
        added: added,
        updated: updated,
        skipped: skipped,
        unavailable: true,
      );
    }
    // 根目录完整枚举成功后才标记「不再存在」的导入记录；整卷离线时已经在
    // 上面按 unavailable 返回，不会把整个库标缺失。
    final rootKey = _pathKey(p.normalize(root));
    for (final entry in byStoredPath.entries) {
      final record = entry.value;
      final path = record.filePath;
      if (path == null) continue;
      final key = _pathKey(p.normalize(path));
      if (key == rootKey) continue;
      if (!key.startsWith(
        rootKey.endsWith(p.separator) ? rootKey : '$rootKey${p.separator}',
      )) {
        continue;
      }
      if (seenStored.contains(key)) continue;
      String canonicalKey;
      try {
        canonicalKey = _pathKey(await File(path).resolveSymbolicLinks());
      } catch (_) {
        canonicalKey = key;
      }
      if (seenCanonical.contains(canonicalKey)) continue;
      try {
        await target.commitBatch([LocalScanMissing(record)]);
      } catch (_) {
        skipped++;
      }
    }
    return FolderScanOutcome(added: added, updated: updated, skipped: skipped);
  }

  /// 只处理给定路径（监听事件能定位到文件时）：只 stat / 更新这些路径，
  /// 不动整棵树，也不做缺文件标记。
  Future<void> scanPaths(String root, Iterable<String> paths) async {
    final rootDir = Directory(root);
    if (!await rootDir.exists()) return;
    final imported = await target.listImported();
    final state = _ScanState(target: target, pathKey: _pathKey);
    for (final record in imported) {
      final path = record.filePath;
      if (path == null || path.isEmpty) continue;
      state.byStoredPath[_pathKey(path)] = record;
    }
    for (final path in paths) {
      final normalized = _pathKey(p.normalize(path));
      if (!normalized.startsWith(
        _pathKey(p.normalize(root)).endsWith(p.separator)
            ? _pathKey(p.normalize(root))
            : '${_pathKey(p.normalize(root))}${p.separator}',
      )) {
        continue;
      }
      await state.processFile(path);
    }
  }
}

/// 单路径增量处理（监听事件定位到文件时使用）：与整树扫描共用同一条
/// 「路径 + mtime + size」判定，不读未变化的标签、不覆盖用户改过的标题。
class _ScanState {
  _ScanState({required this.target, required this.pathKey});

  final LocalScanTarget target;
  final String Function(String) pathKey;
  final Map<String, DownloadedTrack> byStoredPath = {};
  final Set<String> seenStored = {};
  final Set<String> seenCanonical = {};

  Future<void> processFile(String storedPath) async {
    final extension = p
        .extension(storedPath)
        .toLowerCase()
        .replaceFirst('.', '');
    if (!DownloadFileLayout.audioExtensions.contains(extension)) return;
    final storedKey = pathKey(storedPath);
    String canonical;
    try {
      canonical = pathKey(await File(storedPath).resolveSymbolicLinks());
    } catch (_) {
      return;
    }
    if (!seenStored.add(storedKey) || !seenCanonical.add(canonical)) return;
    final FileStat stat;
    try {
      stat = await File(canonical).stat();
    } catch (_) {
      return;
    }
    final size = stat.size;
    if (size <= 0) return;
    final mtime = stat.modified.millisecondsSinceEpoch;
    final existing = byStoredPath[canonical] ?? byStoredPath[storedKey];
    try {
      if (existing == null) {
        await target.importFile(storedPath, sizeBytes: size, mtimeMs: mtime);
      } else if (existing.mtimeMs != mtime ||
          existing.sizeBytes != size ||
          existing.isMissing) {
        await target.refreshFile(existing, sizeBytes: size, mtimeMs: mtime);
      }
    } catch (_) {
      // 单路径刷新失败只跳过该路径；事件只是触发器。
    }
  }
}
