import 'download_notifications_types.dart';

/// Web / 不支持平台：无系统通知可发，整体空实现。
DownloadNotifications createDownloadNotifications() =>
    const NoopDownloadNotifications();
