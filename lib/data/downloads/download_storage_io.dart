import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'download_storage_types.dart';

/// IO 平台（Android/iOS/桌面）下载存储：`dart:io` + `path_provider`。
///
/// 下载根目录按平台选择：
/// - **桌面**：系统下载目录下 `Molia/`（Linux 读 XDG `XDG_DOWNLOAD_DIR`，
///   回退 `~/Downloads`；macOS `~/Downloads`；Windows `%USERPROFILE%\Downloads`）——
///   用户在文件管理器里能直接找到下载的歌；
/// - **iOS**：应用文档目录 `Molia/`（Files app 可见，需 Info.plist 开关）；
/// - **Android**：应用支持目录 `downloads/`（公共 Downloads 走 MediaStore，
///   见 issue #17）。
///
/// 目录结构（歌词 / 封面走子目录，公共目录不散落小文件）：
/// - `<root>/`          音频文件
/// - `<root>/lyrics/`   歌词（长期）
/// - `<root>/covers/`   封面（长期）
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
      return _resolvedRoot = await _resolveRoot();
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
    if (Platform.isIOS) {
      final documents = await getApplicationDocumentsDirectory();
      return p.join(documents.path, publicDownloadsDirName);
    }
    final base = _systemDownloadsDirectory();
    if (base == null) return null;
    return p.join(base, publicDownloadsDirName);
  }

  /// 系统下载目录（桌面）：Linux 优先 XDG 用户目录，其余回退 `~/Downloads`。
  String? _systemDownloadsDirectory() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final profile = env['USERPROFILE'];
      if (profile == null || profile.isEmpty) return null;
      return p.join(profile, 'Downloads');
    }
    final home = env['HOME'];
    if (home == null || home.isEmpty) return null;
    if (Platform.isLinux) {
      final xdg = _xdgDownloadDirectory(home);
      if (xdg != null) return xdg;
    }
    return p.join(home, 'Downloads');
  }

  /// Linux XDG 用户目录：读 `~/.config/user-dirs.dirs` 的 `XDG_DOWNLOAD_DIR`。
  String? _xdgDownloadDirectory(String home) {
    try {
      final config = File(p.join(home, '.config', 'user-dirs.dirs'));
      if (!config.existsSync()) return null;
      final content = config.readAsStringSync();
      final match = RegExp(
        r'^XDG_DOWNLOAD_DIR="?([^"\n]+)"?',
        multiLine: true,
      ).firstMatch(content);
      final raw = match?.group(1);
      if (raw == null || raw.isEmpty) return null;
      final expanded = raw.replaceFirst(r'$HOME', home);
      return expanded.startsWith('/') ? expanded : p.join(home, expanded);
    } catch (_) {
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
  Future<void> copyFile(String from, String to) async {
    final source = File(from);
    final target = File(to);
    await target.parent.create(recursive: true);
    await source.copy(to);
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
