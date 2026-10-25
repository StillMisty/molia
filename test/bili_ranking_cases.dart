import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/http/app_dio.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/sources/builtin/bili_api.dart';
import 'package:molia/sources/builtin/bili_ranking.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';

import 'support/mock_dio.dart';
import 'support/bili_session_mock.dart';

/// B 站音乐榜：唯一榜单表、`rid:day` 解析、cid 透传与 5 分钟缓存。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BuiltinTransport originalTransport;
  late int rankingCalls;

  final fixture = jsonDecode(
    File('test/fixtures/bili_ranking.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  setUpAll(() => originalTransport = BuiltinSearch.transport);

  setUp(() {
    BiliApi.reset();
    rankingCalls = 0;
  });

  tearDown(() => BuiltinSearch.transport = originalTransport);

  MockDioAdapter install({
    bool fail = false,
  }) {
    final adapter = MockDioAdapter((options) async {
      final sessionResponse = biliSessionResponse(options);
      if (sessionResponse != null) return sessionResponse;
      switch (options.uri.path) {
        case '/x/web-interface/ranking':
          rankingCalls++;
          return textResponse(
            jsonEncode(fail ? {'code': -1, 'message': '拒绝'} : fixture),
          );
        default:
          return textResponse('{}', statusCode: 500);
      }
    });
    BuiltinSearch.transport =
        BuiltinTransport(dio: createAppDio(adapter: adapter));
    return adapter;
  }

  test('榜单表只有一张 B 站音乐榜（3:3）', () {
    expect(BiliRanking.boards, hasLength(1));
    final board = BiliRanking.boards.single;
    expect(board.id, 'bili__music_3d');
    expect(board.name, 'B站音乐榜');
    expect(board.bangid, '3:3');
  });

  test('bangid 解析：3:3 / 省略 day 默认 3；其它榜拒绝', () {
    expect(BiliRanking.parseBangid('3:3'), (rid: 3, day: 3));
    expect(BiliRanking.parseBangid('3'), (rid: 3, day: 3));
    expect(BiliRanking.parseBangid(' 3 : 3 '), (rid: 3, day: 3));
    expect(BiliRanking.parseBangid('4:3'), isNull);
    expect(BiliRanking.parseBangid('3:7'), isNull);
    expect(BiliRanking.parseBangid('abc'), isNull);
  });

  test('榜单曲目：bvid/aid/cid/封面/时长，cid 保留在 raw', () async {
    final adapter = install();

    final tracks = await BiliRanking.leaderboardTracks('3:3');

    expect(tracks, hasLength(2));
    expect(tracks.first.sourceKey, 'bili');
    expect(tracks.first.songId, 'BV1rank001');
    expect(tracks.first.title, '榜单曲一');
    expect(tracks.first.artist, 'UP主一');
    expect(tracks.first.coverUrl, 'https://i1.hdslb.com/bfs/archive/rank1.jpg');
    expect(tracks.first.durationMs, 200000);
    expect(tracks.first.raw['aid'], '2001');
    expect(tracks.first.raw['cid'], '3001');
    expect(tracks.first.raw['_artists'], [
      {'name': 'UP主一', 'id': '501'},
    ]);
    expect(tracks[1].durationMs, 240000);

    final request = adapter.requests.singleWhere(
      (r) => r.uri.path == '/x/web-interface/ranking',
    );
    expect(request.uri.queryParameters['rid'], '3');
    expect(request.uri.queryParameters['day'], '3');
    expect(request.uri.queryParameters.containsKey('wts'), isFalse,
        reason: '榜单接口不需要 WBI');
  });

  test('二次调用命中缓存，不重复请求', () async {
    install();

    await BiliRanking.leaderboardTracks('3:3');
    await BiliRanking.leaderboardTracks('3:3');

    expect(rankingCalls, 1);
  });

  test('业务失败抛 SourceFailure（不缓存失败）', () async {
    install(fail: true);

    await expectLater(
      BiliRanking.leaderboardTracks('3:3'),
      throwsA(isA<SourceFailure>()),
    );
    // 失败后再次调用会重新请求，而不是复用失败结果。
    await expectLater(
      BiliRanking.leaderboardTracks('3:3'),
      throwsA(isA<SourceFailure>()),
    );
    expect(rankingCalls, 2);
  });

  test('不支持的 bangid：unsupported 失败', () async {
    await expectLater(
      BiliRanking.leaderboardTracks('4:3'),
      throwsA(
        isA<SourceFailure>()
            .having((e) => e.kind, 'kind', FailureKind.unsupported),
      ),
    );
  });
}
