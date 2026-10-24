import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/bili_api.dart';
import 'package:molia/sources/builtin/bili_search.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';

import 'support/mock_dio.dart';
import 'support/bili_session_mock.dart';

/// B 站搜索解析：真实响应结构（`test/fixtures/bili_search.json`）→ 曲目 /
/// 分页信息；搜索请求经注入传输，不访问网络。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixture = jsonDecode(
    File('test/fixtures/bili_search.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  late BuiltinTransport originalTransport;
  setUpAll(() => originalTransport = BuiltinSearch.transport);
  setUp(BiliApi.reset);
  tearDown(() => BuiltinSearch.transport = originalTransport);

  List<dynamic> resultItems() =>
      ((fixture['data'] as Map)['result'] as List).toList();

  test('标题剥 <em> 并反转义；封面补 https；时长支持 mm:ss / hh:mm:ss', () {
    final tracks = BiliSearch.parseItems(resultItems());

    // 缺 bvid / aid 的条目无法取链，直接过滤。
    expect(tracks, hasLength(2));

    final first = tracks.first;
    expect(first.title, '起风了 & 翻唱');
    expect(first.artist, '买辣椒也用券');
    expect(first.album, '');
    expect(first.coverUrl, 'https://i1.hdslb.com/bfs/archive/cover1.jpg');
    expect(first.duration, const Duration(minutes: 5, seconds: 17));

    final second = tracks[1];
    expect(second.title, '晴天');
    expect(second.coverUrl, 'https://i2.hdslb.com/bfs/archive/cover2.jpg');
    expect(
      second.duration,
      const Duration(hours: 1, minutes: 2, seconds: 3),
    );
  });

  test('raw 原样保留并补 bvid/aid/_types/_artists', () {
    final track = BiliSearch.parseItems(resultItems()).first;
    final raw = track.raw;

    // 原响应字段一个都不能丢（脚本仍读 typename 等）。
    expect(raw['typename'], '音乐');
    expect(raw['description'], '测试视频');
    expect(raw['pic'], '//i1.hdslb.com/bfs/archive/cover1.jpg');

    expect(raw['source'], 'bili');
    expect(raw['bvid'], 'BV1xx411c7mD');
    expect(raw['aid'], '987654');
    expect(
      (raw['_types'] as Map).keys,
      containsAll(['192k', '128k', '64k']),
    );
    expect(raw['_artists'], [
      {'name': '买辣椒也用券', 'id': '123456'},
    ]);

    expect(
        track.qualities.map((q) => q.type).toList(), ['192k', '128k', '64k']);
    // 通用 id 优先级：bvid 在 aid 之前。
    expect(track.songId, 'BV1xx411c7mD');
    expect(track.id, 'bili:BV1xx411c7mD');
  });

  test('总数 / 总页数解析', () {
    expect(BiliSearch.totalOf(fixture), 1000);
    expect(BiliSearch.numPagesOf(fixture), 50);
    expect(BiliSearch.totalOf(const {}), isNull);
    expect(BiliSearch.numPagesOf({'data': {}}), isNull);
  });

  test('searchWithMeta：签名请求、分页信息与末页判定', () async {
    final requests = <Uri>[];
    final transport = BuiltinTransport(
      dio: mockDio((request) async {
        requests.add(request.uri);
        final sessionResponse = biliSessionResponse(request);
        if (sessionResponse != null) return sessionResponse;
        switch (request.uri.path) {
          case '/x/web-interface/wbi/search/type':
            return textResponse(jsonEncode(fixture));
          default:
            return textResponse('{}', statusCode: 500);
        }
      }),
    );
    BuiltinSearch.transport = transport;

    final firstPage = await BiliSearch.searchWithMeta('起风了', page: 1);
    expect(firstPage.failure, isNull);
    expect(firstPage.tracks, hasLength(2));
    expect(firstPage.total, 1000);
    expect(firstPage.hasMore, isTrue);

    final searchUri = requests.last;
    expect(searchUri.path, '/x/web-interface/wbi/search/type');
    expect(searchUri.queryParameters['search_type'], 'video');
    expect(searchUri.queryParameters['order'], 'totalrank');
    expect(searchUri.queryParameters['keyword'], '起风了');
    expect(searchUri.queryParameters['page'], '1');
    expect(searchUri.queryParameters['wts'], isNotEmpty);
    expect(searchUri.queryParameters['w_rid'], isNotEmpty);

    final lastPage = await BiliSearch.searchWithMeta('起风了', page: 50);
    expect(lastPage.hasMore, isFalse, reason: 'page >= numPages 即末页');
  });

  test('空结果：正常空结果，不因缺分页字段误报下一页', () async {
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((request) async {
        switch (request.uri.path) {
          case '/x/frontend/finger/spi':
            return textResponse(
              jsonEncode({
                'code': 0,
                'data': {'b_3': 'b3', 'b_4': 'b4'},
              }),
            );
          case '/x/web-interface/nav':
            return textResponse(
              jsonEncode({
                'code': 0,
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
          case '/x/web-interface/wbi/search/type':
            return textResponse(
              jsonEncode({
                'code': 0,
                'data': {'result': <dynamic>[]},
              }),
            );
          default:
            return textResponse('{}', statusCode: 500);
        }
      }),
    );

    final result = await BiliSearch.searchWithMeta('不存在的内容');
    expect(result.failure, isNull);
    expect(result.tracks, isEmpty);
    expect(result.hasMore, isFalse);
  });
}
