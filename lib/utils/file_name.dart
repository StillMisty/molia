/// 用户可见文件名清洗的唯一实现（下载 / 导出 / 海报共用）。
library;

import 'package:path/path.dart' as p;

final RegExp _illegalFileNameChars = RegExp(r'[\\/:*?"<>|\x00-\x1F]');
final RegExp _whitespaceRun = RegExp(r'\s+');

/// 去掉路径分隔符 / 平台非法字符，折叠空白并限制长度。
///
/// [preserveExtension] 为 true 时截断优先保留扩展名（导出文件）；
/// [fallback] 是清洗后为空 / `.` / `..` 时的兜底名。
String sanitizeFileName(
  String name, {
  String fallback = 'unknown',
  int maxLength = 120,
  bool preserveExtension = true,
}) {
  final replaced = name
      .replaceAll(_illegalFileNameChars, '_')
      .replaceAll(_whitespaceRun, ' ')
      .trim();
  if (replaced.isEmpty || replaced == '.' || replaced == '..') {
    return fallback;
  }
  if (replaced.length <= maxLength) return replaced;
  if (!preserveExtension) {
    return String.fromCharCodes(replaced.runes.take(maxLength)).trim();
  }
  final extension = p.extension(replaced);
  final base = p.basenameWithoutExtension(replaced);
  final budget = maxLength - extension.length;
  final shortened = budget <= 0
      ? String.fromCharCodes(replaced.runes.take(maxLength)).trim()
      : '${String.fromCharCodes(base.runes.take(budget)).trim()}$extension';
  return shortened.isEmpty ? fallback : shortened;
}
