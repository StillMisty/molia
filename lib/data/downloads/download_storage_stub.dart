import 'dart:typed_data';

import 'download_storage_types.dart';

/// Web / 不支持平台的内存空实现：无持久文件系统，下载能力整体关闭。
///
/// `downloadsRoot()` 返回 null，下载服务据此抛可读的 unsupported 失败，
/// UI 隐藏下载入口；其余方法保持安全的空语义（存在性 false / 大小 0）。
class MemoryDownloadStorage implements DownloadStorage {
  @override
  Future<String?> downloadsRoot() async => null;

  @override
  Future<bool> fileExists(String path) async => false;

  @override
  Future<int> fileSize(String path) async => 0;

  @override
  Future<void> copyFile(String from, String to) async {}

  @override
  Future<Uint8List?> readBytes(String path) async => null;

  @override
  Future<void> writeStream(
    String path,
    Stream<List<int>> stream, {
    int? total,
    void Function(int received, int? total)? onProgress,
  }) async {
    // 消费流避免调用方悬挂（结果直接丢弃）。
    await stream.drain<void>();
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {}

  @override
  Future<void> writeString(String path, String content) async {}

  @override
  Future<String?> readString(String path) async => null;

  @override
  Future<void> rename(String from, String to) async {}

  @override
  Future<void> deleteQuietly(String path) async {}
}

/// 工厂：`download_storage.dart` 的条件导入入口。
DownloadStorage createDownloadStorage() => MemoryDownloadStorage();
