import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/sources/builtin/bili_api.dart';
import 'package:molia/sources/builtin/bili_play.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';

import 'support/mock_dio.dart';

/// B 站取链：分 P → WBI playurl → dash 音频选档；直链 headers / 有效期 /
/// 业务码映射都用注入传输验证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BuiltinTransport originalTransport;
  late List<Uri> requests;
  late List<RequestOptions> options;
  late int playUrlCalls;
  late bool notFound;
  late bool riskOnce;
  late int deadline;
  late bool noDash;

  setUpAll(() => originalTransport = BuiltinSearch.transport);

  setUp(() {
    BiliApi.reset();
    BiliPlay.reset();
    requests = [];
    options = [];
    playUrlCalls = 0;
    notFound = false;
    riskOnce = false;
    deadline = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 7200;
    noDash = false;

    String dashUrl(String name) =>
        'https://upos-sz-mirrorcos.bilivideo.com/bfs/audio/$name.m4s'
        '?deadline=$deadline&gen=playurlv3';

    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((request) async {
        requests.add(request.uri);
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
            return textResponse(
              jsonEncode({
                'code': 0,
                'data': [
                  {'cid': 12345, 'page': 1, 'part': 'P1'},
                ],
              }),
            );
          case '/x/player/wbi/playurl':
            playUrlCalls++;
            if (notFound) {
              return textResponse(jsonEncode({'code': -404, 'message': '无'}));
            }
            if (riskOnce && playUrlCalls == 1) {
              return textResponse(
                jsonEncode({'code': -403, 'message': '风控'}),
              );
            }
            if (request.uri.queryParameters['fnval'] == '1') {
              // 无 dash 的老视频：durl 单文件只有 `url` 字段。
              return textResponse(
                jsonEncode({
                  'code': 0,
                  'data': {
                    'durl': [
                      {
                        'url': 'https://cdn.example/video.m4s'
                            '?deadline=$deadline',
                      },
                    ],
                  },
                }),
              );
            }
            if (noDash) {
              return textResponse(
                jsonEncode({
                  'code': 0,
                  'data': <String, dynamic>{},
                }),
              );
            }
            return textResponse(
              jsonEncode({
                'code': 0,
                'data': {
                  'dash': {
                    'duration': 317,
                    'audio': [
                      {
                        'id': 30216,
                        'baseUrl': dashUrl('audio64'),
                        'bandwidth': 64000,
                      },
                      {
                        'id': 30232,
                        // 缺 baseUrl 时走 base_url（接口两种命名都出现过）。
                        'base_url': dashUrl('audio128'),
                        'bandwidth': 128000,
                      },
                      {
                        'id': 30280,
                        'baseUrl': dashUrl('audio192'),
                        'backupUrl': [dashUrl('audio192-backup')],
                        'bandwidth': 192000,
                      },
                    ],
                  },
                },
              }),
            );
          default:
            return textResponse('{}', statusCode: 500);
        }
      }),
    );
  });

  tearDown(() => BuiltinSearch.transport = originalTransport);

  const raw = {'bvid': 'BV1xx411c7mD', 'aid': 987654};

  test('192k：查分 P → 签名 playurl → 30280 直链 + headers / expiresIn', () async {
    final stream = await BiliPlay.resolve(Map<String, dynamic>.from(raw));

    final pagelist = requests.firstWhere(
      (uri) => uri.path == '/x/player/pagelist',
    );
    expect(pagelist.queryParameters['bvid'], 'BV1xx411c7mD');

    final playUri = requests.firstWhere(
      (uri) => uri.path == '/x/player/wbi/playurl',
    );
    expect(playUri.queryParameters['bvid'], 'BV1xx411c7mD');
    expect(playUri.queryParameters['cid'], '12345');
    expect(playUri.queryParameters['fnval'], '16');
    expect(playUri.queryParameters['fnver'], '0');
    expect(playUri.queryParameters['fourk'], '1');
    expect(playUri.queryParameters['wts'], isNotEmpty);
    expect(playUri.queryParameters['w_rid'], isNotEmpty);

    expect(stream.uri.path, endsWith('/audio192.m4s'));
    expect(stream.headers['Referer'], 'https://www.bilibili.com/');
    expect(stream.headers['User-Agent'], contains('Chrome/'));
    expect(stream.headers.containsKey('Cookie'), isFalse);
    expect(stream.expiresIn, isNotNull);
    expect(stream.expiresIn!.inSeconds, greaterThan(7000));
    expect(stream.expiresIn!.inSeconds, lessThanOrEqualTo(7200));

    final playRequest = options.firstWhere(
      (request) => request.uri.path == '/x/player/wbi/playurl',
    );
    expect(playRequest.headers['Referer'], 'https://www.bilibili.com/');
    expect(playRequest.headers['User-Agent'], contains('Chrome/'));
    expect(playRequest.headers['Cookie'], contains('buvid3=buvid3-test'));
  });

  test('128k：选 30232；cid 命中缓存后不再查分 P', () async {
    final first = await BiliPlay.resolve(
      Map<String, dynamic>.from(raw),
      quality: '128k',
    );
    expect(first.uri.path, endsWith('/audio128.m4s'));

    final second = await BiliPlay.resolve(
      Map<String, dynamic>.from(raw),
      quality: '128k',
    );
    expect(second.uri.path, endsWith('/audio128.m4s'));
    expect(
      requests.where((uri) => uri.path == '/x/player/pagelist'),
      hasLength(1),
      reason: '同一 bvid 的 cid 应缓存',
    );
  });

  test('请求音质不在档位内：按 LX 顺序回退到 192k', () async {
    final stream = await BiliPlay.resolve(
      Map<String, dynamic>.from(raw),
      quality: '320k',
    );
    expect(stream.uri.path, endsWith('/audio192.m4s'));
  });

  test('code -404 → SourceFailure(notFound)', () async {
    notFound = true;
    await expectLater(
      BiliPlay.resolve({'bvid': 'BV1xx411c7mD', 'cid': 999}),
      throwsA(
        isA<SourceFailure>()
            .having((failure) => failure.kind, 'kind', FailureKind.notFound)
            .having((failure) => failure.retryable, 'retryable', isFalse),
      ),
    );
    expect(playUrlCalls, 1);
  });

  test('无 dash 时回退 fnval=1 的 durl（读取 url 字段）', () async {
    noDash = true;
    final stream = await BiliPlay.resolve(
      Map<String, dynamic>.from(raw),
      quality: '128k',
    );

    expect(stream.uri.path, endsWith('/video.m4s'));
    expect(stream.headers['Referer'], 'https://www.bilibili.com/');
    expect(playUrlCalls, 2);
    final fallback = options.last;
    expect(fallback.uri.queryParameters['fnval'], '1');
  });

  test('code -403 → 刷新 WBI 会话后重试一次', () async {
    riskOnce = true;
    final stream = await BiliPlay.resolve(
      Map<String, dynamic>.from(raw),
      quality: '128k',
    );
    expect(stream.uri.path, endsWith('/audio128.m4s'));
    expect(playUrlCalls, 2);
    expect(
      requests.where((uri) => uri.path == '/x/frontend/finger/spi'),
      hasLength(2),
      reason: '风控后必须重新拉 buvid/WBI 密钥再试',
    );
  });

  test('缺少 bvid / aid → unsupported，且不发请求', () async {
    await expectLater(
      BiliPlay.resolve(const {}),
      throwsA(
        isA<SourceFailure>()
            .having((failure) => failure.kind, 'kind', FailureKind.unsupported),
      ),
    );
    expect(requests, isEmpty);
  });
}
