import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/http/app_dio.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/sources/builtin/bili_api.dart';
import 'package:molia/sources/builtin/bili_discover.dart';
import 'package:molia/sources/builtin/bili_ranking.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';

import 'support/mock_dio.dart';

/// B 站发现能力：榜单 + 热搜；歌单浏览显式不支持，收藏夹只走导入详情。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const source = BiliDiscoverSource();

  late BuiltinTransport originalTransport;

  Map<String, dynamic> fixture(String name) => jsonDecode(
        File('test/fixtures/$name').readAsStringSync(),
      ) as Map<String, dynamic>;

  setUpAll(() => originalTransport = BuiltinSearch.transport);

  setUp(BiliApi.reset);

  tearDown(() => BuiltinSearch.transport = originalTransport);

  MockDioAdapter install(
    FutureOr<ResponseBody> Function(RequestOptions options) onRequest,
  ) {
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
        default:
          return onRequest(options);
      }
    });
    BuiltinSearch.transport =
        BuiltinTransport(dio: createAppDio(adapter: adapter));
    return adapter;
  }

  test('能力位：只有榜单与热搜，歌单浏览 / 搜索显式关闭', () async {
    expect(source.sourceKey, 'bili');
    expect(source.leaderboards, BiliRanking.boards);
    expect(source.leaderboards, hasLength(1));
    expect(source.supportsLeaderboards, isTrue);
    expect(source.supportsPlaylists, isFalse);
    expect(source.supportsPlaylistSearch, isFalse);
    expect(source.supportsHotSearch, isTrue);

    final tags = await source.tags();
    expect(tags.isEmpty, isTrue);

    await expectLater(
      source.playlists('', 1),
      throwsA(
        isA<SourceFailure>()
            .having((e) => e.kind, 'kind', FailureKind.unsupported)
            .having((e) => e.message, 'message', 'bili: 不支持歌单浏览'),
      ),
    );
    await expectLater(
      source.searchPlaylists('周杰伦', 1),
      throwsA(
        isA<SourceFailure>()
            .having((e) => e.kind, 'kind', FailureKind.unsupported),
      ),
    );
  });

  test('热搜：data.trending.list[].keyword 只收字符串并去重', () async {
    final adapter = install((options) async {
      if (options.uri.path == '/x/web-interface/search/square') {
        return textResponse(jsonEncode(fixture('bili_hot_search.json')));
      }
      return textResponse('{}', statusCode: 500);
    });

    final words = await source.hotSearches();

    expect(words, ['起风了', '周杰伦']);
    final request = adapter.requests.singleWhere(
      (r) => r.uri.path == '/x/web-interface/search/square',
    );
    expect(request.uri.queryParameters['limit'], '10');
  });

  test('热搜失败：抛 SourceFailure', () async {
    install((options) async {
      if (options.uri.path == '/x/web-interface/search/square') {
        return textResponse(jsonEncode({'code': -1}));
      }
      return textResponse('{}', statusCode: 500);
    });

    await expectLater(
      source.hotSearches(),
      throwsA(isA<SourceFailure>()),
    );
  });

  test('playlistDetail 委托收藏夹导入：拉全分页并带曲目', () async {
    final adapter = install((options) async {
      switch (options.uri.path) {
        case '/x/v3/fav/resource/list':
          final pn = options.uri.queryParameters['pn'];
          final page = fixture(
            pn == '1'
                ? 'bili_favorites_page1.json'
                : 'bili_favorites_page2.json',
          );
          return textResponse(jsonEncode(page));
        default:
          return textResponse('{}', statusCode: 500);
      }
    });

    final detail = await source.playlistDetail('123456', 1);

    expect(detail.info.id, '123456');
    expect(detail.info.name, '我的收藏夹');
    expect(detail.tracks, hasLength(25));
    expect(detail.tracks.first.sourceKey, 'bili');
    expect(
      adapter.requests.where((r) => r.uri.path == '/x/v3/fav/resource/list'),
      hasLength(2),
    );
  });
}
