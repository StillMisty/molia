import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/http/app_dio.dart';
import 'package:molia/domain/models/bili_account.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/sources/builtin/bili_api.dart';
import 'package:molia/sources/builtin/bili_client.dart';
import 'package:molia/sources/builtin/bili_session.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';

import 'support/bili_session_mock.dart';
import 'support/mock_dio.dart';

/// B 站请求生命周期：[BiliClient] 的鉴权 / 风控 / 业务码 / 空响应口径。
///
/// 这里直接注入独立传输（不碰全局 `BuiltinSearch.transport`），把「刷新几次、
/// 带不带 Cookie、-403 属于哪类失败」钉在客户端的契约上。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BiliSession session;

  setUp(() {
    BiliApi.reset();
    session = BiliSession();
  });

  MockDioAdapter adapterOf(
    FutureOr<ResponseBody> Function(RequestOptions options) onRequest,
  ) {
    return MockDioAdapter((options) async {
      final session = biliSessionResponse(options);
      if (session != null) return session;
      return onRequest(options);
    });
  }

  BiliClient clientOf(MockDioAdapter adapter) => BiliClient(
    transport: BuiltinTransport(dio: createAppDio(adapter: adapter)),
    session: session,
  );

  int sessionFetches(MockDioAdapter adapter) => adapter.requests
      .where((request) => request.uri.path == '/x/frontend/finger/spi')
      .length;

  test('session 端点：Cookie + WBI 签名，成功后不刷新会话', () async {
    final adapter = adapterOf((options) async {
      if (options.uri.path == '/x/player/wbi/playurl') {
        return textResponse(
          jsonEncode({
            'code': 0,
            'data': {'ok': true},
          }),
        );
      }
      return textResponse('{}', statusCode: 500);
    });
    final client = clientOf(adapter);

    final response = await client.get(
      '/x/player/wbi/playurl',
      query: {'bvid': 'BV1xx411c7mD', 'cid': 7},
      auth: BiliAuth.session,
    );

    expect(response['data'], {'ok': true});
    final request = adapter.requests.singleWhere(
      (r) => r.uri.path == '/x/player/wbi/playurl',
    );
    expect(request.uri.queryParameters['bvid'], 'BV1xx411c7mD');
    expect(request.uri.queryParameters['cid'], '7');
    expect(request.uri.queryParameters['wts'], isNotEmpty);
    expect(request.uri.queryParameters['w_rid'], isNotEmpty);
    expect(request.headers['Cookie'], contains('buvid3=buvid3-test'));
    expect(sessionFetches(adapter), 1, reason: '成功响应不应刷新会话');
  });

  test('session 端点 -403：刷新会话一次后重试成功', () async {
    var calls = 0;
    final adapter = adapterOf((options) async {
      if (options.uri.path == '/x/web-interface/wbi/search/type') {
        calls++;
        if (calls == 1) {
          return textResponse(jsonEncode({'code': -403, 'message': '风控'}));
        }
        return textResponse(
          jsonEncode({
            'code': 0,
            'data': {'ok': true},
          }),
        );
      }
      return textResponse('{}', statusCode: 500);
    });
    final client = clientOf(adapter);

    final response = await client.get(
      '/x/web-interface/wbi/search/type',
      query: {'keyword': '起风了'},
      auth: BiliAuth.session,
    );

    expect(response['data'], {'ok': true});
    expect(calls, 2);
    expect(sessionFetches(adapter), 2, reason: '命中风控只刷新一次');
  });

  test('session 端点 -403 持续：只刷新一次，最终 unknown（不是 notFound）', () async {
    var calls = 0;
    final adapter = adapterOf((options) async {
      if (options.uri.path == '/x/web-interface/wbi/search/type') {
        calls++;
        return textResponse(jsonEncode({'code': -403, 'message': '风控'}));
      }
      return textResponse('{}', statusCode: 500);
    });
    final client = clientOf(adapter);

    await expectLater(
      client.get(
        '/x/web-interface/wbi/search/type',
        query: {'keyword': '起风了'},
        auth: BiliAuth.session,
      ),
      throwsA(
        isA<SourceFailure>()
            .having((f) => f.kind, 'kind', FailureKind.unknown)
            .having((f) => f.retryable, 'retryable', isTrue),
      ),
    );
    expect(calls, 2, reason: '首次 + 刷新后重试一次');
    expect(sessionFetches(adapter), 2, reason: '刷新也只发生一次');
  });

  test('标准口径 -404：notFound 且不刷新会话', () async {
    final adapter = adapterOf(
      (options) async => textResponse(jsonEncode({'code': -404})),
    );
    final client = clientOf(adapter);

    await expectLater(
      client.get('/x/player/wbi/playurl', auth: BiliAuth.session),
      throwsA(
        isA<SourceFailure>()
            .having((f) => f.kind, 'kind', FailureKind.notFound)
            .having((f) => f.retryable, 'retryable', isFalse),
      ),
    );
    expect(
      adapter.requests.where((r) => r.uri.path == '/x/player/wbi/playurl'),
      hasLength(1),
    );
    expect(sessionFetches(adapter), 1, reason: '-404 不是风控');
  });

  test('收藏夹口径 -403：notFound（私密 / 失效），不拉会话、不刷新', () async {
    final adapter = adapterOf(
      (options) async => textResponse(jsonEncode({'code': -403})),
    );
    final client = clientOf(adapter);

    await expectLater(
      client.get(
        '/x/v3/fav/resource/list',
        query: {'media_id': '123'},
        codePolicy: BiliCodePolicy.favorites,
      ),
      throwsA(
        isA<SourceFailure>()
            .having((f) => f.kind, 'kind', FailureKind.notFound)
            .having((f) => f.retryable, 'retryable', isFalse),
      ),
    );
    expect(
      adapter.requests.where((r) => r.uri.path == '/x/v3/fav/resource/list'),
      hasLength(1),
    );
    expect(sessionFetches(adapter), 0, reason: '收藏夹的 -403 不是会话风控');
  });

  test('匿名口径：不带 Cookie，也不拉 buvid / WBI 会话', () async {
    final adapter = adapterOf(
      (options) async => textResponse(jsonEncode({'code': 0, 'data': {}})),
    );
    final client = clientOf(adapter);

    await client.get('/x/v2/reply/main', query: {'oid': '1'});

    final request = adapter.requests.singleWhere(
      (r) => r.uri.path == '/x/v2/reply/main',
    );
    expect(request.headers['Referer'], 'https://www.bilibili.com/');
    expect(request.headers['User-Agent'], contains('Chrome/'));
    expect(request.headers.containsKey('Cookie'), isFalse);
    expect(sessionFetches(adapter), 0);
  });

  test(
    '账号口径：account / accountSession 带账号 Cookie，session / anonymous 不带',
    () async {
      session.apply(
        cookieHeader: 'SESSDATA=test-sessdata; bili_jct=test-jct',
        account: const BiliAccount(userId: '1'),
      );
      final adapter = adapterOf((options) async {
        switch (options.uri.path) {
          case '/x/web-interface/nav':
            return textResponse(
              jsonEncode({
                'code': 0,
                'data': {'isLogin': true},
              }),
            );
          case '/x/player/wbi/v2':
          case '/x/player/wbi/playurl':
          case '/x/v2/reply/main':
            return textResponse(jsonEncode({'code': 0, 'data': {}}));
          default:
            return textResponse('{}', statusCode: 500);
        }
      });
      final client = clientOf(adapter);

      // 账号资料：只带账号 Cookie，不拉 buvid / WBI。
      await client.get(
        '/x/web-interface/nav',
        auth: BiliAuth.account,
        codePolicy: BiliCodePolicy.none,
      );
      final nav = adapter.requests.last;
      expect(
        nav.headers['Cookie'],
        'SESSDATA=test-sessdata; bili_jct=test-jct',
      );
      expect(sessionFetches(adapter), 0);

      // 字幕：buvid + WBI + 账号 Cookie。
      await client.get(
        '/x/player/wbi/v2',
        query: {'bvid': 'BV1xx411c7mD', 'cid': 1},
        auth: BiliAuth.accountSession,
      );
      final subtitle = adapter.requests.last;
      expect(subtitle.headers['Cookie'], contains('buvid3=buvid3-test'));
      expect(subtitle.headers['Cookie'], contains('SESSDATA=test-sessdata'));
      expect(subtitle.uri.queryParameters['w_rid'], isNotEmpty);

      // 播放取链：即使已登录也不能带账号 Cookie。
      await client.get(
        '/x/player/wbi/playurl',
        query: {'bvid': 'BV1xx411c7mD', 'cid': 1},
        auth: BiliAuth.session,
      );
      final playurl = adapter.requests.last;
      expect(playurl.headers['Cookie'], contains('buvid3=buvid3-test'));
      expect(playurl.headers['Cookie'], isNot(contains('SESSDATA')));

      // 评论 / 搜索等匿名端点：完全不带 Cookie。
      await client.get('/x/v2/reply/main', query: {'oid': '1'});
      final reply = adapter.requests.last;
      expect(reply.headers.containsKey('Cookie'), isFalse);
    },
  );

  test('空 body / 非 JSON：归一为 network 失败（可重试）', () async {
    for (final body in ['', '<html>not json</html>']) {
      final adapter = adapterOf((options) async => textResponse(body));
      final client = clientOf(adapter);

      await expectLater(
        client.get('/x/web-interface/ranking'),
        throwsA(
          isA<SourceFailure>()
              .having((f) => f.kind, 'kind', FailureKind.network)
              .having((f) => f.retryable, 'retryable', isTrue),
        ),
        reason: 'body=${body.isEmpty ? 'empty' : 'html'}',
      );
    }
  });

  test('无业务码的静态 JSON：不校验 code，仍走匿名请求头', () async {
    final adapter = adapterOf(
      (options) async => textResponse(jsonEncode({'body': []})),
    );
    final client = clientOf(adapter);

    final body = await client.get(
      'https://aisubtitle.hdslb.com/bfs/subtitle/zh.json',
      codePolicy: BiliCodePolicy.none,
    );

    expect(body['body'], isEmpty);
    final request = adapter.requests.single;
    expect(request.uri.host, 'aisubtitle.hdslb.com');
    expect(request.headers.containsKey('Cookie'), isFalse);
    expect(sessionFetches(adapter), 0);
  });
}
