import 'dart:async' show FutureOr;
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/sources/any_listen/any_listen_api.dart';
import 'package:molia/sources/any_listen/any_listen_config.dart';
import 'package:molia/sources/any_listen/any_listen_errors.dart';
import 'package:molia/sources/any_listen/any_listen_source.dart';
import 'package:molia/sources/source_track.dart';

/// 本地 HttpServer mock：只允许访问 127.0.0.1，不依赖真实网络。
class MockAnyListenServer {
  late final HttpServer _server;
  final List<MockRequest> requests = [];

  int get port => _server.port;
  String get baseUrl => 'http://127.0.0.1:$port';

  Future<void> start(FutureOr<void> Function(MockRequest request) handler) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      try {
        Map<String, dynamic>? body;
        if (request.method == 'POST') {
          final text = await utf8.decoder.bind(request).join();
          final decoded = text.isEmpty ? null : jsonDecode(text);
          if (decoded is Map) body = decoded.cast<String, dynamic>();
        }
        final captured = MockRequest(request, body);
        requests.add(captured);
        await handler(captured);
      } catch (_) {
        // 测试收尾（force close）时写入响应会抛异常，忽略即可。
      }
    });
  }

  Future<void> stop() => _server.close(force: true);

  MockRequest requestTo(String path) =>
      requests.firstWhere((r) => r.path == path, orElse: () => throw StateError('未收到请求: $path'));
}

class MockRequest {
  MockRequest(this.request, this.body);

  final HttpRequest request;
  final Map<String, dynamic>? body;

  String get method => request.method;
  String get path => request.uri.path;
  Uri get uri => request.uri;
  HttpHeaders get headers => request.headers;

  String? get authorization => headers.value(HttpHeaders.authorizationHeader);
}

void respondJson(MockRequest req, dynamic body, {int status = 200}) {
  req.request.response
    ..statusCode = status
    ..headers.contentType =
        ContentType('application', 'json', charset: 'utf-8')
    ..write(jsonEncode(body));
  req.request.response.close();
}

void respondText(
  MockRequest req,
  String body, {
  int status = 200,
  ContentType? contentType,
}) {
  req.request.response.statusCode = status;
  if (contentType != null) req.request.response.headers.contentType = contentType;
  req.request.response.write(body);
  req.request.response.close();
}

/// 默认响应：握手 + 上游 MusicInfoOnline 形状的搜索/取链/歌词/封面。
Future<void> handleDefault(MockAnyListenServer server, MockRequest req) async {
  switch (req.path) {
    case '/api/ipc/hello':
      respondText(req, AnyListenEndpoints.helloMagic);
    case '/api/ipc/id':
      respondText(req, 'OjppZDo6-TEST-SERVER');
    case '/api/music/search':
      respondJson(req, {
        'list': [
          {
            'id': 'any-1',
            'name': '夜曲',
            'singer': '周杰伦',
            'interval': '03:55',
            'isLocal': false,
            'meta': {
              'musicId': 'any-1',
              'albumName': '十一月的萧邦',
              'picUrl': 'https://img.example/cover.jpg',
              'source': 'tx',
              'qualitys': {
                '320k': {'sizeStr': '8.5MB'},
                'flac': {'sizeStr': '25MB'},
              },
            },
          },
          // 缺少 name 的脏数据应被跳过
          {'id': 'dirty', 'singer': 'x'},
        ],
        'total': 120,
        'limit': 30,
        'page': 1,
      });
    case '/api/music/url':
      respondJson(req, {
        'url': '${server.baseUrl}/stream/1.mp3',
        'quality': '320k',
        'isFromCache': false,
      });
    case '/api/music/lyric':
      respondJson(req, {
        'info': {
          'lyric': '[00:01.00]测试歌词',
          'tlyric': '[00:01.00]translated',
          'rlyric': '[00:01.00]romaji',
          'awlyric': '[0,1000](0,1000,0)测',
        },
        'isFromCache': false,
      });
    case '/api/music/pic':
      respondJson(req, {'url': '${server.baseUrl}/pic/1.jpg', 'isFromCache': false});
    default:
      respondJson(req, {'message': 'not found'}, status: 404);
  }
}

Future<AnyListenSource> buildSource(
  String baseUrl, {
  Duration timeout = const Duration(seconds: 5),
  AnyListenApi? api,
}) async {
  final source = AnyListenSource(api: api ?? AnyListenApi(timeout: timeout));
  await source.updateConfig(AnyListenConfig(
    serverUrl: baseUrl,
    token: 'test-token',
    enabled: true,
  ));
  return source;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_test 默认把 HttpClient 的请求全部短路为 HTTP 400（用于防止真实网络）；
  // 本文件的请求只访问 127.0.0.1 的本地 mock HttpServer，因此恢复真实客户端。
  HttpOverrides.global = null;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AnyListenSource：搜索/取链/歌词/封面（本地 HttpServer mock）', () {
    late MockAnyListenServer server;
    late AnyListenSource source;

    setUp(() async {
      server = MockAnyListenServer();
      await server.start((req) => handleDefault(server, req));
      source = await buildSource(server.baseUrl);
    });

    tearDown(() async {
      source.dispose();
      await server.stop();
    });

    test('search 解析 MusicInfoOnline 并把 raw 原样透传', () async {
      final result = await source.search('夜曲', page: 1, limit: 30);

      expect(result.total, 120);
      expect(result.hasMore, isTrue);
      expect(result.tracks, hasLength(1)); // 脏数据被跳过

      final track = result.tracks.single;
      expect(track.sourceKey, AnyListenSource.sourceKey);
      expect(track.origin, AnyListenSource.origin);
      expect(track.title, '夜曲');
      expect(track.artist, '周杰伦');
      expect(track.album, '十一月的萧邦');
      expect(track.coverUrl, 'https://img.example/cover.jpg');
      expect(track.duration, const Duration(minutes: 3, seconds: 55));
      expect(track.qualities.map((q) => q.type), containsAll(['320k', 'flac']));
      expect(
        track.qualities.firstWhere((q) => q.type == 'flac').size,
        '25MB',
      );
      // raw 原样：id/meta.source 等字段必须保留，供取链回传
      expect(track.raw['id'], 'any-1');
      expect(track.raw['interval'], '03:55');
      expect((track.raw['meta'] as Map)['source'], 'tx');

      // 请求参数与鉴权头
      final searchReq = server.requestTo('/api/music/search');
      expect(searchReq.method, 'GET');
      expect(searchReq.uri.queryParameters['name'], '夜曲');
      expect(searchReq.uri.queryParameters['page'], '1');
      expect(searchReq.uri.queryParameters['limit'], '30');
      expect(searchReq.authorization, 'Bearer test-token');
    });

    test('resolveUrl 把 raw 作为 musicInfo 回传，并携带所选音质', () async {
      final track = (await source.search('夜曲')).tracks.single;
      final url = await source.resolveUrl(track, requestedQuality: 'flac');

      expect(url, '${server.baseUrl}/stream/1.mp3');

      final post = server.requestTo('/api/music/url');
      expect(post.method, 'POST');
      expect(post.body!['quality'], 'flac');
      final musicInfo = post.body!['musicInfo'] as Map;
      expect(musicInfo['id'], 'any-1');
      expect((musicInfo['meta'] as Map)['source'], 'tx');
    });

    test('fetchLyric 解析 info 包裹的歌词字段', () async {
      final track = (await source.search('夜曲')).tracks.single;
      final lyric = await source.fetchLyric(track);

      expect(lyric, isNotNull);
      expect(lyric!.lyric, '[00:01.00]测试歌词');
      expect(lyric.tlyric, '[00:01.00]translated');
      expect(lyric.rlyric, '[00:01.00]romaji');
      expect(lyric.awlyric, '[0,1000](0,1000,0)测');
    });

    test('fetchPic 解析 url 字段', () async {
      final track = (await source.search('夜曲')).tracks.single;
      expect(await source.fetchPic(track), '${server.baseUrl}/pic/1.jpg');
    });

    test('testConnection 握手成功并返回服务器标识', () async {
      final result = await source.testConnection();

      expect(result.ok, isTrue);
      expect(result.serverId, 'OjppZDo6-TEST-SERVER');
      expect(result.message, contains('OjppZDo6-TEST-SERVER'));
      expect(result.errorKind, isNull);
      expect(server.requestTo('/api/ipc/hello').method, 'GET');
    });
  });

  group('AnyListenSource：错误分支', () {
    test('未配置时给出 notConfigured，且不发起网络请求', () async {
      SharedPreferences.setMockInitialValues({});
      final source = AnyListenSource();
      await source.init();
      expect(source.isConfigured, isFalse);
      expect(source.isUsable, isFalse);

      AnyListenException? captured;
      try {
        await source.search('x');
      } on AnyListenException catch (error) {
        captured = error;
      }
      expect(captured, isNotNull);
      expect(captured!.kind, AnyListenErrorKind.notConfigured);
      expect(captured.message, contains('未配置'));

      final result = await source.testConnection();
      expect(result.ok, isFalse);
      expect(result.errorKind, AnyListenErrorKind.notConfigured);

      source.dispose();
    });

    test('连接失败（端口不可达）归类为 connectionFailed，testConnection 不抛异常', () async {
      // 先绑定再关闭拿到一个必然不可达的端口
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close();

      final source = await buildSource('http://127.0.0.1:$deadPort');
      await expectLater(
        source.search('x'),
        throwsA(isA<AnyListenException>().having(
          (e) => e.kind,
          'kind',
          AnyListenErrorKind.connectionFailed,
        )),
      );

      final result = await source.testConnection();
      expect(result.ok, isFalse);
      expect(result.errorKind, AnyListenErrorKind.connectionFailed);
      expect(result.message, contains('无法连接'));
      source.dispose();
    });

    test('请求超时归类为 connectionFailed', () async {
      final server = MockAnyListenServer();
      await server.start((req) async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        respondText(req, AnyListenEndpoints.helloMagic);
      });

      final source = AnyListenSource(
        api: AnyListenApi(timeout: const Duration(milliseconds: 50)),
      );
      await source.updateConfig(AnyListenConfig(
        serverUrl: server.baseUrl,
        enabled: true,
      ));

      final result = await source.testConnection();
      expect(result.ok, isFalse);
      expect(result.errorKind, AnyListenErrorKind.connectionFailed);
      expect(result.message, contains('超时'));

      source.dispose();
      await server.stop();
    });

    test('HTTP 401 归类为 unauthorized', () async {
      final server = MockAnyListenServer();
      await server.start((req) {
        respondJson(req, {'message': 'Auth failed'}, status: 401);
      });
      final source = await buildSource(server.baseUrl);

      await expectLater(
        source.search('x'),
        throwsA(isA<AnyListenException>().having(
          (e) => e.kind,
          'kind',
          AnyListenErrorKind.unauthorized,
        )),
      );
      source.dispose();
      await server.stop();
    });

    test('HTTP 500 归类为 connectionFailed（可重试）', () async {
      final server = MockAnyListenServer();
      await server.start((req) {
        respondJson(req, {'message': 'boom'}, status: 500);
      });
      final source = await buildSource(server.baseUrl);

      AnyListenException? captured;
      try {
        await source.search('x');
      } on AnyListenException catch (error) {
        captured = error;
      }
      expect(captured!.kind, AnyListenErrorKind.connectionFailed);
      expect(captured.retryable, isTrue);
      source.dispose();
      await server.stop();
    });

    test('响应不是合法 JSON 归类为 badResponse', () async {
      final server = MockAnyListenServer();
      await server.start((req) {
        respondText(req, '<html>not json</html>',
            contentType: ContentType.html);
      });
      final source = await buildSource(server.baseUrl);

      await expectLater(
        source.search('x'),
        throwsA(isA<AnyListenException>().having(
          (e) => e.kind,
          'kind',
          AnyListenErrorKind.badResponse,
        )),
      );
      source.dispose();
      await server.stop();
    });

    test('JSON 但缺少列表归类为 badResponse', () async {
      final server = MockAnyListenServer();
      await server.start((req) => respondJson(req, {'foo': 1}));
      final source = await buildSource(server.baseUrl);

      await expectLater(
        source.search('x'),
        throwsA(isA<AnyListenException>().having(
          (e) => e.kind,
          'kind',
          AnyListenErrorKind.badResponse,
        )),
      );
      source.dispose();
      await server.stop();
    });

    test('歌词响应不是 JSON 对象归类为 badResponse；无歌词返回 null', () async {
      dynamic lyricPayload = 'oops';
      final server = MockAnyListenServer();
      await server.start((req) {
        if (req.path == '/api/music/lyric') {
          respondJson(req, lyricPayload);
        } else {
          handleDefault(server, req);
        }
      });
      final source = await buildSource(server.baseUrl);
      final track = SourceTrack(
        sourceKey: AnyListenSource.sourceKey,
        origin: AnyListenSource.origin,
        title: 'x',
        artist: '',
        album: '',
        raw: const {'id': 'any-1'},
      );

      await expectLater(
        source.fetchLyric(track),
        throwsA(isA<AnyListenException>().having(
          (e) => e.kind,
          'kind',
          AnyListenErrorKind.badResponse,
        )),
      );

      // info 存在但没有 lyric：视为「无歌词」，返回 null 以便上层回退
      lyricPayload = {
        'info': {'name': 'x'}
      };
      expect(await source.fetchLyric(track), isNull);

      source.dispose();
      await server.stop();
    });

    test('取链响应缺少 url 归类为 badResponse', () async {
      final server = MockAnyListenServer();
      await server.start((req) {
        if (req.path == '/api/music/url') {
          respondJson(req, {'quality': '320k'});
        } else {
          handleDefault(server, req);
        }
      });
      final source = await buildSource(server.baseUrl);
      final track = SourceTrack(
        sourceKey: AnyListenSource.sourceKey,
        origin: AnyListenSource.origin,
        title: 'x',
        artist: '',
        album: '',
        raw: const {'id': 'any-1'},
      );

      await expectLater(
        source.resolveUrl(track),
        throwsA(isA<AnyListenException>().having(
          (e) => e.kind,
          'kind',
          AnyListenErrorKind.badResponse,
        )),
      );
      source.dispose();
      await server.stop();
    });

    test('连接探测：服务器不是 any-listen 时给出 badResponse', () async {
      final server = MockAnyListenServer();
      await server.start((req) => respondText(req, 'hello from some other app'));
      final source = await buildSource(server.baseUrl);

      final result = await source.testConnection();
      expect(result.ok, isFalse);
      expect(result.errorKind, AnyListenErrorKind.badResponse);
      expect(result.message, contains('any-listen'));
      source.dispose();
      await server.stop();
    });
  });
}
