import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'download_storage_types.dart';

/// IO 平台（Android/iOS/桌面）下载存储：`dart:io` + `path_provider`。
///
/// 目录结构（应用支持目录，持久、系统清理不会触碰）：
/// - `<appSupport>/downloads/`        音频文件
/// - `<appSupport>/downloads/lyrics/` 歌词（长期）
/// - `<appSupport>/downloads/covers/` 封面（长期）
///
/// 测试可注入 [rootOverride] 指向临时目录，或注入 [supportDirectory]
/// 替换 path_provider。
class IoDownloadStorage implements DownloadStorage {
  IoDownloadStorage({
    String? rootOverride,
    Future<Directory> Function()? supportDirectory,
  })  : _rootOverride = rootOverride,
        _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final String? _rootOverride;
  final Future<Directory> Function() _supportDirectory;

  String? _resolvedRoot;

  @override
  Future<String?> downloadsRoot() async {
    final override = _rootOverride;
    if (override != null) return override;
    if (_resolvedRoot != null) return _resolvedRoot;
    try {
      final support = await _supportDirectory();
      return _resolvedRoot = p.join(support.path, downloadsDirName);
    } catch (_) {
      // 目录不可用（测试 / 平台异常）：按不支持处理，UI 隐藏下载入口。
      return null;
    }
  }

  @override
  Future<bool> fileExists(String path) async {
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<int> fileSize(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return 0;
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<void> writeStream(
    String path,
    Stream<List<int>> stream, {
    int? total,
    void Function(int received, int? total)? onProgress,
  }) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
    } finally {
      try {
        await sink.close();
      } catch (_) {
        // 流异常时的收尾失败不覆盖原始错误。
      }
    }
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> writeString(String path, String content) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
  }

  @override
  Future<String?> readString(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    final file = File(from);
    await file.parent.create(recursive: true);
    await file.rename(to);
  }

  @override
  Future<void> deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删除失败静默：清理路径不应影响主流程。
    }
  }
}

/// 工厂：`download_storage.dart` 的条件导入入口。
DownloadStorage createDownloadStorage() => IoDownloadStorage();
