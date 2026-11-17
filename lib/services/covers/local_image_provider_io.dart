import 'dart:io';

import 'package:flutter/widgets.dart' show FileImage, ImageProvider;

/// `file://` URI → `FileImage`；非 file URI / 路径无法解析时返回 null。
ImageProvider? localFileImageProvider(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'file') return null;
  try {
    final path = uri.toFilePath();
    if (path.isEmpty) return null;
    return FileImage(File(path));
  } catch (_) {
    return null;
  }
}
