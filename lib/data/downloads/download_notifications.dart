import 'download_notifications_io.dart' as platform;
import 'download_notifications_types.dart';

export 'download_notifications_types.dart';

/// 创建当前平台的下载类通知端口（歌曲下载 / 应用更新）。
///
/// - **Android**：前台服务（dataSync）+ 系统进度通知，后台也能继续下载；
/// - **桌面 / iOS**：没有同构的系统通知语义（下载与更新都在前台完成），
///   空实现；
/// - 通道缺失 / 原生失败一律 no-op 只记日志，**不影响下载与更新本身**。
DownloadNotifications createDownloadNotifications() =>
    platform.createDownloadNotifications();
