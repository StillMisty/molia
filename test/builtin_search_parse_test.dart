import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/kg_search.dart';
import 'package:molia/sources/builtin/kw_search.dart';
import 'package:molia/sources/builtin/mg_search.dart';
import 'package:molia/sources/builtin/tx_search.dart';
import 'package:molia/sources/builtin/wy_search.dart';
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
    });

    test('kg: 酷狗搜索响应解析', () {
      final json = _fixture('kg') as Map;
      final tracks = KgSearch.parseItems(json['data']['lists'] as List);
      expect(tracks, isNotEmpty);
      _assertCommon(tracks.first, 'kg');
      expect((tracks.first.raw['hash'] as String).isNotEmpty, isTrue);
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
}
