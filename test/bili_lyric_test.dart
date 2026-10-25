import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/bili_account.dart';
import 'package:molia/sources/builtin/bili_account.dart';
import 'package:molia/sources/builtin/bili_api.dart';
import 'package:molia/sources/builtin/bili_lyric.dart';
import 'package:molia/sources/builtin/bili_play.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';

import 'support/bili_session_mock.dart';
import 'support/mock_dio.dart';

/// B 站 CC 字幕歌词：登录态、WBI 取字幕、选轨、LRC 时间轴与失败降级。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BuiltinTransport originalTransport;
  late List<RequestOptions> options;
  late List<Map<String, dynamic>> subtitles;
  late int playerCode;
  late int pagelistCalls;

  const accountCookie = 'SESSDATA=test-sessdata; bili_jct=test-jct';

  setUpAll(() => originalTransport = BuiltinSearch.transport);

  setUp(() {
    BiliApi.reset();
    BiliPlay.reset();
    BiliAccountStore.instance.reset();
    options = [];
    pagelistCalls = 0;
    playerCode = 0;

    const zhUrl = '//aisubtitle.hdslb.com/bfs/subtitle/zh.json';
    const enUrl = 'https://aisubtitle.hdslb.com/bfs/subtitle/en.json';
    subtitles = [
      {'lan': 'en-US', 'lan_doc': 'English', 'subtitle_url': enUrl},
      {'lan': 'zh-CN', 'lan_doc': '中文（中国）', 'subtitle_url': zhUrl},
    ];

    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((request) async {
        options.add(request);
        final sessionResponse = biliSessionResponse(request);
        if (sessionResponse != null) return sessionResponse;
        switch (request.uri.path) {
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
          case '/x/player/wbi/v2':
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

  tearDown(() {
    BuiltinSearch.transport = originalTransport;
    BiliAccountStore.instance.reset();
  });

  void login() {
    BiliAccountStore.instance.update(
      cookieHeader: accountCookie,
      account: const BiliAccount(userId: '1'),
    );
  }

  test('未登录：直接返回 null，不发任何 B 站请求', () async {
    final lyric = await BiliLyric.fetch(const {
      'bvid': 'BV1xx411c7mD',
      'aid': 987654,
    });
    expect(lyric, isNull);
    expect(options, isEmpty);
  });

  test('登录后中文优先：WBI + 账号 Cookie，按 from 排序并生成 LRC', () async {
    login();
    final lyric = await BiliLyric.fetch(const {
      'bvid': 'BV1xx411c7mD',
      'aid': 987654,
    });

    expect(lyric, isNotNull);
    expect(lyric!.lyric, '[00:00.250]第二行\n[00:00.250]第三行\n[00:01.500]第一行');

    final player = options.firstWhere((o) => o.uri.path == '/x/player/wbi/v2');
    expect(player.uri.queryParameters['bvid'], 'BV1xx411c7mD');
    expect(player.uri.queryParameters['cid'], '12345');
    expect(player.uri.queryParameters['wts'], isNotEmpty);
    expect(player.uri.queryParameters['w_rid'], isNotEmpty);
    expect(player.headers['Referer'], 'https://www.bilibili.com/');
    expect(player.headers['User-Agent'], contains('Chrome/'));
    expect(player.headers['Cookie'], contains('SESSDATA=test-sessdata'));
    expect(player.headers['Cookie'], contains('buvid3=buvid3-test'));

    final subtitle = options.firstWhere(
      (o) => o.uri.path == '/bfs/subtitle/zh.json',
    );
    expect(subtitle.uri.scheme, 'https', reason: '// 开头必须补 https');
    expect(subtitle.uri.host, 'aisubtitle.hdslb.com');
    expect(
      subtitle.headers.containsKey('Cookie'),
      isFalse,
      reason: '字幕 CDN 是公开资源，不能带账号 Cookie',
    );
    expect(
      options.any((o) => o.uri.path == '/bfs/subtitle/en.json'),
      isFalse,
      reason: '有中文轨时不应再取英文轨',
    );

    // 取链复用同一 cid：歌词拉过之后不应再查分 P。
    expect(await BiliPlay.cidOf(const {'bvid': 'BV1xx411c7mD'}), 12345);
    expect(pagelistCalls, 1);
    final pagelist = options.firstWhere(
      (o) => o.uri.path == '/x/player/pagelist',
    );
    expect(pagelist.headers.containsKey('Cookie'), isFalse);
  });

  test('WBI 失败时退回 unsigned 账号接口', () async {
    login();
    var wbiCalls = 0;
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((request) async {
        options.add(request);
        final sessionResponse = biliSessionResponse(request);
        if (sessionResponse != null) return sessionResponse;
        if (request.uri.path == '/x/player/wbi/v2') {
          wbiCalls++;
          return textResponse(jsonEncode({'code': -352, 'message': '风控'}));
        }
        if (request.uri.path == '/x/player/pagelist') {
          return textResponse(
            jsonEncode({
              'code': 0,
              'data': [
                {'cid': 12345},
              ],
            }),
          );
        }
        if (request.uri.path == '/x/player/v2') {
          return textResponse(
            jsonEncode({
              'code': 0,
              'data': {
                'subtitle': {'subtitles': subtitles},
              },
            }),
          );
        }
        if (request.uri.path == '/bfs/subtitle/zh.json') {
          return textResponse(
            jsonEncode({
              'body': [
                {'from': 1.0, 'content': '退回成功'},
              ],
            }),
          );
        }
        return textResponse('{}', statusCode: 500);
      }),
    );

    final lyric = await BiliLyric.fetch(const {'bvid': 'BV1xx411c7mD'});
    expect(lyric?.lyric, '[00:01.000]退回成功');
    expect(wbiCalls, 2, reason: '风控刷新一次 + 重试仍失败');
    final fallback = options.firstWhere((o) => o.uri.path == '/x/player/v2');
    expect(fallback.headers['Cookie'], contains('SESSDATA=test-sessdata'));
  });

  test('raw 带 cid：不查分 P', () async {
    login();
    final lyric = await BiliLyric.fetch(const {
      'bvid': 'BV1xx411c7mD',
      'cid': 777,
    });

    expect(lyric, isNotNull);
    expect(pagelistCalls, 0);
    final player = options.firstWhere((o) => o.uri.path == '/x/player/wbi/v2');
    expect(player.uri.queryParameters['cid'], '777');
  });

  test('无中文轨：取第一条有地址的字幕，协议相对地址补 https', () async {
    login();
    subtitles = [
      {
        'lan': 'en-US',
        'lan_doc': 'English',
        'subtitle_url': '//aisubtitle.hdslb.com/bfs/subtitle/en.json',
      },
    ];

    final lyric = await BiliLyric.fetch(const {
      'bvid': 'BV1xx411c7mD',
      'cid': 777,
    });
    expect(lyric?.lyric, '[00:00.000]English line');

    final subtitle = options.firstWhere(
      (o) => o.uri.path == '/bfs/subtitle/en.json',
    );
    expect(subtitle.uri.scheme, 'https');
  });

  test('lan 未知但 lan_doc 含「中文」：按中文轨优先', () async {
    login();
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

    final lyric = await BiliLyric.fetch(const {
      'bvid': 'BV1xx411c7mD',
      'cid': 777,
    });
    expect(lyric?.lyric, contains('第一行'));
  });

  test('无字幕轨 / 空字幕文件：返回 null 且不报错', () async {
    login();
    subtitles = [];
    expect(
      await BiliLyric.fetch(const {'bvid': 'BV1xx411c7mD', 'cid': 777}),
      isNull,
    );

    subtitles = [
      {
        'lan': 'zh-CN',
        'lan_doc': '中文（中国）',
        'subtitle_url': 'https://aisubtitle.hdslb.com/bfs/subtitle/empty.json',
      },
    ];
    expect(
      await BiliLyric.fetch(const {'bvid': 'BV1xx411c7mD', 'cid': 777}),
      isNull,
    );
  });

  test('业务码失败：返回 null（歌词失败不影响播放）', () async {
    login();
    playerCode = -404;
    expect(
      await BiliLyric.fetch(const {'bvid': 'BV1xx411c7mD', 'cid': 777}),
      isNull,
    );
  });

  test('缺少 bvid / aid：返回 null 且不发请求', () async {
    login();
    expect(await BiliLyric.fetch(const {'cid': 777}), isNull);
    expect(options, isEmpty);
  });
}
