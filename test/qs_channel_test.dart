import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/builtin_lyric_dispatch.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/builtin/qs_artist.dart';
import 'package:molia/sources/builtin/qs_lyric.dart';
import 'package:molia/sources/builtin/qs_search.dart';
import 'package:molia/sources/source_track.dart';

import 'support/mock_dio.dart';

dynamic _fixture(String path) =>
    jsonDecode(File('test/fixtures/$path').readAsStringSync());

/// 分享页 SSR 的最小外壳：适配器只认 `_ROUTER_DATA = {...}` 后面的 JSON。
String _shareHtml(Object? loaderData) =>
    '<html><script>_ROUTER_DATA = ${jsonEncode({'loaderData': loaderData})};'
    '</script></html>';

Map<String, dynamic> _searchBody({
  required List<Map<String, dynamic>> tracks,
  bool hasMore = true,
}) => {
  'result_groups': [
    {
      'id': 'tracks',
      'next_cursor': '20',
      'has_more': hasMore,
      'data': [
        for (final track in tracks)
          {
            'entity': {'track': track},
          },
      ],
    },
  ],
};

Map<String, dynamic> _track({
  required String id,
  required String name,
  required String artistId,
  required String artistName,
}) => {
  'id': id,
  'name': name,
  'duration': 200000,
  'album': {
    'id': 'a1',
    'name': '专辑',
    'url_cover': {
      'uri': 'cover',
      'urls': ['https://p3-luna.douyinpic.com/img/'],
    },
  },
  'artists': [
    {'id': artistId, 'name': artistName},
  ],
  'bit_rates': [
    {'quality': 'highest', 'size': 1000},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BuiltinTransport originalTransport;
  setUpAll(() => originalTransport = BuiltinSearch.transport);
  tearDown(() => BuiltinSearch.transport = originalTransport);

  group('qs 歌词', () {
    test('KRC → 行级 LRC + LX 逐字（去掉第三字段）', () {
      final result = QsLyric.parseContent(
        '[60,1470]<0,350,0>不<400,340,0>敢\n'
        '[2260,3270]<0,250,0>左<360,200,0>顾',
      )!;
      expect(result.lyric, '[00:00.060]不敢\n[00:02.260]左顾');
      expect(
        result.lxlyric,
        '[00:00.060]<0,350>不<400,340>敢\n'
        '[00:02.260]<0,250>左<360,200>顾',
      );
      expect(result.tlyric, isNull, reason: '平台不返回翻译');
      expect(result.rlyric, isNull, reason: '平台不返回罗马音');
    });

    test('空歌词 / 无时间标签：null 或原样兜底', () {
      expect(QsLyric.parse(null), isNull);
      expect(QsLyric.parse({'content': '  '}), isNull);
      expect(QsLyric.parseContent('[ti:标题]')!.lyric, '[ti:标题]');
    });

    test('原生取词派发：track_id → seo_track → 逐字歌词', () async {
      BuiltinSearch.transport = BuiltinTransport(
        dio: mockDio((request) {
          expect(request.uri.path, '/luna/h5/seo_track');
          expect(
            request.uri.queryParameters['track_id'],
            '7079108541549643812',
          );
          return textResponse(
            jsonEncode({
              'lyric': {'content': '[60,1470]<0,350,0>不<400,340,0>敢'},
            }),
          );
        }),
      );

      final result = await BuiltinLyricDispatch().fetch(
        const SourceTrack(
          sourceKey: 'qs',
          origin: 'builtin',
          title: '小半',
          artist: '陈粒',
          album: '小梦大半',
          raw: {'track_id': '7079108541549643812'},
        ),
      );
      expect(result, isNotNull);
      expect(result!.lyric, '[00:00.060]不敢');
      expect(result.lxlyric, '[00:00.060]<0,350>不<400,340>敢');
    });
  });

  group('qs 搜索', () {
    test('空响应重试后成功；分页按平台 20 条游标走', () async {
      var calls = 0;
      BuiltinSearch.transport = BuiltinTransport(
        dio: mockDio((request) {
          calls++;
          if (calls <= 2) return textResponse('');
          expect(request.uri.queryParameters['cursor'], '20');
          expect(request.uri.queryParameters['q'], '陈粒');
          return textResponse(
            jsonEncode(
              _searchBody(
                tracks: [
                  _track(
                    id: '7079108541549643812',
                    name: '小半',
                    artistId: '6776144869279664130',
                    artistName: '陈粒',
                  ),
                ],
              ),
            ),
          );
        }),
      );

      final result = await QsSearch.searchWithMeta('陈粒', page: 2);
      expect(calls, 3, reason: '前两次空 body 必须重试');
      expect(result.failure, isNull);
      expect(result.tracks.single.title, '小半');
      expect(result.tracks.single.artist, '陈粒');
      expect(result.hasMore, isTrue);
    });

    test('平台正常返回空结果：不是失败', () async {
      BuiltinSearch.transport = BuiltinTransport(
        dio: mockDio((_) => textResponse('{"extra":{"empty_search":1}}')),
      );
      final result = await QsSearch.searchWithMeta('没有这首歌');
      expect(result.failure, isNull);
      expect(result.tracks, isEmpty);
    });
  });

  group('qs 歌手', () {
    test('分享页样本 + 同名搜索按歌手 id 补齐（不混入他人曲目）', () async {
      final artistPage = _fixture('artists/qs_page.json');
      BuiltinSearch.transport = BuiltinTransport(
        dio: mockDio((request) {
          if (request.uri.host == 'www.qishui.com') {
            expect(request.uri.path, '/share/artist');
            return textResponse(_shareHtml({'artist_page': artistPage}));
          }
          expect(request.uri.path, '/luna/search/track');
          return textResponse(
            jsonEncode(
              _searchBody(
                tracks: [
                  _track(
                    id: '7004',
                    name: '分享页没有的歌',
                    artistId: '6776144869279664130',
                    artistName: '陈粒',
                  ),
                  _track(
                    id: '7005',
                    name: '别人的歌',
                    artistId: '999',
                    artistName: '别人',
                  ),
                ],
              ),
            ),
          );
        }),
      );

      final detail = await QsArtist.fetch('6776144869279664130');
      expect(detail.id, '6776144869279664130');
      expect(detail.name, '陈粒');
      expect(detail.avatarUrl, contains('douyinpic.com'));
      expect(detail.description, contains('贵阳'));
      expect(detail.tracks.map((track) => track.title), contains('分享页没有的歌'));
      expect(
        detail.tracks.map((track) => track.title),
        isNot(contains('别人的歌')),
        reason: '只接受 raw._artists 里 id 相同的曲目',
      );
      expect(detail.hasMore, isFalse, reason: '平台没有完整歌手曲库');
    });
  });
}
