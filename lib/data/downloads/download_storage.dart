import 'download_storage_io.dart' as platform;
import 'download_storage_types.dart';

export 'download_storage_types.dart';

/// 创建当前平台的下载存储实现（`dart:io` + `path_provider`）。
///
/// 下载根目录按平台选择：桌面 = 系统下载目录下 `Molia/`，iOS = 应用文档
/// 目录，Android = 应用支持目录；目录不可解析（无文件系统 / 权限失败）时
/// `downloadsRoot()` 返回 null，UI 据此隐藏下载入口。
///
/// [customRoot] 为设置页选择的保存位置：返回非空时优先使用（每次解析都
/// 重新读取，改设置无需重启）。
DownloadStorage createDownloadStorage({String? Function()? customRoot}) =>
    platform.createDownloadStorage(customRoot: customRoot);
