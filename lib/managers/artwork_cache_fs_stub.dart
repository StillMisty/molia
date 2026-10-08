// ignore: depend_on_referenced_packages
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show CacheInfoRepository, FileSystem, MemoryCacheSystem, NonStoringObjectProvider;

/// Web：无持久文件系统，使用 flutter_cache_manager 的内存实现。
FileSystem createArtworkFileSystem(String cacheKey, String? directoryPath) =>
    MemoryCacheSystem();

/// Web：无持久元数据，使用非存储实现（与 Config 默认一致）。
CacheInfoRepository createArtworkRepository(String cacheKey) =>
    NonStoringObjectProvider();
