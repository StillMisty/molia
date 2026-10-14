/// 公共下载目录发布器的公共类型。
///
/// 独立成文件，避免工厂（`downloads_publisher.dart`）与平台实现
/// （`downloads_publisher_io.dart` / `downloads_publisher_stub.dart`）
/// 循环依赖，同时保证 Web 编译不引入 `dart:io` / MethodChannel。
library;

/// 公共 Downloads 发布器（Android MediaStore）。
///
/// **公共副本是发布副本，不是播放源**：应用目录里的下载文件仍是唯一播放
/// 取链目标（`DownloadService.localUriFor`），公共目录里的拷贝只让用户在
/// 文件管理器 / 其它播放器里能直接看到、导出歌；删除下载时经本端口一并
/// 删除公共副本，避免残留。
///
/// 失败一律 best-effort：返回 null / false 由调用方只记日志，不影响下载。
abstract interface class DownloadsPublisher {
  /// 当前平台是否支持发布公共副本（仅 Android；Web / 桌面 / iOS 为 false）。
  ///
  /// 桌面 / iOS 的下载根目录本身就是公共目录（系统下载目录 / 应用文档
  /// 目录），不需要二次发布；Web 无持久文件系统。
  bool get supported;

  /// 把 [sourcePath]（应用私有文件）发布为公共 Downloads 里的 [displayName]。
  ///
  /// 成功返回 content URI（存进下载记录，供删除时回收），
  /// 不支持 / 失败返回 null。
  Future<String?> publish({
    required String sourcePath,
    required String displayName,
    required String mimeType,
  });

  /// 删除公共副本（幂等：行已不存在也算成功）；失败返回 false。
  Future<bool> remove(String uri);
}

/// 空实现：Web / 桌面 / iOS / 单测（发布能力整体关闭）。
class NoopDownloadsPublisher implements DownloadsPublisher {
  const NoopDownloadsPublisher();

  @override
  bool get supported => false;

  @override
  Future<String?> publish({
    required String sourcePath,
    required String displayName,
    required String mimeType,
  }) async =>
      null;

  @override
  Future<bool> remove(String uri) async => false;
}
