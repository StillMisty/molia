import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/providers/collection_presenter.dart';
import 'package:molia/providers/library_collections.dart';
import 'package:molia/providers/local_songs_collection.dart';
import 'package:molia/utils/collection_row_query.dart';

void main() {
  final playlists = <PlaylistInfo>[
    const PlaylistInfo(
      id: 1,
      name: '我的收藏',
      createdAt: 1,
      trackCount: 3,
      isFavorites: true,
    ),
    const PlaylistInfo(id: 2, name: 'Road', createdAt: 2, trackCount: 1),
  ];

  CollectionPresenter presenter() => CollectionPresenter();

  CollectionIdentity identityFor(int selected) => presenter().identityFor(
        selectedId: selected,
        playlists: playlists,
        favoritesId: 1,
        favoritesName: '我的收藏',
        historyName: '播放历史',
        localSongsName: '本地歌曲',
      );

  PlaylistTrack track(String id, {String title = '', String artist = ''}) =>
      PlaylistTrack(
        playlistId: 1,
        sourceKey: 'wy',
        songId: id,
        title: title.isEmpty ? 'Song $id' : title,
        artist: artist.isEmpty ? 'Artist $id' : artist,
        addedAt: 1,
      );

  PlayHistoryEntry history(String id) => PlayHistoryEntry(
        sourceKey: 'wy',
        songId: id,
        title: 'Song $id',
        artist: 'Artist $id',
        playedAt: 1,
      );

  group('合集身份', () {
    test('收藏：落库 id = 收藏列表 id，键 / 列规范为收藏档', () {
      final identity = identityFor(LibraryCollections.favoritesSentinel);

      expect(identity.kind, CollectionKind.favorites);
      expect(identity.playlistId, 1);
      expect(identity.displayName, '我的收藏');
      expect(identity.collectionKey, LibraryCollections.favoritesOrderKey);
      expect(identity.columnLayout, CollectionColumnLayout.standard);
    });

    test('播放历史：无落库 id，独有历史列规范', () {
      final identity = identityFor(LibraryCollections.historySentinel);

      expect(identity.kind, CollectionKind.history);
      expect(identity.playlistId, isNull);
      expect(identity.displayName, '播放历史');
      expect(identity.collectionKey, LibraryCollections.historyOrderKey);
      expect(identity.columnLayout, CollectionColumnLayout.history);
    });

    test('本地歌曲：无落库 id，键走下载合集键', () {
      final identity = identityFor(LibraryCollections.downloadsSentinel);

      expect(identity.kind, CollectionKind.localSongs);
      expect(identity.playlistId, isNull);
      expect(identity.displayName, '本地歌曲');
      expect(identity.collectionKey, LibraryCollections.downloadsOrderKey);
    });

    test('自建列表：落库 id = 选集 id，键按 id 生成', () {
      final identity = identityFor(2);

      expect(identity.kind, CollectionKind.custom);
      expect(identity.playlistId, 2);
      expect(identity.displayName, 'Road');
      expect(identity.collectionKey, LibraryCollections.playlistOrderKey(2));
    });

    test('未手动选择时沿用 LibraryCollections 的默认回退', () {
      final identity = identityFor(LibraryCollections.unset);

      // 收藏有 3 首 → 默认落在收藏，而不是第一个列表。
      expect(identity.kind, CollectionKind.favorites);
      expect(identity.selectedId, LibraryCollections.favoritesSentinel);
    });
  });

  group('视图投影', () {
    test('曲目合集：排序 + 搜索只作用于可见行，全量用于空态判定', () {
      final presenter = CollectionPresenter();
      final identity = identityFor(LibraryCollections.favoritesSentinel);
      final tracks = [track('b', title: 'Beta'), track('a', title: 'Alpha')];

      final view = presenter.viewFor(
        identity: identity,
        tracks: tracks,
        history: const [],
        localSongs: const [],
        query: 'alpha',
        sort: CollectionTrackSort.title,
      );

      expect(view.visible.map((row) => row.songId), ['a']);
      expect(view.visibleCount, 1);
      expect(view.tracks, tracks);
      expect(view.hasItems, isTrue);
      expect(view.visibleHistory, isEmpty);
      expect(view.visibleLocalSongs, isEmpty);
    });

    test('历史合集：可见历史行按标题 / 歌手过滤，曲目列表为空', () {
      final identity = identityFor(LibraryCollections.historySentinel);
      final rows = [history('1'), history('2')];

      final view = presenter().viewFor(
        identity: identity,
        tracks: const [],
        history: rows,
        localSongs: const [],
        query: 'Song 2',
        sort: CollectionTrackSort.added,
      );

      expect(view.visible, isEmpty);
      expect(view.visibleHistory.map((row) => row.songId), ['2']);
      expect(view.visibleCount, 1);
      expect(view.hasItems, isTrue);
    });

    test('本地歌曲合集：可见本地行参与过滤与计数', () {
      final identity = identityFor(LibraryCollections.downloadsSentinel);
      final rows = [
        CollectionLocalSong.download(
          const DownloadedTrack(
            originSourceKey: 'wy',
            originSongId: '1',
            title: '下载的歌',
            artist: '歌手',
            filePath: '/downloads/1.mp3',
            downloadedAt: 1,
          ),
        ),
      ];

      final view = presenter().viewFor(
        identity: identity,
        tracks: const [],
        history: const [],
        localSongs: rows,
        query: '下载',
        sort: CollectionTrackSort.added,
      );

      expect(view.visible, isEmpty);
      expect(view.visibleHistory, isEmpty);
      expect(view.visibleLocalSongs, hasLength(1));
      expect(view.visibleCount, 1);
      expect(view.hasItems, isTrue);
    });

    test('空合集：hasItems=false，可见行数为 0', () {
      final identity = identityFor(LibraryCollections.favoritesSentinel);

      final view = presenter().viewFor(
        identity: identity,
        tracks: const [],
        history: const [],
        localSongs: const [],
        query: '',
        sort: CollectionTrackSort.added,
      );

      expect(view.hasItems, isFalse);
      expect(view.visibleCount, 0);
      expect(view.collectionKey, LibraryCollections.favoritesOrderKey);
    });
  });
}
