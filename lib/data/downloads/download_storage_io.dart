import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../files/public_downloads_path.dart';
import 'download_storage_types.dart';

/// IO 平台（Android/iOS/桌面）下载存储：`dart:io` + `path_provider`。
///
/// 下载根目录按平台选择：
/// - **桌面**：系统公共下载目录下 `Molia/`（Windows 走 Known Folder，Linux 走
///   XDG，未配置时回退 `~/Downloads`）——用户在文件管理器里能直接找到下载的歌；
/// - **iOS**：应用文档目录 `Molia/`（文件 App 可见，与“另存目录”同根）；
/// - **Android**：应用支持目录 `downloads/`（公共 Downloads 走 MediaStore）。
///
/// 目录结构（歌词 / 封面走子目录，公共目录不散落小文件）：
/// - `<root>/`          音频文件
/// - `<root>/lyrics/`   歌词（长期）
/// - `<root>/covers/`   封面（长期）
///
/// 测试可注入 [rootOverride] 指向临时目录，或注入 [supportDirectory] /
/// [downloadsDirectory] 替换 path_provider。
class IoDownloadStorage implements DownloadStorage {
  IoDownloadStorage({
    String? rootOverride,
    Future<Directory> Function()? supportDirectory,
    Future<Directory?> Function()? downloadsDirectory,
    String? Function()? customRoot,
  })  : _rootOverride = rootOverride,
        _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
        _downloadsDirectory = downloadsDirectory,
        _customRoot = customRoot;

  final String? _rootOverride;
  final Future<Directory> Function() _supportDirectory;
  final Future<Directory?> Function()? _downloadsDirectory;

  /// 设置页选择的保存位置（每次解析重新读取；改设置无需重启）。
  final String? Function()? _customRoot;

  String? _resolvedRoot;
  String? _resolvedFor;

  @override
  Future<String?> downloadsRoot() async {
    final override = _rootOverride;
    if (override != null) return override;
    final custom = _customRoot?.call()?.trim() ?? '';
    // 自定义根变化（或首次解析）时重新计算。
    if (_resolvedRoot != null && _resolvedFor == custom) return _resolvedRoot;
    try {
      final resolved = custom.isNotEmpty ? custom : await _resolveRoot();
      _resolvedFor = custom;
      return _resolvedRoot = resolved;
    } catch (_) {
      // 目录不可用（测试 / 平台异常）：按不支持处理，UI 隐藏下载入口。
      return null;
    }
  }

  Future<String?> _resolveRoot() async {
    if (Platform.isAndroid) {
      final support = await _supportDirectory();
      return p.join(support.path, downloadsDirName);
    }
    // 桌面 / iOS 与“另存目录”共用同一解析：桌面 = 系统公共下载目录下的
    // Molia/，iOS = 应用文档目录下的 Molia/（文件 App 可见）。
    return resolvePublicDownloadsRoot(downloadsDirectory: _downloadsDirectory);
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
  Future<void> copyFile(String from, String to) async {
    final source = File(from);
    final target = File(to);
    await target.parent.create(recursive: true);
    await source.copy(to);
  }

  @override
  Future<List<String>> listFiles(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const [];
    final files = <String>[];
    try {
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) files.add(entity.path);
      }
    } catch (_) {
      // 权限 / 并发删除：返回已扫描到的部分。
    }
    return files;
  }

  @override
  Future<Uint8List?> readBytes(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List?> readHead(String path, int length) async {
    if (length <= 0) return Uint8List(0);
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.openRead(0, length)) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } catch (_) {
      return null;
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

/// 工厂：`download_storage.dart` 的唯一入口。
DownloadStorage createDownloadStorage({String? Function()? customRoot}) =>
    IoDownloadStorage(customRoot: customRoot);
