import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/bili_api.dart';
import 'package:molia/sources/builtin/bili_play.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:molia/sources/source_track.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/mock_dio.dart';
import 'support/settings_test_support.dart';

/// 无脚本环境下的 B 站路由：搜索 / 播放 / 歌词 / 评论 / UP / 发现由原生
/// 实现提供；专辑与按歌词搜歌尚未接入；五个音乐平台仍保持「无脚本不可搜索」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final searchFixture = jsonDecode(
    File('test/fixtures/bili_search.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  late BuiltinTransport originalTransport;
  setUpAll(() => originalTransport = BuiltinSearch.transport);
  setUp(() {
    BiliApi.reset();
    BiliPlay.reset();
    final deadline = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
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
          case '/x/web-interface/wbi/search/type':
            return textResponse(jsonEncode(searchFixture));
          case '/x/player/wbi/playurl':
            return textResponse(
              jsonEncode({
                'code': 0,
                'data': {
                  'dash': {
                    'audio': [
                      {
                        'id': 30216,
                        'baseUrl': 'https://cdn.example/audio64.m4s'
                            '?deadline=$deadline',
                      },
                      {
                        'id': 30232,
                        'baseUrl': 'https://cdn.example/audio128.m4s'
                            '?deadline=$deadline',
                      },
                      {
                        'id': 30280,
                        'baseUrl': 'https://cdn.example/audio192.m4s'
                            '?deadline=$deadline',
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

  test('能力位：无脚本时 bili 可搜索/播放/取歌词/评论/UP；发现渠道可用', () {
    final manager = SourceManager(settings: testSettingsRegistry());
    addTearDown(manager.dispose);

    final bili = manager.capabilitiesFor('bili');
    expect(bili.search, isTrue);
    expect(bili.pagination, isTrue);
    expect(bili.resolveUrl, isTrue);
    expect(bili.artwork, isTrue);
    expect(bili.lyrics, isTrue, reason: 'CC 字幕歌词 Phase 3 已接入');
    expect(bili.comment, isTrue);
    expect(bili.collection, isFalse);
    expect(bili.artist, isTrue);
    expect(bili.lyricSearch, isFalse);

    // 五个音乐平台没有脚本可取链 → 仍不可搜索 / 播放。
    for (final key in const ['tx', 'wy', 'kg', 'kw', 'mg']) {
      final capabilities = manager.capabilitiesFor(key);
      expect(capabilities.search, isFalse, reason: key);
      expect(capabilities.pagination, isFalse, reason: key);
      expect(capabilities.resolveUrl, isFalse, reason: key);
      expect(capabilities.lyrics, isTrue, reason: key);
    }

    expect(manager.searchableSources.map((o) => o.key), contains('bili'));
    expect(
      manager.channels.firstWhere((o) => o.key == 'bili').discoverable,
      isTrue,
      reason: 'B 站发现页（音乐榜 / 热搜）已接入',
    );
  });

  test('manager.searchWithMeta：bili 搜索走原生实现并带分页', () async {
    final manager = SourceManager(settings: testSettingsRegistry());
    addTearDown(manager.dispose);

    final result = await manager.searchWithMeta('bili', '起风了');
    expect(result.failure, isNull);
    expect(result.tracks, hasLength(2));
    expect(result.tracks.first.sourceKey, 'bili');
    expect(result.tracks.first.songId, 'BV1xx411c7mD');
    expect(result.total, 1000);
    expect(result.hasMore, isTrue);
  });

  test('manager.resolveStream：bili 曲目返回带 Referer/UA 的可播流', () async {
    final manager = SourceManager(settings: testSettingsRegistry());
    addTearDown(manager.dispose);

    final track = SourceTrack(
      sourceKey: 'bili',
      origin: 'builtin',
      title: '起风了',
      artist: '买辣椒也用券',
      album: '',
      raw: const {'bvid': 'BV1xx411c7mD', 'aid': 987654, 'cid': 12345},
    );
    final stream = await manager.resolveStream(track, requestedQuality: '128k');

    expect(stream.uri.path, endsWith('/audio128.m4s'));
    expect(stream.headers['Referer'], 'https://www.bilibili.com/');
    expect(stream.headers['User-Agent'], contains('Chrome/'));
    expect(stream.expiresIn, isNotNull);
  });
}
