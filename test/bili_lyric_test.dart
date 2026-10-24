import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/bili_api.dart';
import 'package:molia/sources/builtin/bili_lyric.dart';
import 'package:molia/sources/builtin/bili_play.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';

import 'support/mock_dio.dart';

/// B 站 CC 字幕歌词：选轨（中文优先）、LRC 时间轴、协议相对地址与失败降级。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BuiltinTransport originalTransport;
  late List<RequestOptions> options;
  late List<Map<String, dynamic>> subtitles;
  late int playerCode;
  late int pagelistCalls;

  setUpAll(() => originalTransport = BuiltinSearch.transport);

  setUp(() {
    BiliApi.reset();
    BiliPlay.reset();
    options = [];
    pagelistCalls = 0;
    playerCode = 0;

    const zhUrl = '//aisubtitle.hdslb.com/bfs/subtitle/zh.json';
    const enUrl = 'https://aisubtitle.hdslb.com/bfs/subtitle/en.json';
    subtitles = [
      {
        'lan': 'en-US',
        'lan_doc': 'English',
        'subtitle_url': enUrl,
      },
      {
        'lan': 'zh-CN',
        'lan_doc': '中文（中国）',
        'subtitle_url': zhUrl,
      },
    ];

    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((request) async {
        options.add(request);
        switch (request.uri.path) {
          case '/x/frontend/finger/spi':
            return textResponse(
              jsonEncode({
                'code': 0,
                'data': {'b_3': 'buvid3-test', 'b_4': 'buvid4-test'},
              }),
            );
          case '/x/web-interface/nav':
            return textResponse(
              jsonEncode({
                'code': -101,
                'data': {
                  'wbi_img': {
                    'img_url': 'https://i0.hdslb.com/bfs/wbi/'
                        '7cd084941338484aae1ad9425b84077c.png',
                    'sub_url': 'https://i0.hdslb.com/bfs/wbi/'
                        '4932caff0ff746eab6f01bf08b70ac45.png',
                  },
                },
              }),
            );
          case '/x/player/pagelist':
            pagelistCalls++;
            return textResponse(
              jsonEncode({
                'code': 0,
                'data': [
                  {'cid': 12345, 'page': 1, 'part': 'P1'},
                ],
              }),
            );
          case '/x/player/v2':
            return textResponse(
              jsonEncode({
                'code': playerCode,
                'data': {
                  'subtitle': {'subtitles': subtitles},
                },
              }),
            );
          case '/bfs/subtitle/zh.json':
            return textResponse(
              jsonEncode({
                'body': [
                  {'from': 1.5, 'to': 2.1, 'content': '第一行'},
                  {'from': 0.25, 'to': 1.0, 'content': '第二行\n第三行'},
                  {'from': 2.2, 'to': 2.5, 'content': '   '},
                ],
              }),
            );
          case '/bfs/subtitle/en.json':
            return textResponse(
              jsonEncode({
                'body': [
                  {'from': 0.0, 'to': 1.0, 'content': 'English line'},
                ],
              }),
            );
          case '/bfs/subtitle/empty.json':
            return textResponse(jsonEncode({'body': []}));
          default:
            return textResponse('{}', statusCode: 500);
        }
      }),
    );
  });

  tearDown(() => BuiltinSearch.transport = originalTransport);

  test('中文优先：选 zh-CN，按 from 排序并生成 LRC；与取链共用 cid', () async {
    final lyric = await BiliLyric.fetch(const {
      'bvid': 'BV1xx411c7mD',
      'aid': 987654,
    });

    expect(lyric, isNotNull);
    expect(
      lyric!.lyric,
      '[00:00.250]第二行\n[00:00.250]第三行\n[00:01.500]第一行',
    );

    final player = options.firstWhere((o) => o.uri.path == '/x/player/v2');
    expect(player.uri.queryParameters['bvid'], 'BV1xx411c7mD');
    expect(player.uri.queryParameters['cid'], '12345');
    expect(player.headers['Referer'], 'https://www.bilibili.com/');
    expect(player.headers['User-Agent'], contains('Chrome/'));
    expect(player.headers['Cookie'], contains('buvid3=buvid3-test'));

    final subtitle = options.firstWhere(
      (o) => o.uri.path == '/bfs/subtitle/zh.json',
    );
    expect(subtitle.uri.scheme, 'https', reason: '// 开头必须补 https');
    expect(subtitle.uri.host, 'aisubtitle.hdslb.com');
    expect(subtitle.headers['Cookie'], contains('buvid3=buvid3-test'));
    expect(
      options.any((o) => o.uri.path == '/bfs/subtitle/en.json'),
      isFalse,
      reason: '有中文轨时不应再取英文轨',
    );

    // 取链复用同一 cid：歌词拉过之后不应再查分 P。
    expect(await BiliPlay.cidOf(const {'bvid': 'BV1xx411c7mD'}), 12345);
    expect(pagelistCalls, 1);
  });

  test('raw 带 cid：不查分 P', () async {
    final lyric = await BiliLyric.fetch(const {
      'bvid': 'BV1xx411c7mD',
      'cid': 777,
    });

    expect(lyric, isNotNull);
    expect(pagelistCalls, 0);
    final player = options.firstWhere((o) => o.uri.path == '/x/player/v2');
    expect(player.uri.queryParameters['cid'], '777');
  });

  test('无中文轨：取第一条有地址的字幕，协议相对地址补 https', () async {
    subtitles = [
      {
        'lan': 'en-US',
        'lan_doc': 'English',
        'subtitle_url': '//aisubtitle.hdslb.com/bfs/subtitle/en.json',
      },
    ];

    final lyric =
        await BiliLyric.fetch(const {'bvid': 'BV1xx411c7mD', 'cid': 777});
    expect(lyric?.lyric, '[00:00.000]English line');

    final subtitle = options.firstWhere(
      (o) => o.uri.path == '/bfs/subtitle/en.json',
    );
    expect(subtitle.uri.scheme, 'https');
  });

  test('lan 未知但 lan_doc 含「中文」：按中文轨优先', () async {
    subtitles = [
      {
        'lan': 'unknown',
        'lan_doc': 'English',
        'subtitle_url': 'https://aisubtitle.hdslb.com/bfs/subtitle/en.json',
      },
      {
        'lan': 'unknown',
        'lan_doc': '中文（自动生成）',
        'subtitle_url': 'https://aisubtitle.hdslb.com/bfs/subtitle/zh.json',
      },
    ];

    final lyric =
        await BiliLyric.fetch(const {'bvid': 'BV1xx411c7mD', 'cid': 777});
    expect(lyric?.lyric, contains('第一行'));
  });

  test('无字幕轨 / 空字幕文件：返回 null 且不报错', () async {
    subtitles = [];
    expect(await BiliLyric.fetch(const {'bvid': 'BV1xx411c7mD', 'cid': 777}),
        isNull);

    subtitles = [
      {
        'lan': 'zh-CN',
        'lan_doc': '中文（中国）',
        'subtitle_url': 'https://aisubtitle.hdslb.com/bfs/subtitle/empty.json',
      },
    ];
    expect(await BiliLyric.fetch(const {'bvid': 'BV1xx411c7mD', 'cid': 777}),
        isNull);
  });

  test('业务码失败：返回 null（歌词失败不影响播放）', () async {
    playerCode = -404;
    expect(await BiliLyric.fetch(const {'bvid': 'BV1xx411c7mD', 'cid': 777}),
        isNull);
  });

  test('缺少 bvid / aid：返回 null 且不发请求', () async {
    expect(await BiliLyric.fetch(const {'cid': 777}), isNull);
    expect(options, isEmpty);
  });
}
