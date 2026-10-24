/// 公共下载目录发布器的公共类型。
///
/// 独立成文件：工厂（`downloads_publisher.dart`）与实现
/// （`downloads_publisher_io.dart`）各自只依赖本文件的类型，
/// `dart:io` / MethodChannel 不会泄漏给调用方。
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
  /// 当前平台是否支持发布公共副本（仅 Android；桌面 / iOS 为 false）。
  ///
  /// 桌面 / iOS 的下载根目录本身就是公共目录（系统下载目录 / 应用文档
  /// 目录），不需要二次发布。
  bool get supported;

  /// 公共 Downloads 的展示根（Android：`.../Download/Molia`；其余平台 null）。
  ///
  /// 只用于设置页 / 保存结果展示；Dart 侧不拿它直接写文件（分区存储下
  /// 必须经 MediaStore）。
  Future<String?> publicRoot();

  /// 把 [sourcePath]（应用私有文件）发布为公共 Downloads 里的 [displayName]。
  ///
  /// [relativeDir] 是 `Molia/` 下的可选子目录（如 `exports` / `posters`），
  /// 空串 = 直接放在 `Molia/` 根下。成功返回 content URI（存进下载记录，
  /// 供删除时回收）；不支持 / 失败返回 null。
  Future<String?> publish({
    required String sourcePath,
    required String displayName,
    required String mimeType,
    String relativeDir = '',
  });

  /// 删除公共副本（幂等：行已不存在也算成功）；失败返回 false。
  Future<bool> remove(String uri);
}

/// 空实现：桌面 / iOS / 单测（发布能力整体关闭）。
class NoopDownloadsPublisher implements DownloadsPublisher {
  const NoopDownloadsPublisher();

  @override
  bool get supported => false;

  @override
  Future<String?> publicRoot() async => null;

  @override
  Future<String?> publish({
    required String sourcePath,
    required String displayName,
    required String mimeType,
    String relativeDir = '',
  }) async =>
      null;

  @override
  Future<bool> remove(String uri) async => false;
}
