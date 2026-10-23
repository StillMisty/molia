import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
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

  /// 设备存储容量通道（仅 Android 注册；其余平台按不可用处理）。
  static const MethodChannel _deviceStorageChannel =
      MethodChannel('top.stillmisty.molia/device_storage');

  final String? _audioDirOverride;
  final String? _artworkDirOverride;
  final Future<Directory> Function() _supportDirectory;

  String? _resolvedAudioDir;
  String? _resolvedArtworkDir;
  int? _totalSpaceCache;

  @override
  Future<int?> totalSpaceBytes() async {
    final cached = _totalSpaceCache;
    if (cached != null) return cached;
    final value = await _queryTotalSpaceBytes();
    // 只缓存成功结果：查询失败（通道时序 / 平台异常）下次仍可重试。
    if (value != null) _totalSpaceCache = value;
    return value;
  }

  /// Android 经原生 StatFs 读内部存储分区总容量；其余平台/失败返回 null
  /// （上层回退固定默认值）。
  Future<int?> _queryTotalSpaceBytes() async {
    if (!Platform.isAndroid) return null;
    try {
      final bytes =
          await _deviceStorageChannel.invokeMethod<num>('getTotalBytes');
      final value = bytes?.toInt();
      return (value == null || value <= 0) ? null : value;
    } catch (_) {
      // 通道缺失（测试 / 独立服务）或查询失败：按不可用处理。
      return null;
    }
  }

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
    // 大缓存目录的递归列举 + 逐文件取大小是 O(文件数) 的串行 IO；留在主
    // isolate 会在打开缓存设置页时卡帧，因此整体丢给短命 isolate，主 isolate
    // 只等结果。这里只捕获目录路径，不把存储对象带进子 isolate。
    final scan = await Isolate.run(
      () => _scanCacheDir(dirPath, withFiles: false),
    );
    return CacheUsage(bytes: scan.bytes, count: scan.count);
  }

  @override
  Future<Map<String, int>> listFiles(String dirPath) async {
    // 与 usage 同理：本地歌曲 / 缓存列表一次列举上千个文件，扫描放在子
    // isolate；回传的只有「文件名 → 字节数」基础类型。
    final scan = await Isolate.run(() => _scanCacheDir(dirPath));
    return scan.files;
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
  Future<int> deleteWhere(
    String dirPath, {
    required bool Function(String fileName) test,
  }) async {
    final files = await _listFiles(dirPath);
    var deleted = 0;
    for (final file in files) {
      if (!test(file.uri.pathSegments.last)) continue;
      try {
        await file.delete();
        deleted++;
      } catch (_) {
        // 忽略单个文件失败：占用/提示按实际删除结果计。
      }
    }
    return deleted;
  }

  @override
  Future<CacheDeleteResult> deleteMatching(
    String dirPath, {
    required String prefix,
    Duration protectAge = Duration.zero,
  }) async {
    final matches = _matchFiles(await _listFiles(dirPath), prefix);
    if (matches.isEmpty) return const CacheDeleteResult();
    final now = DateTime.now();
    var bytes = 0;
    var deleted = 0;
    var skipped = 0;
    for (final file in matches) {
      try {
        if (protectAge > Duration.zero) {
          final modified = (await file.stat()).modified;
          if (now.difference(modified) < protectAge) {
            skipped++;
            continue;
          }
        }
        final size = await file.length();
        await file.delete();
        bytes += size;
        deleted++;
      } catch (_) {
        // 忽略单个文件失败：占用/提示按实际删除结果计。
      }
    }
    return CacheDeleteResult(
      deleted: CacheUsage(bytes: bytes, count: deleted),
      skipped: skipped,
    );
  }

  /// 文件名前缀匹配（只取文件名，不带目录）。
  List<File> _matchFiles(List<File> files, String prefix) => [
        for (final file in files)
          if (file.uri.pathSegments.last.startsWith(prefix)) file,
      ];

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

/// 目录扫描结果：字节数 / 文件数 / 文件名 → 字节数。
///
/// 只含可跨 isolate 发送的基础类型（`int` + `Map<String, int>`），不在子 isolate
/// 里回传 `File` 等平台对象。
typedef _CacheDirScan = ({int bytes, int count, Map<String, int> files});

/// 递归扫描缓存目录（在短命 isolate 中执行，必须是顶层函数）。
///
/// 为什么不能做成实例方法：`Isolate.run` 的闭包只应捕获目录路径这类可发送
/// 值。捕获 `this` 会连同 method channel / `path_provider` 状态一起带进子
/// isolate，而子 isolate 没有平台通道，调用会直接失败。
///
/// 失败语义与原先主 isolate 上的串行实现一致：
/// - 目录不存在或不可读：按空结果处理；
/// - 单个文件取大小失败（正被删除 / 替换）：跳过该文件；
/// - 某个子目录不可读：跳过它，保留其它已扫描到的文件。
_CacheDirScan _scanCacheDir(String dirPath, {bool withFiles = true}) {
  final root = Directory(dirPath);
  if (!root.existsSync()) {
    return (bytes: 0, count: 0, files: const <String, int>{});
  }

  final files = <File>[];
  // 逐目录列举而不是 `listSync(recursive: true)`：子目录不可读时前者能保留
  // 其它已扫描到的文件，与原异步流「返回已扫描部分」的语义一致。
  final pending = <Directory>[root];
  while (pending.isNotEmpty) {
    final dir = pending.removeLast();
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is File) {
          files.add(entity);
        } else if (entity is Directory) {
          pending.add(entity);
        }
      }
    } catch (_) {
      // 权限 / 并发删除等问题：跳过该目录，继续扫描其它目录。
    }
  }

  var bytes = 0;
  final sizes = <String, int>{};
  for (final file in files) {
    try {
      final length = file.lengthSync();
      bytes += length;
      if (withFiles) sizes[file.uri.pathSegments.last] = length;
    } catch (_) {
      // 文件可能正被删除/替换：忽略单个文件错误（仍计入 count，沿用旧口径）。
    }
  }
  return (bytes: bytes, count: files.length, files: sizes);
}

class _FileEntry {
  _FileEntry(this.file, this.modified, this.size);

  final File file;
  final DateTime modified;
  final int size;
}

/// 工厂：`cache_storage.dart` 的唯一入口。
CacheStorage createCacheStorage() => IoCacheStorage();
