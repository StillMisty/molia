import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/builtin/kw_search.dart';
import 'package:molia/sources/builtin/wy_hot_search.dart';

import 'support/mock_dio.dart';

/// 内置传输层：客户端注入、请求头/超时、响应级重试、JSON 解码；
/// 并验证平台搜索 fetch 路径可被 MockClient 完整覆盖。
void main() {
  late BuiltinTransport original;

  setUp(() {
    original = BuiltinSearch.transport;
  });

  tearDown(() {
    BuiltinSearch.transport = original;
  });

  test('getJson：成功解码并合并默认请求头', () async {
    Uri? seenUri;
    Map<String, dynamic>? seenHeaders;
    final transport = BuiltinTransport(
      dio: mockDio((request) async {
        seenUri = request.uri;
        seenHeaders = request.headers;
        return textResponse(jsonEncode({'ok': 1}), statusCode: 200);
      }),
    );

    final json = await transport.getJson('https://example.com/x');
    expect(json, {'ok': 1});
    expect(seenUri.toString(), 'https://example.com/x');
    expect(seenHeaders!['User-Agent'], contains('Mozilla'));
  });

  test('getJson：空 body / 非法 JSON 抛 BuiltinHttpException 且不重试', () async {
    var calls = 0;
    final transport = BuiltinTransport(
      dio: mockDio((_) async {
        calls++;
        return textResponse('', statusCode: 200);
      }),
    );

    await expectLater(
      transport.getJson('https://example.com/x', retries: 3),
      throwsA(isA<BuiltinHttpException>()),
    );
    expect(calls, 1);
  });

  test('getJson：retryIf 响应级重试，耗尽后返回最后一次结果', () async {
    var calls = 0;
    final transport = BuiltinTransport(
      dio: mockDio((_) async {
        calls++;
        return textResponse(jsonEncode({'code': calls}), statusCode: 200);
      }),
    );

    final json = await transport.getJson(
      'https://example.com/x',
      retries: 3,
      retryIf: (value) => value is Map && value['code'] != 3,
    );
    expect(calls, 3);
    expect(json, {'code': 3});
  });

  test('传输异常：重试耗尽后抛 BuiltinHttpException', () async {
    var calls = 0;
    final transport = BuiltinTransport(
      dio: mockDio((_) async {
        calls++;
        throw Exception('boom');
      }),
    );

    await expectLater(
      transport.getJson('https://example.com/x', retries: 3),
      throwsA(isA<BuiltinHttpException>()),
    );
    expect(calls, 3);
  });

  test('postJson：form 编码与 Content-Type', () async {
    String? seenBody;
    String? contentType;
    final transport = BuiltinTransport(
      dio: mockDio((request) async {
        seenBody = requestBodyText(request);
        contentType = request.headers['Content-Type'];
        return textResponse(jsonEncode({'ok': true}), statusCode: 200);
      }),
    );

    await transport.postJson(
      'https://example.com/x',
      form: true,
      body: {'a': 'b c'},
    );
    expect(seenBody, 'a=b+c');
    expect(contentType, 'application/x-www-form-urlencoded');
  });

  test('平台搜索 fetch 路径：注入 MockClient 后 KwSearch 端到端解析', () async {
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((request) async {
        expect(request.uri.host, 'search.kuwo.cn');
        return textResponse(
          jsonEncode({
            'TOTAL': '1',
            'SHOW': '1',
            'abslist': [
              {
                'MUSICRID': 'MUSIC_1',
                'N_MINFO': 'level:320,bitrate:320,format:mp3,size:1.2M',
                'DURATION': '180',
                'SONGNAME': 'Hello',
                'ARTIST': 'Tester',
                'ALBUM': 'Album',
                'ALBUMID': '9',
              },
            ],
          }),
          statusCode: 200,
        );
      }),
    );

    final result = await KwSearch.searchWithMeta('hello');
    expect(result.tracks, hasLength(1));
    expect(result.tracks.single.title, 'Hello');
    expect(result.tracks.single.raw['songmid'], '1');
  });

  test('平台搜索响应级重试：首轮空页后重试成功', () async {
    var calls = 0;
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((_) async {
        calls++;
        final first = calls == 1;
        return textResponse(
          jsonEncode({
            'TOTAL': '1',
            'SHOW': first ? '0' : '1',
            'abslist': first
                ? []
                : [
                    {
                      'MUSICRID': 'MUSIC_1',
                      'N_MINFO': 'level:128,bitrate:128,format:mp3,size:0.8M',
                      'DURATION': '180',
                      'SONGNAME': 'Hello',
                      'ARTIST': 'Tester',
                      'ALBUM': 'Album',
                      'ALBUMID': '9',
                    },
                  ],
          }),
          statusCode: 200,
        );
      }),
    );

    final result = await KwSearch.searchWithMeta('hello');
    expect(calls, 2);
    expect(result.tracks, hasLength(1));
  });

  test('clearCache：清空结果缓存，在途结果不复活，可重复调用', () async {
    var calls = 0;
    final transport = BuiltinTransport(
      dio: mockDio((_) async => textResponse('{}', statusCode: 200)),
    );

    Future<String> load() => transport.cached('demo', () async {
      calls++;
      return 'value-$calls';
    });

    expect(await load(), 'value-1');
    expect(await load(), 'value-1', reason: '命中缓存');
    expect(calls, 1);

    transport
      ..clearCache()
      ..clearCache();
    expect(await load(), 'value-2', reason: '清空后重新取数');
    expect(calls, 2);

    // 在途请求仍返回给原等待方，但不会把结果写回已清空的缓存。
    final gate = Completer<String>();
    final pending = transport.cached('inflight', () {
      calls++;
      return gate.future;
    });
    transport.clearCache();
    gate.complete('old');
    expect(await pending, 'old');
    expect(
      await transport.cached('inflight', () async {
        calls++;
        return 'new';
      }),
      'new',
      reason: '旧任务不回填缓存',
    );
    expect(calls, 4);
  });

  test('发现适配器 fetch：WyHotSearch 走注入客户端且结果被缓存', () async {
    var requests = 0;
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((request) async {
        requests++;
        return bytesResponse(
          utf8.encode(
            jsonEncode({
              'code': 200,
              'data': {
                'itemList': [
                  {'searchWord': '热词一'},
                  {'searchWord': '热词二'},
                ],
              },
            }),
          ),
          statusCode: 200,
        );
      }),
    );

    final words = await WyHotSearch.getList();
    expect(words, ['热词一', '热词二']);
    final again = await WyHotSearch.getList();
    expect(again, words);
    expect(requests, 1, reason: '第二次命中 transport 缓存');
  });
}
