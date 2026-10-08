import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/manager_catalog_source.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart';
import 'package:molia/sources/any_listen/any_listen_config.dart';
import 'package:molia/sources/any_listen/any_listen_source.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
      request.response.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      switch (request.uri.path) {
        case '/api/music/search':
          final limit = int.tryParse(request.uri.queryParameters['limit'] ?? '');
          if (limit == 1) {
            request.response.write(jsonEncode({
              'list': [
                {'id': 'any-1', 'name': '第一首', 'singer': '歌手'},
              ],
              'total': 3,
            }));
          } else {
            request.response.write(jsonEncode({
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
                }
              ],
              'total': 1,
              'limit': 30,
              'page': 1,
            }));
          }
        case '/api/music/url':
          request.response
              .write(jsonEncode({'url': 'http://127.0.0.1:1/stream.mp3'}));
        case '/api/music/lyric':
          request.response.write(jsonEncode({
            'info': {
              'lyric': '[00:00.00]hello',
              'tlyric': '[00:00.00]你好',
            }
          }));
        case '/api/music/pic':
          request.response
              .write(jsonEncode({'url': 'http://127.0.0.1:1/pic.jpg'}));
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
    final manager = SourceManager();
    await manager.init();
    await manager.updateAnyListenConfig(AnyListenConfig(
      serverUrl: 'http://127.0.0.1:$port',
      enabled: true,
    ));
    return manager;
  }

  group('SourceManagerMusicSource · 元信息', () {
    test('capabilities 与路由一致：无脚本内置源不谎报能力', () async {
      final manager = SourceManager();
      addTearDown(manager.dispose);

      final kw = SourceManagerMusicSource('kw', manager);
      expect(kw.key, 'kw');
      expect(kw.capabilities.search, isFalse);
      expect(kw.capabilities.resolveUrl, isFalse);
      expect(kw.capabilities.lyrics, isFalse);
      expect(kw.capabilities.artwork, isFalse);
      expect(kw.capabilities.collection, isFalse);
      expect(kw.capabilities.favorite, isFalse);

      // wy 无脚本也有内置歌词/封面回退；取链仍需要脚本。
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
      final source =
          SourceManagerMusicSource(AnyListenSource.sourceKey, manager);
      expect(source.capabilities.search, isTrue);
      expect(source.capabilities.pagination, isTrue);
      expect(source.capabilities.resolveUrl, isTrue);
      expect(source.capabilities.lyrics, isTrue);
      expect(source.capabilities.artwork, isTrue);
      expect(source.capabilities.collection, isFalse);
    });

    test('displayName 从 manager.searchableSources 读取；adopt 按 key', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(AnyListenSource.sourceKey, manager);
      expect(source.displayName, AnyListenSource.displayName);

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

    test('collection 不支持时抛 SourceFailure(unsupported)', () async {
      final manager = SourceManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('kw', manager);

      await expectLater(
        source.collection(const CollectionRef(type: 'album', id: 'a')),
        throwsA(isA<SourceFailure>()
            .having((f) => f.kind, 'kind', FailureKind.unsupported)),
      );
    });
  });

  group('SourceManagerMusicSource · search/resolve/lyrics/artwork', () {
    test('search：SourceTrack → Track 映射，hasMore/total 原样透传', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(AnyListenSource.sourceKey, manager);

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
      final source = SourceManagerMusicSource(AnyListenSource.sourceKey, manager);

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
      final source = SourceManagerMusicSource(AnyListenSource.sourceKey, manager);

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

    test('resolve：返回 PlayableStream（URL 来自 manager.resolveUrl）', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(AnyListenSource.sourceKey, manager);

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
      final source = SourceManagerMusicSource(AnyListenSource.sourceKey, manager);

      final result = await source.search(const SearchQuery(keyword: 'x'));
      final doc = await source.lyrics(result.items.single);
      expect(doc, isNotNull);
      expect(doc!.lyric, '[00:00.00]hello');
      expect(doc.translation, '[00:00.00]你好');
    });

    test('artwork：URL → Artwork；空 URL 返回 null', () async {
      final manager = await configuredManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource(AnyListenSource.sourceKey, manager);

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
      final manager = SourceManager();
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
        throwsA(isA<SourceFailure>()
            .having((f) => f.kind, 'kind', FailureKind.scriptError)),
      );
    });

    test('search：manager 异常归一化为 SourceFailure(scriptError)', () async {
      final manager = SourceManager();
      addTearDown(manager.dispose);
      final source = SourceManagerMusicSource('kw', manager);

      await expectLater(
        source.search(const SearchQuery(keyword: 'x')),
        throwsA(isA<SourceFailure>()
            .having((f) => f.kind, 'kind', FailureKind.scriptError)
            .having((f) => f.retryable, 'retryable', isTrue)),
      );
    });
  });
}
