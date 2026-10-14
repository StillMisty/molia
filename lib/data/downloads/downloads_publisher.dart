import 'downloads_publisher_stub.dart'
    if (dart.library.io) 'downloads_publisher_io.dart' as platform;
import 'downloads_publisher_types.dart';

export 'downloads_publisher_types.dart';

/// 创建当前平台的公共下载目录发布器。
///
/// - **Android**：MediaStore Downloads 集合（平台通道；发布副本，播放取链
///   仍只认应用目录里的文件）；
/// - **桌面 / iOS**：下载根目录本身就是公共目录（系统下载目录下 `Molia/` /
///   应用文档目录），不需要二次发布；
/// - **Web**：无持久文件系统，空实现。
DownloadsPublisher createDownloadsPublisher() =>
    platform.createDownloadsPublisher();
