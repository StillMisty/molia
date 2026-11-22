import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/cache/request_cache.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/catalog/resolve_policy.dart';
import 'package:molia/domain/models/artist.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/comment.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart';
import 'package:molia/domain/ports/source_registry.dart';
import 'package:molia/services/diagnostics/resolve_metrics.dart';
import 'package:molia/sources/lx/lx_engine_types.dart';

Track _track(String sourceKey, String id) => Track(
  id: TrackId(sourceKey, id),
  title: 'Title $id',
  origin: TrackOrigin.lx,
  payload: {'id': id},
);

class _FakeMusicSource implements MusicSource {
  _FakeMusicSource(this.key);

  @override
  final String key;

  int searchCalls = 0;
  int artistSearchCalls = 0;
  int lyricSearchCalls = 0;
  int resolveCalls = 0;
  Object? searchError;
  Object? artistSearchError;
  Object? lyricSearchError;
  Object? resolveError;

  /// 剩余可失败的取链次数（默认一直失败，直到测试清空 [resolveError]）。
  int resolveErrorTimes = 1 << 30;

  /// 每次取链的模拟耗时（按调用序号，缺省 0）；用于验证总预算硬截止。
  final List<Duration> resolveDelays = [];

  /// 每次取链收到的超时提示（验证按剩余预算下发）。
  final List<Duration?> resolveTimeouts = [];

  /// 成功取链时原样带回的请求头 / 有效期（验证目录层不改写）。
  Map<String, String> resolveHeaders = const {};
  Duration? resolveExpiresIn;

  @override
  String get displayName => key;

  @override
  SourceCapabilities get capabilities => const SourceCapabilities(
    search: true,
    pagination: true,
    resolveUrl: true,
  );

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<SearchResult<Track>> search(
    SearchQuery query, {
    CancelToken? cancel,
  }) async {
    searchCalls++;
    final error = searchError;
    if (error != null) throw error;
    return SearchResult(
      items: [_track(key, '${query.keyword}-p${query.page}')],
      hasMore: true,
      total: 42,
    );
  }

  @override
  Future<SearchResult<ArtistSummary>> searchArtists(
    SearchQuery query, {
    CancelToken? cancel,
  }) async {
    artistSearchCalls++;
    if (artistSearchError != null) throw artistSearchError!;
    return SearchResult(
      items: [
        ArtistSummary(id: '${query.keyword}-a${query.page}', name: '歌手 A'),
      ],
      hasMore: true,
      total: 1,
    );
  }

  @override
  Future<SearchResult<LyricHit>> searchLyrics(
    SearchQuery query, {
    CancelToken? cancel,
  }) async {
    lyricSearchCalls++;
    if (lyricSearchError != null) throw lyricSearchError!;
    return SearchResult(
      items: [
        LyricHit(
          track: _track(key, '${query.keyword}-l${query.page}'),
          snippet: '命中歌词 ${query.keyword}',
        ),
      ],
      hasMore: true,
      total: 1,
    );
  }

  @override
  Future<PlayableStream> resolve(
    Track track, {
    AudioQuality? preferredQuality,
    Duration? timeout,
  }) async {
    resolveCalls++;
    resolveTimeouts.add(timeout);
    final delayIndex = resolveCalls - 1;
    if (delayIndex < resolveDelays.length) {
      await Future<void>.delayed(resolveDelays[delayIndex]);
    }
    final error = resolveError;
    if (error != null && resolveErrorTimes > 0) {
      resolveErrorTimes--;
      throw error;
    }
    return PlayableStream(
      Uri.parse(
        'https://cdn.example/$key/${track.id.id}'
        '${preferredQuality == null ? '' : '?q=${preferredQuality.type}'}',
      ),
      headers: resolveHeaders,
      expiresIn: resolveExpiresIn,
    );
  }

  @override
  Future<LyricsDoc?> lyrics(Track track) async => null;

  @override
  Future<Artwork?> artwork(Track track) async => null;

  @override
  Future<CommentPage> comments(
    Track track, {
    required CommentKind kind,
    int page = 1,
    int limit = 20,
  }) async => CommentPage.fromPage(
    kind: kind,
    items: const [],
    page: page,
    limit: limit,
    total: 0,
  );

  @override
  Future<CollectionPage> collection(
    CollectionRef ref, {
    int page = 1,
    int limit = 50,
  }) async => const CollectionPage();

  @override
  Track? adopt(Track track) => null;
}

class _FakeRegistry implements SourceRegistry {
  _FakeRegistry(Map<String, MusicSource> sources) : _sources = sources;

  final Map<String, MusicSource> _sources;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  List<SourceDescriptor> get descriptors => const [];

  @override
  Set<String> get enabledChannelKeys => _sources.keys.toSet();

  @override
  List<String> get orderedChannelKeys => _sources.keys.toList();

  @override
  MusicSource? byKey(String key) => _sources[key];

  @override
  MusicSource? forTrack(Track track) => _sources[track.id.sourceKey];

  @override
  Future<void> refresh() async {}

  @override
  Future<void> setOrder(List<String> keys) async {}

  @override
  Stream<void> get changes => _changes.stream;

  void dispose() => _changes.close();
}

void main() {
  test('searchCacheKey 符合施工图约定', () {
    expect(
      CatalogService.searchCacheKey(
        'kw',
        const SearchQuery(keyword: 'hello', page: 2, limit: 30),
      ),
      'search:kw:hello:2:30',
    );
  });

  test('search：page/keyword 变化各自独立取数', () async {
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);

    final query = const SearchQuery(keyword: 'hello', page: 1, limit: 30);
    final first = await service.search('kw', query);

    await service.search('kw', const SearchQuery(keyword: 'hello', page: 2));
    expect(source.searchCalls, 2);

    await service.search('kw', const SearchQuery(keyword: 'world', page: 2));
    expect(source.searchCalls, 3);

    expect(first.total, 42);
    expect(first.hasMore, isTrue);
    expect(first.items.single.id, const TrackId('kw', 'hello-p1'));
  });

  test('search：TTL 过期后重新请求（注入时钟）', () async {
    var now = DateTime(2026, 1, 1);
    final cache = RequestCache(
      ttl: const Duration(minutes: 5),
      clock: () => now,
    );
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry, searchCache: cache);

    const query = SearchQuery(keyword: 'hello');
    await service.search('kw', query);
    await service.search('kw', query);
    expect(source.searchCalls, 1);

    now = now.add(const Duration(minutes: 6));
    await service.search('kw', query);
    expect(source.searchCalls, 2);
  });

  test('clearSearchCache：只清搜索缓存，已缓存的取链仍然命中', () async {
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);
    final track = _track('kw', 'a');
    const query = SearchQuery(keyword: 'hello');

    await service.search('kw', query);
    await service.resolve(track);
    expect(source.searchCalls, 1);
    expect(source.resolveCalls, 1);

    service.clearSearchCache();

    await service.search('kw', query);
    await service.resolve(track);
    expect(source.searchCalls, 2, reason: '搜索缓存已清空，重新请求');
    expect(source.resolveCalls, 1, reason: '取链缓存刻意保留，托盘听歌不重新取链');
  });

  test('search：未知音源抛 StateError', () async {
    final registry = _FakeRegistry({});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);

    await expectLater(
      service.search('nope', const SearchQuery(keyword: 'x')),
      throwsStateError,
    );
  });

  test('resolve：不同音质各自独立缓存（不同 key 均调用一次）', () async {
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);

    final track = _track('kw', 'a');
    final first = await service.resolve(
      track,
      quality: const AudioQuality(type: '320k'),
    );
    final second = await service.resolve(track);
    expect(source.resolveCalls, 2, reason: '音质不同 → key 不同 → 各自取链');
    expect(first.uri.toString(), 'https://cdn.example/kw/a?q=320k');
    expect(second.uri.toString(), 'https://cdn.example/kw/a');
  });

  test('resolveCacheKey：键排序稳定，音质/音源参与 key', () {
    final a = Track(
      id: const TrackId('kw', 'a'),
      title: 't',
      origin: TrackOrigin.lx,
      payload: {
        'b': 1,
        'a': {'y': 2, 'x': 1},
      },
    );
    final b = Track(
      id: const TrackId('kw', 'a'),
      title: 't',
      origin: TrackOrigin.lx,
      payload: {
        'a': {'x': 1, 'y': 2},
        'b': 1,
      },
    );

    expect(
      CatalogService.resolveCacheKey(a, null),
      CatalogService.resolveCacheKey(b, null),
      reason: 'Map 键序不同但内容相同 → 同一 key',
    );
    expect(CatalogService.resolveCacheKey(a, null), startsWith('url:kw:'));
    expect(CatalogService.resolveCacheKey(a, null), endsWith(':auto'));
    expect(
      CatalogService.resolveCacheKey(a, const AudioQuality(type: '320k')),
      isNot(
        CatalogService.resolveCacheKey(a, const AudioQuality(type: '128k')),
      ),
    );
    expect(
      CatalogService.resolveCacheKey(a, null),
      isNot(
        CatalogService.resolveCacheKey(
          Track(
            id: const TrackId('tx', 'a'),
            title: 't',
            origin: TrackOrigin.lx,
            payload: a.payload,
          ),
          null,
        ),
      ),
    );
  });

  test('invalidateResolveForTrack：清该曲目全部音质变体，不动其它曲目', () async {
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);

    final track = _track('kw', 'a');
    final other = _track('kw', 'b');
    await service.resolve(track, quality: const AudioQuality(type: '320k'));
    await service.resolve(track, quality: const AudioQuality(type: '128k'));
    await service.resolve(other);
    expect(source.resolveCalls, 3);
    expect(service.resolveCacheCountForTrack(track), 2);

    final removed = service.invalidateResolveForTrack(track);
    expect(removed, 2);
    expect(service.resolveCacheCountForTrack(track), 0);
    expect(service.resolveCacheCountForTrack(other), 1);

    // 再次取链重新命中引擎；其它曲目仍走缓存。
    await service.resolve(track, quality: const AudioQuality(type: '320k'));
    await service.resolve(other);
    expect(source.resolveCalls, 4);
  });

  test('resolve：失败不缓存，下一次可重试成功', () async {
    final source = _FakeMusicSource('kw')
      ..resolveError = const LxEngineException('取链失败');
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);
    final track = _track('kw', 'a');

    await expectLater(
      service.resolve(track),
      throwsA(
        isA<SourceFailure>().having(
          (f) => f.kind,
          'kind',
          FailureKind.scriptError,
        ),
      ),
    );
    // scriptError 可重试：目录层在单飞内多打了一次（共 2 次）仍是失败。
    expect(source.resolveCalls, 2);

    source.resolveError = null;
    final stream = await service.resolve(track);
    expect(stream.uri.toString(), 'https://cdn.example/kw/a');
    expect(source.resolveCalls, 3, reason: '失败不缓存，第二次调用重新取链');
  });

  test('resolve：可重试失败重试一次后成功', () async {
    final source = _FakeMusicSource('kw')
      ..resolveError = const SourceFailure(
        kind: FailureKind.network,
        message: 'boom',
        retryable: true,
      )
      ..resolveErrorTimes = 1;
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);

    final stream = await service.resolve(_track('kw', 'a'));

    expect(stream.uri.toString(), 'https://cdn.example/kw/a');
    expect(source.resolveCalls, 2, reason: '首次失败 + 一次重试');
  });

  test('resolve：不可重试失败（notFound）不重试', () async {
    final source = _FakeMusicSource('kw')
      ..resolveError = const SourceFailure(
        kind: FailureKind.notFound,
        message: '没有该档位',
      );
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);

    await expectLater(
      service.resolve(_track('kw', 'a')),
      throwsA(
        isA<SourceFailure>().having(
          (f) => f.kind,
          'kind',
          FailureKind.notFound,
        ),
      ),
    );
    expect(source.resolveCalls, 1, reason: 'notFound 原样重发没有意义');
  });

  test('resolve：重试耗尽抛最后一次失败且不缓存', () async {
    final source = _FakeMusicSource('kw')
      ..resolveError = const SourceFailure(
        kind: FailureKind.timeout,
        message: '超时',
        retryable: true,
      );
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);
    final track = _track('kw', 'a');

    await expectLater(
      service.resolve(track),
      throwsA(
        isA<SourceFailure>().having((f) => f.kind, 'kind', FailureKind.timeout),
      ),
    );
    expect(source.resolveCalls, 2);
    expect(service.resolveCacheCountForTrack(track), 0, reason: '失败不缓存');

    await expectLater(service.resolve(track), throwsA(isA<SourceFailure>()));
    expect(source.resolveCalls, 4, reason: '每次调用重新走完整重试');
  });

  test('resolve：命中缓存时 headers / expiresIn 原样返回', () async {
    final source = _FakeMusicSource('kw')
      ..resolveHeaders = const {'Referer': 'https://example.com/'}
      ..resolveExpiresIn = const Duration(minutes: 5);
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);
    final track = _track('kw', 'a');

    final first = await service.resolve(track);
    final second = await service.resolve(track);

    expect(second, first, reason: '缓存命中直接返回同一流，不改写请求头 / 有效期');
    expect(second.headers, {'Referer': 'https://example.com/'});
    expect(second.expiresIn, const Duration(minutes: 5));
    expect(source.resolveCalls, 1);
  });

  test('resolve：expiresIn 比默认 TTL 短时按有效期缓存，过期后重新取链', () async {
    var now = DateTime(2026, 1, 1);
    final cache = RequestCache(
      ttl: const Duration(minutes: 10),
      clock: () => now,
    );
    final source = _FakeMusicSource('kw')
      ..resolveExpiresIn = const Duration(minutes: 3);
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry, resolveCache: cache);
    final track = _track('kw', 'a');

    await service.resolve(track);
    // TTL = 3min - 60s = 2min：1min59s 内命中。
    now = now.add(const Duration(minutes: 1, seconds: 59));
    await service.resolve(track);
    expect(source.resolveCalls, 1);

    now = now.add(const Duration(seconds: 2));
    await service.resolve(track);
    expect(source.resolveCalls, 2, reason: '超出平台有效期前 60s 的缓存窗口');
  });

  test('resolve：expiresIn 剩余 ≤60s 时不入缓存（本次仍返回结果）', () async {
    final source = _FakeMusicSource('kw')
      ..resolveExpiresIn = const Duration(seconds: 30);
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);
    final track = _track('kw', 'a');

    final stream = await service.resolve(track);
    expect(stream.uri.toString(), 'https://cdn.example/kw/a');

    await service.resolve(track);
    expect(source.resolveCalls, 2, reason: '零 TTL 不入库，下一次重新取链');
    expect(service.resolveCacheCountForTrack(track), 0);
  });

  test('resolve：注入短 TTL 缓存且无 expiresIn → 按注入缓存的 TTL 过期', () async {
    var now = DateTime(2026, 1, 1);
    final cache = RequestCache(
      ttl: const Duration(minutes: 1),
      clock: () => now,
    );
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry, resolveCache: cache);
    final track = _track('kw', 'a');

    await service.resolve(track);
    await service.resolve(track);
    expect(source.resolveCalls, 1);

    now = now.add(const Duration(seconds: 61));
    await service.resolve(track);
    expect(
      source.resolveCalls,
      2,
      reason: '没有 expiresIn 时不应把注入的 1min 缓存拉回默认 10min',
    );
  });

  test('resolve：单次尝试受总预算硬截止，超时归一化为 timeout', () async {
    // 预算取 500ms：即使调度抖动几百毫秒，`.timeout` 也一定在 2s 的 fake 延迟
    // 之前触发，且触发时已吃掉全部预算 → 第二次尝试不会发起（确定性）。
    final source = _FakeMusicSource('kw')
      ..resolveDelays.add(const Duration(seconds: 2));
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(
      registry: registry,
      resolveBudget: const Duration(milliseconds: 500),
      resolveRetryDelay: (_) => Duration.zero,
    );

    final watch = Stopwatch()..start();
    await expectLater(
      service.resolve(_track('kw', 'a')),
      throwsA(
        isA<SourceFailure>()
            .having((f) => f.kind, 'kind', FailureKind.timeout)
            .having((f) => f.retryable, 'retryable', isTrue),
      ),
    );
    watch.stop();

    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    expect(source.resolveCalls, 1, reason: '预算已耗尽，不再发起第二次尝试');
    expect(
      source.resolveTimeouts.single,
      lessThanOrEqualTo(const Duration(milliseconds: 500)),
      reason: '首次尝试也只拿到剩余预算',
    );
  });

  test('resolve：第二次尝试共享剩余预算，不叠加满额超时', () async {
    // 预算 1200ms：首轮失败（零延迟）到重试准入之间即使抖动几百毫秒，
    // 也仍有剩余预算进入第二次尝试；第二次挂 2s，必然被剩余预算截断。
    final source = _FakeMusicSource('kw')
      ..resolveError = const SourceFailure(
        kind: FailureKind.network,
        message: 'boom',
        retryable: true,
      )
      ..resolveErrorTimes = 1;
    source.resolveDelays.addAll([Duration.zero, const Duration(seconds: 2)]);
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(
      registry: registry,
      resolveBudget: const Duration(milliseconds: 1200),
      resolveRetryDelay: (_) => const Duration(milliseconds: 20),
    );

    final watch = Stopwatch()..start();
    await expectLater(
      service.resolve(_track('kw', 'a')),
      throwsA(
        isA<SourceFailure>().having((f) => f.kind, 'kind', FailureKind.timeout),
      ),
    );
    watch.stop();

    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    expect(source.resolveCalls, 2);
    expect(
      source.resolveTimeouts[1]!.inMilliseconds,
      lessThan(1200),
      reason: '第二次尝试拿到的是扣除首轮与退避后的剩余预算',
    );
    expect(source.resolveTimeouts[1]!.inMilliseconds, greaterThan(0));
  });

  test('resolve：TTL 过期后重新取链', () async {
    var now = DateTime(2026, 1, 1);
    final cache = RequestCache(
      ttl: const Duration(minutes: 10),
      clock: () => now,
    );
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry, resolveCache: cache);
    final track = _track('kw', 'a');

    await service.resolve(track);
    await service.resolve(track);
    expect(source.resolveCalls, 1);

    now = now.add(const Duration(minutes: 10, seconds: 1));
    await service.resolve(track);
    expect(source.resolveCalls, 2, reason: '10min TTL 过期后重新取链');
  });

  test('invalidateResolvePrefix 清空对应音源的取链缓存', () async {
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);
    final track = _track('kw', 'a');

    await service.resolve(track);
    await service.resolve(track);
    expect(source.resolveCalls, 1);

    service.invalidateResolvePrefix('kw');
    await service.resolve(track);
    expect(source.resolveCalls, 2);
  });

  test('search：音源异常归一化为 SourceFailure 且失败不缓存', () async {
    final source = _FakeMusicSource('kw')..searchError = StateError('boom');
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);
    const query = SearchQuery(keyword: 'hello');

    await expectLater(
      service.search('kw', query),
      throwsA(
        isA<SourceFailure>()
            .having((f) => f.kind, 'kind', FailureKind.unknown)
            .having((f) => f.retryable, 'retryable', isFalse),
      ),
    );

    source.searchError = null;
    final result = await service.search('kw', query);
    expect(result.items, isNotEmpty);
    expect(source.searchCalls, 2, reason: '失败不缓存，第二次重新搜索');
  });

  test('searchArtists：同 key 命中缓存；关键词 / 页各自独立；失败不缓存', () async {
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);
    const query = SearchQuery(keyword: '周杰伦');

    final first = await service.searchArtists('kw', query);
    expect(first.items.single.name, '歌手 A');
    await service.searchArtists('kw', query);
    expect(source.artistSearchCalls, 1, reason: '同 key 命中缓存');

    await service.searchArtists(
      'kw',
      const SearchQuery(keyword: '周杰伦', page: 2),
    );
    await service.searchArtists('kw', const SearchQuery(keyword: '温岚'));
    expect(source.artistSearchCalls, 3);

    source.artistSearchError = StateError('boom');
    await expectLater(
      service.searchArtists('kw', const SearchQuery(keyword: '失败')),
      throwsA(isA<SourceFailure>()),
    );
    source.artistSearchError = null;
    await service.searchArtists('kw', const SearchQuery(keyword: '失败'));
    expect(source.artistSearchCalls, 5, reason: '失败不缓存，重试重新搜索');
  });

  test('searchArtists：未知音源抛 StateError；缓存 key 带 artist 段', () async {
    final registry = _FakeRegistry({});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);

    await expectLater(
      service.searchArtists('nope', const SearchQuery(keyword: 'x')),
      throwsStateError,
    );
    expect(
      CatalogService.artistSearchCacheKey(
        'kw',
        const SearchQuery(keyword: '周杰伦'),
      ),
      'search:kw:artist:周杰伦:1:30',
    );
    // 单曲搜索缓存不受影响（前缀失效仍覆盖两者，key 段不冲突）。
    expect(
      CatalogService.searchCacheKey('kw', const SearchQuery(keyword: '周杰伦')),
      'search:kw:周杰伦:1:30',
    );
  });

  test('searchLyrics：同 key 命中缓存；key 带 lyric 段；失败不缓存', () async {
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);
    const query = SearchQuery(keyword: '雨下整夜');

    final first = await service.searchLyrics('kw', query);
    expect(first.items.single.snippet, contains('雨下整夜'));
    expect(first.items.single.track.id.uri, 'kw:雨下整夜-l1');
    await service.searchLyrics('kw', query);
    expect(source.lyricSearchCalls, 1, reason: '同 key 命中缓存');

    source.lyricSearchError = StateError('boom');
    await expectLater(
      service.searchLyrics('kw', const SearchQuery(keyword: '失败')),
      throwsA(isA<SourceFailure>()),
    );
    source.lyricSearchError = null;
    await service.searchLyrics('kw', const SearchQuery(keyword: '失败'));
    expect(source.lyricSearchCalls, 3, reason: '失败不缓存，重试重新搜索');

    expect(
      CatalogService.lyricSearchCacheKey('kw', query),
      'search:kw:lyric:雨下整夜:1:30',
    );
  });

  test('resolve：未知音源抛 StateError', () async {
    final registry = _FakeRegistry({});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);

    await expectLater(service.resolve(_track('nope', 'a')), throwsStateError);
  });

  test('invalidateSearchPrefix 清空对应前缀缓存', () async {
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);

    const query = SearchQuery(keyword: 'hello');
    await service.search('kw', query);
    service.invalidateSearchPrefix('search:kw:');
    await service.search('kw', query);
    expect(source.searchCalls, 2);
  });

  group('resolve_policy', () {
    test('shouldRetryResolve：只重试暂时性失败', () {
      const retryableKinds = [
        FailureKind.network,
        FailureKind.timeout,
        FailureKind.rateLimited,
        FailureKind.scriptError,
        FailureKind.engineRestarting,
      ];
      for (final kind in retryableKinds) {
        expect(
          shouldRetryResolve(
            SourceFailure(kind: kind, message: 'x', retryable: true),
          ),
          isTrue,
          reason: kind.name,
        );
      }

      const terminalKinds = [
        FailureKind.notFound,
        FailureKind.unsupported,
        FailureKind.unauthorized,
        FailureKind.cancelled,
        FailureKind.playback,
        FailureKind.unknown,
      ];
      for (final kind in terminalKinds) {
        expect(
          shouldRetryResolve(
            SourceFailure(kind: kind, message: 'x', retryable: true),
          ),
          isFalse,
          reason: kind.name,
        );
      }

      expect(
        shouldRetryResolve(
          const SourceFailure(kind: FailureKind.network, message: 'x'),
        ),
        isFalse,
        reason: '调用方已标记不可重试时不再重试',
      );
    });

    test('resolveRetryDelay：约 300ms ±30%，按尝试序号增长', () {
      for (var seed = 0; seed < 32; seed++) {
        final delay = resolveRetryDelay(1, random: math.Random(seed));
        expect(delay.inMilliseconds, inInclusiveRange(209, 391));
      }
      expect(
        resolveRetryDelay(2, random: math.Random(0)).inMilliseconds,
        greaterThan(300),
      );
    });
  });

  group('取链指标', () {
    test('缓存命中与成功次数：第二次 resolve 不再真实取链', () async {
      final metrics = ResolveMetrics();
      final source = _FakeMusicSource('kw');
      final registry = _FakeRegistry({'kw': source});
      addTearDown(registry.dispose);
      final service = CatalogService(registry: registry, metrics: metrics);
      final track = _track('kw', 'a');

      await service.resolve(track);
      await service.resolve(track);

      final snapshot = metrics.snapshot();
      expect(snapshot.calls, 2);
      expect(snapshot.cacheHits, 1);
      expect(snapshot.successes, 1, reason: '缓存命中不重复计成功');
      expect(snapshot.failures, 0);
      expect(snapshot.retries, 0);
      expect(source.resolveCalls, 1);
    });

    test('可重试失败重试成功：只记一次成功 + 一次重试', () async {
      final metrics = ResolveMetrics();
      final source = _FakeMusicSource('kw')
        ..resolveError = const SourceFailure(
          kind: FailureKind.network,
          message: 'boom',
          retryable: true,
        )
        ..resolveErrorTimes = 1;
      final registry = _FakeRegistry({'kw': source});
      addTearDown(registry.dispose);
      final service = CatalogService(
        registry: registry,
        metrics: metrics,
        resolveRetryDelay: (_) => Duration.zero,
      );

      await service.resolve(_track('kw', 'a'));

      final snapshot = metrics.snapshot();
      expect(snapshot.calls, 1);
      expect(snapshot.retries, 1);
      expect(snapshot.successes, 1);
      expect(snapshot.failures, 0, reason: '重试后成功不算失败');
      expect(source.resolveCalls, 2);
    });

    test('不可重试失败按类别记一次（notFound，无重试）', () async {
      final metrics = ResolveMetrics();
      final source = _FakeMusicSource('kw')
        ..resolveError = const SourceFailure(
          kind: FailureKind.notFound,
          message: '没有该档位',
        );
      final registry = _FakeRegistry({'kw': source});
      addTearDown(registry.dispose);
      final service = CatalogService(registry: registry, metrics: metrics);

      await expectLater(
        service.resolve(_track('kw', 'a')),
        throwsA(isA<SourceFailure>()),
      );

      final snapshot = metrics.snapshot();
      expect(snapshot.calls, 1);
      expect(snapshot.retries, 0);
      expect(snapshot.successes, 0);
      expect(snapshot.failures, 1);
      expect(snapshot.failuresByKind[FailureKind.notFound], 1);
      expect(snapshot.timeouts, 0);
    });

    test('预算硬截止记 timeout 与 timeout 类别失败', () async {
      final metrics = ResolveMetrics();
      final source = _FakeMusicSource('kw')
        ..resolveDelays.add(const Duration(seconds: 2));
      final registry = _FakeRegistry({'kw': source});
      addTearDown(registry.dispose);
      final service = CatalogService(
        registry: registry,
        metrics: metrics,
        resolveBudget: const Duration(milliseconds: 200),
        // 退避本身就超过剩余预算：只走一次预算兜底，计数可精确断言
        // （零退避时机器负载可能让第二次尝试拿到毫秒级剩余预算）。
        resolveRetryDelay: (_) => const Duration(seconds: 1),
      );

      await expectLater(
        service.resolve(_track('kw', 'a')),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.timeout,
          ),
        ),
      );

      final snapshot = metrics.snapshot();
      expect(snapshot.timeouts, 1, reason: '预算兜底超时单独计数');
      expect(snapshot.retries, 0, reason: '退避已超预算，不再重试');
      expect(snapshot.failures, 1);
      expect(snapshot.failuresByKind[FailureKind.timeout], 1);
    });

    test('同 key 并发取链合并：入口数 > 真实取链数', () async {
      final metrics = ResolveMetrics();
      final source = _FakeMusicSource('kw')
        ..resolveDelays.add(const Duration(milliseconds: 50));
      final registry = _FakeRegistry({'kw': source});
      addTearDown(registry.dispose);
      final service = CatalogService(registry: registry, metrics: metrics);
      final track = _track('kw', 'a');

      final first = service.resolve(track);
      final second = service.resolve(track);
      await Future.wait([first, second]);

      final snapshot = metrics.snapshot();
      expect(snapshot.calls, 2);
      expect(snapshot.cacheHits, 1, reason: '在途条目也算命中（单飞等待）');
      expect(snapshot.successes, 1, reason: '一次真实取链只记一次成功');
      expect(source.resolveCalls, 1);
    });
  });
}
