import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/mapping/track_mapper.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/sources/builtin/artist_source.dart';
import 'package:molia/sources/builtin/crypto_utils.dart';
import 'package:molia/sources/builtin/kg_artist.dart';
import 'package:molia/sources/builtin/kw_artist.dart';
import 'package:molia/sources/builtin/mg_artist.dart';
import 'package:molia/sources/builtin/tx_artist.dart';
import 'package:molia/sources/builtin/wy_artist.dart';
import 'package:molia/sources/builtin/wy_music_detail.dart';

/// 五平台歌手解析：使用真实平台响应快照（test/fixtures/artists/*，
/// 由 tool/gen_artist_fixtures.mjs 抓取）验证字段归一化
/// （歌手 id / 名字 / 头像 / 简介 / 曲目 / 分页）。
dynamic _fixture(String name) =>
    jsonDecode(File('test/fixtures/artists/$name').readAsStringSync());

String _fixtureText(String name) =>
    File('test/fixtures/artists/$name').readAsStringSync();

void main() {
  group('kw 酷我', () {
    test('歌手搜索：id / 名字 / 头像（BASEPICPATH 拼接）/ 歌曲数 / 分页', () {
      final page = KwArtist.parseSearch(_fixtureText('kw_search.json'),
          page: 1, limit: 3);
      expect(page.items, hasLength(3));
      expect(page.items.first.id, '336');
      expect(page.items.first.name, '周杰伦');
      expect(page.items.first.avatarUrl, startsWith('http://img1.kuwo.cn/'));
      expect(page.items.first.songCount, isNotNull);
      expect(page.total, greaterThan(0));
      expect(page.hasMore, isTrue);
    });

    test('歌手详情 + 歌曲：解密 wbd 响应（简介 / 头像 / 曲目 / 分页）', () {
      final info = kwWbdDecodeData(_fixtureText('kw_info.txt'));
      final songs = kwWbdDecodeData(_fixtureText('kw_songs.txt'));
      final artist = KwArtist.parse(
        info: info,
        songs: songs,
        artistId: '336',
        page: 1,
        limit: 3,
      );
      expect(artist.name, '周杰伦');
      expect(artist.avatarUrl, contains('star.kuwo.cn'));
      expect(artist.description, contains('周杰伦'));
      expect(artist.hasMore, isTrue, reason: '总数 1643 > 3');

      expect(artist.tracks, hasLength(3));
      final first = artist.tracks.first;
      expect(first.title, '晴天');
      expect(first.album, '叶惠美');
      expect(first.duration, const Duration(seconds: 269));
      // 歌手引用注入当前歌手（id 与曲目 payload 同体系）。
      expect(first.artists.single.name, '周杰伦');
      expect(first.artists.single.id, '336');
      expect(first.payload['songmid'], '228908');
      expect(
        first.qualities.map((quality) => quality.type).toList(),
        contains('320k'),
      );
    });

    test('响应结构不符：失败', () {
      expect(
        () => KwArtist.parse(info: null, songs: const {}, artistId: '1'),
        throwsA(isA<SourceFailure>()),
      );
    });
  });

  group('kg 酷狗', () {
    test('歌手搜索：id / 名字（平台无头像与总数 → 单页）', () {
      final page = KgArtist.parseSearch(_fixture('kg_search.json'));
      expect(page.items, isNotEmpty);
      expect(page.items.first.id, '3520');
      expect(page.items.first.name, '周杰伦');
      expect(page.items.first.avatarUrl, isNull);
      expect(page.total, isNull);
      expect(page.hasMore, isFalse);
    });

    test('歌手详情 + 歌曲：头像尺寸占位替换 / 简介 / filename 拆分曲目', () {
      final artist = KgArtist.parse(
        info: _fixture('kg_info.json'),
        songs: _fixture('kg_songs.json'),
        artistId: '3520',
        page: 1,
        limit: 3,
      );
      expect(artist.name, '周杰伦');
      expect(artist.avatarUrl, isNot(contains('{size}')));
      expect(artist.avatarUrl, contains('480'));
      expect(artist.description, contains('周杰伦'));
      expect(artist.hasMore, isTrue, reason: '总数 1847 > 3');

      expect(artist.tracks, hasLength(3));
      final first = artist.tracks.first;
      expect(first.title, isNotEmpty);
      expect(first.payload['hash'], isNotEmpty);
      expect(first.artists.single.id, '3520');
      expect(first.duration, isNotNull);
    });
  });

  group('tx QQ 音乐', () {
    test('歌手搜索：singerMID / 头像尺寸替换 / 歌曲数 / meta.sum 分页', () {
      final page = TxArtist.parseSearch(_fixture('tx_search.json'),
          page: 1, limit: 3);
      expect(page.items, isNotEmpty);
      expect(page.items.first.id, '0025NhlN2yWrP4');
      expect(page.items.first.name, '周杰伦');
      expect(page.items.first.avatarUrl, contains('R500x500'));
      expect(page.items.first.songCount, isNotNull);
      expect(page.total, greaterThan(0));
      expect(page.hasMore, isTrue);
    });

    test('歌手详情 + 歌曲：简介 / 曲目与单曲搜索同构（无分页）', () {
      final artist = TxArtist.parse(
        _fixture('tx_detail.json'),
        artistId: '0025NhlN2yWrP4',
        page: 1,
        limit: 3,
      );
      expect(artist.name, '周杰伦');
      expect(artist.avatarUrl, contains('0025NhlN2yWrP4'));
      expect(artist.description, contains('周杰伦'));
      expect(artist.hasMore, isFalse, reason: '平台忽略 begin，只有一页');

      expect(artist.tracks, hasLength(3));
      final first = artist.tracks.first;
      expect(first.payload['songmid'], isNotEmpty);
      expect(first.payload['strMediaMid'], isNotEmpty);
      expect(first.artists.single.id, '0025NhlN2yWrP4');
      expect(first.qualities, isNotEmpty);
    });
  });

  group('wy 网易云', () {
    test('歌手搜索：id / 头像 / 歌曲数（musicSize）/ artistCount 分页', () {
      final page = WyArtist.parseSearch(_fixture('wy_search.json'),
          page: 1, limit: 3);
      expect(page.items, isNotEmpty);
      expect(page.items.first.id, '6452');
      expect(page.items.first.name, '周杰伦');
      expect(page.items.first.avatarUrl, contains('music.126.net'));
      expect(page.items.first.songCount, 581);
      expect(page.total, greaterThan(0));
      expect(page.hasMore, isTrue);
    });

    test('歌手详情 + 歌曲：briefDesc 简介 / ids 补规范 raw', () {
      final detail = _fixture('wy_song_detail.json');
      final tracks = WyMusicDetail.filterList(
        songs: (detail['songs'] as List?) ?? const [],
        privileges: (detail['privileges'] as List?) ?? const [],
      );
      final artist = WyArtist.parse(
        info: _fixture('wy_info.json'),
        tracks: [for (final track in tracks) trackFromSourceTrack(track)],
        songsPage: _fixture('wy_songs.json'),
        artistId: '6452',
        page: 1,
        limit: 3,
      );
      expect(artist.name, '周杰伦');
      expect(artist.avatarUrl, contains('music.126.net'));
      expect(artist.description, contains('周杰伦'));
      expect(artist.hasMore, isTrue, reason: 'more=true / total 579');

      expect(artist.tracks, hasLength(3));
      final first = artist.tracks.first;
      expect(first.payload['songmid'], isNotNull);
      expect(first.artists, isNotEmpty);
      expect(first.artists.first.id, isNotNull);
      expect(first.qualities, isNotEmpty);
    });
  });

  group('mg 咪咕', () {
    test('歌手搜索：字符串 id / 方形头像 / 歌曲数 / totalCount 分页', () {
      final page = MgArtist.parseSearch(_fixture('mg_search.json'),
          page: 1, limit: 3);
      expect(page.items, isNotEmpty);
      expect(page.items.first.id, '112');
      expect(page.items.first.name, '周杰伦');
      expect(page.items.first.avatarUrl, contains('migu.cn'));
      expect(page.items.first.songCount, 413);
      expect(page.total, greaterThan(0));
    });

    test('歌手详情 + 歌曲：无简介（空串）/ 头像 / 曲目字段同构', () {
      final artist = MgArtist.parse(
        info: _fixture('mg_info.json'),
        songs: _fixture('mg_songs.json'),
        artistId: '112',
        page: 1,
        limit: 3,
      );
      expect(artist.name, '周杰伦');
      expect(artist.avatarUrl, contains('migu.cn'));
      expect(artist.description, isEmpty, reason: '平台不提供简介');
      expect(artist.hasMore, isTrue, reason: 'header.nextPageUrl 指向第 2 页');

      expect(artist.tracks, hasLength(3));
      final first = artist.tracks.first;
      expect(first.title, isNotEmpty);
      expect(first.payload['copyrightId'], isNotEmpty);
      expect(first.artists.first.id, '112');
      expect(first.qualities, isNotEmpty);
    });
  });

  group('BuiltinArtists 调度', () {
    test('B 站 UP 也注册为歌手能力', () {
      expect(BuiltinArtists.isSupported('bili'), isTrue);
    });

    test('未知音源：搜索与详情都抛 unsupported', () async {
      expect(
        () => BuiltinArtists.fetch('unknown', '1'),
        throwsA(isA<SourceFailure>()),
      );
      expect(
        () => BuiltinArtists.search('unknown', 'keyword'),
        throwsA(isA<SourceFailure>()),
      );
    });

    test('缺少歌手 id：失败', () {
      expect(
        () => BuiltinArtists.fetch('kw', '  '),
        throwsA(isA<SourceFailure>()),
      );
    });
  });
}
