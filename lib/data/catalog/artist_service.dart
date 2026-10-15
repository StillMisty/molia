import '../../domain/models/artist.dart';
import '../../domain/models/failure.dart';
import '../cache/request_cache.dart';

/// 歌手名 → 歌手条目的检索函数（组合根注入 `CatalogService.searchArtists`）。
///
/// 只在曲目 payload 没有歌手 id 时用到（历史收藏 / 导入列表 / 部分入口），
/// 精确匹配策略由 [ArtistService.resolveByName] 持有。
typedef ArtistSearchFetcher = Future<List<ArtistSummary>> Function(
  String sourceKey,
  String name,
);

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

/// 歌手服务：歌手页分页的唯一取数入口（single-flight + LRU + TTL + 错误归一化）。
///
/// 与 [AlbumService] 同构：页面只依赖本服务，不直接触碰音源。
/// 缓存 key 为 `artist:{sourceKey}:{artistId}:{page}:{limit}`（平台 / 歌手 / 页），
/// 失败不缓存（由 [RequestCache] 保证）；歌手歌曲变化缓慢，TTL 取 10 分钟，
/// 重试时用 [invalidateArtist] 清该歌手全部页。
class ArtistService {
  ArtistService({
    required ArtistFetcher fetch,
    ArtistSearchFetcher? search,
    RequestCache? cache,
    RequestCache? nameCache,
    Duration ttl = const Duration(minutes: 10),
  })  : _fetch = fetch,
        _search = search,
        _cache = cache ?? RequestCache(maxEntries: 64, ttl: ttl),
        _nameCache = nameCache ?? RequestCache(maxEntries: 64, ttl: ttl);

  final ArtistFetcher _fetch;
  final ArtistSearchFetcher? _search;
  final RequestCache _cache;

  /// 名字 → id 的解析缓存（命中 / 未命中都缓存 TTL；检索抛错不缓存）。
  final RequestCache _nameCache;

  /// 取一页歌手详情；同 key 在 TTL 内共享结果，异常归一化为 [SourceFailure]。
  ///
  /// 无歌手能力 / 平台业务失败时由注入的取数函数抛 `SourceFailure`
  /// （边界归一化幂等）。
  Future<ArtistDetail> load(
    String sourceKey,
    String artistId, {
    int page = 1,
    int limit = kArtistPageSize,
  }) {
    final key = cacheKey(sourceKey, artistId, page: page, limit: limit);
    return _cache.getOrCreate<ArtistDetail>(
      key,
      () => _guard(
        () => _fetch(sourceKey, artistId, page: page, limit: limit),
      ),
    );
  }

  /// 按名字解析歌手（精确匹配：trim + 忽略大小写）；未命中 / 无检索能力
  /// 返回 null。同一名字在 TTL 内不重复检索（正负结果都缓存）。
  ///
  /// 用途：曲目 payload 没有歌手 id 时（历史收藏 / 导入列表）回退进歌手页。
  Future<ArtistSummary?> resolveByName(String sourceKey, String name) {
    final query = name.trim();
    final searcher = _search;
    if (query.isEmpty || searcher == null) return Future.value(null);
    return _nameCache.getOrCreate<ArtistSummary?>(
      nameCacheKey(sourceKey, query),
      () async {
        final items = await searcher(sourceKey, query);
        final expected = query.toLowerCase();
        for (final item in items) {
          if (item.name.trim().toLowerCase() == expected) return item;
        }
        return null;
      },
    );
  }

  /// 名字解析缓存 key：`artist-name:{source}:{name}`。
  static String nameCacheKey(String sourceKey, String name) =>
      'artist-name:$sourceKey:$name';

  /// 使该歌手的缓存全部失效（重试 / 手动刷新用）。
  void invalidateArtist(String sourceKey, String artistId) =>
      _cache.invalidatePrefix(artistCacheKeyPrefix(sourceKey, artistId));

  /// 指定歌手当前的缓存条目数（含 in-flight）。
  int countForArtist(String sourceKey, String artistId) =>
      _cache.countPrefix(artistCacheKeyPrefix(sourceKey, artistId));

  /// 缓存 key：`artist:{source}:{id}:{page}:{limit}`。
  static String cacheKey(
    String sourceKey,
    String artistId, {
    required int page,
    int limit = kArtistPageSize,
  }) =>
      '${artistCacheKeyPrefix(sourceKey, artistId)}$page:$limit';

  /// 同一歌手全部缓存的公共前缀。
  static String artistCacheKeyPrefix(String sourceKey, String artistId) =>
      'artist:$sourceKey:$artistId:';

  Future<ArtistDetail> _guard(Future<ArtistDetail> Function() call) async {
    try {
      return await call();
    } catch (e) {
      throw SourceFailure.from(e);
    }
  }
}
