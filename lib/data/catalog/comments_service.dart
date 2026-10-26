import '../../domain/models/comment.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/music_source.dart';
import '../../domain/ports/source_registry.dart';
import '../cache/request_cache.dart';
import 'cached_page_service.dart';

/// 评论服务：评论分页的唯一取数入口（single-flight + LRU + TTL + 错误归一化）。
///
/// 缓存策略收在 [CachedPageService]；本类只负责解析音源与拼缓存 key。
/// 缓存 key 为 `comments:{sourceKey}:{songId}:{kind}:{page}:{limit}`
/// （平台 / 曲目 / 类型 / 页），评论随时间变化，TTL 取 5 分钟，刷新时用
/// [invalidateTrack] 清该曲目全部页。
class CommentsService {
  CommentsService({
    required this._registry,
    RequestCache? cache,
    Duration ttl = const Duration(minutes: 5),
  }) : _pages = CachedPageService<CommentPage, _CommentQuery>(
         fetch: (query, {required page, required limit}) => query.source
             .comments(query.track, kind: query.kind, page: page, limit: limit),
         keyOf: (query, page, limit) =>
             '${trackCacheKeyPrefix(query.track)}${query.kind.name}:$page:$limit',
         maxEntries: 96,
         ttl: ttl,
         cache: cache,
       );

  final SourceRegistry _registry;
  final CachedPageService<CommentPage, _CommentQuery> _pages;

  /// 取一页评论；同 key 在 TTL 内共享结果，异常归一化为 `SourceFailure`。
  ///
  /// 未知音源属编程错误（保持 `StateError`），且在进入泛型缓存前返回，
  /// 不会被归一化；无评论能力时由音源适配器抛 `SourceFailure(unsupported)`。
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
    return _pages.load(
      _CommentQuery(track: track, kind: kind, source: source),
      page: page,
      limit: limit,
    );
  }

  /// 使该曲目的评论缓存全部失效（下拉刷新 / 重试用）。
  void invalidateTrack(Track track) =>
      _pages.invalidatePrefix(trackCacheKeyPrefix(track));

  /// 指定曲目当前的评论缓存条目数（含 in-flight）。
  int countForTrack(Track track) =>
      _pages.countPrefix(trackCacheKeyPrefix(track));

  /// 缓存 key：`comments:{source}:{songId}:{kind}:{page}:{limit}`。
  static String cacheKey(
    Track track, {
    required CommentKind kind,
    required int page,
    int limit = kCommentPageSize,
  }) => '${trackCacheKeyPrefix(track)}${kind.name}:$page:$limit';

  /// 同一曲目全部评论缓存的公共前缀。
  static String trackCacheKeyPrefix(Track track) =>
      'comments:${track.id.sourceKey}:${track.id.id}:';
}

/// 评论分页查询：曲目 + 已解析音源 + 类型，三者都是取数必需。
class _CommentQuery {
  const _CommentQuery({
    required this.track,
    required this.kind,
    required this.source,
  });

  final Track track;
  final CommentKind kind;
  final MusicSource source;
}
