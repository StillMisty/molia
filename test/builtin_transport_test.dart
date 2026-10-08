import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/builtin/kw_search.dart';

/// 内置传输层：客户端注入、请求头/超时、响应级重试、JSON 解码；
/// 并验证平台搜索 fetch 路径可被 MockClient 完整覆盖（旧实现不可测）。
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
    Map<String, String>? seenHeaders;
    final transport = BuiltinTransport(client: MockClient((request) async {
      seenUri = request.url;
      seenHeaders = request.headers;
      return http.Response(jsonEncode({'ok': 1}), 200);
    }));

    final json = await transport.getJson('https://example.com/x');
    expect(json, {'ok': 1});
    expect(seenUri.toString(), 'https://example.com/x');
    expect(seenHeaders!['User-Agent'], contains('Mozilla'));
  });

  test('getJson：空 body / 非法 JSON 抛 BuiltinHttpException 且不重试', () async {
    var calls = 0;
    final transport = BuiltinTransport(client: MockClient((_) async {
      calls++;
      return http.Response('', 200);
    }));

    await expectLater(
      transport.getJson('https://example.com/x', retries: 3),
      throwsA(isA<BuiltinHttpException>()),
    );
    expect(calls, 1);
  });

  test('getJson：retryIf 响应级重试，耗尽后返回最后一次结果', () async {
    var calls = 0;
    final transport = BuiltinTransport(client: MockClient((_) async {
      calls++;
      return http.Response(jsonEncode({'code': calls}), 200);
    }));

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
    final transport = BuiltinTransport(client: MockClient((_) async {
      calls++;
      throw http.ClientException('boom');
    }));

    await expectLater(
      transport.getJson('https://example.com/x', retries: 3),
      throwsA(isA<BuiltinHttpException>()),
    );
    expect(calls, 3);
  });

  test('postJson：form 编码与 Content-Type', () async {
    String? seenBody;
    String? contentType;
    final transport = BuiltinTransport(client: MockClient((request) async {
      seenBody = request.body;
      contentType = request.headers['Content-Type'];
      return http.Response(jsonEncode({'ok': true}), 200);
    }));

    await transport.postJson(
      'https://example.com/x',
      form: true,
      body: {'a': 'b c'},
    );
    expect(seenBody, 'a=b+c');
    expect(contentType, 'application/x-www-form-urlencoded');
  });

  test('平台搜索 fetch 路径：注入 MockClient 后 KwSearch 端到端解析', () async {
    BuiltinSearch.transport = BuiltinTransport(client: MockClient((request) async {
      expect(request.url.host, 'search.kuwo.cn');
      return http.Response(
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
        200,
      );
    }));

    final result = await KwSearch.searchWithMeta('hello');
    expect(result.tracks, hasLength(1));
    expect(result.tracks.single.title, 'Hello');
    expect(result.tracks.single.raw['songmid'], '1');
  });

  test('平台搜索响应级重试：首轮空页后重试成功', () async {
    var calls = 0;
    BuiltinSearch.transport = BuiltinTransport(client: MockClient((_) async {
      calls++;
      final first = calls == 1;
      return http.Response(
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
        200,
      );
    }));

    final result = await KwSearch.searchWithMeta('hello');
    expect(calls, 2);
    expect(result.tracks, hasLength(1));
  });
}
