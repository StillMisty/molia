import 'downloads_publisher_types.dart';

/// Web / 不支持平台：无公共目录可发布，整体空实现。
DownloadsPublisher createDownloadsPublisher() => const NoopDownloadsPublisher();
