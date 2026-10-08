import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'cache_types.dart';
/// IO 平台（Android/iOS/桌面）缓存存储：`dart:io` + `path_provider`。
///
/// 音频与封面目录都放在应用支持目录（持久，系统清理不会触碰）：
/// - `<appSupport>/audio_cache`：just_audio `LockCachingAudioSource` 的
///   cacheFile 落盘位置（LRU 按 mtime 淘汰）；
/// - `<appSupport>/artwork_cache`：flutter_cache_manager 的 FileSystem 根目录
///   （策略 sweep 过期 + 超量 LRU）。
///
/// 测试可注入 [audioDirOverride] / [artworkDirOverride] 指向临时目录，
/// 或注入 [supportDirectory] 替换 path_provider。
class IoCacheStorage implements CacheStorage {
  IoCacheStorage({
    String? audioDirOverride,
    String? artworkDirOverride,
    Future<Directory> Function()? supportDirectory,
  })  : _audioDirOverride = audioDirOverride,
        _artworkDirOverride = artworkDirOverride,
        _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  static const String audioDirName = 'audio_cache';
  static const String artworkDirName = 'artwork_cache';

  final String? _audioDirOverride;
  final String? _artworkDirOverride;
  final Future<Directory> Function() _supportDirectory;

  String? _resolvedAudioDir;
  String? _resolvedArtworkDir;

  @override
  Future<String?> audioCacheDir() async {
    final override = _audioDirOverride;
    if (override != null) return override;
    if (_resolvedAudioDir != null) return _resolvedAudioDir;
    final support = await _supportDirectory();
    return _resolvedAudioDir =
        _join(support.path, audioDirName);
  }

  @override
  Future<String?> artworkCacheDir() async {
    final override = _artworkDirOverride;
    if (override != null) return override;
    if (_resolvedArtworkDir != null) return _resolvedArtworkDir;
    final support = await _supportDirectory();
    return _resolvedArtworkDir = _join(support.path, artworkDirName);
  }

  static String _join(String base, String name) {
    if (base.endsWith(Platform.pathSeparator)) return '$base$name';
    return '$base${Platform.pathSeparator}$name';
  }

  @override
  Future<CacheUsage> usage(String dirPath) async {
    final files = await _listFiles(dirPath);
    var bytes = 0;
    for (final file in files) {
      try {
        bytes += await file.length();
      } catch (_) {
        // 文件可能正被删除/替换：忽略单个文件错误。
      }
    }
    return CacheUsage(bytes: bytes, count: files.length);
  }

  @override
  Future<void> clear(String dirPath) async {
    final files = await _listFiles(dirPath);
    for (final file in files) {
      try {
        await file.delete();
      } catch (_) {
        // 忽略单个文件删除失败（可能被其它进程占用）。
      }
    }
  }

  @override
  Future<int> enforceAudioLimit(
    String dirPath, {
    required int maxBytes,
    required Duration protectAge,
  }) async {
    if (maxBytes <= 0) return 0; // 0 = 不限制
    final files = await _listFiles(dirPath);
    if (files.isEmpty) return 0;

    final entries = <_FileEntry>[];
    var total = 0;
    for (final file in files) {
      try {
        final stat = await file.stat();
        entries.add(_FileEntry(file, stat.modified, stat.size));
        total += stat.size;
      } catch (_) {}
    }
    if (total <= maxBytes) return 0;

    entries.sort((a, b) => a.modified.compareTo(b.modified));
    final now = DateTime.now();
    var deleted = 0;
    for (final entry in entries) {
      if (total <= maxBytes) break;
      // 正在写入（边播边缓存）的文件不能删。
      if (now.difference(entry.modified) < protectAge) continue;
      try {
        await entry.file.delete();
        total -= entry.size;
        deleted++;
      } catch (_) {}
    }
    return deleted;
  }

  @override
  Future<int> sweepArtwork(
    String dirPath, {
    required int maxObjects,
    required int staleDays,
  }) async {
    final files = await _listFiles(dirPath);
    if (files.isEmpty) return 0;

    final entries = <_FileEntry>[];
    for (final file in files) {
      try {
        final stat = await file.stat();
        entries.add(_FileEntry(file, stat.modified, stat.size));
      } catch (_) {}
    }

    final deletedPaths = <String>{};
    var deleted = 0;

    Future<void> remove(_FileEntry entry) async {
      if (deletedPaths.contains(entry.file.path)) return;
      try {
        await entry.file.delete();
        deletedPaths.add(entry.file.path);
        deleted++;
      } catch (_) {}
    }

    // 1) 过期清理。
    if (staleDays > 0) {
      final cutoff = DateTime.now().subtract(Duration(days: staleDays));
      for (final entry in entries) {
        if (entry.modified.isBefore(cutoff)) await remove(entry);
      }
    }

    // 2) 超量 LRU 清理（按 mtime 从旧到新）。
    if (maxObjects > 0) {
      final remaining =
          entries.where((e) => !deletedPaths.contains(e.file.path)).toList()
            ..sort((a, b) => a.modified.compareTo(b.modified));
      var over = remaining.length - maxObjects;
      for (final entry in remaining) {
        if (over <= 0) break;
        await remove(entry);
        over--;
      }
    }

    return deleted;
  }

  Future<List<File>> _listFiles(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const [];
    final files = <File>[];
    try {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) files.add(entity);
      }
    } catch (_) {
      // 目录权限/并发删除等问题：返回已扫描到的部分。
    }
    return files;
  }
}

class _FileEntry {
  _FileEntry(this.file, this.modified, this.size);

  final File file;
  final DateTime modified;
  final int size;
}

/// 工厂：`cache_storage.dart` 的条件导入入口。
CacheStorage createCacheStorage() => IoCacheStorage();
