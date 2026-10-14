import 'dart:io';

/// IO 平台（Android/iOS/桌面）文件存在性探测。
Future<bool> localFileExists(String path) async {
  try {
    return await File(path).exists();
  } catch (_) {
    return false;
  }
}
