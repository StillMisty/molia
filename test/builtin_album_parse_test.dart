import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/album.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/sources/builtin/album_source.dart';
import 'package:molia/sources/builtin/album_utils.dart';
import 'package:molia/sources/builtin/kg_album.dart';
import 'package:molia/sources/builtin/kw_album.dart';
import 'package:molia/sources/builtin/kw_discover.dart';
import 'package:molia/sources/builtin/mg_album.dart';
import 'package:molia/sources/builtin/tx_album.dart';
import 'package:molia/sources/builtin/wy_album.dart';

/// 五平台专辑解析：使用真实平台响应快照（test/fixtures/albums/*.json，
/// 由 tool/gen_album_fixtures.mjs 抓取）验证字段归一化
/// （专辑名 / 歌手 / 封面 / 年份 / 曲目 / 音质 / 分页）。
dynamic _fixture(String name) =>
    jsonDecode(File('test/fixtures/albums/$name.json').readAsStringSync());

String _fixtureText(String name) =>
    File('test/fixtures/albums/$name.json').readAsStringSync();

void main() {
  group('wy 网易云', () {
    test('专辑解析：元信息 / 年份（毫秒时间戳）/ 曲目与音质', () {
      final album = WyAlbum.parse(_fixture('wy'), albumId: '32311');
      expect(album.id, '32311');
      expect(album.name, '神的游戏');
      expect(album.artist, '张悬');
      expect(album.coverUrl, contains('music.126.net'));
      expect(album.year, 2012);
      expect(album.hasMore, isFalse, reason: '接口一次返回整张专辑');

      expect(album.tracks, hasLength(3));
      final first = album.tracks.first;
      expect(first.title, '疯狂的阳光');
      expect(first.artists.single.name, '张悬');
      expect(first.album, '神的游戏');
      expect(first.duration, const Duration(milliseconds: 235146));
      expect(first.payload['songmid'], 326696);
      expect(first.payload['albumId'], 32311);
      // privilege maxbr=999000：flac/320k/128k 三档（顺序按音质从高到低）。
      expect(
        first.qualities.map((quality) => quality.type).toList(),
        ['flac', '320k', '128k'],
      );
    });

    test('业务码非 200：失败', () {
      expect(
        () => WyAlbum.parse({'code': 250}, albumId: '1'),
        throwsA(isA<SourceFailure>()),
      );
    });
  });

  group('tx QQ 音乐', () {
    test('专辑解析：albumMid / 曲目与搜索条目同构 / totalNum 分页', () {
      final album = TxAlbum.parse(
        _fixture('tx'),
        albumMid: '000MkMni19ClKG',
        page: 1,
        limit: 3,
      );
      expect(album.id, '000MkMni19ClKG');
      expect(album.name, '叶惠美');
      expect(album.artist, '周杰伦');
      expect(album.year, 2003);
      expect(
        album.coverUrl,
        'https://y.gtimg.cn/music/photo_new/T002R500x500M000000MkMni19ClKG.jpg',
      );
      expect(album.hasMore, isTrue, reason: 'totalNum=11 > 本页 3');

      expect(album.tracks, hasLength(3));
      final first = album.tracks.first;
      expect(first.title, '以父之名');
      expect(first.duration, const Duration(seconds: 342));
      expect(first.payload['songmid'], '001n4C3p1yv0FU');
      expect(first.payload['strMediaMid'], '002ExFMX2Jt6gv');
      expect(first.payload['albumMid'], '000MkMni19ClKG');
      expect(first.qualities, isNotEmpty);
    });

    test('模块 subcode 非 0：失败', () {
      expect(
        () => TxAlbum.parse(
          {
            'code': 0,
            'albumSonglist': {'code': 500003, 'subcode': 860100001},
          },
          albumMid: '1',
        ),
        throwsA(isA<SourceFailure>()),
      );
    });
  });

  group('kg 酷狗', () {
    test('专辑解析：album/info 元信息 + filename 拆歌名歌手 + 音质 hash', () {
      final album = KgAlbum.parse(
        songs: _fixture('kg_songs'),
        info: _fixture('kg_info'),
        albumId: '1234567',
        page: 1,
        limit: 3,
      );
      expect(album.id, '1234567');
      expect(album.name, 'Kids Learn Animals');
      expect(album.artist, 'The Animal Friends');
      expect(album.coverUrl, contains('imge.kugou.com'));
      expect(album.coverUrl, isNot(contains('{size}')), reason: '尺寸占位符已替换');
      expect(album.year, 2009);
      expect(album.hasMore, isTrue, reason: 'total=12 > 本页 3');

      expect(album.tracks, hasLength(3));
      final first = album.tracks.first;
      expect(first.title, 'Jollity Farm');
      expect(first.artists.single.name, 'The Animal Friends');
      expect(first.duration, const Duration(seconds: 159));
      expect(first.payload['hash'], '09EE635764AFB88319A971AEA30EC179');
      expect(first.payload['albumId'], '1234567');
      // 各音质携带各自 hash（取链依赖）。
      final flac = first.qualities.firstWhere((q) => q.type == 'flac');
      expect(flac.hash, '90EF49D1E590FD5EDD514C931F168C5C');
    });

    test('元信息缺失：曲目仍可展示（名称回退入口）', () {
      final album = KgAlbum.parse(
        songs: _fixture('kg_songs'),
        info: null,
        albumId: '1234567',
      );
      expect(album.name, isEmpty);
      expect(album.tracks, hasLength(3));
    });

    test('errcode 非 0：失败', () {
      expect(
        () => KgAlbum.parse(
          songs: {'status': 0, 'errcode': 30001},
          info: null,
          albumId: '1',
        ),
        throwsA(isA<SourceFailure>()),
      );
    });
  });

  group('kw 酷我', () {
    test('专辑解析：伪 JSON / N_MINFO 音质 / songnum 分页', () {
      final body = KwDiscoverSource.objStr2JSON(_fixtureText('kw'));
      final album = KwAlbum.parse(
        body,
        albumId: '1433',
        page: 1,
        limit: 3,
      );
      expect(album.id, '1433');
      expect(album.name, '黑色香水');
      expect(album.artist, '曹方');
      expect(album.coverUrl, contains('kuwo.cn'));
      expect(album.year, isNull, reason: '接口不返回发行年份');
      expect(album.hasMore, isTrue, reason: 'songnum=12 > 本页 3');

      expect(album.tracks, hasLength(3));
      final first = album.tracks.first;
      expect(first.title, '黑色香水');
      expect(first.album, '黑色香水');
      expect(first.duration, const Duration(seconds: 240));
      expect(first.payload['songmid'], '81642');
      expect(first.qualities, isNotEmpty);
    });

    test('缺少 musiclist：失败', () {
      expect(
        () => KwAlbum.parse({'albumid': '1'}, albumId: '1'),
        throwsA(isA<SourceFailure>()),
      );
    });
  });

  group('mg 咪咕', () {
    test('专辑解析：queryAlbumSong + MIGUM3.0 元信息 / length 时长', () {
      final album = MgAlbum.parse(
        songs: _fixture('mg_songs'),
        info: _fixture('mg_info'),
        albumId: '1142521343',
        page: 1,
        limit: 3,
      );
      expect(album.id, '1142521343');
      expect(album.name, '太阳之子');
      expect(album.artist, '周杰伦');
      expect(album.coverUrl, contains('migu.cn'));
      expect(album.year, 2026);
      expect(album.hasMore, isTrue, reason: 'totalCount=13 > 本页 3');

      expect(album.tracks, hasLength(3));
      final first = album.tracks.first;
      expect(first.title, '太阳之子');
      expect(first.album, '太阳之子');
      expect(first.duration, const Duration(seconds: 297), reason: '00:04:57');
      expect(first.payload['songmid'], '1142543109');
      expect(first.payload['copyrightId'], '6902739Z0BT');
      expect(first.qualities, isNotEmpty);
    });

    test('code 非 000000：失败', () {
      expect(
        () => MgAlbum.parse(
          songs: {'code': '040002'},
          info: null,
          albumId: '1',
        ),
        throwsA(isA<SourceFailure>()),
      );
    });
  });

  group('BuiltinAlbums 调度', () {
    test('能力位：仅五平台内置支持', () {
      for (final key in const ['kw', 'kg', 'tx', 'wy', 'mg']) {
        expect(BuiltinAlbums.isSupported(key), isTrue, reason: key);
      }
      expect(BuiltinAlbums.isSupported('any_listen'), isFalse);
      expect(BuiltinAlbums.isSupported('lx_custom'), isFalse);
    });

    test('未知平台：unsupported（不发请求）', () async {
      await expectLater(
        BuiltinAlbums.fetch('lx_custom', '1'),
        throwsA(
          isA<SourceFailure>()
              .having((f) => f.kind, 'kind', FailureKind.unsupported),
        ),
      );
    });

    test('缺少专辑 id：可重试失败（不发请求）', () async {
      await expectLater(
        BuiltinAlbums.fetch('wy', '  '),
        throwsA(
          isA<SourceFailure>()
              .having((f) => f.kind, 'kind', FailureKind.unknown)
              .having((f) => f.retryable, 'retryable', isTrue),
        ),
      );
    });
  });

  group('album_utils', () {
    test('albumYearOf：毫秒时间戳 / 文本日期 / 裸年份 / 非法值', () {
      expect(albumYearOf(1344528000000), 2012);
      expect(albumYearOf('2009-06-01 00:00:00'), 2009);
      expect(albumYearOf('2026-03-25'), 2026);
      expect(albumYearOf(2012), 2012);
      expect(albumYearOf(null), isNull);
      expect(albumYearOf(''), isNull);
      expect(albumYearOf('未知'), isNull);
    });

    test('albumHasMore：按页码与总数推断；无总数视为结束', () {
      expect(albumHasMore(page: 1, limit: 50, total: 120), isTrue);
      expect(albumHasMore(page: 2, limit: 50, total: 120), isTrue);
      expect(albumHasMore(page: 3, limit: 50, total: 120), isFalse);
      expect(albumHasMore(page: 1, limit: 50, total: 0), isFalse);
      expect(albumHasMore(page: 1, limit: 50, total: null), isFalse);
    });

    test('Album 值相等：曲目 / 分页任一不同即不等', () {
      const a = Album(id: '1', name: 'x', hasMore: true);
      const b = Album(id: '1', name: 'x', hasMore: true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == const Album(id: '1', name: 'x'), isFalse);
    });
  });
}
