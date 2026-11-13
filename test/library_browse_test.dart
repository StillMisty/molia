import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/library_browse.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'package:molia/domain/models/smart_lists.dart';
import 'package:molia/providers/collection_presenter.dart';
import 'package:molia/providers/library_collections.dart';
import 'package:molia/utils/smart_list_rows.dart';

/// 专辑 / 歌手聚合、重复版本与智能列表（纯函数）。
void main() {
  PlaylistTrack track(
    String source,
    String id, {
    String title = '标题',
    String artist = '歌手',
    String album = '专辑',
    String? cover,
    int? duration = 200000,
    int addedAt = 0,
  }) => PlaylistTrack(
    playlistId: 0,
    sourceKey: source,
    songId: id,
    title: title,
    artist: artist,
    album: album,
    coverUrl: cover,
    durationMs: duration,
    addedAt: addedAt,
  );

  DownloadedTrack download(
    String id, {
    bool imported = false,
    String? localKey,
    String title = '本地',
    String artist = '歌手',
    String album = '专辑',
    int? cover,
    int? duration = 200000,
    int downloadedAt = 1,
    int? missingAt,
    String? filePath = '/music/a.mp3',
  }) => DownloadedTrack(
    originSourceKey: imported ? kLocalSourceKey : 'wy',
    originSongId: imported ? (localKey ?? id) : id,
    title: title,
    artist: artist,
    album: album,
    durationMs: duration,
    filePath: filePath,
    sizeBytes: 10,
    imported: imported,
    localKey: imported ? (localKey ?? id) : null,
    downloadedAt: downloadedAt,
    missingAt: missingAt,
  );

  group('Browse index', () {
    test('收藏 ∪ 列表 ∪ 下载去重；代表优先级与空字段补全', () {
      final source = BrowseSource(
        favorites: [track('wy', '1', title: '收藏标题', artist: '', cover: null)],
        playlists: [
          BrowsePlaylist(
            id: 2,
            tracks: [
              track('wy', '1', title: '列表标题', artist: '列表歌手', cover: 'a'),
              track('wy', '2', title: '只有列表', album: '', duration: 100000),
            ],
          ),
          BrowsePlaylist(
            id: 3,
            tracks: [track('wy', '2', title: '重复列表', album: '补全专辑')],
          ),
        ],
      );
      final index = buildBrowseIndex(source);
      expect(index.tracks.map((track) => track.key), ['wy:1', 'wy:2']);
      final first = index.tracks.first;
      expect(first.title, '收藏标题', reason: '收藏优先');
      expect(first.artist, '列表歌手', reason: '后面的候选补空字段');
      expect(first.coverUrl, 'a', reason: '后面的候选补封面');
      final second = index.tracks[1];
      expect(second.title, '只有列表');
      expect(second.album, '补全专辑');
      // 聚合视图不修改源列表：列表自身仍保留重复与顺序。
      expect(source.playlists[0].tracks, hasLength(2));
    });

    test('缺失 / 无音频记录不进入聚合；历史不在输入里', () {
      final index = buildBrowseIndex(
        BrowseSource(
          downloads: [
            download('1', missingAt: 99),
            download('2', filePath: null),
            download('3', imported: true, localKey: 'file:3'),
          ],
        ),
      );
      expect(index.tracks, hasLength(1));
      expect(index.tracks.single.songId, 'file:3');
    });

    test('专辑键：大小写 / 空白归一，未知专辑按主歌手分桶', () {
      final index = buildBrowseIndex(
        BrowseSource(
          favorites: [
            track('wy', '1', album: ' Album  A ', artist: 'A, B'),
            track('wy', '2', album: 'album a', artist: 'A, B'),
            track('wy', '3', album: '', artist: 'C'),
            track('wy', '4', album: '', artist: 'D'),
            track('wy', '5', album: '', artist: ''),
            track('wy', '6', album: '', artist: ''),
          ],
        ),
      );
      expect(index.albums, hasLength(4));
      expect(index.albums.first.album, 'Album  A');
      expect(index.albums.first.tracks, hasLength(2));
      final unknownArtists = index.albums
          .where((group) => group.isUnknownAlbum)
          .map((group) => group.primaryArtist)
          .toList();
      expect(unknownArtists, containsAll(['C', 'D', '']));
      // 双未知合成一个桶。
      expect(
        index.albums
            .where(
              (group) => group.isUnknownAlbum && group.primaryArtist.isEmpty,
            )
            .single
            .tracks,
        hasLength(2),
      );
    });

    test('歌手：多歌手进入每组；AC/DC 不被拆开；未知歌手单桶', () {
      final index = buildBrowseIndex(
        BrowseSource(
          favorites: [
            track('wy', '1', artist: 'AC/DC'),
            track('wy', '2', artist: 'Earth, Wind & Fire'),
            track('wy', '3', artist: ''),
          ],
        ),
      );
      final names = index.artists.map((group) => group.artist).toList();
      expect(names, contains('AC/DC'));
      expect(names, contains('Earth'));
      expect(names, contains('Wind & Fire'));
      expect(names.last, '');
      expect(
        index.artists.firstWhere((group) => group.artist == 'Earth').tracks,
        hasLength(1),
      );
    });
  });

  group('Duplicate versions', () {
    BrowseTrack browse(
      String id, {
      String title = '歌名',
      String artist = '歌手',
      int? duration = 200000,
    }) => BrowseTrack(
      sourceKey: 'wy',
      songId: id,
      title: title,
      artist: artist,
      durationMs: duration,
    );

    test('标题 + 主歌手 + 时长 ≤3s 合并；>3s / 缺时长不合并', () {
      final groups = groupDuplicates([
        browse('1', duration: 200000),
        browse('2', title: ' 歌名 ', artist: '歌手, 另一位', duration: 202900),
        browse('3', duration: 204000),
        browse('4', title: '歌名 (Live)', duration: 200000),
        browse('5', duration: 200000),
        browse('6', duration: null),
      ]);
      expect(groups.first.versions.map((track) => track.songId), [
        '1',
        '2',
        '5',
      ]);
      expect(duplicateVersionCounts(groups)['wy:1'], 3);
      expect(
        groups.any(
          (group) => group.versions.any((track) => track.songId == '3'),
        ),
        isTrue,
      );
      expect(
        groups
            .firstWhere(
              (group) => group.versions.any((track) => track.songId == '1'),
            )
            .versions
            .any((track) => track.songId == '4'),
        isFalse,
        reason: 'live 版标题不同，不合并',
      );
      // 缺时长的行自成一簇，不与有时间的合并。
      expect(
        groups
            .firstWhere(
              (group) => group.versions.any((track) => track.songId == '6'),
            )
            .versions,
        hasLength(1),
      );
    });
  });

  group('Smart lists', () {
    PlayHistoryEntry history(
      String source,
      String id, {
      String title = '历史',
      int playedAt = 1,
    }) => PlayHistoryEntry(
      sourceKey: source,
      songId: id,
      title: title,
      playedAt: playedAt,
    );

    PlayStatTrackEntry stat(
      String source,
      String id, {
      int playCount = 1,
      int listenedMs = 1000,
      int lastPlayedAt = 1,
    }) => PlayStatTrackEntry(
      sourceKey: source,
      songId: id,
      title: '统计',
      playCount: playCount,
      listenedMs: listenedMs,
      lastPlayedAt: lastPlayedAt,
    );

    final downloads = [
      download('1', title: 'B 下载', downloadedAt: 10),
      download(
        '2',
        imported: true,
        localKey: 'file:2',
        title: 'A 导入',
        downloadedAt: 20,
      ),
      download('3', title: '缺失', downloadedAt: 30, missingAt: 99),
      download('4', title: '无音频', downloadedAt: 40, filePath: null),
    ];
    final browse = buildBrowseIndex(
      BrowseSource(
        favorites: [track('wy', '9', title: '收藏')],
        downloads: downloads,
      ),
    );
    final sources = SmartListSources(
      downloads: downloads,
      history: [
        history('wy', '9', title: '收藏', playedAt: 100),
        history('local', 'file:2', title: 'A 导入', playedAt: 90),
        history('local', 'wy:3', title: '缺失', playedAt: 80),
      ],
      stats: [
        stat('wy', '9', playCount: 5, listenedMs: 5000, lastPlayedAt: 100),
        stat(
          'local',
          'file:2',
          playCount: 2,
          listenedMs: 9000,
          lastPlayedAt: 90,
        ),
      ],
      browse: browse,
    );

    test('最近添加按下载时间倒序、排除缺失 / 无音频', () {
      final list = buildSmartList(SmartListIds.recentlyAdded, sources);
      expect(list.map((track) => track.title), ['A 导入', 'B 下载']);
    });

    test('最近播放沿用历史顺序、排除缺失记录', () {
      final list = buildSmartList(SmartListIds.recentlyPlayed, sources);
      expect(list.map((track) => track.title), ['收藏', 'A 导入']);
    });

    test('最常播放：两种指标、只保留仍在曲库的曲目、可限流', () {
      final byCount = buildSmartList(SmartListIds.mostPlayed, sources);
      expect(byCount.map((track) => track.key), ['wy:9', 'local:file:2']);
      final byTime = buildSmartList(
        SmartListIds.mostPlayed,
        sources,
        metric: SmartListMetric.listeningTime,
      );
      expect(byTime.map((track) => track.key), ['local:file:2', 'wy:9']);
      expect(
        buildSmartList(SmartListIds.mostPlayed, sources, cap: 1),
        hasLength(1),
      );
    });

    test('从未播放 = 曲库 - 统计 - 历史', () {
      final list = buildSmartList(SmartListIds.neverPlayed, sources);
      expect(list.map((track) => track.key), ['local:wy:1']);
    });

    test('仅本地 / 已下载 / 文件不见的规则', () {
      expect(
        buildSmartList(SmartListIds.localOnly, sources).map((t) => t.title),
        ['A 导入'],
      );
      expect(
        buildSmartList(SmartListIds.downloaded, sources).map((t) => t.title),
        ['B 下载'],
      );
      expect(
        buildSmartList(SmartListIds.missingFiles, sources).map((t) => t.title),
        ['缺失'],
      );
    });

    test('智能列表 id 不是 playlist id，且全部列表有稳定 id', () {
      for (final id in SmartListIds.all) {
        expect(SmartListIds.isSmartList(id), isTrue);
        expect(id, startsWith('smart:'));
      }
      expect(buildSmartList('playlist:1', sources), isEmpty);
    });
  });

  group('智能列表重复版本展示', () {
    PlaylistTrack row(
      String id, {
      String title = 'Song',
      int duration = 200000,
    }) => PlaylistTrack(
      playlistId: 0,
      sourceKey: 'wy',
      songId: id,
      title: title,
      artist: 'Artist',
      album: 'Album',
      durationMs: duration,
      addedAt: 1,
    );

    test('代表行 + 展开版本；计数按代表行 key', () {
      final rows = [
        TrackCollectionRow(row('1')),
        TrackCollectionRow(row('2', duration: 201000)),
      ];
      final collapsed = buildSmartListDisplayRows(rows, {});
      expect(collapsed.rows, hasLength(1));
      expect(collapsed.versionCounts['wy:1'], 2);
      final expanded = buildSmartListDisplayRows(rows, {'wy:1'});
      expect(expanded.rows, hasLength(2));
      expect(expanded.rows.last.favoriteKey.songId, '2');
    });

    test('未知智能哨兵回退默认收藏，不落到最近添加', () {
      expect(
        LibraryCollections.resolveSelection(
          selected: -99,
          playlists: const [],
          favoritesId: 1,
        ),
        LibraryCollections.favoritesSentinel,
      );
      expect(LibraryCollections.smartIdFor(-99), isNull);
    });
  });
}
