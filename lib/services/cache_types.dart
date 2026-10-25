/// 统一缓存子系统的公共类型（分区 / 用量 / 存储抽象）。
///
/// 独立成文件，避免 `CacheService` 与 `dart:io` 存储实现
/// （`cache_storage_io.dart`）之间形成循环依赖，`dart:io` 也不会泄漏到
/// 策略层。
library;

/// 缓存分区：音频 / 歌词 / 封面。
enum CachePartition {
  /// 音频边播边缓存（持久目录，LRU 按文件 mtime 淘汰）。
  audio,

  /// 歌词缓存（生产组合根启用文件后端：单条 JSON 文件；默认实例仍走
  /// prefs；TTL 从策略读取）。
  lyrics,

  /// 封面缓存（flutter_cache_manager 持久文件 + 策略 sweep）。
  artwork,
}

/// 音频缓存半成品：just_audio `LockCachingAudioSource` 边下载边写 `*.part`，
/// 整个文件落盘后才原子改名成正式缓存名（同 `downloadPartSuffix` 约定）。
const String audioCachePartSuffix = '.part';

/// 字节预取半成品后缀（见 `audio_predownload_io.dart`）：与 just_audio 的
/// [audioCachePartSuffix] 分开，避免两边清理互相误删正在写的文件。
const String audioCachePredownloadSuffix = '.predl';

/// MIME 边车后缀：just_audio 记录原始 Content-Type（`*.mime`），不是音频数据。
const String audioCacheMimeSuffix = '.mime';

/// 分区用量：字节数 + 条目数。
class CacheUsage {
  const CacheUsage({required this.bytes, required this.count});

  /// 占用字节数（歌词为 JSON 文件字节数；prefs 后端按 UTF-8 计）。
  final int bytes;

  /// 条目数（音频/封面为文件数；歌词为当前后端的条目数）。
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

/// 按前缀删除的结果：实际删除的用量 + 因“正在写入”被跳过的文件数。
///
/// 单曲清理（见 `CacheService.clearAudioForTrack`）用 [skipped] 区分
/// 「本来就没缓存」与「正在边播边缓存、暂时不能删」两种空结果。
class CacheDeleteResult {
  const CacheDeleteResult({
    this.deleted = CacheUsage.zero,
    this.skipped = 0,
  });

  final CacheUsage deleted;
  final int skipped;

  @override
  bool operator ==(Object other) =>
      other is CacheDeleteResult &&
      other.deleted == deleted &&
      other.skipped == skipped;

  @override
  int get hashCode => Object.hash(deleted, skipped);

  @override
  String toString() => 'CacheDeleteResult($deleted, skipped: $skipped)';
}

/// 分区存储抽象：策略/统计逻辑（[CacheService]）与平台文件操作解耦。
///
/// IO 实现走 `path_provider` + `dart:io`（`cache_storage_io.dart`）；
/// 目录解析失败时各方法返回 null / 空结果，调用方按「不可用」处理。
abstract class CacheStorage {
  /// 音频持久缓存目录；平台不可用时返回 null。
  Future<String?> audioCacheDir();

  /// 封面持久缓存目录；平台不可用时返回 null。
  Future<String?> artworkCacheDir();

  /// 设备存储总容量（字节）；平台不支持或查询失败时返回 null。
  ///
  /// 默认音频缓存上限的输入（设备容量 ÷ 128，见 `CacheService`）；
  /// 只读一次即可，容量在同一台设备上不会频繁变化。
  Future<int?> totalSpaceBytes();

  /// 统计目录占用；目录不存在时返回 [CacheUsage.zero]。
  Future<CacheUsage> usage(String dirPath);

  /// 列举目录内的缓存文件（文件名 → 字节数）；目录不存在 / 不可读时返回空表。
  ///
  /// 一次目录枚举供「缓存曲目」列表按前缀匹配与状态探测复用（避免逐曲探测）。
  Future<Map<String, int>> listFiles(String dirPath);

  /// 删除目录内文件名满足 [test] 的文件，返回删除数量。
  ///
  /// 只用于「按文件名特征清扫」（如启动时清理中断残留的半成品）；
  /// 按前缀删除走 [deleteMatching]。
  Future<int> deleteWhere(
    String dirPath, {
    required bool Function(String fileName) test,
  });

  /// 删除目录内文件名以 [prefix] 开头的文件，返回删除与跳过的数量。
  ///
  /// [protectAge] 内修改过的文件视为“正在写入”跳过（同
  /// [enforceAudioLimit] 的语义：`LockCachingAudioSource` 边下载边写，
  /// 删活动文件会破坏本次播放/写入）。
  Future<CacheDeleteResult> deleteMatching(
    String dirPath, {
    required String prefix,
    Duration protectAge = Duration.zero,
  });

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
