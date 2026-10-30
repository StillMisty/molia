import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/builtin_cover_urls.dart';
import 'package:molia/sources/builtin/kg_search.dart';
import 'package:molia/sources/builtin/kw_search.dart';
import 'package:molia/sources/builtin/mg_search.dart';
import 'package:molia/sources/builtin/tx_search.dart';
import 'package:molia/sources/builtin/wy_search.dart';
import 'package:molia/sources/raw_track.dart';
import 'package:molia/sources/source_track.dart';

/// 使用真实平台响应的快照（test/fixtures/*.json）验证解析移植的正确性。
dynamic _fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync());

void _assertCommon(SourceTrack track, String sourceKey) {
  expect(track.sourceKey, sourceKey);
  expect(track.title.trim(), isNotEmpty);
  expect(track.raw['source'], sourceKey);
  expect(track.raw['_types'], isA<Map>());
  for (final quality in track.qualities) {
    expect(kLxQualityOrder, contains(quality.type));
  }
  final picked = track.pickQuality('flac');
  expect(picked, isNotEmpty);

  // 歌手引用（项目内部字段 `_artists`）：内置平台搜索注入名字 + 平台歌手 id
  // （歌手页入口据此闭环，见 raw_track.dart 约定）。
  final artists = artistsFromRaw(track.raw);
  expect(artists, isNotEmpty, reason: '内置平台搜索应注入 _artists');
  expect(artists.first.name, isNotEmpty);
  expect(artists.first.id, isNotNull, reason: '歌手 id 与曲目 payload 同体系');
}

void main() {
  group('builtin search fixtures', () {
    test('kw: 酷我搜索响应解析', () {
      final tracks = KwSearch.parseItems(_fixture('kw'));
      expect(tracks, isNotEmpty);
      _assertCommon(tracks.first, 'kw');
      expect(tracks.first.raw['songmid'], isA<String>());
      expect((tracks.first.raw['songmid'] as String).isNotEmpty, isTrue);
      expect(tracks.first.qualities, isNotEmpty);
      expect(
        tracks.first.coverUrl,
        'https://img1.kuwo.cn/star/albumcover/500/s3s94/93/211513640.jpg',
        reason: 'web_albumpic_short 需规整成 500 尺寸封面',
      );
    });

    test('kg: 酷狗搜索响应解析', () {
      final json = _fixture('kg') as Map;
      final tracks = KgSearch.parseItems(json['data']['lists'] as List);
      expect(tracks, isNotEmpty);
      _assertCommon(tracks.first, 'kg');
      expect((tracks.first.raw['hash'] as String).isNotEmpty, isTrue);
      expect(
        tracks.first.coverUrl,
        'http://imge.kugou.com/stdmusic/480/20230920/20230920142503632013.jpg',
        reason: '搜索响应自带 Image，{size} 需替换为 480',
      );
      // 酷狗不同音质携带不同 hash
      final flac = tracks.first.qualities.where((q) => q.type == 'flac');
      if (flac.isNotEmpty) {
        expect(flac.first.hash, isNotNull);
      }
    });

    test('tx: QQ 音乐搜索响应解析', () {
      final json = _fixture('tx') as Map;
      final data = json['music.search.SearchCgiService']['data'];
      final tracks = TxSearch.parseItems(data);
      expect(tracks, isNotEmpty);
      _assertCommon(tracks.first, 'tx');
      expect((tracks.first.raw['songmid'] as String).isNotEmpty, isTrue);
      expect((tracks.first.raw['strMediaMid'] as String).isNotEmpty, isTrue);
      expect(tracks.first.coverUrl, isNotNull);
    });

    test('wy: 网易云搜索响应解析', () {
      final json = _fixture('wy') as Map;
      final tracks =
          WySearch.parseItems((json['data']['resources'] as List));
      expect(tracks, isNotEmpty);
      _assertCommon(tracks.first, 'wy');
      expect((tracks.first.raw['songmid'] as String).isNotEmpty, isTrue);
      expect(tracks.first.artist, isNotEmpty);
      expect(tracks.first.coverUrl, isNotNull);
    });

    test('mg: 咪咕搜索响应解析', () {
      final json = _fixture('mg') as Map;
      final tracks =
          MgSearch.parseItems((json['songResultData']['resultList'] as List));
      expect(tracks, isNotEmpty);
      _assertCommon(tracks.first, 'mg');
      expect((tracks.first.raw['copyrightId'] as String).isNotEmpty, isTrue);
      expect((tracks.first.raw['songmid'] as String).isNotEmpty, isTrue);
    });
  });

  group('builtin cover url', () {
    test('kg：搜索 / 榜单 / 歌单字段都取得到，{size} 替换为 480', () {
      expect(
        kgCoverUrlOf({'Image': 'http://imge.kugou.com/stdmusic/{size}/a.jpg'}),
        'http://imge.kugou.com/stdmusic/480/a.jpg',
      );
      expect(
        kgCoverUrlOf({
          'album_sizable_cover':
              'http://imge.kugou.com/stdmusic/{size}/b.jpg',
        }),
        'http://imge.kugou.com/stdmusic/480/b.jpg',
      );
      expect(
        kgCoverUrlOf({
          'trans_param': {
            'union_cover': 'http://imge.kugou.com/stdmusic/{size}/c.jpg',
          },
        }),
        'http://imge.kugou.com/stdmusic/480/c.jpg',
      );
      expect(kgCoverUrlOf({'Image': ''}), isNull);
      expect(kgCoverUrlOf(null), isNull);
    });

    test('kw：相对路径 / 完整 URL 统一到 500 尺寸', () {
      expect(
        kwCoverUrlOf({'web_albumpic_short': '120/s3s94/93/211513640.jpg'}),
        'https://img1.kuwo.cn/star/albumcover/500/s3s94/93/211513640.jpg',
      );
      expect(
        kwCoverUrlOf({
          'albumpic': 'http://img2.kuwo.cn/star/albumcover/120/s4s17/56/1.jpg',
        }),
        'http://img2.kuwo.cn/star/albumcover/500/s4s17/56/1.jpg',
      );
      expect(
        kwCoverUrlOf({'web_albumpic_short': '3/8/2716789752.jpg'}),
        'https://img1.kuwo.cn/star/albumcover/500/3/8/2716789752.jpg',
        reason: '首段不是尺寸档时不能误删',
      );
      expect(
        kwCoverUrlOf({'pic300': '//img3.kuwo.cn/star/albumcover/300/a/b.jpg'}),
        'https://img3.kuwo.cn/star/albumcover/500/a/b.jpg',
      );
      expect(kwCoverUrlOf({'web_albumpic_short': ''}), isNull);
      expect(kwCoverUrlOf(null), isNull);
    });
  });
}
