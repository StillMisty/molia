import 'download_notifications_stub.dart'
    if (dart.library.io) 'download_notifications_io.dart' as platform;
import 'download_notifications_types.dart';

export 'download_notifications_types.dart';

/// 创建当前平台的下载通知端口。
///
/// - **Android**：前台服务（dataSync）+ 系统进度通知，后台也能继续下载；
/// - **桌面 / iOS / Web**：没有同构的系统通知语义（桌面下载都在前台完成），
///   空实现；
/// - 通道缺失 / 原生失败一律 no-op 只记日志，**不影响下载本身**。
DownloadNotifications createDownloadNotifications() =>
    platform.createDownloadNotifications();
