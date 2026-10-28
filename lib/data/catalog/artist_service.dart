import '../../domain/models/artist.dart';
import '../cache/request_cache.dart';
import 'cached_page_service.dart';

/// 歌手分页取数函数（组合根注入 `SourceManager.fetchArtist`）。
///
/// 用函数类型而不是直接依赖 `SourceManager`：`ArtistService` 与 sources 层
/// 解耦（单测注入假实现即可），注入点在 main.dart（唯一组合根）。
typedef ArtistFetcher = Future<ArtistDetail> Function(
  String sourceKey,
  String artistId, {
  required int page,
  required int limit,
});

typedef _ArtistQuery = ({String sourceKey, String artistId});

/// 歌手服务：歌手页分页的唯一取数入口（single-flight + LRU + TTL + 错误归一化）。
///
/// 缓存策略收在 [CachedPageService]；本类只负责把类型化参数翻译成缓存
/// key / 前缀。缓存 key 为 `artist:{sourceKey}:{artistId}:{page}:{limit}`
/// （平台 / 歌手 / 页），歌手歌曲变化缓慢，TTL 取 10 分钟，重试时用
/// [invalidateArtist] 清该歌手全部页。
class ArtistService {
  ArtistService({
    required ArtistFetcher fetch,
    RequestCache? cache,
    Duration ttl = const Duration(minutes: 10),
  }) : _pages = CachedPageService<ArtistDetail, _ArtistQuery>(
         fetch: (query, {required page, required limit}) =>
             fetch(query.sourceKey, query.artistId, page: page, limit: limit),
         keyOf: (query, page, limit) => cacheKey(
           query.sourceKey,
           query.artistId,
           page: page,
           limit: limit,
         ),
         // 容量 16（约 4 位歌手 × 4 页）：同专辑服务的内存取舍，退出歌手页
         // 后不把整份分页详情留在常驻进程里。
         maxEntries: 16,
         ttl: ttl,
         cache: cache,
       );

  final CachedPageService<ArtistDetail, _ArtistQuery> _pages;

  /// 取一页歌手详情；同 key 在 TTL 内共享结果，异常归一化为 `SourceFailure`。
  ///
  /// 无歌手能力 / 平台业务失败时由注入的取数函数抛 `SourceFailure`
  /// （边界归一化幂等）。
  Future<ArtistDetail> load(
    String sourceKey,
    String artistId, {
    int page = 1,
    int limit = kArtistPageSize,
  }) => _pages.load(
    (sourceKey: sourceKey, artistId: artistId),
    page: page,
    limit: limit,
  );

  /// 使该歌手的缓存全部失效（重试 / 手动刷新用）。
  void invalidateArtist(String sourceKey, String artistId) =>
      _pages.invalidatePrefix(artistCacheKeyPrefix(sourceKey, artistId));

  /// 清空全部分页缓存（托盘隐藏时由内存守卫调用；页面重建后按需重取）。
  ///
  /// 本服务所有 key 都以 `artist:` 开头，整段前缀即全清；在途条目一并移除，
  /// 结果仍返回原等待方，只是不再写回缓存。
  void clearCache() => _pages.invalidatePrefix('artist:');

  /// 指定歌手当前的缓存条目数（含 in-flight）。
  int countForArtist(String sourceKey, String artistId) =>
      _pages.countPrefix(artistCacheKeyPrefix(sourceKey, artistId));

  /// 缓存 key：`artist:{source}:{id}:{page}:{limit}`。
  static String cacheKey(
    String sourceKey,
    String artistId, {
    required int page,
    int limit = kArtistPageSize,
  }) => '${artistCacheKeyPrefix(sourceKey, artistId)}$page:$limit';

  /// 同一歌手全部缓存的公共前缀。
  static String artistCacheKeyPrefix(String sourceKey, String artistId) =>
      'artist:$sourceKey:$artistId:';
}
