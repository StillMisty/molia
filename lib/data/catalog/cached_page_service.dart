import '../../domain/models/failure.dart';
import '../cache/request_cache.dart';

/// 分页取数函数：查询 + 页码 / 每页条数 → 一页结果。
typedef PageFetcher<T, Q> = Future<T> Function(
  Q query, {
  required int page,
  required int limit,
});

/// 分页缓存服务：目录详情（专辑 / 歌手 / 评论）共用的取数骨架。
///
/// 收拢三处重复的缓存策略：single-flight + LRU + TTL 由 [RequestCache]
/// 承担，失败在这里统一归一化为 [SourceFailure]（失败不缓存由缓存保证）。
/// key / 前缀的拼装由类型化适配器注入——平台字面量留在各自模块，泛型层
/// 不解析 key 语义。
///
/// `maxEntries` / `ttl` 只在未注入 `cache` 时生效（注入场景由调用方完全
/// 掌控缓存策略，测试可用可控时钟驱动 TTL）。
class CachedPageService<T, Q> {
  CachedPageService({
    required this._fetch,
    required this._keyOf,
    required int maxEntries,
    Duration ttl = const Duration(minutes: 10),
    RequestCache? cache,
  }) : _cache = cache ?? RequestCache(maxEntries: maxEntries, ttl: ttl);

  final PageFetcher<T, Q> _fetch;
  final String Function(Q query, int page, int limit) _keyOf;
  final RequestCache _cache;

  /// 取一页；同 key 在 TTL 内共享结果，异常归一化为 [SourceFailure]。
  Future<T> load(Q query, {required int page, required int limit}) {
    final key = _keyOf(query, page, limit);
    return _cache.getOrCreate<T>(
      key,
      () => _guard(() => _fetch(query, page: page, limit: limit)),
    );
  }

  /// 使以 [prefix] 开头的全部页失效（重试 / 手动刷新用）。
  ///
  /// 前缀由类型化适配器给出：泛型层不解析「专辑 / 歌手 / 评论」的 key 语义，
  /// 失效与计数也不需要为同一个 Q 构造一份只用于删除的假查询。
  void invalidatePrefix(String prefix) => _cache.invalidatePrefix(prefix);

  /// 与 [prefix] 匹配的缓存条目数（含 in-flight）。
  int countPrefix(String prefix) => _cache.countPrefix(prefix);

  Future<T> _guard(Future<T> Function() call) async {
    try {
      return await call();
    } catch (e) {
      throw SourceFailure.from(e);
    }
  }
}
