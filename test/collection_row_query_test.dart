/// 合集行过滤 / 排序 helper 的单测：标题 / 歌手子串匹配（忽略大小写与空白）
/// 与三种排序口径。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/utils/collection_row_query.dart';

typedef Row = ({String title, String artist});

const List<Row> _rows = [
  (title: 'Song A', artist: 'Artist One'),
  (title: '夜曲', artist: '周杰伦'),
  (title: 'Another', artist: 'Some Artist'),
];

List<Row> filter(String query) => filterRowsByQuery(
      _rows,
      query: query,
      fields: (row) => row,
    );

PlaylistTrack track(
  String title, {
  String artist = '',
  int addedAt = 0,
}) =>
    PlaylistTrack(
      playlistId: 1,
      sourceKey: 'wy',
      songId: title,
      title: title,
      artist: artist,
      album: '',
      addedAt: addedAt,
    );

List<String> titlesOf(List<PlaylistTrack> tracks) =>
    [for (final item in tracks) item.title];

void main() {
  group('filterRowsByQuery', () {
    test('查询为空 / 全空白：原样返回同一列表（不过滤、不复制）', () {
      expect(identical(filter(''), _rows), isTrue);
      expect(identical(filter('   '), _rows), isTrue);
    });

    test('标题子串命中（忽略大小写）', () {
      expect(filter('song'), [_rows[0]]);
      expect(filter('SONG'), [_rows[0]]);
    });

    test('歌手子串命中，与标题同权', () {
      expect(filter('artist one'), [_rows[0]]);
      expect(filter('周杰伦'), [_rows[1]]);
      expect(filter('some artist'), [_rows[2]]);
    });

    test('查询首尾空白被裁剪', () {
      expect(filter('  夜曲  '), [_rows[1]]);
    });

    test('无匹配：返回空列表', () {
      expect(filter('不存在'), isEmpty);
    });
  });

  group('sortCollectionTracks', () {
    final tracks = [
      track('Song B', artist: 'Zoe', addedAt: 1),
      track('song a', artist: 'Amy', addedAt: 2),
      track('Song C', artist: 'Amy', addedAt: 3),
    ];

    test('默认口径：保持传入顺序，且不改动入参', () {
      final sorted = sortCollectionTracks(tracks, CollectionTrackSort.added);
      expect(titlesOf(sorted), ['Song B', 'song a', 'Song C']);
      expect(identical(sorted, tracks), isFalse, reason: '返回新列表');
      expect(titlesOf(tracks), ['Song B', 'song a', 'Song C']);
    });

    test('按标题升序（忽略大小写）', () {
      expect(
        titlesOf(sortCollectionTracks(tracks, CollectionTrackSort.title)),
        ['song a', 'Song B', 'Song C'],
      );
    });

    test('按歌手升序，同歌手按标题', () {
      expect(
        titlesOf(sortCollectionTracks(tracks, CollectionTrackSort.artist)),
        ['song a', 'Song C', 'Song B'],
      );
    });
  });
}
