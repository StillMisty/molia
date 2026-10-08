import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/playback/default_playback_facade.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/source.dart' as domain;
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart';
import 'package:molia/domain/ports/playback_backend.dart';
import 'package:molia/domain/ports/source_registry.dart';
import 'package:molia/domain/ports/state_listenable.dart';
import 'package:molia/domain/ports/ui_messenger.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/search_provider.dart';
import 'package:molia/sources/source_manager.dart' show SourceKind;
import 'package:molia/sources/source_track.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestListenable<T> extends ValueNotifier<T> implements StateListenable<T> {
  _TestListenable(super.value);
}

class _FakeBackend implements PlaybackBackend {
  final _TestListenable<BackendSnapshot> _notifier =
      _TestListenable(BackendSnapshot.empty);

  PlaybackRequest? lastRequest;

  @override
  PlaybackBackendKind get kind => PlaybackBackendKind.local;

  @override
  PlaybackCapabilities get capabilities => const PlaybackCapabilities();

  @override
  bool canHandle(Track track) => true;

  @override
  StateListenable<BackendSnapshot> get state => _notifier;

  @override
  Future<void> load(PlaybackRequest request) async => lastRequest = request;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> next() async {}

  @override
  Future<void> previous() async {}

  @override
  Future<void> setMode(PlayMode mode) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> playQueueIndex(int index) async {}

  @override
  Future<bool> toggleFavorite(Track track) async => false;

  @override
  Future<void> setVolume(double value) async {}
}

class _FakeMessenger implements UiMessenger {
  @override
  void showMessage(String message) {}

  @override
  void showFailure(SourceFailure failure) {}
}

class _FakeMusicSource implements MusicSource {
  _FakeMusicSource(this.key);

  @override
  final String key;

  int searchCalls = 0;
  Object? searchError;
  Future<SearchResult<Track>> Function(SearchQuery query)? onSearch;

  @override
  String get displayName => key;

  @override
  domain.SourceCapabilities get capabilities =>
      const domain.SourceCapabilities(search: true, pagination: true);

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
    if (searchError != null) throw searchError!;
    final handler = onSearch;
    if (handler != null) return handler(query);
    return SearchResult(items: [_track(key, '${query.keyword}-${query.page}')]);
  }

  @override
  Future<PlayableStream> resolve(
    Track track, {
    AudioQuality? preferredQuality,
  }) async =>
      PlayableStream(Uri.parse('https://cdn.example/${track.id.uri}'));

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
  _FakeRegistry(this._sources, this._descriptors);

  final Map<String, MusicSource> _sources;
  List<domain.SourceDescriptor> _descriptors;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  void setDescriptors(List<domain.SourceDescriptor> descriptors) {
    _descriptors = descriptors;
    _changes.add(null);
  }

  @override
  List<domain.SourceDescriptor> get descriptors => _descriptors;

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

domain.SourceDescriptor _descriptor(
  String key,
  String name, {
  domain.SourceKind kind = domain.SourceKind.builtin,
}) =>
    domain.SourceDescriptor(
      key: key,
      displayName: name,
      kind: kind,
      capabilities: const domain.SourceCapabilities(
        search: true,
        pagination: true,
        resolveUrl: true,
      ),
    );

Track _track(String sourceKey, String id) => Track(
      id: TrackId(sourceKey, id),
      title: 'Title $id',
      artists: [Artist(name: 'Artist $id')],
      album: 'Album',
      duration: const Duration(seconds: 30),
      artwork: Artwork(uri: Uri.parse('https://img.example/$id.jpg')),
      origin: TrackOrigin.lx,
      qualities: const [AudioQuality(type: '320k')],
      payload: {'songmid': id, 'id': id},
    );

Future<void> _waitUntil(bool Function() predicate) async {
  for (var i = 0; i < 100 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(predicate(), isTrue, reason: '等待条件超时');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeBackend backend;
  late PlaybackProvider playbackProvider;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = _FakeBackend();
    playbackProvider = PlaybackProvider(
      facade: DefaultPlaybackFacade(backend: backend),
      messenger: _FakeMessenger(),
    );
  });

  tearDown(() {
    playbackProvider.dispose();
  });

  SearchProvider buildProvider(_FakeRegistry registry) {
    final provider = SearchProvider(
      playbackProvider,
      catalogService: CatalogService(registry: registry),
      sourceRegistry: registry,
    );
    addTearDown(provider.dispose);
    return provider;
  }

  test('sourceOptions 由 registry.descriptors 映射，默认选中第一个可用源', () {
    final registry = _FakeRegistry(
      {'kw': _FakeMusicSource('kw'), 'tx': _FakeMusicSource('tx')},
      [
        _descriptor('kw', '酷我'),
        _descriptor('tx', 'QQ音乐', kind: domain.SourceKind.lx),
      ],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    final options = provider.sourceOptions;
    expect(options.map((o) => o.key), ['kw', 'tx']);
    expect(options.map((o) => o.name), ['酷我', 'QQ音乐']);
    expect(options.map((o) => o.kind), [SourceKind.builtin, SourceKind.lx]);
    expect(options.every((o) => o.canSearch), isTrue);

    expect(provider.sourceKey, 'kw');
    expect(provider.hasSelectedSource, isTrue);
    expect(provider.sourceDisplayName, '酷我');
  });

  test('performSearch：结果兼容 map + _sourceTracks 旁路 + 分页元数据', () async {
    final source = _FakeMusicSource('kw')
      ..onSearch = (query) => Future.value(SearchResult(
            items: [_track('kw', 'a'), _track('kw', 'b')],
            hasMore: true,
            total: 100,
          ));
    final registry = _FakeRegistry(
      {'kw': source},
      [_descriptor('kw', '酷我')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(() => !provider.isSearching);

    expect(source.searchCalls, 1);
    expect(provider.currentPage, 1);
    expect(provider.hasMore, isTrue);
    expect(provider.totalResults, 100);

    final tracks = provider.searchResults['tracks']!;
    expect(tracks, hasLength(2));
    expect(tracks.first['id'], 'kw:a');
    expect(tracks.first['name'], 'Title a');
    expect(tracks.first['source'], 'kw');
    expect(tracks.first['duration_ms'], 30000);
    expect(tracks.first['images'], [
      {'url': 'https://img.example/a.jpg'}
    ]);
    expect(tracks.first['artists'], [
      {'name': 'Artist a'}
    ]);

    final filtered = provider.filteredResults;
    expect(filtered, hasLength(2));
    expect(filtered.first['type'], 'track');
    expect(filtered.first['_sourceTrack'], isA<SourceTrack>());
  });

  test('搜索缓存：同 query 重复提交只请求一次', () async {
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry(
      {'kw': source},
      [_descriptor('kw', '酷我')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(() => !provider.isSearching);
    provider.submitSearch('hello');
    await _waitUntil(() => !provider.isSearching);

    expect(source.searchCalls, 1, reason: 'CatalogService 缓存命中');
    expect(provider.searchResults['tracks'], hasLength(1));
  });

  test('loadMore：跨页去重、currentPage/hasMore/total 更新', () async {
    final source = _FakeMusicSource('kw')
      ..onSearch = (query) => Future.value(query.page == 1
          ? SearchResult(
              items: [_track('kw', 'a'), _track('kw', 'b')],
              hasMore: true,
              total: 4,
            )
          : SearchResult(
              items: [_track('kw', 'b'), _track('kw', 'c')],
              hasMore: false,
              total: 4,
            ));
    final registry = _FakeRegistry(
      {'kw': source},
      [_descriptor('kw', '酷我')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(() => !provider.isSearching);

    await provider.loadMore();
    expect(provider.currentPage, 2);
    expect(provider.hasMore, isFalse);
    expect(provider.totalResults, 4);
    final ids = provider.searchResults['tracks']!.map((t) => t['id']).toList();
    expect(ids, ['kw:a', 'kw:b', 'kw:c'], reason: 'b 为跨页重复，应去重');
    expect(source.searchCalls, 2);
  });

  test('搜索失败：errorMessage 保持 Search failed 兼容格式', () async {
    final source = _FakeMusicSource('kw')..searchError = StateError('boom');
    final registry = _FakeRegistry(
      {'kw': source},
      [_descriptor('kw', '酷我')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(() => !provider.isSearching);

    expect(provider.errorMessage, contains('Search failed'));
    expect(provider.errorMessage, contains('boom'));
    expect(provider.failure, isNotNull);
    expect(provider.failure!.kind, FailureKind.unknown,
        reason: 'StateError 归一化为 unknown');
    expect(provider.failure!.retryable, isFalse);
    expect(provider.searchResults, isEmpty);
    expect(provider.filteredResults, isEmpty);
  });

  test('playItem：_sourceTracks 交给 PlaybackProvider，payload 原样保留', () async {
    final source = _FakeMusicSource('kw')
      ..onSearch = (query) => Future.value(SearchResult(
            items: [_track('kw', 'a'), _track('kw', 'b')],
          ));
    final registry = _FakeRegistry(
      {'kw': source},
      [_descriptor('kw', '酷我')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(() => !provider.isSearching);

    provider.playItem(provider.filteredResults[1]);
    final request = backend.lastRequest;
    expect(request, isNotNull);
    expect(request!.startIndex, 1);
    expect(request.tracks, hasLength(2));
    expect(request.tracks[1].id, const TrackId('kw', 'b'));
    expect(request.tracks[1].payload['songmid'], 'b');
    expect(request.tracks[1].qualities.single.type, '320k');
    expect(request.context?.name, '酷我');
  });

  test('registry 变更：当前源失效回退到第一个；无源则清空', () async {
    final registry = _FakeRegistry(
      {'kw': _FakeMusicSource('kw'), 'tx': _FakeMusicSource('tx')},
      [_descriptor('kw', '酷我'), _descriptor('tx', 'QQ音乐')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    expect(provider.sourceKey, 'kw');

    registry.setDescriptors([_descriptor('tx', 'QQ音乐')]);
    await _waitUntil(() => provider.sourceKey == 'tx');
    expect(provider.searchResults, isEmpty);

    registry.setDescriptors([]);
    await _waitUntil(() => provider.sourceKey.isEmpty);
    expect(provider.hasSelectedSource, isFalse);
    expect(provider.sourceOptions, isEmpty);
  });

  test('无音源（未注入 service/registry）：空态行为不变', () async {
    final provider = SearchProvider(playbackProvider);
    addTearDown(provider.dispose);

    expect(provider.sourceOptions, isEmpty);
    expect(provider.hasSelectedSource, isFalse);

    provider.submitSearch('hello');
    await _waitUntil(() => !provider.isSearching);
    expect(provider.searchResults, isEmpty);
    expect(provider.errorMessage, isNull);
  });
}
