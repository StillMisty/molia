import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show TextEditingController;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/artist.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/comment.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/source.dart' as domain;
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart';
import 'package:molia/domain/ports/source_registry.dart';
import 'package:molia/providers/channel_selection.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/search_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackFacade backend;
  late PlaybackProvider playbackProvider;
  late ChannelSelection selection;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakePlaybackFacade();
    playbackProvider = buildTestPlaybackProvider(facade: backend);
  });

  tearDown(() {
    playbackProvider.dispose();
  });

  /// 与生产组合根同形：搜索只读一个 ChannelSelection；默认仍取第一个可
  /// 搜索渠道（都不支持搜索时退回第一个描述）。
  SearchProvider buildProvider(_FakeRegistry registry) {
    selection = ChannelSelection(
      validKeys: () => [
        for (final descriptor in registry.descriptors)
          if (descriptor.enabled) descriptor.key,
      ],
      defaultKey: () {
        final channels = registry.descriptors;
        for (final descriptor in channels) {
          final capabilities = descriptor.capabilities;
          if (capabilities.search ||
              capabilities.artist ||
              capabilities.lyricSearch) {
            return descriptor.key;
          }
        }
        return channels.isEmpty ? '' : channels.first.key;
      },
    );
    addTearDown(selection.dispose);
    final provider = SearchProvider(
      playbackProvider,
      selection: selection,
      catalogService: CatalogService(registry: registry),
      sourceRegistry: registry,
    );
    addTearDown(provider.dispose);
    return provider;
  }

  test('sourceChannels 直接是 registry.descriptors，默认 active 为第一个来源', () {
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
    expect(provider.activeSourceKey, 'kw');
    expect(provider.activeSource?.displayName, '酷我');
    expect(provider.hasActiveSearchSource, isTrue);
    expect(provider.hasSearchableSources, isTrue);
    expect(provider.supportedSearchKinds, [SearchKind.song]);
  });

  test('submitSearch 只搜当前渠道，不再并行其它来源', () async {
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
    expect(tx.searchCalls, 0, reason: '非当前渠道不参与搜索');
    expect(provider.activeSourceKey, 'kw');
    expect(provider.songResults.items.map((row) => row.id.uri), ['kw:hello-1']);
  });

  test('单源分页 / 跨页去重 / 到底守卫', () async {
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
    final registry = _FakeRegistry({'kw': kw}, [_descriptor('kw', '酷我')]);
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(() => provider.songResults.items.length == 2);
    expect(provider.songResults.page, 1);

    await provider.loadMore();
    final results = provider.songResults;
    expect(results.page, 2);
    expect(results.hasMore, isFalse);
    expect(results.total, 4);
    expect(results.items.map((row) => row.id.uri), ['kw:a', 'kw:b', 'kw:c']);

    // 已经到底：再次 loadMore 不再发请求。
    await provider.loadMore();
    expect(kw.searchCalls, 2);
  });

  test('首屏失败：failure 归一化并可重试', () async {
    var fail = true;
    final kw = _FakeMusicSource('kw')
      ..onSearch = (query) async {
        if (fail) {
          throw const SourceFailure(kind: FailureKind.network, message: 'boom');
        }
        return SearchResult(items: [_track('kw', 'ok')]);
      };
    final registry = _FakeRegistry({'kw': kw}, [_descriptor('kw', '酷我')]);
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(() => provider.songResults.failure != null);
    var results = provider.songResults;
    expect(results.failure!.message, contains('boom'));
    expect(results.failure!.kind, FailureKind.network);
    expect(results.items, isEmpty);

    fail = false;
    await provider.retry();
    await _waitUntil(() => provider.songResults.items.isNotEmpty);
    results = provider.songResults;
    expect(results.failure, isNull);
    expect(results.items.single.id.uri, 'kw:ok');
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
    await _waitUntil(() => provider.songResults.items.isNotEmpty);
    expect(provider.songResults.failure, isNull);

    await provider.loadMore();
    var results = provider.songResults;
    expect(results.loadMoreFailed, isTrue);
    expect(results.failure, isNull, reason: '追加页失败不是首屏失败');
    expect(results.page, 1);
    expect(results.items.map((row) => row.id.uri), ['kw:a']);

    failPage2 = false;
    await provider.retry();
    results = provider.songResults;
    expect(results.loadMoreFailed, isFalse);
    expect(results.failure, isNull);
    expect(results.page, 2);
    expect(results.items.map((row) => row.id.uri), ['kw:a', 'kw:b']);
  });

  test('切换当前渠道：清空旧结果并按当前关键词重搜', () async {
    final kw = _FakeMusicSource('kw')
      ..onSearch = (query) =>
          Future.value(SearchResult(items: [_track('kw', 'a')], total: 1));
    final tx = _FakeMusicSource('tx')
      ..onSearch = (query) =>
          Future.value(SearchResult(items: [_track('tx', 'b')], total: 1));
    final registry = _FakeRegistry(
      {'kw': kw, 'tx': tx},
      [_descriptor('kw', '酷我'), _descriptor('tx', 'QQ音乐')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(() => provider.songResults.items.isNotEmpty);
    expect(provider.activeSourceKey, 'kw');

    selection.select('tx');
    expect(provider.activeSourceKey, 'tx');
    expect(provider.searchQuery, 'hello', reason: '切渠道保留关键词');
    await _waitUntil(
      () =>
          provider.activeSourceKey == 'tx' &&
          provider.songResults.items.isNotEmpty,
    );
    expect(provider.searchResults.map((row) => row.id.uri), ['tx:b']);
    expect(kw.searchCalls, 1);
    expect(tx.searchCalls, 1);

    // 空 key 忽略（不再表示「全部来源」，也不会把当前渠道换掉）。
    selection.select('');
    expect(provider.activeSourceKey, 'tx');
  });

  test('切到不支持搜索的渠道：清空结果、不发请求，稍后可搜索时补搜', () async {
    final kw = _FakeMusicSource('kw');
    final tx = _FakeMusicSource('tx');
    final registry = _FakeRegistry(
      {'kw': kw, 'tx': tx},
      [_descriptor('kw', '酷我')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(() => !provider.isSearching);
    expect(kw.searchCalls, 1);

    selection.select('tx');
    expect(provider.activeSourceKey, 'tx');
    expect(provider.hasActiveSearchSource, isFalse);
    expect(provider.supportedSearchKinds, isEmpty);
    expect(provider.songResults.page, 0);
    expect(provider.songResults.items, isEmpty, reason: '旧渠道结果已清空');
    expect(provider.isSearchPending, isFalse, reason: '不可搜索渠道不能永久 pending');
    expect(provider.isSearchBusy, isFalse);

    provider.submitSearch('hello');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(tx.searchCalls, 0, reason: '当前渠道不支持搜索');

    // 脚本 / 来源晚到：同一个 key 变为可搜索后按当前关键词补首屏。
    registry.setDescriptors([
      _descriptor('kw', '酷我'),
      _descriptor('tx', 'QQ音乐'),
    ]);
    await _waitUntil(
      () =>
          provider.activeSourceKey == 'tx' &&
          provider.songResults.items.isNotEmpty,
    );
    expect(tx.searchCalls, 1);
    expect(kw.searchCalls, 1, reason: '不回到旧渠道补搜');
  });

  test('已注册但无搜索能力：hasActiveSearchSource 为 false', () async {
    final script = _FakeMusicSource('script');
    final registry = _FakeRegistry(
      {'script': script},
      [
        _descriptor(
          'script',
          '脚本源',
          capabilities: const domain.SourceCapabilities(),
        ),
      ],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    expect(provider.activeSourceKey, 'script');
    expect(provider.activeSource, isNotNull, reason: '渠道已注册');
    expect(provider.hasActiveSearchSource, isFalse, reason: '能力位全 false');
    expect(provider.supportedSearchKinds, isEmpty);

    provider.submitSearch('hello');
    await _waitUntil(() => !provider.isSearching);
    expect(provider.songResults.page, 0);
    expect(provider.songResults.items, isEmpty);
    expect(script.searchCalls, 0);
  });

  test('已有查询时切到暂不可搜索渠道，能力补齐后自动补搜', () async {
    final kw = _FakeMusicSource('kw');
    final script = _FakeMusicSource('script');
    final registry = _FakeRegistry(
      {'kw': kw, 'script': script},
      [
        _descriptor('kw', '酷我'),
        _descriptor(
          'script',
          '脚本源',
          capabilities: const domain.SourceCapabilities(),
        ),
      ],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(() => provider.songResults.items.isNotEmpty);
    expect(kw.searchCalls, 1);

    selection.select('script');
    expect(provider.hasActiveSearchSource, isFalse);
    expect(provider.songResults.page, 0);
    expect(provider.songResults.items, isEmpty, reason: '切渠道已清空旧结果');

    // 脚本晚到：同一个 key 变为可搜索，当前关键词仍在 provider 上。
    registry.setDescriptors([
      _descriptor('kw', '酷我'),
      _descriptor('script', '脚本源'),
    ]);
    await _waitUntil(
      () =>
          script.searchCalls == 1 &&
          provider.activeSourceKey == 'script' &&
          provider.songResults.items.isNotEmpty,
    );
    expect(provider.searchResults.single.id.uri, 'script:hello-1');
    expect(kw.searchCalls, 1, reason: '不回到旧渠道补搜');
  });

  test('supportedSearchKinds 只看当前渠道；不支持的类型自动回退（优先 song）', () async {
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
    provider.selectSearchKind(SearchKind.artist);
    await _waitUntil(() => provider.artistResults.items.isNotEmpty);
    expect(provider.searchKind, SearchKind.artist);

    selection.select('script');
    expect(provider.searchKind, SearchKind.song, reason: '脚本源无歌手能力 → 回退单曲');
    expect(provider.supportedSearchKinds, [SearchKind.song]);
    expect(provider.artistResults.page, 0);
    expect(provider.artistResults.items, isEmpty, reason: '旧渠道的歌手结果已清空');
    await _waitUntil(() => provider.songResults.items.isNotEmpty);
    expect(script.artistSearchCalls, 0);
    expect(script.searchCalls, 1);
  });

  test('来源移除：当前渠道结果一起移除；其它渠道不自动接管', () async {
    final kw = _FakeMusicSource('kw');
    final tx = _FakeMusicSource('tx');
    final registry = _FakeRegistry(
      {'kw': kw, 'tx': tx},
      [_descriptor('kw', '酷我'), _descriptor('tx', 'QQ音乐')],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('hello');
    await _waitUntil(() => provider.songResults.items.isNotEmpty);

    registry.setDescriptors([_descriptor('tx', 'QQ音乐')]);
    await _waitUntil(() => provider.songResults.items.isEmpty);
    expect(provider.activeSourceKey, 'kw');
    expect(provider.hasActiveSearchSource, isFalse);
    expect(tx.searchCalls, 0, reason: '当前渠道消失时不自动改搜其它渠道');
  });

  test('retryFailed 只重试当前渠道', () async {
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
    await _waitUntil(() => provider.songResults.failure != null);
    expect(provider.activeSourceKey, 'kw');

    fail = false;
    await provider.retryFailed();
    await _waitUntil(() => provider.songResults.items.isNotEmpty);
    expect(kw.searchCalls, 2);
    expect(tx.searchCalls, 0);
  });

  test('playItem：队列只取当前渠道的已加载结果，contextName = 渠道名', () async {
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
    await _waitUntil(() => provider.songResults.items.length == 2);

    provider.playItem(provider.songResults.items[1]);
    final request = backend.lastRequest!;
    expect(request.startIndex, 1);
    expect(request.context?.name, '酷我');
    expect(request.tracks.map((track) => track.id.uri), ['kw:a', 'kw:b']);
    expect(
      request.tracks.every((track) => track.id.sourceKey == 'kw'),
      isTrue,
      reason: '不混平台队列',
    );
  });

  test('releaseSearchResults：清空结果与关键词，保留当前渠道', () async {
    final kw = _FakeMusicSource(
      'kw',
      capabilities: const domain.SourceCapabilities(
        search: true,
        pagination: true,
        artist: true,
        lyricSearch: true,
      ),
    );
    final registry = _FakeRegistry(
      {'kw': kw},
      [_descriptor('kw', '酷我', capabilities: kw.capabilities)],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('周杰伦');
    await _waitUntil(() => !provider.isSearching);
    provider.selectSearchKind(SearchKind.artist);
    await _waitUntil(() => provider.artistResults.items.isNotEmpty);

    provider.releaseSearchResults();
    expect(provider.searchQuery, isEmpty);
    expect(provider.searchResults, isEmpty);
    expect(provider.artistResults.items, isEmpty);
    expect(provider.lyricResults.items, isEmpty);
    expect(provider.songResults.page, 0);
    expect(provider.artistResults.page, 0);
    expect(provider.lyricResults.page, 0);
    expect(provider.isSearching, isFalse);
    expect(provider.activeSourceKey, 'kw', reason: '渠道偏好保留');
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
    await _waitUntil(() => provider.songResults.items.isNotEmpty);
    oldGate.complete(SearchResult(items: [_track('kw', 'old')], total: 1));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(provider.songResults.items.single.id.uri, 'kw:new');
  });

  test('歌词片段按渠道保存；换词清空，追加页同 id 后页覆盖', () async {
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
    final registry = _FakeRegistry(
      {'kw': kw},
      [_descriptor('kw', '酷我', capabilities: kw.capabilities)],
    );
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    provider.submitSearch('歌词');
    await _waitUntil(() => !provider.isSearching);
    provider.selectSearchKind(SearchKind.lyric);
    await _waitUntil(() => provider.lyricResults.items.length == 2);
    expect(provider.lyricResults.items.map((row) => row.lyricSnippet), [
      '第一页 A',
      '第一页 B',
    ]);

    await provider.loadMore();
    expect(provider.lyricResults.items.map((row) => row.lyricSnippet), [
      '第一页 A',
      '第二页 B',
      '第二页 C',
    ]);

    provider.submitSearch('第二词');
    await _waitUntil(() => provider.lyricResults.items.isNotEmpty);
    expect(provider.lyricResults.items.single.lyricSnippet, '新片段');
  });

  test('防抖窗口：isSearchBusy 覆盖等待期，完成后只请求一次', () {
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': source}, [_descriptor('kw', '酷我')]);
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);

    fakeAsync((async) {
      provider.updateSearchQuery('hello');
      expect(provider.isSearchPending, isTrue);
      expect(provider.isSearchBusy, isTrue);
      expect(provider.isSearching, isFalse);
      expect(provider.songResults.page, 0);
      expect(provider.songResults.items, isEmpty);

      async.elapse(const Duration(milliseconds: 299));
      expect(source.searchCalls, 0);
      expect(provider.isSearchBusy, isTrue, reason: '防抖等待期不能显示空结果');

      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(source.searchCalls, 1);
      expect(provider.isSearchBusy, isFalse);
      expect(provider.isSearchPending, isFalse);
      expect(provider.songResults.items, isNotEmpty);
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
      expect(provider.artistResults.items, isNotEmpty);
    });
  });

  test('输入防抖 300ms：连续输入只发最后一次请求', () {
    final kw = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': kw}, [_descriptor('kw', '酷我')]);
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
    selection = ChannelSelection(
      validKeys: () => const [],
      defaultKey: () => '',
    );
    addTearDown(selection.dispose);
    final provider = SearchProvider(playbackProvider, selection: selection);
    addTearDown(provider.dispose);

    expect(provider.sourceChannels, isEmpty);
    expect(provider.hasSearchableSources, isFalse);
    expect(provider.activeSourceKey, isEmpty);
    expect(provider.hasActiveSearchSource, isFalse);
    expect(provider.supportedSearchKinds, isEmpty);

    provider.submitSearch('hello');
    await _waitUntil(() => !provider.isSearching);
    expect(provider.searchResults, isEmpty);
    expect(provider.songResults.page, 0);
    expect(provider.songResults.items, isEmpty);
  });

  test('能力位 → 搜索类型只有一处映射（SourceCapabilities）', () {
    const capabilities = domain.SourceCapabilities(
      search: true,
      artist: true,
      lyricSearch: true,
    );
    expect(capabilities.searchKinds, [
      SearchKind.song,
      SearchKind.artist,
      SearchKind.lyric,
    ]);
    expect(capabilities.supportsAnySearch, isTrue);
    expect(capabilities.supportsSearchKind(SearchKind.artist), isTrue);

    const noSearch = domain.SourceCapabilities(lyrics: true);
    expect(noSearch.searchKinds, isEmpty);
    expect(noSearch.supportsAnySearch, isFalse);
  });

  test('输入绑定：控制器 → 会话防抖重启；会话清空 → 控制器立即清空', () {
    final source = _FakeMusicSource('kw');
    final registry = _FakeRegistry({'kw': source}, [_descriptor('kw', '酷我')]);
    addTearDown(registry.dispose);
    final provider = buildProvider(registry);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final binding = SearchInputBinding(
      session: provider.session,
      controller: controller,
    );
    addTearDown(binding.dispose);
    // 第二个宿主（资料库 tab / 遮罩可同时挂载）共用同一会话，不各自镜像。
    final secondController = TextEditingController();
    addTearDown(secondController.dispose);
    final secondBinding = SearchInputBinding(
      session: provider.session,
      controller: secondController,
    );
    addTearDown(secondBinding.dispose);

    fakeAsync((async) {
      controller.text = 'hello';
      expect(secondController.text, 'hello', reason: '两个宿主的输入框同源');
      expect(provider.searchQuery, 'hello');
      expect(provider.isSearchPending, isTrue, reason: '输入只重启，不立即请求');
      expect(provider.songResults.items, isEmpty);

      async.elapse(const Duration(milliseconds: 299));
      expect(source.searchCalls, 0);
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(source.searchCalls, 1);
      expect(provider.songResults.items, isNotEmpty);

      // 会话侧清空（托盘释放 / 其它宿主）必须立即反映到所有输入框，不等下一帧。
      provider.clearSearch();
      expect(controller.text, isEmpty);
      expect(secondController.text, isEmpty);
      expect(provider.searchQuery, isEmpty);
      expect(provider.filteredResults, isEmpty);
      expect(provider.songResults.items, isEmpty);
    });
  });

  test('预览会话：8 行截断、排序、高亮移动与换词重置（不挂遮罩）', () {
    final preview = SearchPreviewSession();
    addTearDown(preview.dispose);
    final rows = [
      for (var index = 0; index < 10; index++)
        SearchRow(track: _track('kw', 'r$index')),
    ];
    SearchResults<Object> results(List<SearchRow> items) =>
        SearchResults<Object>(items: items);

    preview.update(
      kind: SearchKind.song,
      results: results(rows),
      sourceKey: 'kw',
      query: 'hello',
    );
    expect(preview.totalItems, 10, reason: '总数不是截断后的数量');
    expect(preview.items, hasLength(SearchPreviewSession.defaultMaxItems));
    expect(preview.items.map((item) => item.key), [
      for (var index = 0; index < 8; index++) 'track:kw:r$index',
    ]);
    expect(preview.highlightedKey, 'track:kw:r0');

    preview.moveHighlight(2);
    expect(preview.highlightedKey, 'track:kw:r2');
    expect(preview.highlightedItem, isA<SearchPreviewTrack>());
    preview.moveHighlight(-1);
    expect(preview.highlightedKey, 'track:kw:r1');
    preview.moveHighlight(-100);
    expect(preview.highlightedKey, 'track:kw:r0', reason: '负向越界夹到首行');
    preview.moveHighlight(100);
    expect(preview.highlightedKey, 'track:kw:r7', reason: '正向越界夹到末行');

    // 同一关键词、行身份仍在：用户移动后的高亮保留。
    preview.update(
      kind: SearchKind.song,
      results: results(rows),
      sourceKey: 'kw',
      query: 'hello',
    );
    expect(preview.highlightedKey, 'track:kw:r7');

    // 换词重置策略：新查询从第一条重新开始。
    preview.update(
      kind: SearchKind.song,
      results: results(rows),
      sourceKey: 'kw',
      query: 'next',
    );
    expect(preview.highlightedKey, 'track:kw:r0');

    // 歌手类型的预览顺序与行身份来自同一份投影。
    final artists = [
      for (var index = 0; index < 3; index++)
        ArtistSummary(id: 'a$index', name: '歌手 $index'),
    ];
    preview.update(
      kind: SearchKind.artist,
      results: SearchResults<Object>(items: artists),
      sourceKey: 'kw',
      query: 'next',
    );
    expect(preview.items.map((item) => item.key), [
      'artist:kw:a0',
      'artist:kw:a1',
      'artist:kw:a2',
    ]);
    expect(preview.highlightedItem, isA<SearchPreviewArtist>());
  });

  test('切类型后结果投影与预览一起换（不挂遮罩）', () async {
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

    provider.submitSearch('hello');
    await _waitUntil(() => provider.songResults.items.isNotEmpty);
    expect(provider.session.projection.trackItems, isNotEmpty);
    expect(provider.session.projection.artistItems, isEmpty);

    provider.selectSearchKind(SearchKind.artist);
    await _waitUntil(() => provider.artistResults.items.isNotEmpty);
    final projection = provider.session.projection;
    expect(projection.kind, SearchKind.artist);
    expect(projection.trackItems, isEmpty);
    expect(projection.artistItems.single.id, 'hello-a1');
    expect(provider.session.preview.items.single, isA<SearchPreviewArtist>());
    expect(provider.session.preview.highlightedKey, 'artist:kw:hello-a1');
  });
}
