/// 更新产物下载器入口（按平台条件导入）。
///
/// 原生端实现见 `update_downloader_io.dart`（`dart:io` 只允许出现在条件
/// 导入的实现文件里，否则 Web 构建会被 `dart:io` 打断）；Web 端不支持
/// 应用内下载，stub 直接抛错。
library;

export 'update_downloader_stub.dart'
    if (dart.library.io) 'update_downloader_io.dart';
