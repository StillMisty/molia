/// 歌手页取数端口：只声明页面需要的分页读取能力。
///
/// 具体缓存 / TTL / 错误归一化由 data 层实现（`ArtistService`）；providers 与
/// UI 只依赖本端口和领域 [ArtistDetail]，不感知重试与缓存策略。
library;

import '../models/artist.dart';

abstract interface class ArtistRepository {
  /// 取一页歌手详情；失败时抛领域 `SourceFailure`。
  Future<ArtistDetail> loadArtistPage(
    String sourceKey,
    String artistId, {
    int page = 1,
    int limit = kArtistPageSize,
  });
}
