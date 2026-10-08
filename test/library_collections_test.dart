import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/library_repository.dart'
    show kFavoritesPlaylistName;
import 'package:molia/domain/models/library.dart';
import 'package:molia/providers/library_collections.dart';
import 'package:shared_preferences/shared_preferences.dart';

PlaylistInfo _playlist(int id, {String name = '列表', int trackCount = 0}) =>
    PlaylistInfo(id: id, name: name, createdAt: 0, trackCount: trackCount);

/// 合集策略模块（默认选择 / 顺序 / 持久化）的单一测试面。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('favoritesPlaylistId', () {
    test('按名称查找默认收藏列表', () {
      final playlists = [
        _playlist(1, name: '通勤'),
        _playlist(2, name: kFavoritesPlaylistName),
      ];
      expect(LibraryCollections.favoritesPlaylistId(playlists), 2);
      expect(LibraryCollections.favoritesPlaylistId([_playlist(1)]), isNull);
    });
  });

  group('resolveSelection', () {
    final favorites = _playlist(1, name: kFavoritesPlaylistName, trackCount: 0);
    final nonEmpty = _playlist(2, trackCount: 3);
    final empty = _playlist(3);

    test('手动选择有效列表时沿用；已删除时回退', () {
      expect(
        LibraryCollections.resolveSelection(
          selected: 2,
          playlists: [favorites, nonEmpty],
          favoritesId: 1,
        ),
        2,
      );
      expect(
        LibraryCollections.resolveSelection(
          selected: 99,
          playlists: [favorites, nonEmpty],
          favoritesId: 1,
        ),
        2,
      );
    });

    test('显式收藏 / 历史哨兵始终有效', () {
      expect(
        LibraryCollections.resolveSelection(
          selected: LibraryCollections.favoritesSentinel,
          playlists: [favorites, nonEmpty],
          favoritesId: 1,
        ),
        LibraryCollections.favoritesSentinel,
      );
      expect(
        LibraryCollections.resolveSelection(
          selected: LibraryCollections.historySentinel,
          playlists: [favorites, nonEmpty],
          favoritesId: 1,
        ),
        LibraryCollections.historySentinel,
      );
    });

    test('未选择：优先有曲目的收藏，其次第一个非空列表，最后收藏', () {
      expect(
        LibraryCollections.resolveSelection(
          selected: LibraryCollections.unset,
          playlists: [
            _playlist(1, name: kFavoritesPlaylistName, trackCount: 5),
            nonEmpty,
          ],
          favoritesId: 1,
        ),
        LibraryCollections.favoritesSentinel,
      );
      expect(
        LibraryCollections.resolveSelection(
          selected: LibraryCollections.unset,
          playlists: [favorites, nonEmpty],
          favoritesId: 1,
        ),
        2,
      );
      expect(
        LibraryCollections.resolveSelection(
          selected: LibraryCollections.unset,
          playlists: [favorites, empty],
          favoritesId: 1,
        ),
        LibraryCollections.favoritesSentinel,
      );
      expect(
        LibraryCollections.resolveSelection(
          selected: LibraryCollections.unset,
          playlists: const [],
          favoritesId: null,
        ),
        LibraryCollections.favoritesSentinel,
      );
    });

    test('历史不参与默认回退（未选择时不会落到历史）', () {
      final selected = LibraryCollections.resolveSelection(
        selected: LibraryCollections.unset,
        playlists: const [],
        favoritesId: null,
      );
      expect(selected, isNot(LibraryCollections.historySentinel));
    });
  });

  group('applyOrder', () {
    test('持久化顺序优先，新键按自然顺序追加，未知键忽略', () {
      expect(
        LibraryCollections.applyOrder(
          ['favorites', 'history', 'playlist:3', 'playlist:4'],
          ['playlist:4', 'favorites', 'playlist:99'],
        ),
        ['playlist:4', 'favorites', 'history', 'playlist:3'],
      );
    });

    test('重复键只出现一次', () {
      expect(
        LibraryCollections.applyOrder(
          ['favorites', 'history'],
          ['history', 'history'],
        ),
        ['history', 'favorites'],
      );
    });
  });

  group('持久化', () {
    test('saveOrder / loadOrder 往返', () async {
      final collections = LibraryCollections();
      await collections.saveOrder(['history', 'favorites', 'playlist:7']);
      expect(
        await collections.loadOrder(),
        ['history', 'favorites', 'playlist:7'],
      );
    });

    test('未保存时返回空列表', () async {
      expect(await LibraryCollections().loadOrder(), isEmpty);
    });
  });
}
