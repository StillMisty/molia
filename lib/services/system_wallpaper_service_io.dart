import 'dart:io';

import 'package:flutter/foundation.dart'
    show Brightness, TargetPlatform, defaultTargetPlatform;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// gsettings 值读取入口：返回 `gsettings get` 的 stdout，键 / schema 不存在
/// （非零退出）或进程不可用返回 null。
typedef GsettingsValueReader = Future<String?> Function(String key);

/// 系统壁纸文件探测：桌面取色的壁纸来源（配合
/// `ArtworkPaletteService.loadLocalFile`）。
///
/// 只回答「按亮度找壁纸文件绝对路径」，不解码、不缓存：
/// - Linux（GNOME 系）：`gsettings get org.gnome.desktop.background
///   picture-uri`；深色优先 `picture-uri-dark`，该键拿不到时回落浅色值；
/// - Windows：`%APPDATA%\Microsoft\Windows\Themes\TranscodedWallpaper`
///   （当前壁纸按屏幕裁切后的副本，浅 / 深同一文件）；
/// - 其它平台（KDE / XFCE / macOS / 移动端等）：null，由系统强调色兜底。
///
/// 平台 / gsettings 读取 / environment / 文件存在性全部构造注入：单测不碰
/// 真实桌面会话。任何失败（键缺失、非零退出、进程缺失、文件不存在）都返回
/// null，异常记 warning，不抛、不阻塞启动。
class SystemWallpaperSource {
  SystemWallpaperSource({
    TargetPlatform? platform,
    Map<String, String>? environment,
    GsettingsValueReader? readGsettings,
    Future<bool> Function(String path)? fileExists,
  })  : _platform = platform ?? defaultTargetPlatform,
        _environment = environment ?? Platform.environment,
        _readGsettings = readGsettings ?? _runGsettings,
        _fileExists = fileExists ?? _existsOnDisk;

  /// GNOME 背景设置 schema（GNOME / Cinnamon / MATE 同源）。
  static const String _gnomeBackgroundSchema = 'org.gnome.desktop.background';

  /// Windows 当前壁纸裁切副本相对 `%APPDATA%` 的路径段。
  static const List<String> _windowsWallpaperSegments = <String>[
    'Microsoft',
    'Windows',
    'Themes',
    'TranscodedWallpaper',
  ];

  final TargetPlatform _platform;
  final Map<String, String> _environment;
  final GsettingsValueReader _readGsettings;
  final Future<bool> Function(String path) _fileExists;
  final Logger _logger = Logger('molia.system_wallpaper_source');

  /// 非桌面平台只提示一次：浅 / 深两次解析（同一实例）不刷重复日志。
  bool _warnedUnsupported = false;

  /// 目标亮度的壁纸文件绝对路径；无可用来源返回 null（调用方回退强调色 /
  /// 自定义种子色）。
  Future<String?> resolvePath(Brightness brightness) async {
    try {
      return switch (_platform) {
        TargetPlatform.linux => await _linuxPath(brightness),
        TargetPlatform.windows => await _windowsPath(),
        _ => _unsupportedPlatform(),
      };
    } catch (e) {
      // gsettings 缺失 / 权限失败等：保持 null 走强调色兜底，不打断启动。
      _logger.warning('系统壁纸探测失败（回退强调色）: $e');
      return null;
    }
  }

  String? _unsupportedPlatform() {
    if (!_warnedUnsupported) {
      _warnedUnsupported = true;
      _logger.warning('当前平台无系统壁纸来源（回退强调色）: $_platform');
    }
    return null;
  }

  /// Linux：深色优先 `picture-uri-dark`，键缺失 / 值非法 / 文件不存在时
  /// 回落浅色 `picture-uri`（GNOME 42+ 才有深色键，老版本只有浅色键）。
  Future<String?> _linuxPath(Brightness brightness) async {
    final keys = brightness == Brightness.dark
        ? const <String>['picture-uri-dark', 'picture-uri']
        : const <String>['picture-uri'];
    for (final key in keys) {
      final output = await _readGsettings(key);
      final path = output == null ? null : parseGsettingsValue(output);
      if (path == null) continue;
      if (await _fileExists(path)) return path;
      _logger.fine('壁纸文件不存在，尝试下一个 gsettings 键: $path');
    }
    return null;
  }

  Future<String?> _windowsPath() async {
    final appData = _environment['APPDATA'];
    if (appData == null || appData.isEmpty) {
      _logger.fine('APPDATA 缺失，无法定位 Windows 壁纸');
      return null;
    }
    // 固定用 Windows 路径上下文：该分支只在 Windows 生效，也让其它平台上
    // 跑的测试能断言 `\` 分隔。
    final path = p.windows.joinAll(<String>[
      appData,
      ..._windowsWallpaperSegments,
    ]);
    if (!await _fileExists(path)) {
      _logger.fine('Windows 壁纸文件不存在: $path');
      return null;
    }
    return path;
  }

  /// 解析 `gsettings get` 输出：去 GVariant 引号 → 要求 `file` scheme →
  /// 路径。空串（键未设置）、非 file 值、类型注解等一律 null。
  static String? parseGsettingsValue(String output) {
    var value = output.trim();
    if (value.isEmpty) return null;
    // 类型注解形态（`@s 'x'` / `@as []`）：只接受字符串值本身。
    if (value.startsWith('@')) {
      final space = value.indexOf(' ');
      if (space < 0) return null;
      value = value.substring(space + 1).trim();
    }
    if (value.length >= 2 && value.startsWith("'") && value.endsWith("'")) {
      value = value.substring(1, value.length - 1);
    }
    if (value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'file') return null;
    final String path;
    try {
      // 非法的 file URI（如带非法转义）在 toFilePath 抛 UnsupportedError。
      path = uri.toFilePath();
    } on UnsupportedError {
      return null;
    }
    return path.isEmpty ? null : path;
  }

  static Future<String?> _runGsettings(String key) async {
    final result = await Process.run(
      'gsettings',
      <String>['get', _gnomeBackgroundSchema, key],
    );
    if (result.exitCode != 0) return null;
    return '${result.stdout}';
  }

  static Future<bool> _existsOnDisk(String path) => File(path).exists();
}
