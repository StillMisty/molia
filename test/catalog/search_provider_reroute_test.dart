import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/settings/settings_access.dart';
import 'package:molia/data/settings/settings_keys.dart';
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
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';
import '../support/settings_test_support.dart';

class _TestListenable<T> extends ValueNotifier<T>
    implements StateListenable<T> {
  _TestListenable(super.value);
}

class _FakeBackend implements PlaybackBackend {
  final _TestListenable<BackendSnapshot> _notifier = _TestListenable(
    BackendSnapshot.empty,
  );

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
  Future<bool> moveQueueIndex(int from, int to) async => false;

  @override
  Future<bool> removeQueueIndex(int index) async => false;

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
  Future<void> setCurrentQuality(String quality) async {}

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

  static const _searchOnly = domain.SourceCapabilities(
    search: true,
    pagination: true,
  );

  @override
  final String key;

  @override
  final domain.SourceCapabilities capabilities;

  int searchCalls = 0;
  int artistSearchCalls = 0;
  int lyricSearchCalls = 0;
  final List<int> searchedPages = [];
  Object? searchError;
  Object? artistSearchError;
  Object? lyricSearchError;
  Future<SearchResult<Track>> Function(SearchQuery query)? onSearch;
  Future<SearchResult<ArtistSummary>> Function(SearchQuery query)?
  onSearchArtists;
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
    searchedPages.add(query.page);
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
    final handler = onSearchArtists;
    if (handler != null) return handler(query);
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
  }) async => PlayableStream(Uri.parse('https://cdn.example/${track.id.uri}'));

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
  Set<String> get enabledChannelKeys => {
    for (final descriptor in _descriptors)
      if (descriptor.enabled) descriptor.key,
  };

  @override
  List<String> get orderedChannelKeys => [
    for (final descriptor in _descriptors) descriptor.key,
  ];

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
  domain.SourceCapabilities? capabilities,
}) => domain.SourceDescriptor(
  key: key,
  displayName: name,
  kind: kind,
  capabilities:
      capabilities ??
      const domain.SourceCapabilities(
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
  for (var i = 0; i < 500 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(predicate(), isTrue, reason: '等待条件超时');
}

SearchSourceGroup<SearchRow> _songGroup(SearchProvider provider, String key) =>
    provider.songGroups.firstWhere((group) => group.source.key == key);

SearchSourceGroup<ArtistSummary> _artistGroup(
  SearchProvider provider,
  String key,
) => provider.artistGroups.firstWhere((group) => group.source.key == key);

SearchSourceGroup<SearchRow> _lyricGroup(SearchProvider provider, String key) =>
    provider.lyricGroups.firstWhere((group) => group.source.key == key);

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

  SearchProvider buildProvider(
    _FakeRegistry registry, {
    SettingsAccess? settings,
  }) {
    final provider = SearchProvider(
      playbackProvider,
      catalogService: CatalogService(registry: registry),
      sourceRegistry: registry,
      settings: settings,
    );
    addTearDown(provider.dispose);
    return provider;
  }

  test('sourceChannels 直接是 registry.descriptors，默认「全部来源」', () {
    final registry = _FakeRegistry(
      {'kw': _FakeMusicSource('kw'), 'tx': _FakeMusicSource('tx')},
      [
        _descriptor('kw', '酷我'),
        _descriptor('tx', 'QQ音乐', kind: domain.SourceKind.lx),
      ],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    final options = provider.sourceChannels;
    expect(identical(options, registry.descriptors), isTrue);
    expect(options.map((o) => o.key), ['kw', 'tx']);
    expect(provider.sourceFilter, isEmpty, reason: '默认全部来源');
    expect(provider.sourceFilterOptions.map((o) => o.key), ['kw', 'tx']);
    expect(provider.hasSearchableSources, isTrue);
  });

  test('并行 fan-out：每个来源各取首屏，分组顺序 = descriptors 顺序', () async {
    final slow = Completer<SearchResult<Track>>();
    final kw = _FakeMusicSource('kw')
      ..onSearch = (query) =>
          Future.value(SearchResult(items: [_track('kw', 'a')], total: 1));
    final tx = _FakeMusicSource('tx')..onSearch = (query) => slow.future;
    final registry = _FakeRegistry(
      {'kw': kw, 'tx': tx},
      [_descriptor('tx', 'QQ音乐'), _descriptor('kw', '酷我')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    expect(kw.searchCalls, 1);
    expect(tx.searchCalls, 1, reason: '两个来源首屏并行发起');
    await _waitUntil(() => _songGroup(provider, 'kw').items.isNotEmpty);

    expect(provider.isSearching, isTrue, reason: 'tx 仍在途');
    expect(provider.songGroups.map((g) => g.source.key), ['tx', 'kw']);
    expect(provider.songGroups.first.source.displayName, 'QQ音乐');
    expect(provider.songGroups.last.items.single.id.uri, 'kw:a');
    expect(provider.searchResults.map((row) => row.id.uri), ['kw:a']);

    slow.complete(SearchResult(items: [_track('tx', 'b')], total: 1));
    await _waitUntil(() => !provider.isSearching);
    expect(provider.songGroups.map((g) => g.source.key), ['tx', 'kw']);
    expect(provider.searchResults.map((row) => row.id.uri), ['tx:b', 'kw:a']);
  });

  test('单源失败隔离：一个平台失败不影响其它平台', () async {
    final broken = _FakeMusicSource('kw')..searchError = StateError('boom');
    final healthy = _FakeMusicSource('tx')
      ..onSearch = (query) =>
          Future.value(SearchResult(items: [_track('tx', 'ok')], total: 1));
    final registry = _FakeRegistry(
      {'kw': broken, 'tx': healthy},
      [_descriptor('kw', '酷我'), _descriptor('tx', 'QQ音乐')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(
      () =>
          _songGroup(provider, 'kw').failure != null &&
          _songGroup(provider, 'tx').items.isNotEmpty,
    );

    final failed = _songGroup(provider, 'kw');
    expect(failed.failure, isNotNull);
    expect(failed.failure!.message, contains('boom'));
    expect(failed.failure!.kind, FailureKind.unknown);
    expect(failed.items, isEmpty);
    expect(_songGroup(provider, 'tx').items, hasLength(1));
    expect(provider.searchResults, hasLength(1));
    expect(provider.isSearching, isFalse);
  });

  test('每来源独立分页 / 去重；一个来源到底不影响另一个', () async {
    final kw = _FakeMusicSource('kw')
      ..onSearch = (query) => Future.value(
        query.page == 1
            ? SearchResult(
                items: [_track('kw', 'a'), _track('kw', 'b')],
                hasMore: true,
                total: 4,
              )
            : SearchResult(
                items: [_track('kw', 'b'), _track('kw', 'c')],
                hasMore: false,
                total: 4,
              ),
      );
    final tx = _FakeMusicSource('tx')
      ..onSearch = (query) => Future.value(
        SearchResult(
          items: [_track('tx', 'x')],
          hasMore: query.page < 3,
          total: 3,
        ),
      );
    final registry = _FakeRegistry(
      {'kw': kw, 'tx': tx},
      [_descriptor('kw', '酷我'), _descriptor('tx', 'QQ音乐')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(
      () =>
          _songGroup(provider, 'kw').items.length == 2 &&
          _songGroup(provider, 'tx').items.length == 1,
    );
    expect(provider.songGroups.map((g) => g.page), [1, 1]);

    await provider.loadMore('kw');
    final kwGroup = _songGroup(provider, 'kw');
    expect(kwGroup.page, 2);
    expect(kwGroup.hasMore, isFalse);
    expect(kwGroup.total, 4);
    expect(kwGroup.items.map((row) => row.id.uri), ['kw:a', 'kw:b', 'kw:c']);
    expect(tx.searchCalls, 1, reason: '只加载被请求来源的下一页');
    expect(_songGroup(provider, 'tx').page, 1);

    // 已经到底：再次 loadMore 不再发请求。
    await provider.loadMore('kw');
    expect(kw.searchCalls, 2);
  });

  test('加载更多失败只置 loadMoreFailed，不写首屏 failure', () async {
    var failPage2 = true;
    final source = _FakeMusicSource('kw')
      ..onSearch = (query) async {
        if (query.page == 1) {
          return SearchResult(
            items: [_track('kw', 'a')],
            hasMore: true,
            total: 2,
          );
        }
        if (failPage2) {
          throw const SourceFailure(
            kind: FailureKind.network,
            message: 'page2 boom',
          );
        }
        return SearchResult(
          items: [_track('kw', 'b')],
          hasMore: false,
          total: 2,
        );
      };
    final registry = _FakeRegistry({'kw': source}, [_descriptor('kw', '酷我')]);
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(() => _songGroup(provider, 'kw').items.isNotEmpty);
    expect(_songGroup(provider, 'kw').failure, isNull);

    await provider.loadMore('kw');
    var group = _songGroup(provider, 'kw');
    expect(group.loadMoreFailed, isTrue);
    expect(group.failure, isNull, reason: '追加页失败不是首屏失败');
    expect(group.page, 1);
    expect(group.items.map((row) => row.id.uri), ['kw:a']);

    failPage2 = false;
    await provider.retry('kw');
    group = _songGroup(provider, 'kw');
    expect(group.loadMoreFailed, isFalse);
    expect(group.failure, isNull);
    expect(group.page, 2);
    expect(group.items.map((row) => row.id.uri), ['kw:a', 'kw:b']);
  });

  test('查询期间新来源加入 → 自动补搜（启动时脚本晚加载的回归）', () async {
    final kw = _FakeMusicSource('kw')
      ..onSearch = (query) =>
          Future.value(SearchResult(items: [_track('kw', 'a')], total: 1));
    final tx = _FakeMusicSource('tx')
      ..onSearch = (query) =>
          Future.value(SearchResult(items: [_track('tx', 'b')], total: 1));
    final registry = _FakeRegistry(
      {'kw': kw, 'tx': tx},
      [_descriptor('kw', '酷我')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(() => !provider.isSearching);
    expect(provider.songGroups.map((g) => g.source.key), ['kw']);
    expect(tx.searchCalls, 0);

    registry.setDescriptors([
      _descriptor('kw', '酷我'),
      _descriptor('tx', 'QQ音乐'),
    ]);
    await _waitUntil(
      () =>
          provider.songGroups.length == 2 &&
          _songGroup(provider, 'tx').items.isNotEmpty,
    );
    expect(tx.searchCalls, 1, reason: '新来源按当前关键词补首屏');
    expect(provider.songGroups.map((g) => g.source.key), ['kw', 'tx']);
  });

  test('新来源只补搜当前类型；切换类型时再补其它类型', () async {
    final capabilities = const domain.SourceCapabilities(
      search: true,
      pagination: true,
      artist: true,
      lyricSearch: true,
    );
    final kw = _FakeMusicSource('kw', capabilities: capabilities);
    final tx = _FakeMusicSource('tx', capabilities: capabilities);
    final registry = _FakeRegistry(
      {'kw': kw, 'tx': tx},
      [_descriptor('kw', '酷我', capabilities: capabilities)],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(() => !provider.isSearching);
    provider.selectSearchKind(SearchKind.artist);
    await _waitUntil(() => _artistGroup(provider, 'kw').items.isNotEmpty);

    registry.setDescriptors([
      _descriptor('kw', '酷我', capabilities: capabilities),
      _descriptor('tx', 'QQ音乐', capabilities: capabilities),
    ]);
    await _waitUntil(
      () => provider.artistGroups.any(
        (group) => group.source.key == 'tx' && group.items.isNotEmpty,
      ),
    );
    expect(tx.artistSearchCalls, 1, reason: '当前类型（歌手）补首屏');
    expect(tx.searchCalls, 0, reason: '不在当前类型的单曲不补搜');
    expect(tx.lyricSearchCalls, 0, reason: '不在当前类型的歌词不补搜');

    provider.selectSearchKind(SearchKind.lyric);
    await _waitUntil(
      () => provider.lyricGroups.any(
        (group) => group.source.key == 'tx' && group.items.isNotEmpty,
      ),
    );
    expect(tx.lyricSearchCalls, 1, reason: '切到歌词后再补该类型');
    expect(tx.searchCalls, 0, reason: '单曲仍不补搜');
    expect(tx.artistSearchCalls, 1, reason: '歌手不重复请求');
  });

  test('渠道排序变化立即跟随；descriptors 未变化不重发请求', () async {
    final kw = _FakeMusicSource('kw');
    final tx = _FakeMusicSource('tx');
    final registry = _FakeRegistry(
      {'kw': kw, 'tx': tx},
      [_descriptor('kw', '酷我'), _descriptor('tx', 'QQ音乐')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(() => !provider.isSearching);
    expect(kw.searchCalls, 1);
    expect(tx.searchCalls, 1);

    registry.setDescriptors([
      _descriptor('tx', 'QQ音乐'),
      _descriptor('kw', '酷我'),
    ]);
    await _waitUntil(() => provider.songGroups.first.source.key == 'tx');
    expect(provider.songGroups.map((g) => g.source.key), ['tx', 'kw']);
    expect(kw.searchCalls, 1, reason: '同一来源会话保留');
    expect(tx.searchCalls, 1);

    registry.setDescriptors([
      _descriptor('tx', 'QQ音乐'),
      _descriptor('kw', '酷我'),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(kw.searchCalls, 1);
    expect(tx.searchCalls, 1);
  });

  test('来源移除：分组与会话一起移除，其它来源保留', () async {
    final kw = _FakeMusicSource('kw');
    final tx = _FakeMusicSource('tx');
    final registry = _FakeRegistry(
      {'kw': kw, 'tx': tx},
      [_descriptor('kw', '酷我'), _descriptor('tx', 'QQ音乐')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(() => provider.songGroups.length == 2);

    registry.setDescriptors([_descriptor('kw', '酷我')]);
    await _waitUntil(() => provider.songGroups.length == 1);
    expect(provider.songGroups.single.source.key, 'kw');
    expect(provider.searchResults, hasLength(1));
  });

  test('来源过滤只过滤已加载分组，不重发请求', () async {
    final kw = _FakeMusicSource('kw');
    final tx = _FakeMusicSource('tx');
    final registry = _FakeRegistry(
      {'kw': kw, 'tx': tx},
      [_descriptor('kw', '酷我'), _descriptor('tx', 'QQ音乐')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(() => !provider.isSearching);
    expect(provider.songGroups, hasLength(2));

    provider.selectSourceFilter('tx');
    await Future<void>.delayed(Duration.zero);
    expect(provider.sourceFilter, 'tx');
    expect(provider.songGroups.map((g) => g.source.key), ['tx']);
    expect(provider.searchResults.map((row) => row.id.uri), ['tx:hello-1']);
    expect(kw.searchCalls, 1, reason: '过滤不重发');
    expect(tx.searchCalls, 1);

    provider.selectSourceFilter('');
    expect(provider.songGroups, hasLength(2));
  });

  test('过滤偏好持久化恢复；远端 reload 同步过滤值', () async {
    final registry = _FakeRegistry(
      {'kw': _FakeMusicSource('kw'), 'tx': _FakeMusicSource('tx')},
      [_descriptor('kw', '酷我'), _descriptor('tx', 'QQ音乐')],
    );
    addTearDown(registry.dispose);
    final settings = testSettingsRegistry();
    await settings.write(kSearchSourceFilter, 'tx');

    final provider = buildProvider(registry, settings: settings);
    await _waitUntil(() => provider.sourceFilter == 'tx');
    expect(provider.sourceFilter, 'tx');

    await settings.write(kSearchSourceFilter, 'kw');
    // 同步适配器应用远端值后经组合根触发 reload 钩子。
    await settings.reloadKeys([kSearchSourceFilter.name]);
    await _waitUntil(() => provider.sourceFilter == 'kw');
    expect(provider.sourceFilter, 'kw');
  });

  test('reload 在途时手动过滤不会被晚到旧值覆盖', () async {
    final registry = _FakeRegistry(
      {'kw': _FakeMusicSource('kw'), 'tx': _FakeMusicSource('tx')},
      [_descriptor('kw', '酷我'), _descriptor('tx', 'QQ音乐')],
    );
    addTearDown(registry.dispose);
    final settings = testSettingsRegistry();
    await settings.write(kSearchSourceFilter, 'tx');
    final provider = buildProvider(registry, settings: settings);
    await _waitUntil(() => provider.sourceFilter == 'tx');

    // 模拟远端写入「全部来源」并触发 reload；reload 在途时用户手动选 kw。
    await settings.write(kSearchSourceFilter, '');
    final pendingReload = settings.reloadKeys([kSearchSourceFilter.name]);
    provider.selectSourceFilter('kw');
    await pendingReload;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(provider.sourceFilter, 'kw', reason: '晚到的旧 reload 值不得覆盖用户选择');
  });

  test('selectSourceFilter 写入持久化（失败吞掉）', () async {
    final registry = _FakeRegistry(
      {'kw': _FakeMusicSource('kw')},
      [_descriptor('kw', '酷我')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry, settings: testSettingsRegistry());
    provider.selectSourceFilter('kw');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kSearchSourceFilter.name), 'kw');
  });

  test('类型切换只搜支持该类型的来源；能力位取来源并集', () async {
    final kw = _FakeMusicSource(
      'kw',
      capabilities: const domain.SourceCapabilities(
        search: true,
        pagination: true,
        artist: true,
        lyricSearch: true,
      ),
    );
    final script = _FakeMusicSource('script');
    final registry = _FakeRegistry(
      {'kw': kw, 'script': script},
      [
        _descriptor('kw', '酷我', capabilities: kw.capabilities),
        _descriptor('script', '脚本源'),
      ],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    expect(provider.supportedSearchKinds, [
      SearchKind.song,
      SearchKind.artist,
      SearchKind.lyric,
    ]);

    provider.submitSearch('周杰伦');
    await _waitUntil(() => !provider.isSearching);
    expect(kw.searchCalls, 1);
    expect(script.searchCalls, 1);

    provider.selectSearchKind(SearchKind.artist);
    await _waitUntil(() => _artistGroup(provider, 'kw').items.isNotEmpty);
    expect(kw.artistSearchCalls, 1);
    expect(script.artistSearchCalls, 0, reason: '脚本源无歌手能力，不参与');
    expect(provider.artistGroups.map((g) => g.source.key), ['kw']);
    // 分组元数据（总数 / 页码）来自该来源会话。
    final artistGroup = _artistGroup(provider, 'kw');
    expect(artistGroup.total, 42);
    expect(artistGroup.hasMore, isTrue);

    provider.selectSearchKind(SearchKind.lyric);
    await _waitUntil(() => _lyricGroup(provider, 'kw').items.isNotEmpty);
    expect(kw.lyricSearchCalls, 1);
    expect(script.lyricSearchCalls, 0);
    expect(_lyricGroup(provider, 'kw').items.single.lyricSnippet, '命中歌词 周杰伦');

    // 切回单曲命中已有会话，不重复请求。
    provider.selectSearchKind(SearchKind.song);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(kw.searchCalls, 1);
    expect(script.searchCalls, 1);
  });

  test('过滤到不支持当前类型的来源时临时按全部处理，切回恢复偏好', () async {
    final kw = _FakeMusicSource(
      'kw',
      capabilities: const domain.SourceCapabilities(
        search: true,
        pagination: true,
        artist: true,
      ),
    );
    final script = _FakeMusicSource('script');
    final registry = _FakeRegistry(
      {'kw': kw, 'script': script},
      [
        _descriptor('kw', '酷我', capabilities: kw.capabilities),
        _descriptor('script', '脚本源'),
      ],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('周杰伦');
    await _waitUntil(() => !provider.isSearching);
    provider.selectSourceFilter('script');
    expect(provider.sourceFilter, 'script');

    provider.selectSearchKind(SearchKind.artist);
    await _waitUntil(
      () => provider.artistGroups.any((g) => g.source.key == 'kw'),
    );
    expect(provider.sourceFilter, isEmpty, reason: '演员类型下 script 不支持');
    expect(provider.artistGroups.map((g) => g.source.key), ['kw']);
    expect(script.artistSearchCalls, 0);

    provider.selectSearchKind(SearchKind.song);
    expect(provider.sourceFilter, 'script', reason: '持久化偏好保留');
    expect(provider.songGroups.map((g) => g.source.key), ['script']);
  });

  test('retryFailed：只重试当前类型所有失败来源，互不阻塞', () async {
    var fail = true;
    final kw = _FakeMusicSource('kw')
      ..onSearch = (query) async {
        if (fail) {
          throw const SourceFailure(kind: FailureKind.network, message: 'kw');
        }
        return SearchResult(items: [_track('kw', 'ok')]);
      };
    final tx = _FakeMusicSource('tx')
      ..onSearch = (query) async {
        if (fail) {
          throw const SourceFailure(kind: FailureKind.timeout, message: 'tx');
        }
        return SearchResult(items: [_track('tx', 'ok')]);
      };
    final registry = _FakeRegistry(
      {'kw': kw, 'tx': tx},
      [_descriptor('kw', '酷我'), _descriptor('tx', 'QQ音乐')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(
      () =>
          _songGroup(provider, 'kw').failure != null &&
          _songGroup(provider, 'tx').failure != null,
    );
    expect(provider.songGroups.every((group) => group.failure != null), isTrue);

    fail = false;
    await provider.retryFailed();
    await _waitUntil(
      () =>
          _songGroup(provider, 'kw').items.isNotEmpty &&
          _songGroup(provider, 'tx').items.isNotEmpty,
    );
    expect(provider.songGroups.every((group) => group.failure == null), isTrue);
    expect(kw.searchCalls, 2);
    expect(tx.searchCalls, 2);
  });

  test('playItem：队列只取该行所属来源，contextName = 来源展示名', () async {
    final kw = _FakeMusicSource('kw')
      ..onSearch = (query) => Future.value(
        SearchResult(items: [_track('kw', 'a'), _track('kw', 'b')]),
      );
    final tx = _FakeMusicSource('tx')
      ..onSearch = (query) => Future.value(
        SearchResult(items: [_track('tx', 'x'), _track('tx', 'y')]),
      );
    final registry = _FakeRegistry(
      {'kw': kw, 'tx': tx},
      [_descriptor('kw', '酷我'), _descriptor('tx', 'QQ音乐')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(
      () =>
          _songGroup(provider, 'kw').items.length == 2 &&
          _songGroup(provider, 'tx').items.length == 2,
    );

    final txGroup = _songGroup(provider, 'tx');
    provider.playItem(txGroup.items[1]);
    final request = backend.lastRequest!;
    expect(request.startIndex, 1);
    expect(request.context?.name, 'QQ音乐');
    expect(request.tracks.map((track) => track.id.uri), ['tx:x', 'tx:y']);
    expect(
      request.tracks.every((track) => track.id.sourceKey == 'tx'),
      isTrue,
      reason: '不混平台队列',
    );
    expect(identical(request.tracks[0], txGroup.items[0].track), isTrue);
  });

  test('releaseSearchResults：清空所有来源会话与片段，保留过滤偏好', () async {
    final kw = _FakeMusicSource(
      'kw',
      capabilities: const domain.SourceCapabilities(
        search: true,
        pagination: true,
        artist: true,
        lyricSearch: true,
      ),
    );
    final tx = _FakeMusicSource(
      'tx',
      capabilities: const domain.SourceCapabilities(
        search: true,
        pagination: true,
        lyricSearch: true,
      ),
    );
    final registry = _FakeRegistry(
      {'kw': kw, 'tx': tx},
      [
        _descriptor('kw', '酷我', capabilities: kw.capabilities),
        _descriptor('tx', 'QQ音乐', capabilities: tx.capabilities),
      ],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('周杰伦');
    await _waitUntil(() => !provider.isSearching);
    provider.selectSearchKind(SearchKind.artist);
    await _waitUntil(() => _artistGroup(provider, 'kw').items.isNotEmpty);
    provider.selectSearchKind(SearchKind.lyric);
    await _waitUntil(
      () =>
          _lyricGroup(provider, 'kw').items.isNotEmpty &&
          _lyricGroup(provider, 'tx').items.isNotEmpty,
    );
    provider.selectSourceFilter('tx');

    provider.releaseSearchResults();
    expect(provider.searchQuery, isEmpty);
    expect(provider.searchResults, isEmpty);
    expect(provider.artistResults, isEmpty);
    expect(provider.lyricResults, isEmpty);
    expect(provider.songGroups, isEmpty);
    expect(provider.artistGroups, isEmpty);
    expect(provider.lyricGroups, isEmpty);
    expect(provider.isSearching, isFalse);
    expect(provider.sourceFilter, 'tx', reason: '过滤偏好保留');
  });

  test('换词作废旧会话：旧查询晚到响应不写回新查询', () async {
    final oldGate = Completer<SearchResult<Track>>();
    final kw = _FakeMusicSource('kw')
      ..onSearch = (query) {
        if (query.keyword == '旧词') return oldGate.future;
        return Future.value(
          SearchResult(items: [_track('kw', 'new')], total: 1),
        );
      };
    final registry = _FakeRegistry({'kw': kw}, [_descriptor('kw', '酷我')]);
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('旧词');
    expect(provider.isSearching, isTrue);
    provider.submitSearch('新词');
    await _waitUntil(() => _songGroup(provider, 'kw').items.isNotEmpty);
    oldGate.complete(SearchResult(items: [_track('kw', 'old')], total: 1));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(_songGroup(provider, 'kw').items.single.id.uri, 'kw:new');
  });

  test('歌词片段按来源保存；换词清空，追加页同 id 后页覆盖', () async {
    final kw =
        _FakeMusicSource(
            'kw',
            capabilities: const domain.SourceCapabilities(
              search: true,
              pagination: true,
              lyricSearch: true,
            ),
          )
          ..onSearch = ((query) =>
              Future.value(SearchResult(items: [_track('kw', 's')])))
          ..onSearchLyrics = (query) async {
            if (query.keyword == '第二词') {
              return SearchResult(
                items: [LyricHit(track: _track('kw', 'fresh'), snippet: '新片段')],
              );
            }
            if (query.page == 1) {
              return SearchResult(
                items: [
                  LyricHit(track: _track('kw', 'a'), snippet: '第一页 A'),
                  LyricHit(track: _track('kw', 'b'), snippet: '第一页 B'),
                ],
                hasMore: true,
                total: 3,
              );
            }
            return SearchResult(
              items: [
                LyricHit(track: _track('kw', 'b'), snippet: '第二页 B'),
                LyricHit(track: _track('kw', 'c'), snippet: '第二页 C'),
              ],
              hasMore: false,
              total: 3,
            );
          };
    final tx =
        _FakeMusicSource(
            'tx',
            capabilities: const domain.SourceCapabilities(
              search: true,
              pagination: true,
              lyricSearch: true,
            ),
          )
          ..onSearchLyrics = (query) => Future.value(
            SearchResult(
              items: query.keyword == '歌词'
                  ? [LyricHit(track: _track('tx', 't'), snippet: 'TX 片段')]
                  : const [],
            ),
          );
    final registry = _FakeRegistry(
      {'kw': kw, 'tx': tx},
      [
        _descriptor('kw', '酷我', capabilities: kw.capabilities),
        _descriptor('tx', 'QQ音乐', capabilities: tx.capabilities),
      ],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('歌词');
    await _waitUntil(() => !provider.isSearching);
    provider.selectSearchKind(SearchKind.lyric);
    await _waitUntil(
      () =>
          _lyricGroup(provider, 'kw').items.length == 2 &&
          _lyricGroup(provider, 'tx').items.isNotEmpty,
    );
    expect(_lyricGroup(provider, 'kw').items.map((row) => row.lyricSnippet), [
      '第一页 A',
      '第一页 B',
    ]);
    expect(_lyricGroup(provider, 'tx').items.single.lyricSnippet, 'TX 片段');

    await provider.loadMore('kw');
    expect(_lyricGroup(provider, 'kw').items.map((row) => row.lyricSnippet), [
      '第一页 A',
      '第二页 B',
      '第二页 C',
    ]);

    provider.submitSearch('第二词');
    await _waitUntil(() => _lyricGroup(provider, 'kw').items.isNotEmpty);
    expect(_lyricGroup(provider, 'kw').items.single.lyricSnippet, '新片段');
    expect(
      provider.lyricGroups.any(
        (group) => group.items.any((row) => row.lyricSnippet == 'TX 片段'),
      ),
      isFalse,
      reason: '换词清空所有来源片段',
    );
  });

  test('防抖窗口：isSearchBusy 覆盖等待期，完成后只按最终来源请求一次', () {
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': source}, [_descriptor('kw', '酷我')]);
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    fakeAsync((async) {
      provider.updateSearchQuery('hello');
      expect(provider.isSearchPending, isTrue);
      expect(provider.isSearchBusy, isTrue);
      expect(provider.isSearching, isFalse);
      expect(provider.songGroups, isEmpty);

      async.elapse(const Duration(milliseconds: 299));
      expect(source.searchCalls, 0);
      expect(provider.isSearchBusy, isTrue, reason: '防抖等待期不能显示空结果');

      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(source.searchCalls, 1);
      expect(provider.isSearchBusy, isFalse);
      expect(provider.isSearchPending, isFalse);
      expect(provider.songGroups.single.items, isNotEmpty);
    });
  });

  test('防抖窗口内切换类型：计时器只按最终类型请求一次', () {
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
      [_descriptor('kw', '酷我', capabilities: source.capabilities)],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    fakeAsync((async) {
      provider.updateSearchQuery('hello');
      provider.selectSearchKind(SearchKind.artist);
      expect(provider.searchKind, SearchKind.artist);
      expect(provider.isSearchBusy, isTrue);
      expect(source.searchCalls, 0);
      expect(source.artistSearchCalls, 0);

      async.elapse(const Duration(milliseconds: 300));
      async.flushMicrotasks();
      expect(source.searchCalls, 0, reason: '旧类型不应先发一轮');
      expect(source.artistSearchCalls, 1, reason: '最终类型只请求一次');
      expect(provider.artistGroups.single.items, isNotEmpty);
    });
  });

  test('输入防抖 300ms：连续输入只发最后一次请求（每个来源各一次）', () {
    final kw = _FakeMusicSource('kw');
    final tx = _FakeMusicSource('tx');
    final registry = _FakeRegistry(
      {'kw': kw, 'tx': tx},
      [_descriptor('kw', '酷我'), _descriptor('tx', 'QQ音乐')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    fakeAsync((async) {
      provider.updateSearchQuery('a');
      async.elapse(const Duration(milliseconds: 200));
      provider.updateSearchQuery('ab');

      async.elapse(const Duration(milliseconds: 299));
      expect(kw.searchCalls, 0, reason: '防抖窗口内不应发请求');

      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(kw.searchCalls, 1);
      expect(tx.searchCalls, 1);
      expect(provider.searchQuery, 'ab');
    });
  });

  test('releaseSearchResults：取消待触发的防抖计时器', () {
    final kw = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': kw}, [_descriptor('kw', '酷我')]);
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    fakeAsync((async) {
      provider.updateSearchQuery('a');
      provider.releaseSearchResults();
      async.elapse(const Duration(seconds: 1));
      expect(kw.searchCalls, 0);
      expect(provider.searchQuery, isEmpty);
    });
  });

  test('无音源：空态行为不变', () async {
    final provider = SearchProvider(playbackProvider);
    addTearDown(provider.dispose);

    expect(provider.sourceChannels, isEmpty);
    expect(provider.hasSearchableSources, isFalse);
    expect(provider.sourceFilter, isEmpty);

    provider.submitSearch('hello');
    await _waitUntil(() => !provider.isSearching);
    expect(provider.searchResults, isEmpty);
    expect(provider.songGroups, isEmpty);
  });
}
