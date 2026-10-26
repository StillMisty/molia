import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/manager_catalog_source.dart';
import 'package:molia/data/http/app_dio.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart';
import 'package:molia/sources/any_listen/any_listen_config.dart';
import 'package:molia/sources/any_listen/any_listen_source.dart';
import 'package:molia/sources/builtin/bili_api.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/mock_dio.dart';
import '../support/settings_test_support.dart';

/// 适配器测试：真实 SourceManager + any-listen 本地 mock HTTP 服务
/// （与 any_listen_manager_test.dart 相同手法，不访问真实网络）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late HttpServer server;
  late int port;
  late List<Uri> requests;
  Completer<void>? gate;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    requests = [];
    gate = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((request) async {
      requests.add(request.uri);
      if (request.method == 'POST') {
        await utf8.decoder.bind(request).join();
      }
      if (gate != null) await gate!.future;
      request.response.headers.contentType = ContentType(
        'application',
        'json',
        charset: 'utf-8',
      );
      switch (request.uri.path) {
        case '/api/music/search':
          final limit = int.tryParse(
            request.uri.queryParameters['limit'] ?? '',
          );
          if (limit == 1) {
            request.response.write(
              jsonEncode({
                'list': [
                  {'id': 'any-1', 'name': '第一首', 'singer': '歌手'},
                ],
                'total': 3,
              }),
            );
          } else {
            request.response.write(
              jsonEncode({
                'list': [
                  {
                    'id': 'any-9',
                    'name': '测试曲目',
                    'singer': '测试歌手',
                    'interval': '03:00',
                    'meta': {
                      'albumName': '测试专辑',
                      'source': 'tx',
                      'picUrl': 'http://127.0.0.1:1/cover.jpg',
                      'qualitys': {
                        '320k': {'sizeStr': '8.5MB'},
                      },
                    },
                  },
                ],
                'total': 1,
                'limit': 30,
                'page': 1,
              }),
            );
          }
        case '/api/music/url':
          request.response.write(
            jsonEncode({'url': 'http://127.0.0.1:1/stream.mp3'}),
          );
        case '/api/music/lyric':
          request.response.write(
            jsonEncode({
              'info': {'lyric': '[00:00.00]hello', 'tlyric': '[00:00.00]你好'},
            }),
          );
        case '/api/music/pic':
          request.response.write(
            jsonEncode({'url': 'http://127.0.0.1:1/pic.jpg'}),
          );
        default:
          request.response
            ..statusCode = 404
            ..write('{}');
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  Future<SourceManager> configuredManager() async {
    final manager = SourceManager(settings: testSettingsRegistry());
    await manager.init();
    await manager.updateAnyListenConfig(
      AnyListenConfig(serverUrl: 'http://127.0.0.1:$port', enabled: true),
    );
    return manager;
  }

  group('SourceManagerMusicSource · 元信息', () {
    test('capabilities 与路由一致：内置平台歌词/封面为原生能力', () async {
      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);

      final kw = SourceManagerMusicSource('kw', manager);
      expect(kw.key, 'kw');
      expect(kw.capabilities.search, isFalse);
      expect(kw.capabilities.resolveUrl, isFalse);
      // 内置平台歌词/封面/专辑为 Dart 原生实现（脚本未声明时也可用）。
      expect(kw.capabilities.lyrics, isTrue);
      expect(kw.capabilities.artwork, isTrue);
      expect(kw.capabilities.collection, isTrue);
      expect(kw.capabilities.favorite, isFalse);

      // wy 同五平台一致；取链仍需要脚本。
      final wy = SourceManagerMusicSource('wy', manager);
      expect(wy.capabilities.lyrics, isTrue);
      expect(wy.capabilities.artwork, isTrue);
      expect(wy.capabilities.resolveUrl, isFalse);

      // manager 生命周期由 main 管理：init/dispose 为空实现。
      await kw.init();
      await kw.dispose();
    });

    test('capabilities：any-listen 已配置时全能力', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(
        AnyListenSource.sourceKey,
        manager,
      );
      expect(source.capabilities.search, isTrue);
      expect(source.capabilities.pagination, isTrue);
      expect(source.capabilities.resolveUrl, isTrue);
      expect(source.capabilities.lyrics, isTrue);
      expect(source.capabilities.artwork, isTrue);
      expect(source.capabilities.collection, isFalse);
    });

    test('displayName 从可搜索画像读取；停用 / 未知 key 回退；adopt 按 key', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(
        AnyListenSource.sourceKey,
        manager,
      );
      expect(source.displayName, AnyListenSource.displayName);
      // 停用后回退 key（路由仍可命中历史曲目）。
      await manager.setChannelEnabled(AnyListenSource.sourceKey, false);
      expect(source.displayName, AnyListenSource.sourceKey);

      final kw = SourceManagerMusicSource('kw', manager);
      // 无脚本 / 不可搜索的内置渠道回退 key。
      expect(kw.displayName, 'kw');
      await manager.setChannelEnabled('kw', false);
      expect(kw.displayName, 'kw');
      // 画像里不存在的 key（脚本已下架等）回退 key 本身。
      expect(SourceManagerMusicSource('gone', manager).displayName, 'gone');

      final own = Track(
        id: const TrackId(AnyListenSource.sourceKey, 'x'),
        title: 't',
        origin: TrackOrigin.anyListen,
      );
      final other = Track(
        id: const TrackId('kw', 'x'),
        title: 't',
        origin: TrackOrigin.builtin,
      );
      expect(source.adopt(own), same(own));
      expect(source.adopt(other), isNull);
    });

    test('collection：无能力（脚本源）抛 SourceFailure(unsupported)', () async {
      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('lx_custom', manager);
      expect(source.capabilities.collection, isFalse);

      await expectLater(
        source.collection(const CollectionRef(type: 'album', id: 'a')),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.unsupported,
          ),
        ),
      );
    });

    test('collection：内置平台仅专辑类型支持（歌单/艺人抛 unsupported）', () async {
      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('kw', manager);
      expect(source.capabilities.collection, isTrue);

      await expectLater(
        source.collection(const CollectionRef(type: 'playlist', id: 'a')),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.unsupported,
          ),
        ),
      );
    });

    test('collection：内置平台专辑路由到 SourceManager.fetchAlbum', () async {
      final original = BuiltinSearch.transport;
      BuiltinSearch.transport = BuiltinTransport(
        dio: createAppDio(
          adapter: MockDioAdapter(
            (options) async => textResponse(
              "{'albumid':'1433','name':'黑色香水','artist':'曹方',"
              "'songnum':'12','musiclist':[{'id':'81642','name':'黑色香水',"
              "'artist':'曹方','album':'黑色香水','albumId':1433,"
              "'duration':'240','N_MINFO':'level:h,bitrate:320,format:mp3,size:9.17Mb'}]}",
            ),
          ),
        ),
      );
      addTearDown(() => BuiltinSearch.transport = original);

      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('kw', manager);
      final page = await source.collection(
        const CollectionRef(type: 'album', id: '1433'),
      );
      expect(page.items, hasLength(1));
      expect(page.items.single.id, const TrackId('kw', '81642'));
      expect(page.items.single.payload['albumId'], '1433');
      expect(page.hasMore, isFalse, reason: 'songnum=12 < 默认每页 50');
    });
  });

  group('SourceManagerMusicSource · 歌手 / 歌词', () {
    test('searchArtists / searchLyrics：非内置源无能力 → unsupported', () async {
      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('lx_custom', manager);
      expect(source.capabilities.artist, isFalse);
      expect(source.capabilities.lyricSearch, isFalse);

      await expectLater(
        source.searchArtists(const SearchQuery(keyword: 'x')),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.unsupported,
          ),
        ),
      );
      await expectLater(
        source.searchLyrics(const SearchQuery(keyword: 'x')),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.unsupported,
          ),
        ),
      );
    });

    test('searchArtists / searchLyrics：内置平台未配脚本时能力位与搜索同门', () async {
      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('kw', manager);
      // 与 search 同一门（`_isBuiltinSearchable`：脚本可取链才宣称可用），
      // 避免 UI 显示一个必然失败的入口。
      expect(source.capabilities.search, isFalse);
      expect(source.capabilities.artist, isFalse);
      expect(source.capabilities.lyricSearch, isFalse);

      await expectLater(
        source.searchArtists(const SearchQuery(keyword: '周杰伦')),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.unsupported,
          ),
        ),
      );
      await expectLater(
        source.searchLyrics(const SearchQuery(keyword: '雨下整夜')),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.unsupported,
          ),
        ),
      );
    });
  });

  group('SourceManagerMusicSource · search/resolve/lyrics/artwork', () {
    test('search：SourceTrack → Track 映射，hasMore/total 原样透传', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(
        AnyListenSource.sourceKey,
        manager,
      );

      final result = await source.search(
        const SearchQuery(keyword: '测试', page: 1, limit: 30),
      );

      expect(result.items, hasLength(1));
      expect(result.total, 1);
      expect(result.hasMore, isFalse);

      final track = result.items.single;
      expect(track.id, const TrackId(AnyListenSource.sourceKey, 'any-9'));
      expect(track.title, '测试曲目');
      expect(track.artists.single.name, '测试歌手');
      expect(track.album, '测试专辑');
      expect(track.duration, const Duration(minutes: 3));
      expect(track.origin, TrackOrigin.anyListen);
      expect(track.artwork?.uri.toString(), 'http://127.0.0.1:1/cover.jpg');
      expect(track.qualities.single.type, '320k');
      expect(track.qualities.single.size, '8.5MB');
      // payload 必须与服务器返回对象同引用（raw 原样回传不变量）。
      expect(track.payload['id'], 'any-9');

      expect(requests.single.path, '/api/music/search');
      expect(requests.single.queryParameters['name'], '测试');
      expect(requests.single.queryParameters['page'], '1');
      expect(requests.single.queryParameters['limit'], '30');
    });

    test('search：page/limit 透传，total 推断 hasMore', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(
        AnyListenSource.sourceKey,
        manager,
      );

      final result = await source.search(
        const SearchQuery(keyword: 'x', page: 2, limit: 1),
      );
      expect(result.items, hasLength(1));
      expect(result.total, 3);
      expect(result.hasMore, isTrue, reason: 'page*limit=2 < total=3');
      expect(requests.single.queryParameters['page'], '2');
      expect(requests.single.queryParameters['limit'], '1');
    });

    test('search：取消令牌生效（前/后检查都丢弃结果）', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(
        AnyListenSource.sourceKey,
        manager,
      );

      // 请求前已取消：不发网络请求。
      final cancelled = CancelToken()..cancel();
      final early = await source.search(
        const SearchQuery(keyword: 'x'),
        cancel: cancelled,
      );
      expect(early.items, isEmpty);
      expect(requests, isEmpty);

      // 请求中被取消：结果丢弃。
      gate = Completer<void>();
      final token = CancelToken();
      final pending = source.search(
        const SearchQuery(keyword: 'x'),
        cancel: token,
      );
      // 等请求到达服务器后再取消。
      while (requests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      token.cancel();
      gate!.complete();
      final late = await pending;
      expect(late.items, isEmpty);
    });

    test('resolve：返回 PlayableStream（URL 来自 manager.resolveStream）', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(
        AnyListenSource.sourceKey,
        manager,
      );

      final result = await source.search(const SearchQuery(keyword: 'x'));
      final stream = await source.resolve(
        result.items.single,
        preferredQuality: const AudioQuality(type: '320k'),
      );
      expect(stream.uri, Uri.parse('http://127.0.0.1:1/stream.mp3'));
      expect(stream.headers, isEmpty);
    });

    test('lyrics：LxLyricResult → LyricsDoc（含翻译）', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(
        AnyListenSource.sourceKey,
        manager,
      );

      final result = await source.search(const SearchQuery(keyword: 'x'));
      final doc = await source.lyrics(result.items.single);
      expect(doc, isNotNull);
      expect(doc!.lyric, '[00:00.00]hello');
      expect(doc.translation, '[00:00.00]你好');
    });

    test('artwork：URL → Artwork；空 URL 返回 null', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(
        AnyListenSource.sourceKey,
        manager,
      );

      final result = await source.search(const SearchQuery(keyword: 'x'));
      final art = await source.artwork(result.items.single);
      expect(art, isNotNull);
      expect(art!.uri, Uri.parse('http://127.0.0.1:1/pic.jpg'));

      // 无 decl 的内置平台：fetchPic 返回 null → artwork null。
      final builtinSource = SourceManagerMusicSource('kw', manager);
      final builtinTrack = Track(
        id: const TrackId('kw', 'x'),
        title: 't',
        origin: TrackOrigin.builtin,
        payload: const {'id': 'x'},
      );
      expect(await builtinSource.artwork(builtinTrack), isNull);
    });

    test('无可用源：lyrics 返回 null，resolve 抛 SourceFailure(scriptError)', () async {
      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('kw', manager);
      final track = Track(
        id: const TrackId('kw', 'x'),
        title: 't',
        origin: TrackOrigin.builtin,
        payload: const {'id': 'x'},
      );

      expect(await source.lyrics(track), isNull);
      await expectLater(
        source.resolve(track),
        throwsA(
          isA<SourceFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.scriptError,
          ),
        ),
      );
    });

    test('search：manager 异常归一化为 SourceFailure(scriptError)', () async {
      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('kw', manager);

      await expectLater(
        source.search(const SearchQuery(keyword: 'x')),
        throwsA(
          isA<SourceFailure>()
              .having((f) => f.kind, 'kind', FailureKind.scriptError)
              .having((f) => f.retryable, 'retryable', isTrue),
        ),
      );
    });

    test('search：平台返回 failed 时抛 SourceFailure（不静默成空结果）', () async {
      final original = BuiltinSearch.transport;
      addTearDown(() => BuiltinSearch.transport = original);
      BuiltinSearch.transport = BuiltinTransport(
        dio: mockDio((_) async => textResponse('{}', statusCode: 500)),
      );
      BiliApi.reset();

      final manager = SourceManager(settings: testSettingsRegistry());
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('bili', manager);

      await expectLater(
        source.search(const SearchQuery(keyword: 'x')),
        throwsA(isA<SourceFailure>()),
        reason: '失败必须在边界暴露，换源页才能把 B 站列进失败源',
      );
    });
  });
}
