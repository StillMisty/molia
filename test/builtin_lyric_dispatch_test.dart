import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/builtin_lyric_dispatch.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/builtin/mg_lyric.dart';
import 'package:molia/sources/builtin/zlib_io.dart' as zlib_impl;
import 'package:molia/sources/source_track.dart';

import 'support/mock_dio.dart';

/// 内置平台原生取词派发（BuiltinLyricDispatch）契约：五平台分派、空 raw
/// 降级、缓存与失败不缓存。只经 [BuiltinLyricDispatch.fetch] 接口验证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BuiltinTransport originalTransport;
  setUpAll(() => originalTransport = BuiltinSearch.transport);
  tearDown(() => BuiltinSearch.transport = originalTransport);

  SourceTrack track(String sourceKey, Map<String, dynamic> raw) => SourceTrack(
        sourceKey: sourceKey,
        origin: 'builtin',
        title: '测试',
        artist: '歌手',
        album: '',
        raw: raw,
      );

  /// 酷我 LRCX：`TP=content` + zlib + `yeelion` XOR（与平台真实编码一致）。
  List<int> encodeLrcx(String text) {
    final inner = utf8.encode(text);
    const key = 'yeelion';
    final xored = Uint8List(inner.length);
    for (var i = 0; i < inner.length; i++) {
      xored[i] = inner[i] ^ key.codeUnitAt(i % key.length);
    }
    final compressed = zlib_impl.zlibDeflate(utf8.encode(base64.encode(xored)));
    return [
      ...utf8.encode('TP=content\r\nlrcx=1\r\n\r\n'),
      ...compressed,
    ];
  }

  test('五平台分派：请求落到各自平台端点，命中解码结果', () async {
    final requests = <Uri>[];
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((request) async {
        requests.add(request.uri);
        switch (request.uri.host) {
          case 'mlyric.kuwo.cn':
            return bytesResponse(
              encodeLrcx('[kuwo:127]\n[00:00.000]<1120,-1120>你<2400,160>好\n'),
              statusCode: 200,
            );
          case 'interface3.music.163.com':
            return textResponse(
              jsonEncode({
                'code': 200,
                'lrc': {'lyric': '[00:00.000]你好'},
              }),
              statusCode: 200,
            );
          case 'u.y.qq.com':
            return textResponse(
              jsonEncode({
                'code': 0,
                'req': {
                  'code': 0,
                  'data': {'lyric': '[0,1000]你(0,200)好(200,300)\n'},
                },
              }),
              statusCode: 200,
            );
          case 'lyrics.kugou.com':
            if (request.uri.path.contains('/search')) {
              return textResponse(
                jsonEncode({
                  'candidates': [
                    {'id': 'c1', 'accesskey': 'k1'},
                  ],
                }),
                statusCode: 200,
              );
            }
            return textResponse(
              jsonEncode({
                'fmt': 'lrc',
                'content': base64.encode(utf8.encode('[00:00.000]你好')),
              }),
              statusCode: 200,
            );
          case 'mrc.example':
            return textResponse(
              MgLyric.encrypt('[1000,500]你(1000,200)好(1200,300)\n'),
              statusCode: 200,
            );
          default:
            return textResponse('意外请求：${request.uri}', statusCode: 500);
        }
      }),
    );

    final dispatch = BuiltinLyricDispatch();
    final kw = await dispatch.fetch(track('kw', {'songmid': '228908'}));
    final wy = await dispatch.fetch(track('wy', {'songmid': '1399112638'}));
    final tx = await dispatch.fetch(track('tx', {'songId': '123'}));
    final kg = await dispatch.fetch(track('kg', {
      'hash': 'HASH',
      'name': '测试',
      '_interval': 200,
    }));
    final mg = await dispatch.fetch(track('mg', {
      'songmid': '1',
      'mrcUrl': 'https://mrc.example/mrc',
    }));

    expect(kw?.lyric, contains('你好'), reason: 'kw 走 LRCX 解码');
    expect(kw?.lxlyric, contains('<0,160>你'), reason: 'kw 逐字时间不可丢');
    expect(wy?.lyric, contains('你好'), reason: 'wy 走 eapi 歌词接口');
    expect(tx?.lyric, contains('你好'), reason: 'tx 走 PlayLyricInfo');
    expect(tx?.lxlyric, contains('<0,200>你'), reason: 'tx QRC 逐字时间不可丢');
    expect(kg?.lyric, contains('你好'), reason: 'kg 走 KRC 搜索 + 下载');
    expect(mg?.lyric, contains('你好'), reason: 'mg 走 MRC 解密');
    expect(mg?.lxlyric, contains('<0,200>你'), reason: 'mg MRC 逐字时间不可丢');

    expect(
      requests.map((uri) => uri.host).toSet(),
      containsAll([
        'mlyric.kuwo.cn',
        'interface3.music.163.com',
        'u.y.qq.com',
        'lyrics.kugou.com',
        'mrc.example',
      ]),
    );
    // kg 的 timelength 来自 `_interval` 秒（缺省 0 会让平台少返回逐字歌词）。
    expect(
      requests
          .singleWhere((uri) =>
              uri.host == 'lyrics.kugou.com' && uri.path.contains('search'))
          .query,
      contains('timelength=200'),
    );
  });

  test('空 raw / 非内置平台：降级返回 null 且不发请求', () async {
    final requests = <RequestOptions>[];
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((request) async {
        requests.add(request);
        return textResponse('{}', statusCode: 200);
      }),
    );

    final dispatch = BuiltinLyricDispatch();
    expect(await dispatch.fetch(track('wy', const {})), isNull);
    expect(await dispatch.fetch(track('tx', const {})), isNull);
    expect(await dispatch.fetch(track('kg', const {})), isNull);
    expect(await dispatch.fetch(track('kw', const {})), isNull);
    expect(await dispatch.fetch(track('mg', const {})), isNull);
    expect(
      await dispatch.fetch(track('custom-source', {'songmid': '1'})),
      isNull,
    );
    expect(requests, isEmpty);
  });

  test('缓存：失败不进缓存、成功命中缓存', () async {
    final song = track('wy', {'songmid': '42'});
    var calls = 0;
    var healthy = false;
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((request) async {
        calls++;
        if (!healthy) {
          // HTTP 200 但业务拒绝：取词失败，且不触发传输层重试。
          return textResponse('{}', statusCode: 200);
        }
        return textResponse(
          jsonEncode({
            'code': 200,
            'lrc': {'lyric': '[00:00.000]你好'},
          }),
          statusCode: 200,
        );
      }),
    );

    final dispatch = BuiltinLyricDispatch();
    expect(await dispatch.fetch(song), isNull);
    expect(calls, 1);

    healthy = true;
    expect((await dispatch.fetch(song))?.lyric, contains('你好'));
    expect(calls, 2, reason: '失败不进缓存：下一次调用重新请求');

    expect((await dispatch.fetch(song))?.lyric, contains('你好'));
    expect(calls, 2, reason: '成功后命中缓存：同曲目不再请求');
  });
}
