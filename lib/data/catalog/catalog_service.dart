import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../../domain/models/artist.dart';
import '../../domain/models/catalog.dart';
import '../../domain/models/failure.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/music_source.dart';
import '../../domain/ports/source_registry.dart';
import '../cache/request_cache.dart';

/// 目录服务：聚合 [SourceRegistry] 与请求缓存，是 providers 的唯一搜索入口。
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

  /// 歌手搜索（搜索页「歌手」分段）；同 `sourceKey + keyword + page + limit`
  /// 在 TTL 内共享结果（与单曲搜索同一缓存实例，key 带 `artist` 段）。
  Future<SearchResult<ArtistSummary>> searchArtists(
    String sourceKey,
    SearchQuery query,
  ) {
    final source = _registry.byKey(sourceKey);
    if (source == null) {
      return Future.error(StateError('未知音源: $sourceKey'));
    }
    final key = artistSearchCacheKey(sourceKey, query);
    return _searchCache.getOrCreate<SearchResult<ArtistSummary>>(
      key,
      () => _guardSourceCall(() => source.searchArtists(query)),
    );
  }

  /// 按歌词搜歌（搜索页「歌词」分段）；缓存口径与单曲搜索一致。
  Future<SearchResult<LyricHit>> searchLyrics(
    String sourceKey,
    SearchQuery query,
  ) {
    final source = _registry.byKey(sourceKey);
    if (source == null) {
      return Future.error(StateError('未知音源: $sourceKey'));
    }
    final key = lyricSearchCacheKey(sourceKey, query);
    return _searchCache.getOrCreate<SearchResult<LyricHit>>(
      key,
      () => _guardSourceCall(() => source.searchLyrics(query)),
    );
  }

  /// 取本地可播流；同 `source + payload + quality` 在 TTL 内共享结果。
  ///
  /// `quality` 为空时使用 `auto` 占位（实际音质由 SourceManager 按用户偏好
  /// 决定，切换偏好后 key 不变，10min 内可能命中旧音质的 URL）。
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

  /// 搜索缓存 key：`search:{source}:{keyword}:{page}:{limit}`。
  static String searchCacheKey(String sourceKey, SearchQuery query) =>
      'search:$sourceKey:${query.keyword}:${query.page}:${query.limit}';

  /// 歌手搜索缓存 key：`search:{source}:artist:{keyword}:{page}:{limit}`
  /// （`search:{source}:` 前缀失效对单曲与歌手同时生效）。
  static String artistSearchCacheKey(String sourceKey, SearchQuery query) =>
      'search:$sourceKey:artist:${query.keyword}:${query.page}:${query.limit}';

  /// 歌词搜索缓存 key：`search:{source}:lyric:{keyword}:{page}:{limit}`。
  static String lyricSearchCacheKey(String sourceKey, SearchQuery query) =>
      'search:$sourceKey:lyric:${query.keyword}:${query.page}:${query.limit}';

  /// 取链缓存 key：`url:{source}:{hash(payload)}:{quality}`。
  ///
  /// `payload` 用递归排序键的稳定序列化后 md5，保证相同内容生成相同 key；
  /// 无音质参数时以 `auto` 占位。
  static String resolveCacheKey(Track track, AudioQuality? quality) =>
      'url:${track.id.sourceKey}:${payloadDigestOf(track)}:'
      '${quality?.type ?? 'auto'}';

  /// 取链缓存 key 的曲目段：`url:{source}:{digest}:`（不含音质）。
  ///
  /// 同一曲目的所有音质变体共享该前缀（单曲失效/占用查询用）。
  static String resolveCacheKeyPrefix(Track track) =>
      'url:${track.id.sourceKey}:${payloadDigestOf(track)}:';

  /// payload 稳定摘要（排序键 JSON → md5）。
  ///
  /// 记忆化：raw payload 按不变量「原样透传」（同一引用），同一曲目的重复
  /// 取链 / 缓存占用查询（单曲清缓存、信息页）不再重复做递归排序 + 编码
  /// + md5；Expando 弱引用不阻止 payload 回收。
  static final Expando<String> _payloadDigests = Expando<String>();

  static String payloadDigestOf(Track track) {
    final payload = track.payload;
    final cached = _payloadDigests[payload];
    if (cached != null) return cached;
    final digest =
        crypto.md5.convert(utf8.encode(_canonicalJson(payload))).toString();
    _payloadDigests[payload] = digest;
    return digest;
  }

  /// 使指定音源的取链缓存失效（预留：播放失败/403 时立即失效并重试）。
  void invalidateResolvePrefix(String sourceKey) =>
      _resolveCache.invalidatePrefix('url:$sourceKey:');

  /// 使指定曲目的取链缓存失效（含所有音质变体；单曲清缓存用）。
  ///
  /// 不清取链缓存的话，删掉音频文件后重播仍会命中旧 URL——用户
  /// 「清理后重来」的意图会落空。
  int invalidateResolveForTrack(Track track) {
    final prefix = resolveCacheKeyPrefix(track);
    final removed = _resolveCache.countPrefix(prefix);
    _resolveCache.invalidatePrefix(prefix);
    return removed;
  }

  /// 指定曲目当前的取链缓存条目数（含 in-flight）。
  int resolveCacheCountForTrack(Track track) =>
      _resolveCache.countPrefix(resolveCacheKeyPrefix(track));

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
