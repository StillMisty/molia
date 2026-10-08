/// 封面缓存 FileSystem 平台实现选择（IO：持久目录；Web：内存默认实现）。
library;

export 'artwork_cache_fs_stub.dart'
    if (dart.library.io) 'artwork_cache_fs_io.dart';
