import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../../domain/models/catalog.dart';
import '../../domain/models/failure.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/music_source.dart';
import '../../domain/ports/source_registry.dart';
import '../cache/request_cache.dart';

/// 目录服务：聚合 [SourceRegistry] 与请求缓存，是 providers 的唯一搜索入口
/// （施工图 §2.5.2 / §2.5.3）。
///
/// 职责：
/// - `search`：single-flight + LRU + TTL（默认 5min）搜索缓存；
/// - `resolve`：single-flight + LRU + TTL（默认 10min）取链缓存，key 为
///   `url:{sourceKey}:{hash(payload)}:{quality}`（稳定序列化 + md5）；
/// - 边界错误统一归一化为 [SourceFailure]（幂等，失败不缓存由 RequestCache 保证）。
class CatalogService {
  CatalogService({
    required SourceRegistry registry,
    RequestCache? searchCache,
    Duration searchTtl = const Duration(minutes: 5),
    RequestCache? resolveCache,
    Duration resolveTtl = const Duration(minutes: 10),
  })  : _registry = registry,
        _searchCache = searchCache ?? RequestCache(ttl: searchTtl),
        _resolveCache = resolveCache ?? RequestCache(ttl: resolveTtl);

  final SourceRegistry _registry;
  final RequestCache _searchCache;
  final RequestCache _resolveCache;

  /// 搜索指定音源；同 `sourceKey + keyword + page + limit` 在 TTL 内共享结果。
  ///
  /// 音源调用抛出的异常在缓存边界内归一化为 [SourceFailure]（失败不缓存，
  /// 下一次调用会重试）；未知音源属编程错误，保持 `StateError`。
  Future<SearchResult<Track>> search(String sourceKey, SearchQuery query) {
    final source = _registry.byKey(sourceKey);
    if (source == null) {
      return Future.error(StateError('未知音源: $sourceKey'));
    }
    final key = searchCacheKey(sourceKey, query);
    return _searchCache.getOrCreate<SearchResult<Track>>(
      key,
      () => _guardSourceCall(() => source.search(query)),
    );
  }

  /// 取本地可播流；同 `source + payload + quality` 在 TTL 内共享结果。
  ///
  /// `quality` 为空时使用 `auto` 占位（实际音质由 SourceManager 按用户偏好
  /// 决定，切换偏好后 key 不变，10min 内可能命中旧音质的 URL——见交付报告风险）。
  Future<PlayableStream> resolve(Track track, {AudioQuality? quality}) {
    final source = _registry.forTrack(track);
    if (source == null) {
      return Future.error(StateError('未知音源: ${track.id.sourceKey}'));
    }
    final key = resolveCacheKey(track, quality);
    return _resolveCache.getOrCreate<PlayableStream>(
      key,
      () => _guardSourceCall(
        () => source.resolve(track, preferredQuality: quality),
      ),
    );
  }

  /// 使指定前缀的搜索缓存失效（如 `search:kw:`）。
  void invalidateSearchPrefix(String prefix) =>
      _searchCache.invalidatePrefix(prefix);

  /// 搜索缓存 key（施工图 §2.5.2：`search:{source}:{keyword}:{page}:{limit}`）。
  static String searchCacheKey(String sourceKey, SearchQuery query) =>
      'search:$sourceKey:${query.keyword}:${query.page}:${query.limit}';

  /// 取链缓存 key（施工图 §2.5.2：`url:{source}:{hash(payload)}:{quality}`）。
  ///
  /// `payload` 用递归排序键的稳定序列化后 md5，保证相同内容生成相同 key；
  /// 无音质参数时以 `auto` 占位。
  static String resolveCacheKey(Track track, AudioQuality? quality) {
    final digest = crypto.md5
        .convert(utf8.encode(_canonicalJson(track.payload)))
        .toString();
    return 'url:${track.id.sourceKey}:$digest:${quality?.type ?? 'auto'}';
  }

  /// 使指定音源的取链缓存失效（预留：播放失败/403 时立即失效并重试）。
  void invalidateResolvePrefix(String sourceKey) =>
      _resolveCache.invalidatePrefix('url:$sourceKey:');

  /// 归一化音源调用异常；[SourceFailure] 幂等透传。
  Future<T> _guardSourceCall<T>(Future<T> Function() call) async {
    try {
      return await call();
    } catch (e) {
      throw SourceFailure.from(e);
    }
  }

  /// 稳定 JSON：递归排序 Map 键（List 保持顺序），非 JSON 值降级为字符串。
  static String _canonicalJson(Object? value) => jsonEncode(
        _canonicalize(value),
        toEncodable: (object) => object.toString(),
      );

  static Object? _canonicalize(Object? value) {
    if (value is Map) {
      final entries = value.entries
          .map((entry) => MapEntry(entry.key.toString(), _canonicalize(entry.value)))
          .toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      return {for (final entry in entries) entry.key: entry.value};
    }
    if (value is List) {
      return [for (final item in value) _canonicalize(item)];
    }
    return value;
  }
}
