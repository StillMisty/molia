import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/http/app_dio.dart';
import 'package:molia/domain/models/album.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/sources/builtin/album_source.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/builtin/kg_album.dart';
import 'package:molia/sources/builtin/kw_album.dart';
import 'package:molia/sources/builtin/mg_album.dart';
import 'package:molia/sources/builtin/tx_album.dart';
import 'package:molia/sources/builtin/wy_album.dart';

import 'support/mock_dio.dart';

/// 专辑取数链路（请求构造 / 分页参数 / 业务码失败）的离线单测：
/// 用 `MockDioAdapter` 拦在真实 socket 之前，不联网。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BuiltinTransport originalTransport;
  setUpAll(() => originalTransport = BuiltinSearch.transport);
  tearDown(() => BuiltinSearch.transport = originalTransport);

  /// 注入一个「按请求返回响应」的传输层，返回的 adapter 可断言请求。
  MockDioAdapter install(
    FutureOr<ResponseBody> Function(RequestOptions options) handler,
  ) {
    final adapter = MockDioAdapter(handler);
    BuiltinSearch.transport =
        BuiltinTransport(dio: createAppDio(adapter: adapter));
    return adapter;
  }

  group('wy 网易云', () {
    test('专辑：GET api/v1/album/{id} + 曲目解析', () async {
      final adapter = install((options) async {
        expect(options.uri.path, '/api/v1/album/32311');
        return textResponse(jsonEncode({
          'code': 200,
          'album': {
            'id': 32311,
            'name': '神的游戏',
            'artist': {'name': '张悬'},
            'picUrl': 'http://img/cover.jpg',
            'publishTime': 1344528000000,
          },
          'songs': [
            {
              'id': 326696,
              'name': '疯狂的阳光',
              'ar': [
                {'name': '张悬'},
              ],
              'al': {
                'id': 32311,
                'name': '神的游戏',
                'picUrl': 'http://img/cover.jpg',
              },
              'dt': 235146,
              'privilege': {'maxbr': 320000},
              'h': {'size': 9408305},
              'l': {'size': 3763348},
            },
          ],
        }));
      });

      final album = await WyAlbum.fetch('32311');
      expect(adapter.requests, hasLength(1));
      expect(album.name, '神的游戏');
      expect(album.year, 2012);
      expect(album.tracks.single.title, '疯狂的阳光');
      expect(album.tracks.single.qualities, isNotEmpty);
    });

    test('code 非 200：重试耗尽后归一化为可重试失败', () async {
      final adapter = install((options) async {
        return textResponse(jsonEncode({'code': 250}));
      });
      await expectLater(
        WyAlbum.fetch('1'),
        throwsA(
          isA<SourceFailure>()
              .having((f) => f.kind, 'kind', FailureKind.unknown)
              .having((f) => f.retryable, 'retryable', isTrue),
        ),
      );
      expect(adapter.requests, hasLength(BuiltinTransport.defaultRetries));
    });
  });

  group('tx QQ 音乐', () {
    test('专辑：albumSonglist 模块 + begin/num 分页参数', () async {
      final adapter = install((options) async {
        return textResponse(jsonEncode({
          'code': 0,
          'albumSonglist': {
            'code': 0,
            'data': {
              'albumMid': '000MkMni19ClKG',
              'totalNum': 11,
              'songList': [
                {
                  'songInfo': {
                    'id': 97771,
                    'mid': '001n4C3p1yv0FU',
                    'name': '以父之名',
                    'title': '以父之名',
                    'interval': 342,
                    'file': {
                      'media_mid': '002ExFMX2Jt6gv',
                      'size_128mp3': 5473371,
                    },
                    'album': {
                      'mid': '000MkMni19ClKG',
                      'name': '叶惠美',
                      'time_public': '2003-07-31',
                    },
                    'singer': [
                      {'name': '周杰伦'},
                    ],
                  },
                },
              ],
            },
          },
        }));
      });

      final album = await TxAlbum.fetch('000MkMni19ClKG', page: 2, limit: 30);
      final data = jsonDecode(
        adapter.lastRequest.uri.queryParameters['data']!,
      ) as Map;
      final section = data['albumSonglist'] as Map;
      expect(section['module'], 'music.musichallAlbum.AlbumSongList');
      expect(section['method'], 'GetAlbumSongList');
      final param = section['param'] as Map;
      expect(param['albumMid'], '000MkMni19ClKG');
      expect(param['begin'], 30);
      expect(param['num'], 30);
      expect(param['order'], 2);

      expect(album.name, '叶惠美');
      expect(album.artist, '周杰伦');
      expect(album.year, 2003);
      expect(album.tracks.single.payload['songmid'], '001n4C3p1yv0FU');
      // totalNum=11，第 2 页（begin=30）已到尾部。
      expect(album.hasMore, isFalse);
    });
  });

  group('kg 酷狗', () {
    test('专辑：album/song 分页 + album/info 元信息（两次请求）', () async {
      final adapter = install((options) async {
        if (options.uri.path == '/api/v3/album/song') {
          return textResponse(jsonEncode({
            'status': 1,
            'errcode': 0,
            'data': {
              'total': 12,
              'info': [
                {
                  'audio_id': 1,
                  'filename': 'The Animal Friends - Jolly Farm',
                  'duration': 159,
                  'hash': 'HASH128',
                  'filesize': 2548832,
                  '320hash': 'HASH320',
                  '320filesize': 6372059,
                  'sqhash': 'HASHFLAC',
                  'sqfilesize': 15779165,
                  'album_id': '1234567',
                },
              ],
            },
          }));
        }
        return textResponse(jsonEncode({
          'status': 1,
          'errcode': 0,
          'data': {
            'albumid': 1234567,
            'albumname': 'Kids Learn Animals',
            'singername': 'The Animal Friends',
            'imgurl': 'http://img/{size}.jpg',
            'publishtime': '2009-06-01 00:00:00',
          },
        }));
      });

      final album = await KgAlbum.fetch('1234567', page: 1, limit: 5);
      expect(adapter.requests, hasLength(2));
      final songsQuery = adapter.requests.first.uri.queryParameters;
      expect(songsQuery['albumid'], '1234567');
      expect(songsQuery['page'], '1');
      expect(songsQuery['pagesize'], '5');
      final infoQuery = adapter.lastRequest.uri.queryParameters;
      expect(infoQuery['albumid'], '1234567');

      expect(album.name, 'Kids Learn Animals');
      expect(album.coverUrl, 'http://img/480.jpg');
      expect(album.tracks.single.title, 'Jolly Farm');
      expect(album.tracks.single.qualities.first.hash, 'HASHFLAC');
      expect(album.hasMore, isTrue);
    });
  });

  group('kw 酷我', () {
    test('专辑：r.s stype=albuminfo + pn/rn 分页（伪 JSON 文本）', () async {
      final adapter = install((options) async {
        return textResponse(
          "{'albumid':'1433','name':'黑色香水','artist':'曹方','img':'http://img/x.jpg',"
          "'songnum':'12','musiclist':[{'id':'81642','name':'黑色香水',"
          "'artist':'曹方','album':'黑色香水','albumId':1433,'duration':'240',"
          "'N_MINFO':'level:h,bitrate:320,format:mp3,size:9.17Mb'}]}",
        );
      });

      final album = await KwAlbum.fetch('1433', page: 2, limit: 10);
      final query = adapter.lastRequest.uri.queryParameters;
      expect(query['stype'], 'albuminfo');
      expect(query['albumid'], '1433');
      expect(query['pn'], '1');
      expect(query['rn'], '10');

      expect(album.name, '黑色香水');
      expect(album.tracks.single.payload['songmid'], '81642');
      expect(album.tracks.single.qualities.single.type, '320k');
    });
  });

  group('mg 咪咕', () {
    test('专辑：queryAlbumSong + MIGUM3.0 元信息（两次请求）', () async {
      final adapter = install((options) async {
        if (options.uri.path.contains('queryAlbumSong')) {
          return textResponse(jsonEncode({
            'code': '000000',
            'data': {
              'totalCount': '13',
              'songList': [
                {
                  'songId': '1142543109',
                  'copyrightId': '6902739Z0BT',
                  'songName': '太阳之子',
                  'singer': '周杰伦',
                  'album': '太阳之子',
                  'albumId': '1142521343',
                  'length': '00:04:57',
                  'newRateFormats': [
                    {'formatType': 'HQ', 'size': '11897419'},
                  ],
                },
              ],
            },
          }));
        }
        return textResponse(jsonEncode({
          'code': '000000',
          'data': {
            'albumId': '1142521343',
            'title': '太阳之子',
            'singer': '周杰伦',
            'imgItems': [
              {'img': 'http://img/cover.webp'},
            ],
            'publishDate': '2026-03-25',
            'totalCount': '13',
          },
        }));
      });

      final album = await MgAlbum.fetch('1142521343', page: 1, limit: 50);
      expect(adapter.requests, hasLength(2));
      final songsQuery = adapter.requests.first.uri.queryParameters;
      expect(songsQuery['albumId'], '1142521343');
      expect(songsQuery['pageNo'], '1');
      final infoQuery = adapter.lastRequest.uri.queryParameters;
      expect(infoQuery['albumId'], '1142521343');

      expect(album.name, '太阳之子');
      expect(album.year, 2026);
      expect(album.tracks.single.duration, const Duration(seconds: 297));
      expect(album.tracks.single.payload['copyrightId'], '6902739Z0BT');
      expect(album.hasMore, isTrue);
    });
  });

  group('BuiltinAlbums 调度', () {
    test('fetch 按平台分发到各实现', () async {
      install((options) async {
        if (options.uri.host == 'search.kuwo.cn') {
          return textResponse(
            "{'albumid':'1','name':'x','artist':'y','songnum':'0',"
            "'musiclist':[]}",
          );
        }
        return textResponse(jsonEncode({
          'code': 200,
          'album': {'id': 1, 'name': 'x'},
          'songs': [],
        }));
      });

      final kw = await BuiltinAlbums.fetch('kw', '1');
      expect(kw, isA<Album>());
      final wy = await BuiltinAlbums.fetch('wy', '1');
      expect(wy.id, '1');
    });
  });
}
