import 'downloads_publisher_io.dart' as platform;
import 'downloads_publisher_types.dart';

export 'downloads_publisher_types.dart';

/// 创建当前平台的公共下载目录发布器。
///
/// - **Android**：MediaStore Downloads 集合（平台通道；发布副本，播放取链
///   仍只认应用目录里的文件）；
/// - **桌面 / iOS**：下载根目录本身就是公共目录（系统下载目录下 `Molia/` /
///   应用文档目录），`supported` 为 false，发布与删除都是 no-op。
DownloadsPublisher createDownloadsPublisher() =>
    platform.createDownloadsPublisher();
