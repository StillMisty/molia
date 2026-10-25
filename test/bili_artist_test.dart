import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/http/app_dio.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/sources/builtin/bili_api.dart';
import 'package:molia/sources/builtin/bili_artist.dart';
import 'package:molia/sources/builtin/bili_search.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';

import 'support/mock_dio.dart';
import 'support/bili_session_mock.dart';

/// B 站 UP 主页：用户搜索 / 资料 / 投稿主路径 + 风控回退到视频搜索。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BuiltinTransport originalTransport;
  late int navCalls;

  Map<String, dynamic> fixture(String name) => jsonDecode(
        File('test/fixtures/$name').readAsStringSync(),
      ) as Map<String, dynamic>;

  setUpAll(() => originalTransport = BuiltinSearch.transport);

  setUp(() {
    BiliApi.reset();
    navCalls = 0;
  });

  tearDown(() => BuiltinSearch.transport = originalTransport);

  /// 会话请求统一兜底；业务路径交给 [onRequest]。
  MockDioAdapter install(
    FutureOr<ResponseBody> Function(RequestOptions options) onRequest,
  ) {
    final adapter = MockDioAdapter((options) async {
      final sessionResponse =
          biliSessionResponse(options, onNav: () => navCalls++);
      if (sessionResponse != null) return sessionResponse;
      switch (options.uri.path) {
        default:
          return onRequest(options);
      }
    });
    BuiltinSearch.transport =
        BuiltinTransport(dio: createAppDio(adapter: adapter));
    return adapter;
  }

  Map<String, dynamic> cardFixture({String name = '周杰伦'}) => {
        'code': 0,
        'data': {
          'card': {
            'mid': '336',
            'name': name,
            'face': '//i0.hdslb.com/bfs/face/jay.jpg',
            'sign': '华语流行歌手',
            'fans': 100000,
          },
        },
      };

  test('用户搜索：mid/uname/头像/投稿数 + 分页', () async {
    final adapter = install((options) async {
      if (options.uri.path == '/x/web-interface/wbi/search/type') {
        return textResponse(jsonEncode(fixture('bili_user_search.json')));
      }
      return textResponse('{}', statusCode: 500);
    });

    final page = await BiliSearch.searchUsers('周杰伦');

    expect(page.items, hasLength(2));
    expect(page.items.first.id, '336');
    expect(page.items.first.name, '周杰伦');
    expect(
      page.items.first.avatarUrl,
      'https://i0.hdslb.com/bfs/face/jay.jpg',
    );
    expect(page.items.first.songCount, 100);
    expect(page.items[1].name, '无头像UP & 测试');
    expect(page.items[1].avatarUrl, isNull);
    expect(page.total, 42);
    expect(page.hasMore, isTrue);

    final request = adapter.requests.singleWhere(
      (r) => r.uri.path == '/x/web-interface/wbi/search/type',
    );
    final query = request.uri.queryParameters;
    expect(query['search_type'], 'bili_user');
    expect(query['keyword'], '周杰伦');
    expect(query['page'], '1');
    expect(query['wts'], isNotEmpty);
    expect(query['w_rid'], isNotEmpty);
  });

  test('用户搜索 -403：与视频搜索同一套策略，刷新会话一次后重试', () async {
    var searchCalls = 0;
    install((options) async {
      if (options.uri.path == '/x/web-interface/wbi/search/type') {
        searchCalls++;
        if (searchCalls == 1) {
          return textResponse(jsonEncode({'code': -403, 'message': '风控'}));
        }
        return textResponse(jsonEncode(fixture('bili_user_search.json')));
      }
      return textResponse('{}', statusCode: 500);
    });

    final page = await BiliSearch.searchUsers('周杰伦');

    expect(page.items, hasLength(2));
    expect(searchCalls, 2);
    expect(navCalls, 2, reason: '首次会话 + 风控刷新一次');
  });

  test('UP 资料 + 空间投稿：曲目映射与 dm 指纹参数', () async {
    final adapter = install((options) async {
      switch (options.uri.path) {
        case '/x/web-interface/card':
          return textResponse(jsonEncode(cardFixture()));
        case '/x/space/wbi/arc/search':
          return textResponse(jsonEncode(fixture('bili_space.json')));
        default:
          return textResponse('{}', statusCode: 500);
      }
    });

    final detail = await BiliArtist.fetch('336');

    expect(detail.id, '336');
    expect(detail.name, '周杰伦');
    expect(detail.avatarUrl, 'https://i0.hdslb.com/bfs/face/jay.jpg');
    expect(detail.description, '华语流行歌手');
    expect(detail.tracks, hasLength(2));
    expect(detail.hasMore, isTrue, reason: 'page.count=35 超过一页 30 条');

    final first = detail.tracks.first;
    expect(first.title, '投稿一：夜曲');
    expect(first.duration, const Duration(minutes: 4, seconds: 5));
    expect(first.artists.first.name, '周杰伦');
    expect(first.artists.first.id, '336', reason: '可点进 UP 主页');
    expect(first.payload['bvid'], 'BV1space001');
    expect(first.payload['aid'], '1001');
    expect(first.payload['cid'], '111');
    expect(first.payload['_artists'], [
      {'name': '周杰伦', 'id': '336'},
    ]);

    final request = adapter.requests.singleWhere(
      (r) => r.uri.path == '/x/space/wbi/arc/search',
    );
    final query = request.uri.queryParameters;
    expect(query['mid'], '336');
    expect(query['pn'], '1');
    expect(query['ps'], '30');
    expect(query['order'], 'pubdate');
    expect(query['dm_img_list'], '[]');
    expect(query['dm_img_str'], isNotEmpty);
    expect(query['dm_cover_img_str'], isNotEmpty);
    expect(
      query['dm_img_inter'],
      '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}',
    );
    expect(query['wts'], isNotEmpty);
    expect(query['w_rid'], isNotEmpty);
  });

  test('资料 card 失败：回退 space/wbi/acc/info', () async {
    final adapter = install((options) async {
      switch (options.uri.path) {
        case '/x/web-interface/card':
          return textResponse(jsonEncode({'code': -404}));
        case '/x/space/wbi/acc/info':
          return textResponse(
            jsonEncode({
              'code': 0,
              'data': {
                'mid': 336,
                'name': '周杰伦（空间）',
                'face': '//i1.hdslb.com/bfs/face/space.jpg',
                'sign': '空间简介',
              },
            }),
          );
        case '/x/space/wbi/arc/search':
          return textResponse(jsonEncode(fixture('bili_space.json')));
        default:
          return textResponse('{}', statusCode: 500);
      }
    });

    final detail = await BiliArtist.fetch('336');

    expect(detail.name, '周杰伦（空间）');
    expect(detail.avatarUrl, 'https://i1.hdslb.com/bfs/face/space.jpg');
    expect(detail.description, '空间简介');
    final request = adapter.requests.singleWhere(
      (r) => r.uri.path == '/x/space/wbi/acc/info',
    );
    expect(request.uri.queryParameters['w_rid'], isNotEmpty);
  });

  test('空间风控：刷新会话一次后回退视频搜索并按 mid 过滤', () async {
    final adapter = install((options) async {
      switch (options.uri.path) {
        case '/x/web-interface/card':
          return textResponse(jsonEncode(cardFixture()));
        case '/x/space/wbi/arc/search':
          return textResponse(jsonEncode({'code': -352, 'message': '风控'}));
        case '/x/web-interface/wbi/search/type':
          return textResponse(
            jsonEncode({
              'code': 0,
              'data': {
                'numPages': 2,
                'result': [
                  {
                    'mid': 336,
                    'author': '周杰伦',
                    'bvid': 'BV1fallback1',
                    'aid': 9001,
                    'title': '<em class="keyword">夜曲</em>',
                    'pic': '//i1.hdslb.com/bfs/archive/fb1.jpg',
                    'duration': '03:00',
                  },
                  {
                    'mid': 999,
                    'author': '别人',
                    'bvid': 'BV1other',
                    'aid': 9002,
                    'title': '别人的视频',
                    'duration': '02:00',
                  },
                ],
              },
            }),
          );
        default:
          return textResponse('{}', statusCode: 500);
      }
    });

    final detail = await BiliArtist.fetch('336');

    expect(navCalls, 2, reason: '-352 后刷新一次会话');
    expect(
      adapter.requests.where((r) => r.uri.path == '/x/space/wbi/arc/search'),
      hasLength(2),
    );
    expect(detail.tracks, hasLength(1));
    expect(detail.tracks.single.title, '夜曲');
    expect(detail.tracks.single.payload['bvid'], 'BV1fallback1');
    expect(detail.hasMore, isTrue);

    final fallback = adapter.requests.last;
    expect(fallback.uri.path, '/x/web-interface/wbi/search/type');
    expect(fallback.uri.queryParameters['search_type'], 'video');
    expect(fallback.uri.queryParameters['keyword'], '周杰伦');
    expect(fallback.uri.queryParameters['order'], 'totalrank');
  });

  test('空间返回空 vlist 但 count>0：按风控回退视频搜索', () async {
    final adapter = install((options) async {
      switch (options.uri.path) {
        case '/x/web-interface/card':
          return textResponse(jsonEncode(cardFixture()));
        case '/x/space/wbi/arc/search':
          return textResponse(
            jsonEncode({
              'code': 0,
              'data': {
                'list': {'vlist': <dynamic>[]},
                'page': {'count': 35},
              },
            }),
          );
        case '/x/web-interface/wbi/search/type':
          return textResponse(
            jsonEncode({
              'code': 0,
              'data': {
                'numPages': 1,
                'result': [
                  {
                    'mid': 336,
                    'author': '周杰伦',
                    'bvid': 'BV1riskfree',
                    'aid': 9101,
                    'title': '兜底投稿',
                    'duration': '02:30',
                  },
                ],
              },
            }),
          );
        default:
          return textResponse('{}', statusCode: 500);
      }
    });

    final detail = await BiliArtist.fetch('336');

    expect(detail.tracks, hasLength(1));
    expect(detail.tracks.single.title, '兜底投稿');
    expect(
      adapter.requests
          .where((r) => r.uri.path == '/x/web-interface/wbi/search/type'),
      hasLength(1),
      reason: '空 vlist + count>0 视为风控，不返回空页',
    );
  });

  test('空间返回空 vlist 且 count==0：真实空主页，不触发搜索', () async {
    final adapter = install((options) async {
      switch (options.uri.path) {
        case '/x/web-interface/card':
          return textResponse(jsonEncode(cardFixture()));
        case '/x/space/wbi/arc/search':
          return textResponse(
            jsonEncode({
              'code': 0,
              'data': {
                'list': {'vlist': <dynamic>[]},
                'page': {'count': 0},
              },
            }),
          );
        default:
          return textResponse('{}', statusCode: 500);
      }
    });

    final detail = await BiliArtist.fetch('336');

    expect(detail.tracks, isEmpty);
    expect(detail.hasMore, isFalse);
    expect(
      adapter.requests
          .where((r) => r.uri.path == '/x/web-interface/wbi/search/type'),
      isEmpty,
    );
  });

  test('回退搜索无结果：返回资料 + 空列表，不失败整页', () async {
    install((options) async {
      switch (options.uri.path) {
        case '/x/web-interface/card':
          return textResponse(jsonEncode(cardFixture()));
        case '/x/space/wbi/arc/search':
          return textResponse(jsonEncode({'code': -352}));
        case '/x/web-interface/wbi/search/type':
          return textResponse(
            jsonEncode({
              'code': 0,
              'data': {'numPages': 1, 'result': <dynamic>[]},
            }),
          );
        default:
          return textResponse('{}', statusCode: 500);
      }
    });

    final detail = await BiliArtist.fetch('336');

    expect(detail.name, '周杰伦');
    expect(detail.tracks, isEmpty);
    expect(detail.hasMore, isFalse);
  });

  test('资料与空间资料都失败：抛 SourceFailure', () async {
    install((options) async {
      switch (options.uri.path) {
        case '/x/web-interface/card':
          return textResponse(jsonEncode({'code': -404}));
        case '/x/space/wbi/acc/info':
          return textResponse(jsonEncode({'code': -352}));
        default:
          return textResponse('{}', statusCode: 500);
      }
    });

    await expectLater(
      BiliArtist.fetch('336'),
      throwsA(isA<SourceFailure>()),
    );
  });
}
