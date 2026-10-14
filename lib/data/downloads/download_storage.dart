import 'download_storage_stub.dart'
    if (dart.library.io) 'download_storage_io.dart' as platform;
import 'download_storage_types.dart';

export 'download_storage_types.dart';

/// 创建当前平台的下载存储实现。
///
/// Web：空实现（无持久文件系统，`downloadsRoot()` 为 null）；
/// IO（Android/iOS/桌面）：`path_provider` 应用支持目录下的 `downloads/`。
DownloadStorage createDownloadStorage() => platform.createDownloadStorage();
