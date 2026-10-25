import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:logging/logging.dart';

final _logger = Logger('molia.json_backup_picker');

/// 选择并读取一份 JSON 备份文件；取消 / 读取失败返回 null。
///
/// 导入只消费文本（解析与合并由同步引擎负责），文件选择的平台差异集中在
/// 这里，调用方不必依赖 `dart:io` 之外的文件选择实现。
Future<String?> pickJsonBackupText() async {
  try {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = files.isEmpty ? null : files.first.path;
    if (path == null) return null;
    return await File(path).readAsString();
  } catch (e) {
    _logger.fine('读取 JSON 备份失败: $e');
    return null;
  }
}
