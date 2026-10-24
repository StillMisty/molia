/// 公共下载目录（应用“另存目录”）的路径解析。
///
/// 只做解析，不写文件：下载存储（`IoDownloadStorage`）与另存服务
/// （`SaveAs`）共用同一口径，避免桌面 / iOS 各自维护一套回退逻辑。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../downloads/download_storage_types.dart' show publicDownloadsDirName;

/// 解析桌面 / iOS 的公共输出根。
///
/// - 桌面：系统“下载”目录下的 `Molia/`（Windows 走 Known Folder，Linux 走
///   XDG，未配置时回退 `~/Downloads`）；
/// - iOS：应用文档目录下的 `Molia/`（Info.plist 已开文件共享，文件 App 可见）；
/// - Android：返回 null——公共 Downloads 只能经 MediaStore 写入，实际路径由
///   原生通道提供（这里不猜 `/storage/emulated/0`）。
///
/// [customRoot] 非空时优先（桌面设置页自选保存位置）。
/// [downloadsDirectory] / [documentsDirectory] 仅测试注入；生产走
/// `path_provider`。目录不在这里创建，首次写入时由调用方创建。
Future<String?> resolvePublicDownloadsRoot({
  String? Function()? customRoot,
  Future<Directory?> Function()? downloadsDirectory,
  Future<Directory> Function()? documentsDirectory,
}) async {
  final custom = customRoot?.call()?.trim() ?? '';
  if (custom.isNotEmpty) return custom;
  if (Platform.isAndroid) return null;

  if (Platform.isIOS) {
    try {
      final documents =
          await (documentsDirectory ?? getApplicationDocumentsDirectory)();
      return p.join(documents.path, publicDownloadsDirName);
    } catch (_) {
      return null;
    }
  }

  Directory? downloads;
  try {
    downloads = await (downloadsDirectory ?? getDownloadsDirectory)();
  } catch (_) {
    // path_provider 不可用（测试 / 极简平台）：走环境变量回退。
    downloads = null;
  }
  final base = downloads?.path ?? _fallbackDesktopDownloadsPath();
  if (base == null || base.isEmpty) return null;
  return p.join(base, publicDownloadsDirName);
}

/// 桌面系统“下载”目录的回退解析（path_provider 返回 null 时）。
///
/// Linux 优先读 XDG `XDG_DOWNLOAD_DIR`；Windows 用 `USERPROFILE`，其余桌面
/// 用 `~/Downloads`。Windows Known Folder 被 OneDrive 重定向时
/// `path_provider` 会先命中，不会走到这里。
String? _fallbackDesktopDownloadsPath() {
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
