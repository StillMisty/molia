/// 另存服务（Save As）的公共类型。
///
/// “另存目录”是应用对用户可见的输出根：桌面 = 系统公共下载目录下的
/// `Molia/`，Android = 系统「下载」下的 `Molia/`（MediaStore），iOS =
/// 文件 App 可见的应用文档目录 `Molia/`。下载与导出共用这一口径。
library;

import 'dart:typed_data';

/// 导出类 JSON 子目录（备份 / 听歌统计）。
const String saveAsExportsDirName = 'exports';

/// 海报 PNG 子目录。
const String saveAsPostersDirName = 'posters';

/// 保存结果的位置类型：决定 UI 用哪条文案展示。
enum SaveLocationKind {
  /// 桌面：可读绝对路径。
  fileSystem,

  /// Android：系统「下载」下的相对路径（`Download/Molia/...`）。
  downloads,

  /// iOS：文件 App 里的相对路径（`Molia/...`）。
  filesApp,
}

/// 另存结果。
sealed class SaveAsResult {
  const SaveAsResult();
}

/// 已保存（[path] 为绝对路径或 Android content URI）。
final class SaveAsSaved extends SaveAsResult {
  const SaveAsSaved({
    required this.path,
    required this.displayPath,
    required this.kind,
  });

  final String path;

  /// 给用户看的路径（按 [kind] 加平台前缀后展示）。
  final String displayPath;

  final SaveLocationKind kind;
}

/// 用户取消（保留系统对话框 / 选择器的取消语义，不提示失败）。
final class SaveAsCancelled extends SaveAsResult {
  const SaveAsCancelled();
}

/// 保存失败（[error] 只进日志，不直接展示给用户）。
final class SaveAsFailed extends SaveAsResult {
  const SaveAsFailed([this.error]);

  final Object? error;
}

/// 桌面“另存为”对话框：返回选中路径；取消返回 null；平台不可用抛异常
/// （调用方回退直接写入另存目录）。
typedef SaveFileDialog = Future<String?> Function({
  required String fileName,
  required Uint8List bytes,
  required String mimeType,
  String? initialDirectory,
  String? dialogTitle,
  List<String>? allowedExtensions,
});

/// 另存服务：桌面弹“另存为”（默认目录 = 另存目录），Android / iOS 直接写
/// 平台对应的公共输出位置。
abstract interface class SaveAs {
  /// 另存目录（展示用）；不可用返回 null。
  ///
  /// Android 返回 `.../Download/Molia`，iOS 返回应用文档目录下的
  /// `Molia/`，桌面返回解析出的绝对路径。
  Future<String?> rootPath();

  /// 把 [bytes] 写到另存目录的 [relativeDir] 子目录。
  ///
  /// [fileName] 只是默认文件名（桌面对话框可改编）；[dialogTitle] /
  /// [allowedExtensions] 仅桌面对话框使用。
  Future<SaveAsResult> saveBytes({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String relativeDir = '',
    String? dialogTitle,
    List<String>? allowedExtensions,
  });

  /// 把一个已有文件复制 / 发布到另存目录（音频导出用）。
  Future<SaveAsResult> saveFile({
    required String sourcePath,
    required String fileName,
    required String mimeType,
    String relativeDir = '',
  });

  /// 在系统文件管理器中显示 [path]；不支持 / 失败返回 false。
  Future<bool> reveal(String path);
}
