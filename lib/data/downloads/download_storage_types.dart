/// 下载存储的公共类型与目录约定。
///
/// 独立成文件：工厂（`download_storage.dart`）与 `dart:io` 实现
/// （`download_storage_io.dart`）各自只依赖本文件的类型，`dart:io` 不会
/// 泄漏给调用方。
library;

import 'dart:typed_data';

/// 下载根目录名（应用支持目录下，与 `cache/audio_cache` 完全隔离）。
const String downloadsDirName = 'downloads';

/// 公共下载目录下的应用子目录名（桌面 / iOS：`<系统下载目录>/Molia`）。
const String publicDownloadsDirName = 'Molia';

/// 歌词子目录（长期存储，不走 `LyricsCache` 的 TTL 语义）。
const String downloadsLyricsDirName = 'lyrics';

/// 封面子目录。
const String downloadsCoversDirName = 'covers';

/// 下载中的半成品文件后缀（完成后原子改名为最终文件名）。
const String downloadPartSuffix = '.part';

/// 下载文件存储抽象：下载服务与平台文件操作解耦。
///
/// 实现（`IoDownloadStorage`）走 `path_provider` + `dart:io`；
/// 目录不可解析（无文件系统 / 权限失败）时 `downloadsRoot()` 返回 null，
/// UI 据此隐藏下载入口。
abstract interface class DownloadStorage {
  /// 下载根目录绝对路径；目录不可用（无文件系统 / 解析失败）时返回 null。
  Future<String?> downloadsRoot();

  /// 旧版下载根目录（应用支持目录 `downloads/`）：供「迁移旧位置的下载」
  /// 使用；与 [downloadsRoot] 相同或不存在时返回 null。
  Future<String?> legacyDownloadsRoot();

  /// 文件是否存在。
  Future<bool> fileExists(String path);

  /// 文件大小（字节）；不存在 / 不可读返回 0。
  Future<int> fileSize(String path);

  /// 复制文件（缓存 → 下载目录的命中拷贝；父目录自动创建）。
  Future<void> copyFile(String from, String to);

  /// 递归列出目录下的文件绝对路径（维护页清扫用）；目录不存在返回空。
  Future<List<String>> listFiles(String dirPath);

  /// 读取文件字节；不存在 / 不可读返回 null。
  Future<Uint8List?> readBytes(String path);

  /// 读取文件开头 [length] 字节（本地导入解析标签只读头部，不整文件读入）；
  /// 文件短于 [length] 时返回全部；不存在 / 不可读返回 null。
  Future<Uint8List?> readHead(String path, int length);

  /// 流式写入文件（父目录自动创建）。
  ///
  /// [total] 为预期总字节（响应头 Content-Length，未知时 null）；
  /// [onProgress] 在每个分片写入后回调（received 为累计字节）。
  /// 流异常 / 取消时向上抛出，调用方负责清理半成品。
  Future<void> writeStream(
    String path,
    Stream<List<int>> stream, {
    int? total,
    void Function(int received, int? total)? onProgress,
  });

  /// 写入字节（歌词 / 封面小文件）。
  Future<void> writeBytes(String path, List<int> bytes);

  /// 写入 UTF-8 文本。
  Future<void> writeString(String path, String content);

  /// 读取 UTF-8 文本；文件不存在 / 不可读返回 null。
  Future<String?> readString(String path);

  /// 同目录内原子改名（半成品 → 最终文件）。
  Future<void> rename(String from, String to);

  /// 删除文件；失败静默（清理路径不应抛错）。
  Future<void> deleteQuietly(String path);
}
