/// 音乐文件夹扫描器：树枚举、增量判定、取消、缺文件标记。
///
/// 枚举交给 [MusicFolderTree] 端口：桌面是 `dart:io`，Android 是 SAF
/// `content://` 树；扫描器本身不 import `dart:io`，只按 locator 字符串工作。
///
/// 边界：只读文件头（标签由导入端口负责），不复制 / 移动 / 重命名 / 删除
/// 用户文件；事件监听只是「重新扫描」的触发器，不是真相来源。
library;

import 'dart:async';

import 'package:logging/logging.dart';

import '../../data/files/local_locator.dart';
import '../../domain/models/download.dart';
import '../../domain/ports/music_folder_tree.dart';
import '../download/download_file_layout.dart';

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

/// 扫描跳过原因（D4 的八类；日志只记数量，不暴露路径）。
enum ScanSkipReason {
  unsupportedFormat,
  hidden,
  permissionDenied,
  symlinkCycle,
  depthExceeded,
  zeroBytes,
  duplicatePath,
  rootUnavailable,
}

class FolderScanOutcome {
  const FolderScanOutcome({
    this.added = 0,
    this.updated = 0,
    this.skipped = 0,
    this.cancelled = false,
    this.unavailable = false,
    this.accessRevoked = false,
    this.skipReasons = const {},
  });

  final int added;
  final int updated;
  final int skipped;
  final bool cancelled;
  final bool unavailable;

  /// 根不可用是因为权限被撤销 / 系统拒绝（SAF 授权撤销）。
  final bool accessRevoked;
  final Map<ScanSkipReason, int> skipReasons;
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
    required this.tree,
    String Function(String locator)? pathKey,
    DateTime Function()? clock,
  }) : _pathKey = pathKey ?? localLocatorKey,
       _clock = clock ?? DateTime.now;

  final LocalScanTarget target;
  final MusicFolderTree tree;
  final Logger _logger = Logger('molia.music_folder_scanner');

  /// 平台大小写规则（Windows / macOS 不敏感；Linux / Android / SAF 敏感）。
  /// 只用于比较，存库保留原始 locator。
  final String Function(String locator) _pathKey;
  final DateTime Function() _clock;

  /// 扫描一个根目录；[onProgress] 节流到 100ms。
  Future<FolderScanOutcome> scan(
    String root, {
    ScanCancellation? cancellation,
    void Function(ScanProgress progress)? onProgress,
  }) async {
    final imported = await target.listImported();
    final byStoredPath = <String, DownloadedTrack>{
      for (final record in imported)
        if (record.filePath != null && record.filePath!.isNotEmpty)
          _pathKey(record.filePath!): record,
    };
    // 已见过的 locator 同时记录「存储地址」与「规范化地址」：符号链接根 /
    // macOS `/private` 别名不会因为两边不同而重复导入或误标缺失。
    final seenStored = <String>{};
    final seenCanonical = <String>{};
    var added = 0;
    var updated = 0;
    var skipped = 0;
    var cancelled = false;
    var rootFailed = false;
    var accessRevoked = false;
    var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
    final pending = <LocalScanChange>[];
    final reasons = <ScanSkipReason, int>{};

    void skip(ScanSkipReason reason) {
      skipped++;
      reasons[reason] = (reasons[reason] ?? 0) + 1;
    }

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
        for (var i = 0; i < batch.length; i++) {
          skip(ScanSkipReason.permissionDenied);
        }
      }
    }

    Future<void> processEntry(FolderTreeEntry entry) async {
      final extension = _audioExtensionOf(entry);
      if (!DownloadFileLayout.audioExtensions.contains(extension)) {
        skip(ScanSkipReason.unsupportedFormat);
        return;
      }
      final storedKey = _pathKey(entry.locator);
      final canonicalKey = _pathKey(entry.canonicalLocator);
      if (!seenStored.add(storedKey) || !seenCanonical.add(canonicalKey)) {
        skip(ScanSkipReason.duplicatePath); // 同一文件的链接 + 真实路径
        return;
      }
      final size = entry.sizeBytes;
      if (size <= 0) {
        skip(ScanSkipReason.zeroBytes);
        return;
      }
      final mtime = entry.mtimeMs;
      final existing = byStoredPath[canonicalKey] ?? byStoredPath[storedKey];
      if (existing == null) {
        // 保存第一次发现的 locator，不替换成符号链接目标。
        pending.add(
          LocalScanImport(path: entry.locator, sizeBytes: size, mtimeMs: mtime),
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
      report(_relativeDirectory(entry.relativePath));
    }

    try {
      await for (final event in tree.walk(
        root,
        maxDepth: kMaxScanDepth,
        isCancelled: () => cancellation?.isCancelled == true,
      )) {
        if (cancelled || cancellation?.isCancelled == true) {
          cancelled = true;
          break;
        }
        switch (event) {
          case FolderTreeEntryFound(:final entry):
            if (entry.isDirectory) continue;
            await processEntry(entry);
          case FolderTreeSkipped reason:
            skip(_scanReason(reason.reason));
        }
      }
    } on FolderTreeUnavailable catch (e) {
      // 根枚举失败：整轮作废，绝不把它的记录标缺失。
      rootFailed = true;
      accessRevoked = e.permissionDenied;
      skip(ScanSkipReason.rootUnavailable);
    } catch (_) {
      rootFailed = true;
      skip(ScanSkipReason.rootUnavailable);
    }
    await flush();
    if (cancellation?.isCancelled == true) cancelled = true;
    if (cancelled) {
      return FolderScanOutcome(
        added: added,
        updated: updated,
        skipped: skipped,
        cancelled: true,
        skipReasons: Map.unmodifiable(reasons),
      );
    }
    if (rootFailed) {
      return FolderScanOutcome(
        added: added,
        updated: updated,
        skipped: skipped,
        unavailable: true,
        accessRevoked: accessRevoked,
        skipReasons: Map.unmodifiable(reasons),
      );
    }
    // 根目录完整枚举成功后才标记「不再存在」的导入记录；整卷离线 / SAF
    // 授权撤销时已经在上面按 unavailable 返回，不会把整个库标缺失。
    final rootKey = _pathKey(root);
    for (final entry in byStoredPath.entries) {
      final record = entry.value;
      final path = record.filePath;
      if (path == null) continue;
      final key = _pathKey(path);
      if (key == rootKey) continue;
      if (!isLocatorUnder(root, path)) continue;
      if (seenStored.contains(key)) continue;
      String canonicalKey;
      try {
        canonicalKey = _pathKey(await tree.canonicalLocator(path));
      } catch (_) {
        canonicalKey = key;
      }
      if (seenCanonical.contains(canonicalKey)) continue;
      try {
        await target.commitBatch([LocalScanMissing(record)]);
      } catch (_) {
        skip(ScanSkipReason.permissionDenied);
      }
    }
    final outcome = FolderScanOutcome(
      added: added,
      updated: updated,
      skipped: skipped,
      skipReasons: Map.unmodifiable(reasons),
    );
    _logger.info(
      '扫描完成：新增 $added / 更新 $updated / 跳过 $skipped'
      '${reasons.isEmpty ? '' : '（$reasons）'}',
    );
    return outcome;
  }

  /// 只处理给定路径（监听事件能定位到文件时）：只 stat / 更新这些路径，
  /// 不动整棵树，也不做缺文件标记。
  Future<void> scanPaths(String root, Iterable<String> paths) async {
    final rootStat = await tree.stat(root);
    if (rootStat == null) return;
    final imported = await target.listImported();
    final state = _ScanState(target: target, pathKey: _pathKey);
    for (final record in imported) {
      final path = record.filePath;
      if (path == null || path.isEmpty) continue;
      state.byStoredPath[_pathKey(path)] = record;
    }
    for (final path in paths) {
      if (!isLocatorUnder(root, path)) continue;
      final entry = await tree.stat(
        path,
        relativePath: relativeLocatorPath(root, path) ?? '',
      );
      if (entry == null) continue;
      await state.processEntry(entry);
    }
  }

  Future<String?> displayName(String root) => tree.displayName(root);

  /// provider 的显示名偶尔不带扩展名：回退到文档 id / 路径。
  static String _audioExtensionOf(FolderTreeEntry entry) {
    final fromName = audioExtensionOfLocator(entry.displayName);
    return fromName.isNotEmpty
        ? fromName
        : audioExtensionOfLocator(entry.locator);
  }

  static String _relativeDirectory(String relativePath) {
    final index = relativePath.lastIndexOf('/');
    return index <= 0 ? '' : relativePath.substring(0, index);
  }

  static ScanSkipReason _scanReason(FolderTreeSkipReason reason) =>
      switch (reason) {
        FolderTreeSkipReason.hidden => ScanSkipReason.hidden,
        FolderTreeSkipReason.depthExceeded => ScanSkipReason.depthExceeded,
        FolderTreeSkipReason.symlinkCycle => ScanSkipReason.symlinkCycle,
        FolderTreeSkipReason.unreadable => ScanSkipReason.permissionDenied,
      };
}

/// 单路径增量处理（监听事件定位到文件时使用）：与整树扫描共用同一条
/// 「locator + mtime + size」判定，不读未变化的标签、不覆盖用户改过的标题。
class _ScanState {
  _ScanState({required this.target, required this.pathKey});

  final LocalScanTarget target;
  final String Function(String) pathKey;
  final Map<String, DownloadedTrack> byStoredPath = {};
  final Set<String> seenStored = {};
  final Set<String> seenCanonical = {};

  Future<void> processEntry(FolderTreeEntry entry) async {
    if (entry.isDirectory) return;
    final extension = MusicFolderScanner._audioExtensionOf(entry);
    if (!DownloadFileLayout.audioExtensions.contains(extension)) return;
    final storedKey = pathKey(entry.locator);
    final canonicalKey = pathKey(entry.canonicalLocator);
    if (!seenStored.add(storedKey) || !seenCanonical.add(canonicalKey)) return;
    if (entry.sizeBytes <= 0) return;
    final existing = byStoredPath[canonicalKey] ?? byStoredPath[storedKey];
    try {
      if (existing == null) {
        await target.importFile(
          entry.locator,
          sizeBytes: entry.sizeBytes,
          mtimeMs: entry.mtimeMs,
        );
      } else if (existing.mtimeMs != entry.mtimeMs ||
          existing.sizeBytes != entry.sizeBytes ||
          existing.isMissing) {
        await target.refreshFile(
          existing,
          sizeBytes: entry.sizeBytes,
          mtimeMs: entry.mtimeMs,
        );
      }
    } catch (_) {
      // 单路径刷新失败只跳过该路径；事件只是触发器。
    }
  }
}
