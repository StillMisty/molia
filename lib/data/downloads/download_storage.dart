import 'download_storage_io.dart' as platform;
import 'download_storage_types.dart';

export 'download_storage_types.dart';

/// 创建当前平台的下载存储实现（`dart:io` + `path_provider`）。
///
/// 下载根目录按平台选择：桌面 = 系统公共下载目录下 `Molia/`（Windows Known
/// Folder / Linux XDG），iOS = 应用文档目录，Android = 应用支持目录；目录不可
/// 解析（无文件系统 / 权限失败）时 `downloadsRoot()` 返回 null，UI 据此隐藏
/// 下载入口。
///
/// [customRoot] 为设置页选择的保存位置：返回非空时优先使用（每次解析都
/// 重新读取，改设置无需重启）。
DownloadStorage createDownloadStorage({String? Function()? customRoot}) =>
    platform.createDownloadStorage(customRoot: customRoot);
