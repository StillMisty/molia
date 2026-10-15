import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/http/app_dio.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/builtin/kg_artist.dart';
import 'package:molia/sources/builtin/kg_lyric_search.dart';
import 'package:molia/sources/builtin/kw_artist.dart';
import 'package:molia/sources/builtin/kw_lyric_search.dart';
import 'package:molia/sources/builtin/lyric_search.dart';
import 'package:molia/sources/builtin/mg_artist.dart';
import 'package:molia/sources/builtin/mg_lyric_search.dart';
import 'package:molia/sources/builtin/tx_artist.dart';
import 'package:molia/sources/builtin/tx_lyric_search.dart';
import 'package:molia/sources/builtin/wy_artist.dart';
import 'package:molia/sources/builtin/wy_lyric_search.dart';

import 'support/mock_dio.dart';

/// 歌手取数与歌词搜索的**请求构造**离线单测：用 `MockDioAdapter` 拦在真实
/// socket 之前（响应直接回放 test/fixtures 的真实快照），不联网。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BuiltinTransport originalTransport;
  setUpAll(() => originalTransport = BuiltinSearch.transport);
  tearDown(() => BuiltinSearch.transport = originalTransport);

  MockDioAdapter install(
    FutureOr<ResponseBody> Function(RequestOptions options) handler,
  ) {
    final adapter = MockDioAdapter(handler);
    BuiltinSearch.transport =
        BuiltinTransport(dio: createAppDio(adapter: adapter));
    return adapter;
  }

  String fixtureText(String name) =>
      File('test/fixtures/$name').readAsStringSync();

  group('歌手取数链路', () {
    test('kw：wbd 签名请求 + 密文响应解码（详情 + 歌曲两请求）', () async {
      final adapter = install((options) async {
        expect(options.uri.host, 'wbd.kuwo.cn');
        expect(options.uri.queryParameters['appId'], 'y67sprxhhpws');
        expect(options.uri.queryParameters['sign'], isNotEmpty);
        if (options.uri.path.endsWith('/artist_info')) {
          return textResponse(fixtureText('artists/kw_info.txt'));
        }
        expect(options.uri.path, '/api/bd/artist/artist_music');
        return textResponse(fixtureText('artists/kw_songs.txt'));
      });

      final artist = await KwArtist.fetch('336', page: 1, limit: 3);
      expect(adapter.requests, hasLength(2));
      expect(artist.name, '周杰伦');
      expect(artist.tracks, hasLength(3));
    });

    test('kg：singer/song 分页参数 + 详情 best-effort', () async {
      final adapter = install((options) async {
        expect(options.uri.host, 'mobiles.kugou.com');
        if (options.uri.path == '/api/v5/singer/song') {
          expect(options.uri.queryParameters['singerid'], '3520');
          expect(options.uri.queryParameters['page'], '2');
          expect(options.uri.queryParameters['pagesize'], '3');
          return textResponse(fixtureText('artists/kg_songs.json'));
        }
        expect(options.uri.path, '/api/v5/singer/info');
        return textResponse(fixtureText('artists/kg_info.json'));
      });

      final artist = await KgArtist.fetch('3520', page: 2, limit: 3);
      expect(adapter.requests, hasLength(2));
      expect(artist.name, '周杰伦');
      expect(artist.tracks, hasLength(3));
    });

    test('tx：musicu 签名请求（详情与歌曲同请求）', () async {
      final adapter = install((options) async {
        expect(options.uri.host, 'u.y.qq.com');
        expect(options.uri.queryParameters['sign'], startsWith('zzc'));
        return textResponse(fixtureText('artists/tx_detail.json'));
      });

      final artist = await TxArtist.fetch('0025NhlN2yWrP4', limit: 3);
      expect(adapter.requests, hasLength(1));
      expect(artist.name, '周杰伦');
      expect(artist.tracks, hasLength(3));
      expect(artist.hasMore, isFalse, reason: '平台无分页');
    });

    test('wy：歌曲列表 → 详情（weapi）→ 歌曲线（weapi 三请求）', () async {
      final adapter = install((options) async {
        if (options.uri.path == '/api/v1/artist/songs') {
          expect(options.uri.queryParameters['id'], '6452');
          expect(options.uri.queryParameters['offset'], '0');
          return textResponse(fixtureText('artists/wy_songs.json'));
        }
        if (options.uri.path == '/weapi/v1/artist/6452') {
          return textResponse(fixtureText('artists/wy_info.json'));
        }
        expect(options.uri.path, '/weapi/v3/song/detail');
        return textResponse(fixtureText('artists/wy_song_detail.json'));
      });

      final artist = await WyArtist.fetch('6452', limit: 3);
      expect(adapter.requests, hasLength(3));
      expect(artist.name, '周杰伦');
      expect(artist.description, isNotEmpty);
      expect(artist.tracks, hasLength(3));
    });

    test('mg：pc/bmw 详情 + 歌曲（pageNo 分页）', () async {
      final adapter = install((options) async {
        expect(options.uri.host, 'app.c.nf.migu.cn');
        if (options.uri.path == '/pc/bmw/singer/song/v1.0') {
          expect(options.uri.queryParameters['singerId'], '112');
          expect(options.uri.queryParameters['pageNo'], '1');
          expect(options.uri.queryParameters['type'], '1');
          return textResponse(fixtureText('artists/mg_songs.json'));
        }
        expect(options.uri.path, '/pc/bmw/singer/info/v1.1');
        return textResponse(fixtureText('artists/mg_info.json'));
      });

      final artist = await MgArtist.fetch('112', limit: 3);
      expect(adapter.requests, hasLength(2));
      expect(artist.name, '周杰伦');
      expect(artist.description, isEmpty, reason: '平台不提供简介');
      expect(artist.tracks, hasLength(3));
    });

    test('业务拒绝（结构不符）：失败可重试', () async {
      // kg 业务码异常（重试耗尽后由解析层判结构不符）。
      install((options) async =>
          textResponse('{"status":0,"errcode":1,"data":null}'));

      await expectLater(
        KgArtist.fetch('3520'),
        throwsA(
          isA<SourceFailure>().having((f) => f.retryable, 'retryable', isTrue),
        ),
      );
    });
  });

  group('歌词搜索取数链路', () {
    test('kw：stype=lyric 请求 + 片段', () async {
      final adapter = install((options) async {
        expect(options.uri.host, 'search.kuwo.cn');
        expect(options.uri.queryParameters['stype'], 'lyric');
        expect(options.uri.queryParameters['rn'], '3');
        return textResponse(fixtureText('lyric_search/kw.txt'));
      });

      final page = await KwLyricSearch.search('雨下整夜', limit: 3);
      expect(adapter.requests, hasLength(1));
      expect(page.hits, isNotEmpty);
      expect(page.hits.first.snippet, contains('雨下整夜'));
    });

    test('kg：lyric_search 请求 + 片段', () async {
      final adapter = install((options) async {
        expect(options.uri.host, 'songsearch.kugou.com');
        expect(options.uri.path, '/lyric_search');
        expect(options.uri.queryParameters['keyword'], '雨下整夜');
        expect(options.uri.queryParameters['pagesize'], '3');
        return textResponse(fixtureText('lyric_search/kg.json'));
      });

      final page = await KgLyricSearch.search('雨下整夜', limit: 3);
      expect(adapter.requests, hasLength(1));
      expect(page.hits, isNotEmpty);
      expect(page.hits.first.snippet, contains('雨下整夜'));
      expect(page.total, 1000, reason: 'runner 从 data.total 取总数');
      expect(page.hasMore, isTrue);
    });

    test('kg：业务码异常 → 抛 SourceFailure（失败不静默空结果）', () async {
      install((options) async =>
          textResponse('{"status":0,"error_code":1,"data":null}'));

      await expectLater(
        KgLyricSearch.search('雨下整夜'),
        throwsA(
          isA<SourceFailure>().having((f) => f.retryable, 'retryable', isTrue),
        ),
      );
    });

    test('tx：musicu search_type=7 签名请求', () async {
      final adapter = install((options) async {
        expect(options.uri.host, 'u.y.qq.com');
        expect(options.uri.queryParameters['sign'], startsWith('zzc'));
        expect(requestBodyText(options), contains('"search_type":7'));
        return textResponse(fixtureText('lyric_search/tx.json'));
      });

      final page = await TxLyricSearch.search('雨下整夜', limit: 3);
      expect(adapter.requests, hasLength(1));
      expect(page.hits.first.snippet, contains('雨下整夜'));
      expect(page.total, 3);
      expect(page.hasMore, isFalse, reason: '3 条结果一页取满');
    });

    test('wy：type=1006 搜索 + ids 补规范 raw（两请求）', () async {
      final adapter = install((options) async {
        if (options.uri.path == '/api/search/get/web') {
          expect(options.uri.queryParameters['type'], '1006');
          return textResponse(fixtureText('lyric_search/wy_search.json'));
        }
        expect(options.uri.path, '/weapi/v3/song/detail');
        return textResponse(fixtureText('lyric_search/wy_song_detail.json'));
      });

      final page = await WyLyricSearch.search('雨下整夜', limit: 3);
      expect(adapter.requests, hasLength(2));
      expect(page.hits, hasLength(3));
      expect(page.hits.first.track.raw['songmid'], isNotNull);
      expect(page.hits.first.snippet, contains('雨下整夜'));
    });

    test('mg：searchAll lyricSong=1 签名请求 + 片段', () async {
      final adapter = install((options) async {
        expect(options.uri.host, 'jadeite.migu.cn');
        expect(options.uri.queryParameters['searchSwitch'],
            contains('lyricSong'));
        expect(options.headers['sign'], isNotEmpty);
        return textResponse(fixtureText('lyric_search/mg.json'));
      });

      final page = await MgLyricSearch.search('雨下整夜', limit: 3);
      expect(adapter.requests, hasLength(1));
      expect(page.hits, isNotEmpty);
      expect(page.hits.first.snippet, contains('雨下整夜'));
      expect(page.total, 80);
      expect(page.hasMore, isTrue);
    });

    test('BuiltinLyricSearch 调度：不支持的平台抛 unsupported', () async {
      install((options) async => textResponse('{}'));
      await expectLater(
        BuiltinLyricSearch.searchWithMeta('script-source', '雨下整夜'),
        throwsA(
          isA<SourceFailure>()
              .having((f) => f.kind, 'kind', FailureKind.unsupported),
        ),
      );
    });
  });
}
