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
        album: 'Album $id',
        durationMs: 180000,
        coverUrl: 'https://cover/$id.jpg',
        addedAt: 1,
      );

  PlayHistoryEntry history(String id) => PlayHistoryEntry(
        sourceKey: 'wy',
        songId: id,
        title: 'Song $id',
        artist: 'Artist $id',
        album: 'Album $id',
        durationMs: 180000,
        coverUrl: 'https://cover/$id.jpg',
        playedAt: 1,
      );

  CollectionLocalSong localSong(String id, {bool imported = false}) =>
      CollectionLocalSong.download(
        DownloadedTrack(
          originSourceKey: imported ? kLocalSourceKey : 'wy',
          originSongId: id,
          title: imported ? '导入 $id' : '下载 $id',
          artist: 'Artist $id',
          album: 'Album $id',
          durationMs: 180000,
          filePath: '/downloads/$id.mp3',
          imported: imported,
          downloadedAt: 1,
        ),
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

  group('行联合', () {
    test('曲目行：展示字段 / 稳定 key / 收藏键来自 PlaylistTrack', () {
      final row = TrackCollectionRow(track('1'));

      expect(row.key, 'wy:1');
      expect(row.title, 'Song 1');
      expect(row.artist, 'Artist 1');
      expect(row.album, 'Album 1');
      expect(row.durationMs, 180000);
      expect(row.artworkUrl, 'https://cover/1.jpg');
      expect(row.favoriteKey, (sourceKey: 'wy', songId: '1'));
      expect(row.toPlaylistTrack(addedAt: 2), same(row.track));
    });

    test('历史行：key 带历史前缀，曲目快照按历史项还原', () {
      final row = HistoryCollectionRow(history('1'));

      expect(row.key, 'h:wy:1');
      expect(row.playedAt, 1);
      expect(row.toPlaylistTrack(addedAt: 9).addedAt, 9);
      expect(row.toPlaylistTrack(addedAt: 9).songId, '1');
    });

    test('本地歌曲行：key 带本地前缀，缓存 / 导入来源可判定', () {
      final downloaded = LocalSongCollectionRow(localSong('1'));
      final imported = LocalSongCollectionRow(localSong('2', imported: true));

      expect(downloaded.key, 'l:wy:1');
      expect(downloaded.isCached, isFalse);
      expect(downloaded.isImported, isFalse);
      expect(imported.key, 'l:local:2');
      expect(imported.isImported, isTrue);
      expect(imported.favoriteKey,
          (sourceKey: kLocalSourceKey, songId: 'local:2'));
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

      final row = view.visibleRows.single as TrackCollectionRow;
      expect(row.track.songId, 'a');
      expect(row.key, 'wy:a');
      expect(view.visibleCount, 1);
      expect(view.tracks, tracks);
      expect(view.hasItems, isTrue);
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

      final row = view.visibleRows.single as HistoryCollectionRow;
      expect(row.entry.songId, '2');
      expect(row.key, 'h:wy:2');
      expect(view.visibleCount, 1);
      expect(view.hasItems, isTrue);
    });

    test('本地歌曲合集：可见本地行参与过滤与计数', () {
      final identity = identityFor(LibraryCollections.downloadsSentinel);
      final rows = [localSong('1')];

      final view = presenter().viewFor(
        identity: identity,
        tracks: const [],
        history: const [],
        localSongs: rows,
        query: '下载',
        sort: CollectionTrackSort.added,
      );

      final row = view.visibleRows.single as LocalSongCollectionRow;
      expect(row.song.title, '下载 1');
      expect(row.key, 'l:wy:1');
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
      expect(view.visibleRows, isEmpty);
      expect(view.visibleCount, 0);
      expect(view.collectionKey, LibraryCollections.favoritesOrderKey);
    });

    test('同一输入复用同一视图与可见行（不重新分配行对象）', () {
      final presenter = CollectionPresenter();
      final identity = identityFor(LibraryCollections.favoritesSentinel);
      final tracks = [track('b'), track('a')];

      final first = presenter.viewFor(
        identity: identity,
        tracks: tracks,
        history: const [],
        localSongs: const [],
        query: '',
        sort: CollectionTrackSort.added,
      );
      final second = presenter.viewFor(
        identity: identityFor(LibraryCollections.favoritesSentinel),
        tracks: tracks,
        history: const [],
        localSongs: const [],
        query: '',
        sort: CollectionTrackSort.added,
      );

      expect(identical(second, first), isTrue);
      expect(identical(second.visibleRows, first.visibleRows), isTrue);
    });

    test('历史写入（历史列表换引用）不失效收藏视图', () {
      final presenter = CollectionPresenter();
      final identity = identityFor(LibraryCollections.favoritesSentinel);
      final tracks = [track('b'), track('a')];

      final first = presenter.viewFor(
        identity: identity,
        tracks: tracks,
        history: [history('1')],
        localSongs: const [],
        query: '',
        sort: CollectionTrackSort.added,
      );
      // 后台播放写入历史：provider 替换历史列表引用，收藏曲目引用不变。
      final second = presenter.viewFor(
        identity: identity,
        tracks: tracks,
        history: [history('2'), history('1')],
        localSongs: const [],
        query: '',
        sort: CollectionTrackSort.added,
      );

      expect(identical(second, first), isTrue);
      expect(identical(second.visibleRows, first.visibleRows), isTrue);
    });

    test('查询 / 排序 / 曲目列表 / 身份变化都让缓存失效', () {
      final presenter = CollectionPresenter();
      final identity = identityFor(LibraryCollections.favoritesSentinel);
      final tracks = [track('b', title: 'Beta'), track('a', title: 'Alpha')];

      CollectionView view({
        CollectionIdentity? withIdentity,
        List<PlaylistTrack>? withTracks,
        String query = '',
        CollectionTrackSort sort = CollectionTrackSort.added,
      }) =>
          presenter.viewFor(
            identity: withIdentity ?? identity,
            tracks: withTracks ?? tracks,
            history: const [],
            localSongs: const [],
            query: query,
            sort: sort,
          );

      final base = view();

      final queried = view(query: 'alpha');
      expect(identical(queried, base), isFalse);
      expect(queried.visibleRows.single.title, 'Alpha');

      final sorted = view(sort: CollectionTrackSort.title);
      expect(identical(sorted, base), isFalse);
      expect(sorted.visibleRows.first.title, 'Alpha');

      final replacedTracks = [...tracks, track('c', title: 'Gamma')];
      final grown = view(withTracks: replacedTracks);
      expect(identical(grown, base), isFalse);
      expect(grown.visibleCount, 3);
      expect(identical(grown.tracks, replacedTracks), isTrue);

      final renamed = view(
        withIdentity: CollectionIdentity(
          selectedId: identity.selectedId,
          kind: identity.kind,
          playlistId: identity.playlistId,
          displayName: 'Favorites',
        ),
      );
      expect(identical(renamed, base), isFalse);
      expect(renamed.displayName, 'Favorites');
    });

    test('历史 / 本地歌曲按各自源列表失效，互不串缓存', () {
      final presenter = CollectionPresenter();
      final historyIdentity = identityFor(LibraryCollections.historySentinel);
      final historyRows = [history('1')];

      final firstHistory = presenter.viewFor(
        identity: historyIdentity,
        tracks: const [],
        history: historyRows,
        localSongs: const [],
        query: '',
        sort: CollectionTrackSort.added,
      );
      final secondHistory = presenter.viewFor(
        identity: historyIdentity,
        tracks: const [],
        history: [...historyRows, history('2')],
        localSongs: const [],
        query: '',
        sort: CollectionTrackSort.added,
      );
      expect(identical(secondHistory, firstHistory), isFalse);
      expect(secondHistory.visibleCount, 2);

      final localIdentity = identityFor(LibraryCollections.downloadsSentinel);
      final localRows = [localSong('1')];
      final firstLocal = presenter.viewFor(
        identity: localIdentity,
        tracks: const [],
        history: const [],
        localSongs: localRows,
        query: '',
        sort: CollectionTrackSort.added,
      );
      final secondLocal = presenter.viewFor(
        identity: localIdentity,
        tracks: const [],
        history: const [],
        localSongs: [...localRows, localSong('2')],
        query: '',
        sort: CollectionTrackSort.added,
      );
      expect(identical(secondLocal, firstLocal), isFalse);
      expect(secondLocal.visibleCount, 2);
    });
  });

  group('行动作构成', () {
    CollectionRowActionSpec add() =>
        const CollectionRowActionSpec(CollectionRowActionKind.addToPlaylist);
    CollectionRowActionSpec swap() =>
        const CollectionRowActionSpec(CollectionRowActionKind.swapSource);
    CollectionRowActionSpec removePlaylist() => const CollectionRowActionSpec(
          CollectionRowActionKind.removeFromPlaylist,
          destructive: true,
        );
    CollectionRowActionSpec removeFavorite() => const CollectionRowActionSpec(
          CollectionRowActionKind.removeFromFavorite,
          destructive: true,
        );
    CollectionRowActionSpec toggleFavorite() =>
        const CollectionRowActionSpec(CollectionRowActionKind.toggleFavorite);
    CollectionRowActionSpec deleteHistory() => const CollectionRowActionSpec(
          CollectionRowActionKind.deleteHistoryEntry,
          destructive: true,
        );
    CollectionRowActionSpec deleteLocal() => const CollectionRowActionSpec(
          CollectionRowActionKind.deleteLocalSong,
          destructive: true,
        );

    test('曲目行：收藏 / 自建列表 / 本地音源的动作集合', () {
      final presenter = CollectionPresenter();
      final trackRow = TrackCollectionRow(track('1'));

      expect(
        presenter.rowActionsFor(
          trackRow,
          identityFor(LibraryCollections.favoritesSentinel),
        ),
        [add(), swap(), removeFavorite()],
      );
      expect(
        presenter.rowActionsFor(trackRow, identityFor(2)),
        [add(), swap(), removePlaylist()],
      );
      expect(
        presenter.rowActionsFor(
          TrackCollectionRow(
            PlaylistTrack(
              playlistId: 1,
              sourceKey: kLocalSourceKey,
              songId: 'x',
              title: '本地',
              addedAt: 1,
            ),
          ),
          identityFor(LibraryCollections.favoritesSentinel),
        ),
        [add(), removeFavorite()],
        reason: '本地音源不提供换源',
      );
      // 自建列表 id 尚未落定：只有加入列表（与旧实现一致）。
      expect(
        presenter.rowActionsFor(
          trackRow,
          const CollectionIdentity(
            selectedId: 99,
            kind: CollectionKind.custom,
            playlistId: null,
            displayName: '新列表',
          ),
        ),
        [add()],
      );
    });

    test('历史行：远端记录有换源，本地记录没有', () {
      final presenter = CollectionPresenter();
      final identity = identityFor(LibraryCollections.historySentinel);

      expect(
        presenter.rowActionsFor(HistoryCollectionRow(history('1')), identity),
        [add(), swap(), deleteHistory()],
      );
      expect(
        presenter.rowActionsFor(
          HistoryCollectionRow(
            PlayHistoryEntry(
              sourceKey: kLocalSourceKey,
              songId: 'x',
              title: '本地',
              playedAt: 1,
            ),
          ),
          identity,
        ),
        [add(), deleteHistory()],
      );
    });

    test('本地歌曲行：加入列表 + 收藏开关 + 删除', () {
      final row = LocalSongCollectionRow(localSong('1'));

      expect(
        presenter().rowActionsFor(
          row,
          identityFor(LibraryCollections.downloadsSentinel),
        ),
        [add(), toggleFavorite(), deleteLocal()],
      );
    });
  });
}
