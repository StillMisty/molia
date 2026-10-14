import 'download_storage_stub.dart'
    if (dart.library.io) 'download_storage_io.dart' as platform;
import 'download_storage_types.dart';

export 'download_storage_types.dart';

/// 创建当前平台的下载存储实现。
///
/// Web：空实现（无持久文件系统，`downloadsRoot()` 为 null）；
/// IO（Android/iOS/桌面）：平台默认下载根目录（桌面 = 系统下载目录下
/// `Molia/`，iOS = 应用文档目录，Android = 应用支持目录）。
///
/// [customRoot] 为设置页选择的保存位置：返回非空时优先使用（每次解析都
/// 重新读取，改设置无需重启）。
DownloadStorage createDownloadStorage({String? Function()? customRoot}) =>
    platform.createDownloadStorage(customRoot: customRoot);
