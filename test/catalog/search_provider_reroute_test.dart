import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/artist.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/comment.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/source.dart' as domain;
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart';
import 'package:molia/domain/ports/playback_backend.dart';
import 'package:molia/domain/ports/source_registry.dart';
import 'package:molia/domain/ports/state_listenable.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/search_provider.dart';
import 'package:molia/sources/source_manager.dart' show SourceKind;
import 'package:shared_preferences/shared_preferences.dart';
import '../support/fakes.dart';

class _TestListenable<T> extends ValueNotifier<T>
    implements StateListenable<T> {
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
  Stream<Track> get trackCompletions => const Stream.empty();

  @override
  void setStopAfterCurrentTrack(bool enabled) {}

  @override
  Future<void> enqueueTracks(List<Track> tracks) async {
    lastEnqueued = tracks;
  }

  List<Track>? lastEnqueued;

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

  @override
  Future<void> updateTrackArtwork(String trackUri, Uri? artwork) async {}

  @override
  Future<void> replaceQueueTrack(String trackUri, Track newTrack) async {}
}

class _FakeMusicSource implements MusicSource {
  _FakeMusicSource(this.key, {this.capabilities = _searchOnly});

  static const _searchOnly =
      domain.SourceCapabilities(search: true, pagination: true);

  @override
  final String key;

  @override
  final domain.SourceCapabilities capabilities;

  int searchCalls = 0;
  int artistSearchCalls = 0;
  int lyricSearchCalls = 0;
  Object? searchError;
  Object? artistSearchError;
  Object? lyricSearchError;
  Future<SearchResult<Track>> Function(SearchQuery query)? onSearch;
  Future<SearchResult<LyricHit>> Function(SearchQuery query)? onSearchLyrics;

  @override
  String get displayName => key;

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
  Future<SearchResult<ArtistSummary>> searchArtists(
    SearchQuery query, {
    CancelToken? cancel,
  }) async {
    artistSearchCalls++;
    if (artistSearchError != null) throw artistSearchError!;
    return SearchResult(
      items: [
        ArtistSummary(
          id: '${query.keyword}-a${query.page}',
          name: '歌手 ${query.keyword}',
        ),
      ],
      hasMore: true,
      total: 42,
    );
  }

  @override
  Future<SearchResult<LyricHit>> searchLyrics(
    SearchQuery query, {
    CancelToken? cancel,
  }) async {
    lyricSearchCalls++;
    if (lyricSearchError != null) throw lyricSearchError!;
    final handler = onSearchLyrics;
    if (handler != null) return handler(query);
    return SearchResult(
      items: [
        LyricHit(
          track: _track(
            key,
            '${query.keyword}-l${query.page}',
          ),
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
  }) async =>
      PlayableStream(Uri.parse('https://cdn.example/${track.id.uri}'));

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
  }) async =>
      CommentPage.fromPage(
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
    playbackProvider = buildTestPlaybackProvider(backend: backend);
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

  test('performSearch：typed 行 + 分页元数据', () async {
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

    final tracks = provider.searchResults;
    expect(tracks, hasLength(2));
    expect(tracks.first.id.uri, 'kw:a');
    expect(tracks.first.title, 'Title a');
    expect(tracks.first.duration, const Duration(seconds: 30));
    expect(tracks.first.coverUrl, 'https://img.example/a.jpg');
    expect(tracks.first.track.artists.single.name, 'Artist a');
    expect(tracks.first.lyricSnippet, isNull);

    final filtered = provider.filteredResults;
    expect(filtered, hasLength(2));
    expect(filtered, isNotEmpty);
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
    expect(provider.searchResults, hasLength(1));
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
    final ids = provider.searchResults.map((row) => row.id.uri).toList();
    expect(ids, ['kw:a', 'kw:b', 'kw:c'], reason: 'b 为跨页重复，应去重');
    expect(source.searchCalls, 2);
  });

  test('搜索失败：failure 归一化（kind/message），结果保留为空', () async {
    final source = _FakeMusicSource('kw')..searchError = StateError('boom');
    final registry = _FakeRegistry(
      {'kw': source},
      [_descriptor('kw', '酷我')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(() => !provider.isSearching);

    expect(provider.failure, isNotNull);
    expect(provider.failure!.message, contains('boom'),
        reason: '归一化后的 message 保留原始说明');
    expect(provider.failure!.kind, FailureKind.unknown,
        reason: 'StateError 归一化为 unknown');
    expect(provider.failure!.retryable, isFalse);
    expect(provider.searchResults, isEmpty);
    expect(provider.filteredResults, isEmpty);
  });

  test('playItem：SourceTrack 队列交给 PlaybackProvider，payload 原样保留', () async {
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

  test('搜索类型：能力位决定分段；不支持的类型切换被忽略', () async {
    final script = _FakeMusicSource('script');
    final registry = _FakeRegistry(
      {'kw': _FakeMusicSource('kw'), 'script': script},
      [_descriptor('kw', '酷我'), _descriptor('script', '脚本源')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    // kw 的音乐源能力位由 `_descriptor` 决定（无 artist）→ 只有单曲。
    expect(provider.searchKind, SearchKind.song);
    expect(provider.supportedSearchKinds, [SearchKind.song]);
    provider.selectSearchKind(SearchKind.artist);
    expect(provider.searchKind, SearchKind.song, reason: '不支持的类型忽略');
    expect(script.artistSearchCalls, 0);
  });

  test('歌手类型：切换触发独立搜索；分页 / 错误取当前类型视图', () async {
    final source = _FakeMusicSource(
      'kw',
      capabilities: const domain.SourceCapabilities(
        search: true,
        pagination: true,
        artist: true,
      ),
    );
    final registry = _FakeRegistry(
      {'kw': source},
      [_descriptor('kw', '酷我')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    expect(provider.supportedSearchKinds, [SearchKind.song, SearchKind.artist]);

    provider.submitSearch('周杰伦');
    await _waitUntil(() => !provider.isSearching);
    expect(provider.searchResults, isNotEmpty);

    provider.selectSearchKind(SearchKind.artist);
    await _waitUntil(
        () => !provider.isSearching && provider.artistResults.isNotEmpty);
    expect(source.artistSearchCalls, 1, reason: '切到歌手类型才发起歌手搜索');
    expect(provider.artistResults.single.name, '歌手 周杰伦');
    expect(provider.totalResults, 42, reason: '分页元数据取当前类型');
    expect(provider.hasMore, isTrue);

    // 切回单曲：命中已有结果，不重复请求。
    provider.selectSearchKind(SearchKind.song);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(source.searchCalls, 1);

    // 歌手类型加载下一页。
    provider.selectSearchKind(SearchKind.artist);
    await provider.loadMore();
    await _waitUntil(() => source.artistSearchCalls == 2);
    expect(provider.artistResults, hasLength(2));
  });

  test('歌手类型：换关键词清空会话，切回重新搜索', () async {
    final source = _FakeMusicSource(
      'kw',
      capabilities: const domain.SourceCapabilities(
        search: true,
        pagination: true,
        artist: true,
      ),
    );
    final registry = _FakeRegistry(
      {'kw': source},
      [_descriptor('kw', '酷我')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('周杰伦');
    await _waitUntil(() => !provider.isSearching);
    provider.selectSearchKind(SearchKind.artist);
    await _waitUntil(() => provider.artistResults.isNotEmpty);
    expect(source.artistSearchCalls, 1);

    // 歌手类型处于激活态时换词：直接按新关键词刷新（同一会话）。
    provider.submitSearch('温岚');
    await _waitUntil(() =>
        provider.artistResults.isNotEmpty &&
        provider.artistResults.single.name == '歌手 温岚');
    expect(source.artistSearchCalls, 2);

    // 切回单曲后换词：非激活类型的会话被清空，切回时重新搜索。
    provider.selectSearchKind(SearchKind.song);
    provider.submitSearch('林俊杰');
    await _waitUntil(() => !provider.isSearching);
    expect(provider.artistResults, isEmpty, reason: '换词清空非激活类型的会话');

    provider.selectSearchKind(SearchKind.artist);
    await _waitUntil(() => provider.artistResults.isNotEmpty);
    expect(source.artistSearchCalls, 3);
    expect(provider.artistResults.single.name, '歌手 林俊杰');
  });

  test('歌词类型：切换触发歌词搜索；片段随结果发布；播放队列取歌词列表', () async {
    final source = _FakeMusicSource(
      'kw',
      capabilities: const domain.SourceCapabilities(
        search: true,
        pagination: true,
        lyricSearch: true,
      ),
    );
    source.onSearch = (query) => Future.value(SearchResult(
          items: [_track('kw', 'a')],
          total: 1,
        ));
    source.onSearchLyrics = (query) => Future.value(SearchResult(
          items: [
            LyricHit(track: _track('kw', 'l1'), snippet: '雨下整夜'),
          ],
          total: 1,
        ));
    final registry = _FakeRegistry(
      {'kw': source},
      [_descriptor('kw', '酷我')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    expect(provider.supportedSearchKinds, [SearchKind.song, SearchKind.lyric]);

    provider.submitSearch('雨下整夜');
    await _waitUntil(() => !provider.isSearching);
    expect(source.lyricSearchCalls, 0, reason: '单曲类型不请求歌词搜索');

    provider.selectSearchKind(SearchKind.lyric);
    await _waitUntil(() => provider.lyricResults.isNotEmpty);
    expect(source.lyricSearchCalls, 1);
    expect(provider.lyricResults.single.lyricSnippet, '雨下整夜');
    expect(provider.lyricResults.single.title, 'Title l1');
    expect(provider.totalResults, 1, reason: '分页元数据取当前类型');

    // 播放：队列取歌词结果（下标与歌词列表一致），payload 原样保留。
    provider.playItem(provider.lyricResults.single);
    final request = backend.lastRequest;
    expect(request, isNotNull);
    expect(request!.startIndex, 0);
    expect(request.tracks.single.id.uri, 'kw:l1');
  });

  test('歌词类型：能力位不足时分段不出现且切换被忽略', () async {
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry(
      {'kw': source},
      [_descriptor('kw', '酷我')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    expect(provider.supportedSearchKinds, [SearchKind.song]);
    provider.selectSearchKind(SearchKind.lyric);
    expect(provider.searchKind, SearchKind.song);
    expect(source.lyricSearchCalls, 0);
  });

  test('歌手类型：换源后能力位不足时回退单曲', () async {
    final script = _FakeMusicSource('script');
    final registry = _FakeRegistry(
      {
        'kw': _FakeMusicSource(
          'kw',
          capabilities: const domain.SourceCapabilities(
            search: true,
            pagination: true,
            artist: true,
          ),
        ),
        'script': script,
      },
      [_descriptor('kw', '酷我'), _descriptor('script', '脚本源')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('周杰伦');
    await _waitUntil(() => !provider.isSearching);
    provider.selectSearchKind(SearchKind.artist);
    await _waitUntil(() => provider.artistResults.isNotEmpty);

    provider.selectSource('script');
    expect(provider.searchKind, SearchKind.song, reason: '换源回退单曲');
    expect(provider.supportedSearchKinds, [SearchKind.song]);
  });

  test('输入防抖 300ms：连续输入只发最后一次请求', () {
    final source = _FakeMusicSource('kw');
    SearchQuery? lastQuery;
    source.onSearch = (query) async {
      lastQuery = query;
      return SearchResult(items: [_track('kw', '1')]);
    };
    final registry = _FakeRegistry({'kw': source}, [_descriptor('kw', '酷我')]);
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    fakeAsync((async) {
      provider.updateSearchQuery('a');
      async.elapse(const Duration(milliseconds: 200));
      provider.updateSearchQuery('ab');

      async.elapse(const Duration(milliseconds: 299));
      expect(source.searchCalls, 0, reason: '防抖窗口内不应发请求');

      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(source.searchCalls, 1);
      expect(lastQuery?.keyword, 'ab');
      expect(provider.searchQuery, 'ab');
    });
  });

  test('无音源（未注入 service/registry）：空态行为不变', () async {
    final provider = SearchProvider(playbackProvider);
    addTearDown(provider.dispose);

    expect(provider.sourceOptions, isEmpty);
    expect(provider.hasSelectedSource, isFalse);

    provider.submitSearch('hello');
    await _waitUntil(() => !provider.isSearching);
    expect(provider.searchResults, isEmpty);
    expect(provider.failure, isNull);
  });
}
