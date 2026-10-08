import 'cache_types.dart';
import 'cache_storage_stub.dart'
    if (dart.library.io) 'cache_storage_io.dart' as platform;

export 'cache_types.dart';

/// 创建当前平台的缓存存储实现。
///
/// Web：空实现（音频/封面分区返回 null，usage 恒为 0）；
/// IO（Android/iOS/桌面）：`path_provider` 应用支持目录下的持久目录。
CacheStorage createPlatformCacheStorage() => platform.createCacheStorage();
