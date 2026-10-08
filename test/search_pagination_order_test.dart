import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/sources/builtin/kg_search.dart';
import 'package:molia/sources/builtin/kw_search.dart';
import 'package:molia/sources/builtin/mg_search.dart';
import 'package:molia/sources/builtin/tx_search.dart';
import 'package:molia/sources/builtin/wy_search.dart';
import 'package:molia/sources/source_manager.dart';
import 'package:molia/sources/lx/lx_search_parse.dart';
import 'package:molia/sources/source_search_result.dart';
import 'package:molia/sources/source_track.dart';

/// 使用真实平台响应的快照（test/fixtures/*.json）验证 total 提取。
dynamic _fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync());

SourceTrack _track(String name) => SourceTrack(
      sourceKey: 'fake',
      origin: 'lx',
      title: name,
      artist: 'tester',
      album: '',
      raw: const {'id': 'x'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SourceSearchResult.fromPage', () {
    test('有 total 时按 page*limit < total 判断 hasMore', () {
      final first = SourceSearchResult.fromPage(
        tracks: [_track('a')],
        page: 1,
        limit: 30,
        total: 100,
      );
      expect(first.total, 100);
      expect(first.hasMore, isTrue);

      final last = SourceSearchResult.fromPage(
        tracks: [_track('a')],
        page: 4,
        limit: 30,
        total: 100,
      );
      expect(last.hasMore, isFalse);

      final exact = SourceSearchResult.fromPage(
        tracks: const [],
        page: 2,
        limit: 50,
        total: 100,
      );
      expect(exact.hasMore, isFalse);
    });

    test('isEnd 优先于 total', () {
      final ended = SourceSearchResult.fromPage(
        tracks: [_track('a')],
        page: 1,
        limit: 30,
        total: 100,
        isEnd: true,
      );
      expect(ended.hasMore, isFalse);

      final more = SourceSearchResult.fromPage(
        tracks: const [],
        page: 5,
        limit: 30,
        total: 10,
        isEnd: false,
      );
      expect(more.hasMore, isTrue);
    });

    test('无 total/isEnd 时用 tracks.length >= limit 近似', () {
      final full = SourceSearchResult.fromPage(
        tracks: List.generate(30, (i) => _track('t$i')),
        page: 1,
        limit: 30,
      );
      expect(full.hasMore, isTrue);

      final partial = SourceSearchResult.fromPage(
        tracks: List.generate(3, (i) => _track('t$i')),
        page: 1,
        limit: 30,
      );
      expect(partial.hasMore, isFalse);
    });
  });

  group('parseSourceCount / parseSourceBool', () {
    test('兼容 int / num / String', () {
      expect(parseSourceCount(42), 42);
      expect(parseSourceCount(42.0), 42);
      expect(parseSourceCount(' 123 '), 123);
      expect(parseSourceCount('abc'), isNull);
      expect(parseSourceCount(null), isNull);
    });

    test('兼容 bool / 0 / 1', () {
      expect(parseSourceBool(true), isTrue);
      expect(parseSourceBool(false), isFalse);
      expect(parseSourceBool(1), isTrue);
      expect(parseSourceBool(0), isFalse);
      expect(parseSourceBool('true'), isTrue);
      expect(parseSourceBool(null), isNull);
    });
  });

  group('内置平台 total 提取（真实响应夹具）', () {
    test('kw: TOTAL', () {
      expect(KwSearch.totalOf(_fixture('kw')), 3292);
    });

    test('kg: data.total', () {
      expect(KgSearch.totalOf(_fixture('kg')), 480);
    });

    test('tx: data.meta.sum', () {
      final json = _fixture('tx') as Map;
      final data = json['music.search.SearchCgiService']['data'];
      expect(TxSearch.totalOf(data), 999);
    });

    test('wy: data.totalCount', () {
      final json = _fixture('wy') as Map;
      expect(WySearch.totalOf(json['data']), 273);
    });

    test('mg: songResultData.totalCount', () {
      expect(MgSearch.totalOf(_fixture('mg')), 100);
    });
  });

  group('LX 脚本扩展搜索分页解析', () {
    final manager = SourceManager();
    tearDownAll(manager.dispose);

    test('列表 + isEnd', () {
      final result = parseLxSearchResult(
        'fake',
        {
          'list': [
            {'name': 'A', 'singer': 'B'},
            {'name': 'C', 'singer': 'D'},
          ],
          'isEnd': true,
        },
        page: 1,
        limit: 30,
      );
      expect(result.tracks, hasLength(2));
      expect(result.hasMore, isFalse);
      expect(result.total, isNull);
    });

    test('列表 + total', () {
      final items = List.generate(30, (i) => {'name': 'T$i', 'singer': 'S'});
      final result = parseLxSearchResult(
        'fake',
        {'list': items, 'total': 100},
        page: 1,
        limit: 30,
      );
      expect(result.tracks, hasLength(30));
      expect(result.total, 100);
      expect(result.hasMore, isTrue);
    });

    test('裸数组按长度近似 hasMore', () {
      final full = parseLxSearchResult(
        'fake',
        List.generate(
            2, (i) => {'name': 'T$i', 'singer': 'S', 'source': 'fake'}),
        page: 1,
        limit: 2,
      );
      expect(full.hasMore, isTrue);

      final partial = parseLxSearchResult(
        'fake',
        [
          {'name': 'only', 'singer': 'S'}
        ],
        page: 1,
        limit: 2,
      );
      expect(partial.hasMore, isFalse);
      expect(partial.tracks.single.raw['source'], 'fake');
    });

    test('嵌套 data.list + hasMore=false', () {
      final result = parseLxSearchResult(
        'fake',
        {
          'data': {
            'list': [
              {'name': 'A', 'artist': 'B'}
            ],
            'total': 50,
          },
          'hasMore': false,
        },
        page: 1,
        limit: 30,
      );
      expect(result.tracks, hasLength(1));
      expect(result.total, 50);
      expect(result.hasMore, isFalse);
    });

    test('空响应', () {
      final result = parseLxSearchResult('fake', null);
      expect(result.tracks, isEmpty);
      expect(result.hasMore, isFalse);
    });
  });

  group('音源排序', () {
    test('applySourceOrder: 顺序表优先，未列出的保持原相对顺序追加', () {
      expect(
        SourceManager.applySourceOrder(['a', 'b', 'c'], ['c', 'a']),
        ['c', 'a', 'b'],
      );
      expect(
        SourceManager.applySourceOrder(['a', 'b', 'c'], []),
        ['a', 'b', 'c'],
      );
      expect(
        SourceManager.applySourceOrder(['a', 'b'], ['x', 'b', 'b']),
        ['b', 'a'],
      );
      expect(SourceManager.applySourceOrder([], ['a']), isEmpty);
    });

    test('setSourceOrder 去重并持久化，resetSourceOrder 清空', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = SourceManager();
      expect(manager.sourceOrder, isEmpty);

      await manager.setSourceOrder(['tx', 'kw', 'tx', '']);
      expect(manager.sourceOrder, ['tx', 'kw']);

      await manager.resetChannelOrder();
      expect(manager.sourceOrder, isEmpty);
      manager.dispose();
    });

    test('init 时恢复持久化的顺序', () async {
      SharedPreferences.setMockInitialValues({
        'lx_source_order': ['wy', 'kw'],
      });
      final manager = SourceManager();
      await manager.init();
      expect(manager.sourceOrder, ['wy', 'kw']);
      manager.dispose();
    });
  });
}
