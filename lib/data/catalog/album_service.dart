import '../../domain/models/album.dart';
import '../cache/request_cache.dart';
import 'cached_page_service.dart';

/// 专辑分页取数函数（组合根注入 `SourceManager.fetchAlbum`）。
///
/// 用函数类型而不是直接依赖 `SourceManager`：`AlbumService` 与 sources 层
/// 解耦（单测注入假实现即可），注入点在 main.dart（唯一组合根）。
typedef AlbumFetcher = Future<Album> Function(
  String sourceKey,
  String albumId, {
  required int page,
  required int limit,
});

typedef _AlbumQuery = ({String sourceKey, String albumId});

/// 专辑服务：专辑分页的唯一取数入口（single-flight + LRU + TTL + 错误归一化）。
///
/// 缓存策略收在 [CachedPageService]；本类只负责把类型化参数翻译成缓存
/// key / 前缀。缓存 key 为 `album:{sourceKey}:{albumId}:{page}:{limit}`
/// （平台 / 专辑 / 页），专辑曲目变化缓慢，TTL 取 10 分钟，重试时用
/// [invalidateAlbum] 清该专辑全部页。
class AlbumService {
  AlbumService({
    required AlbumFetcher fetch,
    RequestCache? cache,
    Duration ttl = const Duration(minutes: 10),
  }) : _pages = CachedPageService<Album, _AlbumQuery>(
         fetch: (query, {required page, required limit}) =>
             fetch(query.sourceKey, query.albumId, page: page, limit: limit),
         keyOf: (query, page, limit) =>
             cacheKey(query.sourceKey, query.albumId, page: page, limit: limit),
         // 容量 16（约 4 张专辑 × 4 页）：专辑页退出后队列 / 列表常驻内存
         // 优先，翻回旧专辑按需重取（10min TTL 仍在，重复跳转不重复请求）。
         maxEntries: 16,
         ttl: ttl,
         cache: cache,
       );

  final CachedPageService<Album, _AlbumQuery> _pages;

  /// 取一页专辑；同 key 在 TTL 内共享结果，异常归一化为 `SourceFailure`。
  ///
  /// 无专辑能力 / 平台业务失败时由注入的取数函数抛 `SourceFailure`
  /// （边界归一化幂等）。
  Future<Album> load(
    String sourceKey,
    String albumId, {
    int page = 1,
    int limit = kAlbumPageSize,
  }) => _pages.load(
    (sourceKey: sourceKey, albumId: albumId),
    page: page,
    limit: limit,
  );

  /// 使该专辑的缓存全部失效（重试 / 手动刷新用）。
  void invalidateAlbum(String sourceKey, String albumId) =>
      _pages.invalidatePrefix(albumCacheKeyPrefix(sourceKey, albumId));

  /// 清空全部分页缓存（托盘隐藏时由内存守卫调用；页面重建后按需重取）。
  ///
  /// 本服务所有 key 都以 `album:` 开头，整段前缀即全清；在途条目一并移除，
  /// 结果仍返回原等待方，只是不再写回缓存（与单专辑失效同一语义）。
  void clearCache() => _pages.invalidatePrefix('album:');

  /// 指定专辑当前的缓存条目数（含 in-flight）。
  int countForAlbum(String sourceKey, String albumId) =>
      _pages.countPrefix(albumCacheKeyPrefix(sourceKey, albumId));

  /// 缓存 key：`album:{source}:{id}:{page}:{limit}`。
  static String cacheKey(
    String sourceKey,
    String albumId, {
    required int page,
    int limit = kAlbumPageSize,
  }) => '${albumCacheKeyPrefix(sourceKey, albumId)}$page:$limit';

  /// 同一专辑全部缓存的公共前缀。
  static String albumCacheKeyPrefix(String sourceKey, String albumId) =>
      'album:$sourceKey:$albumId:';
}
