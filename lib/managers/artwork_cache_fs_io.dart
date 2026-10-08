import 'dart:io' show Platform;

// flutter_cache_manager 依赖 file 包；这里直接用其接口类型实现持久
// FileSystem（官方 IOFileSystem 固定使用临时目录，无法注入目录）。
// ignore: depend_on_referenced_packages
import 'package:file/file.dart' as pf;
// ignore: depend_on_referenced_packages
import 'package:file/local.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show
        CacheInfoRepository,
        CacheObjectProvider,
        FileSystem,
        IOFileSystem,
        JsonCacheInfoRepository;

/// 持久封面 FileSystem：所有缓存文件落在 [directoryPath]（应用支持目录）。
///
/// flutter_cache_manager 只要求实现 `createFile(name)`；文件名为
/// `{uuid}.{ext}` 的相对路径，因此目录需预先创建。
class PersistentArtworkFileSystem implements FileSystem {
  PersistentArtworkFileSystem(this.directoryPath);

  final String directoryPath;

  static const LocalFileSystem _local = LocalFileSystem();
  Future<pf.Directory>? _directory;

  Future<pf.Directory> _ensureDirectory() {
    return _directory ??= () async {
      final dir = _local.directory(directoryPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }();
  }

  @override
  Future<pf.File> createFile(String name) async =>
      (await _ensureDirectory()).childFile(name);
}

/// 创建封面缓存 FileSystem；[directoryPath] 为空（目录解析失败）时回退到
/// flutter_cache_manager 默认的临时目录实现（IOFileSystem）。
FileSystem createArtworkFileSystem(String cacheKey, String? directoryPath) {
  if (directoryPath == null || directoryPath.isEmpty) {
    return IOFileSystem(cacheKey);
  }
  try {
    return PersistentArtworkFileSystem(directoryPath);
  } catch (_) {
    return IOFileSystem(cacheKey);
  }
}

/// 创建与 flutter_cache_manager `Config` 默认行为一致的元数据库：
/// Android/iOS/macOS 用 sqflite（CacheObjectProvider），其余 IO 平台用
/// JSON 文件（JsonCacheInfoRepository）。
CacheInfoRepository createArtworkRepository(String cacheKey) {
  if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
    return CacheObjectProvider(databaseName: cacheKey);
  }
  return JsonCacheInfoRepository(databaseName: cacheKey);
}
