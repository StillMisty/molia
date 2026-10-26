import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/bili_account.dart';
import 'package:molia/services/lyrics/builtin_lyric_provider.dart';
import 'package:molia/services/lyrics/lyric_provider.dart';
import 'package:molia/services/lyrics/lyrics_source_registry.dart';
import 'package:molia/services/lyrics/lyrics_source_strategy.dart';
import 'package:molia/sources/builtin/bili_account.dart';
import 'package:molia/sources/builtin/bili_api.dart';
import 'package:molia/sources/builtin/bili_play.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';

import 'support/bili_session_mock.dart';
import 'support/mock_dio.dart';

/// 歌词来源注册表与通用内置 platform provider：渠道自动派生、B 站登录
/// 门槛、手动换源的搜索 / 取词（raw 透传）与失败收口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const accountCookie = 'SESSDATA=test-sessdata; bili_jct=test-jct';
  final biliMatch = SongMatch(
    songId: 'BV1xx411c7mD',
    title: '晴天',
    artist: '某UP主',
    extra: const {'bvid': 'BV1xx411c7mD', 'cid': 777},
  );

  late BuiltinTransport originalTransport;

  setUpAll(() => originalTransport = BuiltinSearch.transport);

  setUp(() {
    // 每个用例都从真实传输基线出发：上一个用例注入的 mock 不外溢。
    BuiltinSearch.transport = originalTransport;
    BiliApi.reset();
    BiliPlay.reset();
    BiliAccountStore.instance.reset();
  });

  tearDownAll(() => BuiltinSearch.transport = originalTransport);

  void login() {
    BiliAccountStore.instance.update(
      cookieHeader: accountCookie,
      account: const BiliAccount(userId: '1'),
    );
  }

  /// 让 B 站匿名会话（buvid + WBI）走通，其余请求交给 [endpoint]。
  BuiltinTransport biliTransport(
    FutureOrResponse endpoint, {
    List<RequestOptions>? requests,
  }) {
    return BuiltinTransport(
      dio: mockDio((request) async {
        requests?.add(request);
        final session = biliSessionResponse(request);
        if (session != null) return session;
        return endpoint(request);
      }),
    );
  }

  group('lyrics source registry', () {
    test('standard：渠道按内置顺序声明，B 站只进手动换源', () {
      final registry = LyricsSourceRegistry.standard;

      expect(registry.strategies.map((strategy) => strategy.channelKey), [
        'tx',
        'wy',
        'kg',
        'kw',
        'mg',
        'bili',
        'lrclib',
      ]);

      final bili = registry.strategies.firstWhere(
        (s) => s.channelKey == 'bili',
      );
      expect(bili.provider.name, 'bili');
      expect(bili.provider, isA<BuiltinLyricProvider>());
      expect(bili.autoFallback, isFalse);
      expect(bili.isChannel, isTrue);
      expect(bili.unavailable, isNotNull);

      final lrclib = registry.strategies.firstWhere(
        (s) => s.channelKey == 'lrclib',
      );
      expect(lrclib.isChannel, isFalse, reason: 'LRCLIB 不是音源渠道');

      // 自动回退仍是五个音乐平台 + LRCLIB：B 站字幕要登录，且视频结果
      // 不是「歌曲」，不参与并行竞速。
      expect(registry.autoProviders.map((provider) => provider.name), [
        'qq',
        'netease',
        'kugou',
        'kuwo',
        'migu',
        'lrclib',
      ]);
      expect(
        registry.autoProviders.map((provider) => provider.name),
        isNot(contains('bili')),
      );
    });

    test('B 站可用性按调用时求值：登录后消失、退出后恢复', () {
      final bili = LyricsSourceRegistry.standard.strategies.firstWhere(
        (s) => s.channelKey == 'bili',
      );

      expect(bili.unavailable!(), LyricsSourceUnavailable.biliLoginRequired);

      login();
      expect(bili.unavailable!(), isNull);

      BiliAccountStore.instance.clear();
      expect(bili.unavailable!(), LyricsSourceUnavailable.biliLoginRequired);
    });

    test('manualSources：同源置顶，其余保持声明顺序', () {
      final registry = LyricsSourceRegistry.standard;
      final declared = registry.strategies.map((s) => s.channelKey).toList();

      expect(registry.manualSources().map((s) => s.channelKey), declared);
      expect(
        registry.manualSources(preferredKey: 'bili').map((s) => s.channelKey),
        ['bili', ...declared.where((key) => key != 'bili')],
      );
      expect(
        registry
            .manualSources(preferredKey: 'not-a-source')
            .map((s) => s.channelKey),
        declared,
        reason: '未知源不应改变顺序',
      );
    });
  });

  group('builtin lyric provider', () {
    test('搜索：B 站视频 → SongMatch（bvid / UP 主 / 时长 / raw）', () async {
      final requests = <RequestOptions>[];
      BuiltinSearch.transport = biliTransport((request) async {
        if (request.uri.path == '/x/web-interface/wbi/search/type') {
          return textResponse(
            jsonEncode({
              'code': 0,
              'data': {
                'numResults': 1,
                'numPages': 1,
                'result': [
                  {
                    'title': '<em class="keyword">晴天</em> 翻唱',
                    'author': '某UP主',
                    'mid': 42,
                    'bvid': 'BV1xx411c7mD',
                    'duration': '04:29',
                    'pic': '//i0.hdslb.com/cover.jpg',
                  },
                ],
              },
            }),
          );
        }
        return textResponse('{}', statusCode: 404);
      }, requests: requests);

      final matches = await BuiltinLyricProvider('bili')
          .searchMultiple('晴天', '周杰伦', limit: 3);

      expect(matches, hasLength(1));
      final match = matches.single;
      expect(match.songId, 'BV1xx411c7mD');
      expect(match.title, '晴天 翻唱');
      expect(match.artist, '某UP主');
      expect(match.duration, const Duration(minutes: 4, seconds: 29));
      expect(match.album, isNull);
      expect(match.extra['bvid'], 'BV1xx411c7mD');

      final search = requests.firstWhere(
        (request) => request.uri.path == '/x/web-interface/wbi/search/type',
      );
      expect(search.uri.queryParameters['keyword'], '晴天 周杰伦');
      expect(
        search.headers['Cookie'] ?? '',
        isNot(contains('SESSDATA')),
        reason: '搜索保持匿名，不随账号 Cookie',
      );
    });

    test('取词：raw 透传给字幕接口，空扩展行按 null', () async {
      login();
      BuiltinSearch.transport = biliTransport((request) async {
        switch (request.uri.path) {
          case '/x/player/wbi/v2':
            return textResponse(
              jsonEncode({
                'code': 0,
                'data': {
                  'subtitle': {
                    'subtitles': [
                      {
                        'lan': 'zh-CN',
                        'lan_doc': '中文（中国）',
                        'subtitle_url':
                            'https://aisubtitle.hdslb.com/bfs/subtitle/zh.json',
                      },
                    ],
                  },
                },
              }),
            );
          case '/bfs/subtitle/zh.json':
            return textResponse(
              jsonEncode({
                'body': [
                  {'from': 1.0, 'content': '第一句'},
                ],
              }),
            );
          default:
            return textResponse('{}', statusCode: 404);
        }
      });

      final provider = BuiltinLyricProvider('bili');
      final payload = await provider.fetchForMatch(biliMatch);

      expect(payload, isNotNull);
      expect(payload!.lyric, '[00:01.000]第一句');
      expect(payload.translation, isNull);
      expect(payload.roma, isNull);
      expect(payload.lxlyric, isNull);
      // 通用实现只有 songId 无法取词（B 站还需要 bvid/cid）。
      expect(await provider.fetchLyric('BV1xx411c7mD'), isNull);
    });

    test('未登录：B 站取词直接返回 null，不发请求', () async {
      final requests = <RequestOptions>[];
      BuiltinSearch.transport = BuiltinTransport(
        dio: mockDio((request) async {
          requests.add(request);
          return textResponse('{}', statusCode: 500);
        }),
      );

      final payload =
          await BuiltinLyricProvider('bili').fetchForMatch(biliMatch);

      expect(payload, isNull);
      expect(requests, isEmpty, reason: '未登录时字幕接口必为空，不白跑');
    });

    test('搜索失败：归一为空结果（不抛给换源页）', () async {
      BuiltinSearch.transport = biliTransport(
        (request) async => textResponse('{}', statusCode: 500),
      );

      final matches =
          await BuiltinLyricProvider('bili').searchMultiple('晴天', '周杰伦');
      expect(matches, isEmpty);
    });

    test('空关键词：不搜索、不请求', () async {
      final requests = <RequestOptions>[];
      BuiltinSearch.transport = BuiltinTransport(
        dio: mockDio((request) async {
          requests.add(request);
          return textResponse('{}', statusCode: 500);
        }),
      );

      expect(
        await BuiltinLyricProvider('bili').searchMultiple(' ', ''),
        isEmpty,
      );
      expect(requests, isEmpty);
    });
  });
}

/// 测试端点：会话请求之外的响应。
typedef FutureOrResponse = Future<ResponseBody> Function(
  RequestOptions request,
);
