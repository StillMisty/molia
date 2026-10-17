import 'package:molia/services/cache_types.dart';

/// 内存缓存存储：模拟「没有可写文件系统」的平台环境（文件系统不可用 / 权限缺失）。
///
/// 音频分区在无文件系统时不启用，封面缓存由 flutter_cache_manager 的
/// `MemoryCacheSystem` 承载（随页面生命周期）。这里统一返回空结果，
/// 供 `CacheService` 一族的降级路径单测使用。
class MemoryCacheStorage implements CacheStorage {
  @override
  Future<String?> audioCacheDir() async => null;

  @override
  Future<String?> artworkCacheDir() async => null;

  @override
  Future<int?> totalSpaceBytes() async => null;

  @override
  Future<CacheUsage> usage(String dirPath) async => CacheUsage.zero;

  @override
  Future<Map<String, int>> listFiles(String dirPath) async => const {};

  @override
  Future<int> deleteWhere(
    String dirPath, {
    required bool Function(String fileName) test,
  }) async =>
      0;

  @override
  Future<CacheDeleteResult> deleteMatching(
    String dirPath, {
    required String prefix,
    Duration protectAge = Duration.zero,
  }) async =>
      const CacheDeleteResult();

  @override
  Future<void> clear(String dirPath) async {}

  @override
  Future<int> enforceAudioLimit(
    String dirPath, {
    required int maxBytes,
    required Duration protectAge,
  }) async =>
      0;

  @override
  Future<int> sweepArtwork(
    String dirPath, {
    required int maxObjects,
    required int staleDays,
  }) async =>
      0;
}
