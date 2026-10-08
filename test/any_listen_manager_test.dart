import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/sources/any_listen/any_listen_config.dart';
import 'package:molia/sources/any_listen/any_listen_source.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:molia/sources/source_track.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_test 默认把 HttpClient 的请求全部短路为 HTTP 400（用于防止真实网络）；
  // 本文件的请求只访问 127.0.0.1 的本地 mock HttpServer，因此恢复真实客户端。
  HttpOverrides.global = null;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SourceManager × any-listen：未配置/未启用时零影响', () {
    test('未配置时不出现在 searchableSources，且可用性为 false', () async {
      final manager = SourceManager();
      await manager.init();

      expect(manager.anyListenAvailable, isFalse);
      expect(manager.anyListenConfig.isConfigured, isFalse);
      expect(
        manager.searchableSources.where((o) => o.kind == SourceKind.anyListen),
        isEmpty,
      );

      manager.dispose();
    });

    test('仅配置未启用时同样不出现', () async {
      SharedPreferences.setMockInitialValues({
        'any_listen_server_url': 'http://127.0.0.1:9500',
        'any_listen_token': 'tk',
        'any_listen_enabled': false,
      });
      final manager = SourceManager();
      await manager.init();

      expect(manager.anyListenConfig.isConfigured, isTrue);
      expect(manager.anyListenAvailable, isFalse);
      expect(
        manager.searchableSources.where((o) => o.kind == SourceKind.anyListen),
        isEmpty,
      );

      manager.dispose();
    });

    test('未配置时路由到 any-listen 的能力方法给出领域失败（不吞不崩）', () async {
      final manager = SourceManager();
      await manager.init();

      // 跨出 sources 层后是 SourceFailure（未配置 → unsupported），
      // 不再是 any-listen 内部异常类型。
      await expectLater(
        manager.search(AnyListenSource.sourceKey, 'x'),
        throwsA(isA<SourceFailure>()
            .having((e) => e.kind, 'kind', FailureKind.unsupported)),
      );

      final track = SourceTrack(
        sourceKey: AnyListenSource.sourceKey,
        origin: AnyListenSource.origin,
        title: 'x',
        artist: '',
        album: '',
        raw: const {'id': 'any-1'},
      );
      await expectLater(
        manager.resolveUrl(track),
        throwsA(isA<SourceFailure>()
            .having((e) => e.kind, 'kind', FailureKind.unsupported)),
      );

      // 歌词/封面契约允许失败：返回 null，不抛异常
      expect(await manager.fetchLyric(track), isNull);
      expect(await manager.fetchPic(track), isNull);

      manager.dispose();
    });
  });

  group('SourceManager × any-listen：配置与路由', () {
    test('updateAnyListenConfig：持久化、通知、出现在列表末尾', () async {
      final manager = SourceManager();
      await manager.init();

      var notified = 0;
      manager.addListener(() => notified++);

      final saved = await manager.updateAnyListenConfig(const AnyListenConfig(
        serverUrl: 'http://127.0.0.1:9500/',
        token: 'tk',
        enabled: true,
      ));

      expect(saved, isTrue);
      expect(notified, greaterThan(0));
      expect(manager.anyListenAvailable, isTrue);
      expect(manager.anyListenConfig.serverUrl, 'http://127.0.0.1:9500');

      final options = manager.searchableSources;
      final anyListen = options
          .where((o) => o.kind == SourceKind.anyListen)
          .toList();
      expect(anyListen, hasLength(1));
      expect(anyListen.single.key, AnyListenSource.sourceKey);
      expect(anyListen.single.name, AnyListenSource.displayName);
      expect(anyListen.single.canSearch, isTrue);
      // 新 key 未出现在持久化顺序表中：自动排在末尾，不打乱既有排序
      expect(options.last.key, AnyListenSource.sourceKey);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('any_listen_server_url'), 'http://127.0.0.1:9500');
      expect(prefs.getBool('any_listen_enabled'), isTrue);

      manager.dispose();
    });

    test('reloadAnyListenConfig：直接写 prefs 后重新加载可见性', () async {
      final manager = SourceManager();
      await manager.init();

      SharedPreferences.setMockInitialValues({
        'any_listen_server_url': 'http://127.0.0.1:9500',
        'any_listen_enabled': true,
      });
      await manager.reloadAnyListenConfig();
      expect(manager.anyListenAvailable, isTrue);

      manager.dispose();
    });

    test('通过 SourceManager 路由搜索/取链到本地 mock 服务器', () async {
      // 本地 HttpServer mock（不访问真实网络）
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      server.listen((request) async {
        try {
          requests.add(request.uri.path);
          if (request.method == 'POST') {
            await utf8.decoder.bind(request).join();
          }
          request.response.headers.contentType =
              ContentType('application', 'json', charset: 'utf-8');
          switch (request.uri.path) {
            case '/api/music/search':
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
                    },
                  }
                ],
                'total': 1,
                'limit': 30,
                'page': 1,
              }));
            case '/api/music/url':
              request.response
                  .write(jsonEncode({'url': 'http://127.0.0.1:1/stream.mp3'}));
            default:
              request.response
                ..statusCode = 404
                ..write('{}');
          }
          await request.response.close();
        } catch (_) {
          // 测试收尾时忽略写入异常
        }
      });

      final manager = SourceManager();
      await manager.init();

      await manager.updateAnyListenConfig(AnyListenConfig(
        serverUrl: 'http://127.0.0.1:${server.port}',
        enabled: true,
      ));

      final result =
          await manager.searchWithMeta(AnyListenSource.sourceKey, '测试');
      expect(result.tracks, hasLength(1));
      expect(result.tracks.single.title, '测试曲目');
      expect(result.tracks.single.raw['id'], 'any-9');

      final url = await manager.resolveUrl(result.tracks.single);
      expect(url, 'http://127.0.0.1:1/stream.mp3');
      expect(
        requests,
        containsAll(['/api/music/search', '/api/music/url']),
      );

      manager.dispose();
      await server.close(force: true);
    });

    test('鉴权失败：401 跨层后仍是 unauthorized（不退化为 unknown）', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        try {
          request.response
            ..statusCode = 401
            ..write('{}');
          await request.response.close();
        } catch (_) {
          // 测试收尾时忽略写入异常
        }
      });

      final manager = SourceManager();
      await manager.init();
      await manager.updateAnyListenConfig(AnyListenConfig(
        serverUrl: 'http://127.0.0.1:${server.port}',
        enabled: true,
      ));

      await expectLater(
        manager.search(AnyListenSource.sourceKey, 'x'),
        throwsA(isA<SourceFailure>()
            .having((e) => e.kind, 'kind', FailureKind.unauthorized)
            .having((e) => e.retryable, 'retryable', isFalse)),
      );

      manager.dispose();
      await server.close(force: true);
    });
  });
}
