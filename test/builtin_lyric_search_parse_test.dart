import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/sources/builtin/kg_lyric_search.dart';
import 'package:molia/sources/builtin/kw_lyric_search.dart';
import 'package:molia/sources/builtin/lyric_search.dart';
import 'package:molia/sources/builtin/mg_lyric_search.dart';
import 'package:molia/sources/builtin/tx_lyric_search.dart';
import 'package:molia/sources/builtin/wy_lyric_search.dart';
import 'package:molia/sources/builtin/wy_music_detail.dart';
import 'package:molia/sources/raw_track.dart';

/// 五平台「按歌词搜歌」解析：使用真实平台响应快照
/// （test/fixtures/lyric_search/*，由 tool/gen_lyric_search_fixtures.mjs 抓取）
/// 验证字段归一化（曲目 / 命中片段 / 分页）。
dynamic _fixture(String name) =>
    jsonDecode(File('test/fixtures/lyric_search/$name').readAsStringSync());

String _fixtureText(String name) =>
    File('test/fixtures/lyric_search/$name').readAsStringSync();

void main() {
  group('kw 酷我（stype=lyric，模糊匹配）', () {
    test('歌词搜索：曲目同构 + `lrc` 片段 + TOTAL 分页', () {
      final page = KwLyricSearch.parseSearch(
        _fixtureText('kw.txt'),
        page: 1,
        limit: 3,
      );
      expect(page.hits, isNotEmpty);
      final first = page.hits.first;
      expect(first.snippet, contains('雨下整夜'));
      expect(first.track.title, isNotEmpty);
      expect(first.track.raw['songmid'], isNotEmpty);
      expect(first.track.qualities, isNotEmpty);
      expect(page.total, greaterThan(0));
      expect(page.hasMore, isTrue);
    });
  });

  group('kg 酷狗', () {
    test('歌词搜索：MixSongID / 音质（含 Res 无损 24bit）/ Lyric 片段 / 封面', () {
      final page = KgLyricSearch.parseSearch(
        _fixture('kg.json'),
        page: 1,
        limit: 3,
      );
      expect(page.hits, isNotEmpty);
      final first = page.hits.first;
      expect(first.snippet, contains('雨下整夜'));
      expect(first.track.title, isNotEmpty);
      expect(first.track.raw['songmid'], isNotEmpty);
      expect(first.track.raw['hash'], isNotEmpty);
      expect(first.track.coverUrl, isNot(contains('{size}')));
      expect(
        first.track.qualities.map((quality) => quality.type),
        containsAll(<String>['128k', 'flac24bit']),
      );
      // 歌手引用（歌手页入口）。
      expect(artistsFromRaw(first.track.raw).single.id, '7336700');
      expect(first.track.album, isEmpty, reason: '歌词搜索响应不含专辑名');
      expect(page.total, 1000);
      expect(page.hasMore, isTrue);
    });
  });

  group('tx QQ 音乐（search_type=7）', () {
    test('歌词搜索：条目与单曲搜索同构 + `lyric` 片段 + meta.sum', () {
      final page = TxLyricSearch.parseSearch(
        _fixture('tx.json'),
        page: 1,
        limit: 3,
      );
      expect(page.hits, isNotEmpty);
      final first = page.hits.first;
      expect(first.track.title, '七里香');
      expect(first.snippet, contains('雨下整夜'));
      expect(first.track.raw['strMediaMid'], isNotEmpty);
      expect(first.track.qualities, isNotEmpty);
      expect(page.total, 3);
      expect(page.hasMore, isFalse, reason: '3 条结果一页取满');
    });

    test('响应结构不符：失败', () {
      expect(
        () => TxLyricSearch.parseSearch(const {'code': 0}, page: 1, limit: 3),
        throwsA(isA<SourceFailure>()),
      );
    });
  });

  group('wy 网易云（type=1006）', () {
    test('歌词搜索：ids → 规范 raw + 高亮歌词片段', () {
      final searchBody = _fixture('wy_search.json');
      final detail = _fixture('wy_song_detail.json');
      final tracks = WyMusicDetail.filterList(
        songs: (detail['songs'] as List?) ?? const [],
        privileges: (detail['privileges'] as List?) ?? const [],
      );
      final page = WyLyricSearch.buildPage(
        body: searchBody,
        tracks: tracks,
        page: 1,
        limit: 3,
      );
      expect(page.hits, hasLength(3));
      final first = page.hits.first;
      expect(first.track.title, isNotEmpty);
      expect(first.track.raw['songmid'], isNotNull);
      expect(first.track.qualities, isNotEmpty);
      // 片段取高亮行起 3 行并去标签。
      expect(first.snippet, isNotNull);
      expect(first.snippet, isNot(contains('<b>')));
      expect(first.snippet, contains('雨下整夜'));
      expect(page.total, 60);
      expect(page.hasMore, isTrue);
    });

    test('片段：无高亮行退回首行；空数组为 null', () {
      expect(
        WyLyricSearch.lyricSnippetOf(['第一行', '第二行']),
        '第一行 第二行',
      );
      expect(WyLyricSearch.lyricSnippetOf(const []), isNull);
      expect(WyLyricSearch.lyricSnippetOf(const ['', '  ']), isNull);
    });
  });

  group('mg 咪咕（lyricSong=1）', () {
    test('歌词搜索：条目同构 + multiLyricStr 片段 + totalCount', () {
      final page = MgLyricSearch.parseSearch(
        _fixture('mg.json'),
        page: 1,
        limit: 3,
      );
      expect(page.hits, isNotEmpty);
      final first = page.hits.first;
      expect(first.snippet, contains('雨下整夜'));
      expect(first.track.title, isNotEmpty);
      expect(first.track.raw['copyrightId'], isNotEmpty);
      expect(artistsFromRaw(first.track.raw).single.id, '337');
      expect(first.track.qualities, isNotEmpty);
      expect(page.total, 80);
      expect(page.hasMore, isTrue);
    });
  });

  group('BuiltinLyricSearch 调度', () {
    test('未知音源：抛 unsupported', () {
      expect(
        () => BuiltinLyricSearch.searchWithMeta('unknown', '雨下整夜'),
        throwsA(
          isA<SourceFailure>()
              .having((f) => f.kind, 'kind', FailureKind.unsupported),
        ),
      );
    });

    test('支持矩阵与内置平台一致', () {
      expect(
        BuiltinLyricSearch.supportedKeys,
        containsAll(<String>['kw', 'kg', 'tx', 'wy', 'mg']),
      );
      expect(BuiltinLyricSearch.isSupported('script-source'), isFalse);
    });
  });
}
