import 'package:flutter/foundation.dart';

/// 本地封面路径 → 媒体会话地址。
///
/// - Windows：裸路径（WinRT `StorageFile.GetFileFromPathAsync` 分支）；
/// - Android / iOS / macOS / Linux：`file://` URI。
String? mediaArtworkUriForPath(String path) {
  if (path.isEmpty) return null;
  if (defaultTargetPlatform == TargetPlatform.windows) return path;
  return Uri.file(path).toString();
}
