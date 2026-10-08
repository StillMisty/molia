import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/cache/request_cache.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart';
import 'package:molia/domain/ports/source_registry.dart';
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
  int resolveCalls = 0;
  Object? searchError;
  Object? resolveError;

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
  Future<PlayableStream> resolve(
    Track track, {
    AudioQuality? preferredQuality,
  }) async {
    resolveCalls++;
    final error = resolveError;
    if (error != null) throw error;
    return PlayableStream(
      Uri.parse('https://cdn.example/$key/${track.id.id}'
          '${preferredQuality == null ? '' : '?q=${preferredQuality.type}'}'),
    );
  }

  @override
  Future<LyricsDoc?> lyrics(Track track) async => null;

  @override
  Future<Artwork?> artwork(Track track) async => null;

  @override
  Future<CollectionPage> collection(
    CollectionRef ref, {
    int page = 1,
    int limit = 50,
  }) async =>
      const CollectionPage();

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

  test('search：同 key 命中缓存；page/keyword 变化各自独立', () async {
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);

    final query = const SearchQuery(keyword: 'hello', page: 1, limit: 30);
    final first = await service.search('kw', query);
    final second = await service.search('kw', query);
    expect(source.searchCalls, 1, reason: '同 key 第二次应命中缓存');
    expect(second, first);

    await service.search('kw', const SearchQuery(keyword: 'hello', page: 2));
    expect(source.searchCalls, 2);

    await service.search('kw', const SearchQuery(keyword: 'world', page: 2));
    expect(source.searchCalls, 3);

    expect(first.total, 42);
    expect(first.hasMore, isTrue);
    expect(first.items.single.id, const TrackId('kw', 'hello-p1'));
  });

  test('search：并发同 key 单飞（只执行一次）', () async {
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);

    const query = SearchQuery(keyword: 'same');
    final results = await Future.wait([
      service.search('kw', query),
      service.search('kw', query),
      service.search('kw', query),
    ]);
    expect(source.searchCalls, 1);
    expect(results[1], results[0]);
    expect(results[2], results[0]);
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

  test('resolve：同曲同音质第二次命中缓存（0 次引擎调用）', () async {
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': source});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);

    final track = _track('kw', 'a');
    const quality = AudioQuality(type: '320k');
    final first = await service.resolve(track, quality: quality);
    final second = await service.resolve(track, quality: quality);

    expect(source.resolveCalls, 1, reason: '第二次应命中 resolve 缓存');
    expect(second, first);
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

    expect(CatalogService.resolveCacheKey(a, null),
        CatalogService.resolveCacheKey(b, null),
        reason: 'Map 键序不同但内容相同 → 同一 key');
    expect(CatalogService.resolveCacheKey(a, null), startsWith('url:kw:'));
    expect(CatalogService.resolveCacheKey(a, null), endsWith(':auto'));
    expect(
      CatalogService.resolveCacheKey(a, const AudioQuality(type: '320k')),
      isNot(CatalogService.resolveCacheKey(
          a, const AudioQuality(type: '128k'))),
    );
    expect(
      CatalogService.resolveCacheKey(a, null),
      isNot(CatalogService.resolveCacheKey(
          Track(
            id: const TrackId('tx', 'a'),
            title: 't',
            origin: TrackOrigin.lx,
            payload: a.payload,
          ),
          null)),
    );
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
      throwsA(isA<SourceFailure>()
          .having((f) => f.kind, 'kind', FailureKind.scriptError)),
    );

    source.resolveError = null;
    final stream = await service.resolve(track);
    expect(stream.uri.toString(), 'https://cdn.example/kw/a');
    expect(source.resolveCalls, 2, reason: '失败不缓存，第二次重新取链');
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
      throwsA(isA<SourceFailure>()
          .having((f) => f.kind, 'kind', FailureKind.unknown)
          .having((f) => f.retryable, 'retryable', isFalse)),
    );

    source.searchError = null;
    final result = await service.search('kw', query);
    expect(result.items, isNotEmpty);
    expect(source.searchCalls, 2, reason: '失败不缓存，第二次重新搜索');
  });

  test('resolve：未知音源抛 StateError', () async {
    final registry = _FakeRegistry({});
    addTearDown(registry.dispose);
    final service = CatalogService(registry: registry);

    await expectLater(
      service.resolve(_track('nope', 'a')),
      throwsStateError,
    );
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
}
