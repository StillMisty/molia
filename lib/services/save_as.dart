import 'dart:io';

import '../data/downloads/downloads_publisher.dart';
import 'save_as_io.dart';
import 'save_as_types.dart';

export 'save_as_types.dart';

/// 创建另存服务：桌面弹“另存为”，Android 走 MediaStore，iOS 写应用文档目录。
///
/// [customRoot] 为设置页选择的保存位置（桌面）；Android / iOS 忽略。
/// [dialog] / 文件系统函数仅测试注入。
SaveAs createSaveAs({
  String? Function()? customRoot,
  SaveFileDialog? dialog,
  Future<Directory?> Function()? downloadsDirectory,
  Future<Directory> Function()? documentsDirectory,
  Future<Directory> Function()? temporaryDirectory,
}) =>
    createIoSaveAs(
      publisher: createDownloadsPublisher(),
      customRoot: customRoot,
      dialog: dialog,
      downloadsDirectory: downloadsDirectory,
      documentsDirectory: documentsDirectory,
      temporaryDirectory: temporaryDirectory,
    );
