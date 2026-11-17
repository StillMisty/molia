/// 专辑页取数端口：只声明页面需要的分页读取能力。
///
/// 具体缓存 / TTL / 错误归一化由 data 层实现（`AlbumService`）；providers 与
/// UI 只依赖本端口和领域 [Album]，不感知重试与缓存策略。
library;

import '../models/album.dart';

abstract interface class AlbumRepository {
  /// 取一页专辑；失败时抛领域 `SourceFailure`。
  Future<Album> loadAlbumPage(
    String sourceKey,
    String albumId, {
    int page = 1,
    int limit = kAlbumPageSize,
  });
}
