import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/http/app_dio.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/sources/builtin/bili_api.dart';
import 'package:molia/sources/builtin/bili_favorites.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';

import 'support/mock_dio.dart';

/// B 站收藏夹：链接形态解析、全部分页、视频过滤、私密失败与详情字段。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BuiltinTransport originalTransport;
  late Map<int, Map<String, dynamic>> pages;
  late List<String> requestedPages;
  late int? errorCode;
  late bool infoNull;

  Map<String, dynamic> fixture(String name) => jsonDecode(
        File('test/fixtures/$name').readAsStringSync(),
      ) as Map<String, dynamic>;

  setUpAll(() => originalTransport = BuiltinSearch.transport);

  setUp(() {
    BiliApi.reset();
    BiliFavorites.redirectDioForTest = null;
    pages = {
      1: fixture('bili_favorites_page1.json'),
      2: fixture('bili_favorites_page2.json'),
    };
    requestedPages = [];
    errorCode = null;
    infoNull = false;
  });

  tearDown(() {
    BuiltinSearch.transport = originalTransport;
    BiliFavorites.redirectDioForTest = null;
  });

  MockDioAdapter install() {
    final adapter = MockDioAdapter((options) async {
      switch (options.uri.path) {
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
        case '/x/v3/fav/folder/created/list-all':
          return textResponse(
            jsonEncode({
              'code': 0,
              'data': {
                'list': [
                  {'id': 321, 'fid': 321, 'title': '第一个收藏夹'},
                  {'id': 654, 'fid': 654, 'title': '第二个收藏夹'},
                ],
              },
            }),
          );
        case '/x/v3/fav/resource/list':
          if (errorCode != null) {
            return textResponse(jsonEncode({'code': errorCode}));
          }
          final pn = options.uri.queryParameters['pn'] ?? '';
          requestedPages.add(pn);
          if (infoNull) {
            return textResponse(
              jsonEncode({
                'code': 0,
                'data': {'info': null, 'medias': <dynamic>[]},
              }),
            );
          }
          final page = pages[int.tryParse(pn) ?? 1];
          if (page == null) {
            return textResponse(jsonEncode({'code': -404}));
          }
          return textResponse(jsonEncode(page));
        default:
          return textResponse('{}', statusCode: 500);
      }
    });
    BuiltinSearch.transport =
        BuiltinTransport(dio: createAppDio(adapter: adapter));
    return adapter;
  }

  group('parseMediaId', () {
    test('纯数字 / fid / media_id / ml 路径', () async {
      expect(await BiliFavorites.parseMediaId('123456'), '123456');
      expect(await BiliFavorites.parseMediaId('  123456  '), '123456');
      expect(
        await BiliFavorites.parseMediaId(
          'https://space.bilibili.com/336/favlist?fid=555&ftype=create',
        ),
        '555',
      );
      expect(
        await BiliFavorites.parseMediaId(
          'https://www.bilibili.com/medialist/detail/ml987654?type=1',
        ),
        '987654',
      );
      expect(
        await BiliFavorites.parseMediaId(
          'https://www.bilibili.com/list/watchlater?media_id=777',
        ),
        '777',
      );
      expect(
        await BiliFavorites.parseMediaId(
          'www.bilibili.com/medialist/detail/ml42',
        ),
        '42',
      );
    });

    test('无法识别的链接返回 null', () async {
      expect(await BiliFavorites.parseMediaId(''), isNull);
      expect(await BiliFavorites.parseMediaId('not a link'), isNull);
      expect(
        await BiliFavorites.parseMediaId('https://example.com/playlist/1'),
        isNull,
      );
    });

    test('favlist 不带 fid：取该 UP 的第一个收藏夹', () async {
      install();
      expect(
        await BiliFavorites.parseMediaId(
          'https://space.bilibili.com/336/favlist',
        ),
        '321',
      );
    });

    test('b23 短链：跟随 302 后解析目标地址', () async {
      final redirects = <Uri>[];
      BiliFavorites.redirectDioForTest = mockDio((request) async {
        redirects.add(request.uri);
        if (request.uri.host == 'b23.tv') {
          return textResponse(
            '',
            statusCode: 302,
            headers: {
              'location': [
                'https://www.bilibili.com/medialist/detail/ml321?type=1',
              ],
            },
          );
        }
        return textResponse('');
      });

      expect(await BiliFavorites.parseMediaId('https://b23.tv/abcdef'), '321');
      expect(redirects.first.host, 'b23.tv');
      expect(redirects.last.host, 'www.bilibili.com');
    });
  });

  group('detail', () {
    test('拉全部分页并保留顺序；过滤非视频 / 失效条目', () async {
      install();

      final detail = await BiliFavorites.detail('123456', 1);

      expect(requestedPages, ['1', '2']);
      expect(detail.tracks, hasLength(25));
      expect(detail.tracks.first.title, '收藏曲1 & 测试');
      expect(detail.tracks.first.songId, 'BV1fav001');
      expect(
        detail.tracks.first.coverUrl,
        'https://i1.hdslb.com/bfs/archive/fav1.jpg',
      );
      expect(detail.tracks.first.durationMs, 121000);
      expect(detail.tracks.first.raw['aid'], '4001');
      expect(detail.tracks.first.raw['upper'], {
        'mid': 336,
        'name': '周杰伦',
      });
      expect(detail.tracks.first.raw['cnt_info'], {'play': 10});
      expect(detail.tracks.last.songId, 'BV1fav025');

      expect(detail.info.id, '123456');
      expect(detail.info.name, '我的收藏夹');
      expect(
        detail.info.coverUrl,
        'https://i0.hdslb.com/bfs/archive/fav-cover.jpg',
      );
      expect(detail.info.author, '周杰伦');
      expect(detail.info.playCount, 3250, reason: '1..25 各 10 倍播放量');
      expect(detail.info.trackCount, 26);
      expect(detail.info.description, '收藏简介 & 说明');
      final date = DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000);
      expect(
        detail.info.createdAt,
        '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}',
      );
    });

    test('忽略入参 page：永远从第 1 页开始拉全', () async {
      install();

      final detail = await BiliFavorites.detail('123456', 5);

      expect(detail.tracks, hasLength(25));
      expect(requestedPages, ['1', '2']);
    });

    test('私密 / 失效收藏夹：code 非 0 → SourceFailure(notFound)', () async {
      errorCode = -403;
      install();

      await expectLater(
        BiliFavorites.detail('123456', 1),
        throwsA(
          isA<SourceFailure>()
              .having((e) => e.kind, 'kind', FailureKind.notFound)
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
    });

    test('后续页缺 info：沿用第一页详情继续拉全', () async {
      pages[2] = {...pages[2]!}..remove('info');
      install();

      final detail = await BiliFavorites.detail('123456', 1);

      expect(requestedPages, ['1', '2']);
      expect(detail.tracks, hasLength(25));
      expect(detail.info.name, '我的收藏夹');
      expect(detail.info.trackCount, 26);
    });

    test('info 为空：按不可见收藏夹失败', () async {
      infoNull = true;
      install();

      await expectLater(
        BiliFavorites.detail('123456', 1),
        throwsA(
          isA<SourceFailure>()
              .having((e) => e.kind, 'kind', FailureKind.notFound),
        ),
      );
    });

    test('无法识别的链接：直接失败，不发请求', () async {
      final adapter = install();

      await expectLater(
        BiliFavorites.detail('not a link', 1),
        throwsA(
          isA<SourceFailure>()
              .having((e) => e.kind, 'kind', FailureKind.notFound),
        ),
      );
      expect(adapter.requests, isEmpty);
    });
  });
}
