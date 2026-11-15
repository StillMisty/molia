import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../../app/perf/data_path_trace.dart';
import '../../domain/models/artist.dart';
import '../../domain/models/catalog.dart';
import '../../domain/models/failure.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/music_source.dart';
import '../../domain/ports/source_registry.dart';
import '../../services/diagnostics/failure_ring_buffer.dart';
import '../../services/diagnostics/resolve_metrics.dart';
import '../cache/request_cache.dart';
import 'resolve_policy.dart' as policy;

/// 目录服务：聚合 [SourceRegistry] 与请求缓存，是 providers 的唯一搜索入口。
///
/// 职责：
/// - `search`：single-flight + LRU + TTL（默认 5min）搜索缓存；
/// - `resolve`：single-flight + LRU + 取链缓存（默认 10min 上限，平台给了
///   `expiresIn` 时按有效期缩短），key 为
///   `url:{sourceKey}:{hash(payload)}:{quality}`（稳定序列化 + md5）；
///   同一次取链内有界重试，且整段受 [policy.kResolveBudget] 硬截止；
/// - 边界错误统一归一化为 [SourceFailure]（幂等，失败不缓存由 RequestCache 保证）；
/// - 计数进 [ResolveMetrics]（只记数字与失败类别，不记直链 / payload）。
class CatalogService {
  CatalogService({
    required this._registry,
    this._failures,
    ResolveMetrics? metrics,
    RequestCache? searchCache,
    Duration searchTtl = const Duration(minutes: 5),
    RequestCache? resolveCache,
    Duration? resolveTtl,
    this.resolveBudget = policy.kResolveBudget,
    Duration Function(int attempt)? resolveRetryDelay,
  }) : _metrics = metrics ?? ResolveMetrics.session,
       _resolveRetryDelay = resolveRetryDelay ?? policy.resolveRetryDelay,
       _resolveTtl = resolveTtl ?? resolveCache?.ttl ?? _kDefaultResolveTtl,
       _searchCache = searchCache ?? RequestCache(ttl: searchTtl),
       _resolveCache =
           resolveCache ?? RequestCache(ttl: resolveTtl ?? _kDefaultResolveTtl);

  final SourceRegistry _registry;
  final FailureRecorder? _failures;

  /// 取链指标（默认 [ResolveMetrics.session]，与诊断页共用）。
  final ResolveMetrics _metrics;
  final RequestCache _searchCache;
  final RequestCache _resolveCache;

  /// 单曲取链总预算（含重试与退避）；默认 [policy.kResolveBudget]。
  ///
  /// 公开只读：测试与自定义装配可注入更小预算验证截止行为。
  final Duration resolveBudget;

  /// 重试退避函数（默认 [policy.resolveRetryDelay] 的 300ms ±30% 抖动）。
  final Duration Function(int attempt) _resolveRetryDelay;

  /// 取链缓存 TTL 上限：显式 `resolveTtl` 优先，否则跟随注入缓存的 TTL，
  /// 最后回退默认 10min（平台返回 `expiresIn` 时再取更短者）。
  final Duration _resolveTtl;

  static const Duration _kDefaultResolveTtl = Duration(minutes: 10);

  /// 直链失效前的安全余量：缓存必须在平台截止时间之前退出。
  static const Duration _resolveExpirySafety = Duration(seconds: 60);

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
    // 命中判定要在 getOrCreate 之前取：调用之后条目状态已变，无法区分
    // 「这次是缓存命中」还是「这次刚创建」。
    final cached = _searchCache.isFresh(key);
    return DataPathTrace.async(
      'search.catalog',
      () => _searchCache.getOrCreate<SearchResult<Track>>(
        key,
        () => DataPathTrace.async(
          'search.source',
          () => _guardSourceCall(sourceKey, () => source.search(query)),
          fields: () => {'source': sourceKey, 'page': query.page},
        ),
      ),
      fields: () => {
        'source': sourceKey,
        'page': query.page,
        'cached': cached ? 1 : 0,
      },
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
      () => _guardSourceCall(sourceKey, () => source.searchArtists(query)),
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
      () => _guardSourceCall(sourceKey, () => source.searchLyrics(query)),
    );
  }

  /// 取本地可播流；同 `source + payload + quality` 在缓存有效期内共享结果。
  ///
  /// `quality` 为空时使用 `auto` 占位（实际音质由 SourceManager 按用户偏好
  /// 决定，切换偏好后 key 不变，缓存有效期内可能命中旧音质的 URL）。
  ///
  /// 缓存时长上限取构造时的 `_resolveTtl`（显式 `resolveTtl` → 注入缓存的 TTL
  /// → 默认 10min），平台给了 `expiresIn` 时再收紧为
  /// `min(上限, expiresIn - 60s)`：B 站等平台的直链自带截止时间，缓存超过它
  /// 只会把死链接交给播放器。`expiresIn` 剩余不足 60s 时不入库（单飞等待方
  /// 仍拿到值），下一次取链重新问平台。
  Future<PlayableStream> resolve(Track track, {AudioQuality? quality}) {
    final source = _registry.forTrack(track);
    if (source == null) {
      return Future.error(StateError('未知音源: ${track.id.sourceKey}'));
    }
    final key = resolveCacheKey(track, quality);
    final cached = _resolveCache.isFresh(key);
    _metrics.recordCall();
    if (cached) _metrics.recordCacheHit();
    return DataPathTrace.async(
      'resolve.catalog',
      () => _resolveCache.getOrCreate<PlayableStream>(
        key,
        () => _resolveWithRetry(source, track, quality),
        ttlFor: _resolveTtlFor,
      ),
      fields: () => {
        'source': track.id.sourceKey,
        'quality': quality?.type ?? 'auto',
        'cached': cached ? 1 : 0,
      },
    );
  }

  /// 取链 + 有界重试（single-flight 内完成：并发调用方共享整段重试）。
  ///
  /// 整段受 [resolveBudget] 硬截止：每次尝试只用「剩余预算」作为音源超时提示
  /// 并叠加 `.timeout` 兜底，因此第二次尝试不会把总耗时再拉长一倍。只在
  /// [policy.shouldRetryResolve] 判定为暂时性失败时重试；失败仍是失败
  /// （RequestCache 不缓存），调用方看到的是最后一次失败的 [SourceFailure]。
  ///
  /// 指标口径：[ResolveMetrics.recordSuccess] / [ResolveMetrics.recordFailure]
  /// 只在这里记（真实取链），所以 single-flight 合并的并发入口不会把一次
  /// 取链记成多次成败；入口数与缓存命中在 [resolve] 记。预算兜底的
  /// `recordTimeout` 在截断时就记（含随后重试成功的请求），因此它不是失败计数的
  /// 子集。
  Future<PlayableStream> _resolveWithRetry(
    MusicSource source,
    Track track,
    AudioQuality? quality,
  ) async {
    final sourceKey = track.id.sourceKey;
    final qualityLabel = quality?.type ?? 'auto';
    final stopwatch = Stopwatch()..start();
    var attempt = 0;
    while (true) {
      attempt++;
      final remaining = resolveBudget - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        _metrics
          ..recordTimeout()
          ..recordFailure(FailureKind.timeout);
        throw SourceFailure(
          kind: FailureKind.timeout,
          message: '取链超时：${resolveBudget.inMilliseconds}ms 总预算已用完',
          retryable: true,
        );
      }
      try {
        // attempt / retried 直接取自本轮循环（不落静态字段）：埋点只在
        // 这次调用内有效，避免并发取链互相覆盖。
        final stream = await DataPathTrace.async(
          'resolve.source',
          () =>
              _guardSourceCall(
                sourceKey,
                () => source.resolve(
                  track,
                  preferredQuality: quality,
                  timeout: remaining,
                ),
                // 取链失败会经播放链路到达 PlaybackErrorRecovery；那里统一记录，
                // 避免同一失败在目录与播放两个边界各记一次。
                recordFailure: false,
              ).timeout(
                remaining,
                // `.timeout` 只截断等待方：底层请求没有取消能力，仍会跑完，
                // 结果被丢弃（播放侧下一次取链会重新问音源）。
                onTimeout: () {
                  // 只有外层预算兜底才记 timeout；音源自己报的超时算普通失败。
                  // 重试后最终成功也保留这条截断记录（见 recordTimeout）。
                  _metrics.recordTimeout();
                  throw SourceFailure(
                    kind: FailureKind.timeout,
                    message: '取链超时（剩余 ${remaining.inMilliseconds}ms）',
                    retryable: true,
                  );
                },
              ),
          fields: () => {
            'source': sourceKey,
            'quality': qualityLabel,
            'attempt': attempt,
            'retried': attempt > 1 ? 1 : 0,
          },
        );
        _metrics.recordSuccess();
        return stream;
      } on SourceFailure catch (failure) {
        final canRetry =
            attempt < policy.kResolveMaxAttempts &&
            policy.shouldRetryResolve(failure) &&
            stopwatch.elapsed < resolveBudget;
        if (!canRetry) {
          _metrics.recordFailure(failure.kind);
          rethrow;
        }
        final delay = _resolveRetryDelay(attempt);
        // 退避后已超预算：别再让用户多等一次注定超时的请求。
        if (stopwatch.elapsed + delay >= resolveBudget) {
          _metrics.recordFailure(failure.kind);
          rethrow;
        }
        _metrics.recordRetry();
        await Future<void>.delayed(delay);
      }
    }
  }

  /// 按平台有效期收紧取链缓存 TTL（语义见 [resolve]）。
  Duration _resolveTtlFor(PlayableStream stream) {
    final expiresIn = stream.expiresIn;
    if (expiresIn == null) return _resolveTtl;
    final remaining = expiresIn - _resolveExpirySafety;
    if (remaining <= Duration.zero) return Duration.zero;
    return remaining < _resolveTtl ? remaining : _resolveTtl;
  }

  /// 使指定前缀的搜索缓存失效（如 `search:kw:`）。
  void invalidateSearchPrefix(String prefix) =>
      _searchCache.invalidatePrefix(prefix);

  /// 清空全部搜索缓存（单曲 / 歌手 / 歌词共用同一实例）。
  ///
  /// 托盘隐藏时由内存守卫调用：搜索结果带 raw payload，且下次打开搜索多半
  /// 换了关键词，没有常驻价值。取链缓存**刻意保留**：托盘听歌仍在取链，
  /// 清掉会让恢复后的播放重新走一遍音源脚本。
  void clearSearchCache() => _searchCache.clear();

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
    final digest = crypto.md5
        .convert(utf8.encode(_canonicalJson(payload)))
        .toString();
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
  Future<T> _guardSourceCall<T>(
    String sourceKey,
    Future<T> Function() call, {
    bool recordFailure = true,
  }) async {
    try {
      return await call();
    } catch (e) {
      final failure = SourceFailure.from(e);
      if (recordFailure) {
        _failures?.recordFailure(
          failure: failure,
          channelKey: sourceKey,
          channelDisplayName: _displayNameFor(sourceKey),
        );
      }
      throw failure;
    }
  }

  String _displayNameFor(String sourceKey) {
    for (final descriptor in _registry.descriptors) {
      if (descriptor.key == sourceKey) return descriptor.displayName;
    }
    return sourceKey;
  }

  /// 稳定 JSON：递归排序 Map 键（List 保持顺序），非 JSON 值降级为字符串。
  static String _canonicalJson(Object? value) => jsonEncode(
    _canonicalize(value),
    toEncodable: (object) => object.toString(),
  );

  static Object? _canonicalize(Object? value) {
    if (value is Map) {
      final entries =
          value.entries
              .map(
                (entry) =>
                    MapEntry(entry.key.toString(), _canonicalize(entry.value)),
              )
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
