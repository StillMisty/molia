/// 下载文件维护面：目录展示 / 半成品清扫 / 孤儿回收 / 公共副本补发布。
///
/// 为什么与 [DownloadManager] 分开：这些动作只碰下载根目录与已落库记录，
/// 不参与下载队列、取链或取消；管理页之外没有消费方。把它拆成独立端口，
/// 页面测试只需要一个维护小假件，命令面也不必为维护动作扩容。
library;

/// 下载文件维护命令（由 `DownloadService` 实现）。
abstract interface class DownloadMaintenance {
  /// 当前解析出的下载根目录（不可用返回 null）。
  Future<String?> rootPath();

  /// 把已有音频补发布到公共 Downloads，返回 `(发布数, 失败数)`。
  Future<(int, int)> publishMissingPublicCopies();

  /// 清扫崩溃遗留的半成品（`*.part`），返回删除数量。
  Future<int> cleanupIncompleteDownloads();

  /// 无记录引用的孤儿文件（绝对路径）。
  Future<List<String>> orphanFiles();

  /// 删除孤儿文件，返回实际删除数量。
  Future<int> deleteOrphanFiles({Iterable<String>? paths});
}
