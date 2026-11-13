/// 海报分享临时文件：写入系统临时目录，用完即删（best-effort）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// 把 PNG 字节写成临时文件，执行 [action]，无论成败都删除临时文件。
Future<T> withTemporaryPosterPng<T>(
  Uint8List bytes,
  Future<T> Function(File file) action, {
  Directory? directory,
}) async {
  final dir = directory ?? Directory.systemTemp;
  final file = File(
    p.join(
      dir.path,
      'molia_poster_${DateTime.now().microsecondsSinceEpoch}.png',
    ),
  );
  try {
    await file.writeAsBytes(bytes, flush: true);
    return await action(file);
  } finally {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 分享已经完成 / 失败：残留临时文件不覆盖原始结果。
    }
  }
}
