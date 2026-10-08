import 'cache_types.dart';

/// Web 平台缓存存储：无持久文件系统。
///
/// 音频分区在 Web 本就不启用（`LockCachingAudioSource` 依赖文件系统），
/// 封面缓存由 flutter_cache_manager 的 `MemoryCacheSystem` 承载（随页面
/// 生命周期）。这里统一返回空结果，保证 `CacheService` 在 Web 可用。
class MemoryCacheStorage implements CacheStorage {
  @override
  Future<String?> audioCacheDir() async => null;

  @override
  Future<String?> artworkCacheDir() async => null;

  @override
  Future<CacheUsage> usage(String dirPath) async => CacheUsage.zero;

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

/// 工厂：`cache_storage.dart` 的条件导入入口。
CacheStorage createCacheStorage() => MemoryCacheStorage();
