/// 本地封面文件 → 系统媒体会话可用的地址（条件导出，Web 构建安全）。
///
/// Windows 的 `flutter_media_session` WinRT 实现只在「不带 scheme 且文件存在」
/// 时走 `StorageFile` 分支；其余平台（Android / iOS / macOS / Linux）需要
/// `file://` URI。转换规则只保留这一份实现。
library;

export 'media_artwork_uri_stub.dart'
    if (dart.library.io) 'media_artwork_uri_io.dart';
