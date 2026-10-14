import '../../domain/models/comment.dart';
import '../../domain/models/failure.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/source_registry.dart';
import '../cache/request_cache.dart';

/// 评论服务：评论分页的唯一取数入口（single-flight + LRU + TTL + 错误归一化）。
///
/// 与 [CatalogService] 同构：provider 只依赖本服务，不直接触碰音源。
/// 缓存 key 为 `comments:{sourceKey}:{songId}:{kind}:{page}:{limit}`
/// （平台 / 曲目 / 类型 / 页），失败不缓存（由 [RequestCache] 保证）；
/// 评论随时间变化，TTL 取 5 分钟，刷新时用 [invalidateTrack] 清该曲目全部页。
class CommentsService {
  CommentsService({
    required SourceRegistry registry,
    RequestCache? cache,
    Duration ttl = const Duration(minutes: 5),
  })  : _registry = registry,
        _cache = cache ?? RequestCache(maxEntries: 96, ttl: ttl);

  final SourceRegistry _registry;
  final RequestCache _cache;

  /// 取一页评论；同 key 在 TTL 内共享结果，异常归一化为 [SourceFailure]。
  ///
  /// 未知音源属编程错误（保持 `StateError`）；无评论能力时由音源适配器
  /// 抛 `SourceFailure(unsupported)`。
  Future<CommentPage> fetch(
    Track track, {
    required CommentKind kind,
    int page = 1,
    int limit = kCommentPageSize,
  }) {
    final source = _registry.forTrack(track);
    if (source == null) {
      return Future.error(StateError('未知音源: ${track.id.sourceKey}'));
    }
    final key = cacheKey(track, kind: kind, page: page, limit: limit);
    return _cache.getOrCreate<CommentPage>(
      key,
      () => _guard(() => source.comments(
            track,
            kind: kind,
            page: page,
            limit: limit,
          )),
    );
  }

  /// 使该曲目的评论缓存全部失效（下拉刷新 / 重试用）。
  void invalidateTrack(Track track) =>
      _cache.invalidatePrefix(trackCacheKeyPrefix(track));

  /// 指定曲目当前的评论缓存条目数（含 in-flight）。
  int countForTrack(Track track) =>
      _cache.countPrefix(trackCacheKeyPrefix(track));

  /// 缓存 key：`comments:{source}:{songId}:{kind}:{page}:{limit}`。
  static String cacheKey(
    Track track, {
    required CommentKind kind,
    required int page,
    int limit = kCommentPageSize,
  }) =>
      '${trackCacheKeyPrefix(track)}${kind.name}:$page:$limit';

  /// 同一曲目全部评论缓存的公共前缀。
  static String trackCacheKeyPrefix(Track track) =>
      'comments:${track.id.sourceKey}:${track.id.id}:';

  Future<CommentPage> _guard(Future<CommentPage> Function() call) async {
    try {
      return await call();
    } catch (e) {
      throw SourceFailure.from(e);
    }
  }
}
