/// 另存服务的 IO 实现：桌面“另存为” / Android MediaStore / iOS 应用文档目录。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/downloads/download_storage_types.dart'
    show publicDownloadsDirName;
import '../data/downloads/downloads_publisher.dart';
import '../data/files/public_downloads_path.dart';
import 'save_as_types.dart';

/// 系统「下载」的目录名（Android `Environment.DIRECTORY_DOWNLOADS`）。
const String _androidPublicDownloadsDirName = 'Download';

/// 另存服务的 IO 实现。
///
/// 写入策略：
/// - 桌面：有 [dialog] 时先弹“另存为”（默认目录 = 另存目录），取消即结束；
///   对话框不可用 / 抛异常时回退直接写入另存目录；
/// - Android：先写临时文件，再经 [DownloadsPublisher] 发布进 MediaStore
///   （分区存储下 Dart 不能直接写公共 Downloads）；
/// - iOS：直接写应用文档目录（文件 App 可见），不弹系统选择器。
class IoSaveAs implements SaveAs {
  IoSaveAs({
    required this._publisher,
    this._customRoot,
    this._dialog,
    this._downloadsDirectory,
    this._documentsDirectory,
    this._temporaryDirectory,
    bool? android,
    bool? ios,
  })  : _isAndroid = android ?? Platform.isAndroid,
        _isIos = ios ?? Platform.isIOS;

  final DownloadsPublisher _publisher;
  final String? Function()? _customRoot;
  final SaveFileDialog? _dialog;
  final Future<Directory?> Function()? _downloadsDirectory;
  final Future<Directory> Function()? _documentsDirectory;
  final Future<Directory> Function()? _temporaryDirectory;

  /// 平台判定可在测试注入（CI 跑在 Linux，无法真实切到 Android / iOS）。
  final bool _isAndroid;
  final bool _isIos;

  final Logger _logger = Logger('molia.save_as');

  @override
  Future<String?> rootPath() async {
    if (_isAndroid) return _publisher.publicRoot();
    return resolvePublicDownloadsRoot(
      customRoot: _customRoot,
      downloadsDirectory: _downloadsDirectory,
      documentsDirectory: _documentsDirectory,
    );
  }

  @override
  Future<SaveAsResult> saveBytes({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String relativeDir = '',
    String? dialogTitle,
  }) async {
    final safeName = _safeFileName(fileName);
    final safeDir = _safeRelativeDir(relativeDir);
    final dialog = _dialog;
    if (dialog != null) {
      final root = await rootPath();
      final initialDirectory = root == null ? null : p.join(root, safeDir);
      if (initialDirectory != null) {
        try {
          await Directory(initialDirectory).create(recursive: true);
        } catch (_) {
          // 目录创建失败交给对话框 / 回退路径处理。
        }
      }
      try {
        final picked = await dialog(
          fileName: safeName,
          bytes: bytes,
          mimeType: mimeType,
          initialDirectory: initialDirectory,
          dialogTitle: dialogTitle,
        );
        if (picked == null) return const SaveAsCancelled();
        return SaveAsSaved(
          path: picked,
          displayPath: picked,
          kind: SaveLocationKind.fileSystem,
        );
      } catch (e) {
        // 对话框不可用（无 portal / 无 zenity）：回退直接写默认目录，
        // 保证“保存”动作仍能完成。
        _logger.fine('另存对话框不可用，回退默认目录: $e');
      }
    }
    return _writeBytesDirect(
      fileName: safeName,
      bytes: bytes,
      mimeType: mimeType,
      relativeDir: safeDir,
    );
  }

  Future<SaveAsResult> _writeBytesDirect({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    required String relativeDir,
  }) async {
    if (_isAndroid) {
      return _writeAndroid(
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeType,
        relativeDir: relativeDir,
      );
    }
    final root = await rootPath();
    if (root == null) return const SaveAsFailed();
    try {
      final dir = p.join(root, relativeDir);
      await Directory(dir).create(recursive: true);
      final target = _uniquePath(dir, fileName);
      await File(target).writeAsBytes(bytes, flush: true);
      return SaveAsSaved(
        path: target,
        displayPath: _isIos
            ? p.join(
                publicDownloadsDirName,
                relativeDir,
                p.basename(target),
              )
            : target,
        kind: _isIos ? SaveLocationKind.filesApp : SaveLocationKind.fileSystem,
      );
    } catch (e) {
      _logger.fine('写入另存目录失败: $e');
      return SaveAsFailed(e);
    }
  }

  Future<SaveAsResult> _writeAndroid({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    required String relativeDir,
  }) async {
    final Directory tempDir;
    try {
      tempDir = await (_temporaryDirectory ?? getTemporaryDirectory)();
    } catch (e) {
      return SaveAsFailed(e);
    }
    final temp = File(
      p.join(
        tempDir.path,
        'save_${DateTime.now().microsecondsSinceEpoch}_$fileName',
      ),
    );
    try {
      await temp.writeAsBytes(bytes, flush: true);
      final uri = await _publisher.publish(
        sourcePath: temp.path,
        displayName: fileName,
        mimeType: mimeType,
        relativeDir: relativeDir,
      );
      if (uri == null) return const SaveAsFailed();
      return SaveAsSaved(
        path: uri,
        displayPath: p.join(
          _androidPublicDownloadsDirName,
          publicDownloadsDirName,
          relativeDir,
          fileName,
        ),
        kind: SaveLocationKind.downloads,
      );
    } catch (e) {
      _logger.fine('发布到公共 Downloads 失败: $e');
      return SaveAsFailed(e);
    } finally {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // 临时文件清理失败不影响保存结果。
      }
    }
  }

  @override
  Future<SaveAsResult> saveFile({
    required String sourcePath,
    required String fileName,
    required String mimeType,
    String relativeDir = '',
  }) async {
    final safeName = _safeFileName(fileName);
    final safeDir = _safeRelativeDir(relativeDir);
    if (_isAndroid) {
      try {
        final uri = await _publisher.publish(
          sourcePath: sourcePath,
          displayName: safeName,
          mimeType: mimeType,
          relativeDir: safeDir,
        );
        if (uri == null) return const SaveAsFailed();
        return SaveAsSaved(
          path: uri,
          displayPath: p.join(
            _androidPublicDownloadsDirName,
            publicDownloadsDirName,
            safeDir,
            safeName,
          ),
          kind: SaveLocationKind.downloads,
        );
      } catch (e) {
        return SaveAsFailed(e);
      }
    }

    final root = await rootPath();
    if (root == null) return const SaveAsFailed();
    try {
      final dir = p.join(root, safeDir);
      final target = _uniquePath(dir, safeName);
      if (p.equals(sourcePath, target)) {
        return SaveAsSaved(
          path: target,
          displayPath: _isIos
              ? p.join(publicDownloadsDirName, safeDir, safeName)
              : target,
          kind:
              _isIos ? SaveLocationKind.filesApp : SaveLocationKind.fileSystem,
        );
      }
      await Directory(dir).create(recursive: true);
      await File(sourcePath).copy(target);
      return SaveAsSaved(
        path: target,
        displayPath: _isIos
            ? p.join(publicDownloadsDirName, safeDir, p.basename(target))
            : target,
        kind: _isIos ? SaveLocationKind.filesApp : SaveLocationKind.fileSystem,
      );
    } catch (e) {
      _logger.fine('复制到另存目录失败: $e');
      return SaveAsFailed(e);
    }
  }

  @override
  Future<bool> reveal(String path) async {
    if (_isAndroid || _isIos) return false;
    try {
      if (Platform.isLinux) {
        final dir = File(path).parent.path;
        final result = await Process.run('xdg-open', [dir]);
        return result.exitCode == 0;
      }
      if (Platform.isWindows) {
        final result = await Process.run('explorer.exe', ['/select,', path]);
        return result.exitCode == 0;
      }
      if (Platform.isMacOS) {
        final result = await Process.run('open', ['-R', path]);
        return result.exitCode == 0;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 文件名清洗：去掉路径分隔符 / 平台非法字符，避免把标题写进子目录。
  String _safeFileName(String name) {
    final replaced = name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (replaced.isEmpty || replaced == '.' || replaced == '..') {
      return 'molia_export';
    }
    if (replaced.length <= 120) return replaced;
    // 先留出扩展名，避免超长标题把 `.json` / `.png` 截掉。
    final extension = p.extension(replaced);
    final base = p.basenameWithoutExtension(replaced);
    final budget = 120 - extension.length;
    final shortened = budget <= 0
        ? String.fromCharCodes(replaced.runes.take(120)).trim()
        : '${String.fromCharCodes(base.runes.take(budget)).trim()}$extension';
    return shortened;
  }

  /// 子目录清洗：只允许一层层普通目录，拒绝 `..` / 绝对路径。
  String _safeRelativeDir(String relativeDir) {
    final segments = relativeDir
        .split('/')
        .map((segment) => segment.trim())
        .where((segment) =>
            segment.isNotEmpty && segment != '.' && segment != '..')
        .toList();
    return segments.join('/');
  }

  /// 同目录内避免覆盖：`name.ext` → `name (2).ext`。
  String _uniquePath(String dir, String fileName) {
    var target = p.join(dir, fileName);
    if (!File(target).existsSync()) return target;
    final extension = p.extension(fileName);
    final base = p.basenameWithoutExtension(fileName);
    for (var index = 2; index < 1000; index++) {
      target = p.join(dir, '$base ($index)$extension');
      if (!File(target).existsSync()) return target;
    }
    return p.join(
      dir,
      '${base}_${DateTime.now().microsecondsSinceEpoch}$extension',
    );
  }
}

/// 桌面“另存为”对话框（file_picker）。
///
/// 不传 `type` / `allowedExtensions`：file_picker 13.2.0 起两者被标记为
/// deprecated，且上游明确说明 `saveFile()` 从未使用过它们（原本就不生效）。
Future<String?> _filePickerSaveDialog({
  required String fileName,
  required Uint8List bytes,
  required String mimeType,
  String? initialDirectory,
  String? dialogTitle,
}) async {
  final uri = await FilePicker.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    bytes: bytes,
    mimeType: mimeType,
    initialDirectory: initialDirectory,
  );
  if (uri == null) return null;
  return uri.toFilePath(windows: Platform.isWindows);
}

/// 创建生产实现；[dialog] 仅测试注入，默认桌面启用、移动端关闭。
SaveAs createIoSaveAs({
  required DownloadsPublisher publisher,
  String? Function()? customRoot,
  SaveFileDialog? dialog,
  Future<Directory?> Function()? downloadsDirectory,
  Future<Directory> Function()? documentsDirectory,
  Future<Directory> Function()? temporaryDirectory,
}) {
  final isMobile = Platform.isAndroid || Platform.isIOS;
  return IoSaveAs(
    publisher: publisher,
    customRoot: customRoot,
    dialog: dialog ?? (isMobile ? null : _filePickerSaveDialog),
    downloadsDirectory: downloadsDirectory,
    documentsDirectory: documentsDirectory,
    temporaryDirectory: temporaryDirectory,
  );
}
