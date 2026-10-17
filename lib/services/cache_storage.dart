import 'cache_types.dart';
import 'cache_storage_io.dart' as platform;

export 'cache_types.dart';

/// 创建当前平台的缓存存储实现。
///
/// 目录取 `path_provider` 应用支持目录下的持久目录
/// （`<appSupport>/audio_cache` / `artwork_cache`）；目录不可用时各方法
/// 返回 null / 空结果，UI 按「不可用」展示。
CacheStorage createPlatformCacheStorage() => platform.createCacheStorage();
