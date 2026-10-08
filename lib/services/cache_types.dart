/// 统一缓存子系统的公共类型（分区 / 用量 / 存储抽象）。
///
/// 独立成文件，避免 `CacheService` 与平台存储实现（`cache_storage_io.dart`
/// / `cache_storage_stub.dart`）之间形成循环依赖；同时保证 Web 编译时
/// 不引入 `dart:io`。
library;

/// 缓存分区：音频 / 歌词 / 封面。
enum CachePartition {
  /// 音频边播边缓存（持久目录，LRU 按文件 mtime 淘汰）。
  audio,

  /// 歌词缓存（SharedPreferences JSON，TTL 从策略读取）。
  lyrics,

  /// 封面缓存（flutter_cache_manager 持久文件 + 策略 sweep）。
  artwork,
}

/// 分区用量：字节数 + 条目数。
class CacheUsage {
  const CacheUsage({required this.bytes, required this.count});

  /// 占用字节数（歌词为 JSON 文本 UTF-8 字节数）。
  final int bytes;

  /// 条目数（音频/封面为文件数，歌词为缓存键数）。
  final int count;

  static const CacheUsage zero = CacheUsage(bytes: 0, count: 0);

  CacheUsage operator +(CacheUsage other) =>
      CacheUsage(bytes: bytes + other.bytes, count: count + other.count);

  @override
  bool operator ==(Object other) =>
      other is CacheUsage && other.bytes == bytes && other.count == count;

  @override
  int get hashCode => Object.hash(bytes, count);

  @override
  String toString() => 'CacheUsage(bytes: $bytes, count: $count)';
}

/// 分区存储抽象：策略/统计逻辑（[CacheService]）与平台文件操作解耦。
///
/// IO 实现走 `path_provider` + `dart:io`（[IoCacheStorage]）；Web 无持久
/// 文件系统，使用空实现（[MemoryCacheStorage]）。
abstract class CacheStorage {
  /// 音频持久缓存目录；平台不可用时返回 null。
  Future<String?> audioCacheDir();

  /// 封面持久缓存目录；平台不可用时返回 null。
  Future<String?> artworkCacheDir();

  /// 统计目录占用；目录不存在时返回 [CacheUsage.zero]。
  Future<CacheUsage> usage(String dirPath);

  /// 删除目录内所有缓存文件（保留目录本身）。
  Future<void> clear(String dirPath);

  /// 音频 LRU 淘汰：按文件 mtime 从旧到新删除，直到总量 <= [maxBytes]。
  ///
  /// [maxBytes] <= 0 表示不限制；[protectAge] 内修改过的文件视为“正在写入”
  /// 跳过（`LockCachingAudioSource` 边下载边写，不能删活动文件）。
  /// 返回删除的文件数。
  Future<int> enforceAudioLimit(
    String dirPath, {
    required int maxBytes,
    required Duration protectAge,
  });

  /// 封面策略 sweep：先删 mtime 超过 [staleDays] 的文件，再按 mtime LRU
  /// 删到 [maxObjects] 以内。0 表示对应维度不限制。返回删除的文件数。
  Future<int> sweepArtwork(
    String dirPath, {
    required int maxObjects,
    required int staleDays,
  });
}
