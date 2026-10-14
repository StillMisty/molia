import '../../domain/models/album.dart';
import '../../domain/models/failure.dart';
import '../cache/request_cache.dart';

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

/// 专辑服务：专辑分页的唯一取数入口（single-flight + LRU + TTL + 错误归一化）。
///
/// 与 [CommentsService] 同构：页面只依赖本服务，不直接触碰音源。
/// 缓存 key 为 `album:{sourceKey}:{albumId}:{page}:{limit}`（平台 / 专辑 / 页），
/// 失败不缓存（由 [RequestCache] 保证）；专辑曲目变化缓慢，TTL 取 10 分钟，
/// 重试时用 [invalidateAlbum] 清该专辑全部页。
class AlbumService {
  AlbumService({
    required AlbumFetcher fetch,
    RequestCache? cache,
    Duration ttl = const Duration(minutes: 10),
  })  : _fetch = fetch,
        _cache = cache ?? RequestCache(maxEntries: 64, ttl: ttl);

  final AlbumFetcher _fetch;
  final RequestCache _cache;

  /// 取一页专辑；同 key 在 TTL 内共享结果，异常归一化为 [SourceFailure]。
  ///
  /// 无专辑能力 / 平台业务失败时由注入的取数函数抛 `SourceFailure`
  /// （边界归一化幂等）。
  Future<Album> load(
    String sourceKey,
    String albumId, {
    int page = 1,
    int limit = kAlbumPageSize,
  }) {
    final key = cacheKey(sourceKey, albumId, page: page, limit: limit);
    return _cache.getOrCreate<Album>(
      key,
      () => _guard(
        () => _fetch(sourceKey, albumId, page: page, limit: limit),
      ),
    );
  }

  /// 使该专辑的缓存全部失效（重试 / 手动刷新用）。
  void invalidateAlbum(String sourceKey, String albumId) =>
      _cache.invalidatePrefix(albumCacheKeyPrefix(sourceKey, albumId));

  /// 指定专辑当前的缓存条目数（含 in-flight）。
  int countForAlbum(String sourceKey, String albumId) =>
      _cache.countPrefix(albumCacheKeyPrefix(sourceKey, albumId));

  /// 缓存 key：`album:{source}:{id}:{page}:{limit}`。
  static String cacheKey(
    String sourceKey,
    String albumId, {
    required int page,
    int limit = kAlbumPageSize,
  }) =>
      '${albumCacheKeyPrefix(sourceKey, albumId)}$page:$limit';

  /// 同一专辑全部缓存的公共前缀。
  static String albumCacheKeyPrefix(String sourceKey, String albumId) =>
      'album:$sourceKey:$albumId:';

  Future<Album> _guard(Future<Album> Function() call) async {
    try {
      return await call();
    } catch (e) {
      throw SourceFailure.from(e);
    }
  }
}
