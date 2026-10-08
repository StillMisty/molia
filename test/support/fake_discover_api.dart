import 'package:molia/domain/models/discover.dart';
import 'package:molia/sources/builtin/discover_source.dart';
import 'package:molia/sources/source_track.dart';
import 'package:molia/sources/builtin/discover_track_mapper.dart';

/// 内存版发现数据源（provider / widget 测试用，不发网络请求）。
class FakeDiscoverSource implements DiscoverSource {
  FakeDiscoverSource({this.sourceKey = 'wy'});

  @override
  final String sourceKey;

  @override
  bool get supportsLeaderboards => leaderboards.isNotEmpty;
  @override
  bool get supportsPlaylists => true;
  @override
  bool get supportsPlaylistSearch => true;
  @override
  bool get supportsHotSearch => true;

  bool fail = false;
  int leaderboardCalls = 0;
  int hotSearchCalls = 0;
  int tagCalls = 0;

  final DiscoverTrack track = const DiscoverTrack(
    sourceKey: 'wy',
    songId: '111',
    title: '歌曲A',
    artist: '歌手',
    album: '专辑',
    coverUrl: 'https://p1.music.126.net/x.jpg',
    durationMs: 245000,
    raw: {'songmid': 111, 'source': 'wy'},
  );

  @override
  List<DiscoverLeaderboard> get leaderboards => const [
        DiscoverLeaderboard(id: 'wy__3778678', name: '热歌榜', bangid: '3778678'),
      ];

  Future<T> _guard<T>(T value) async {
    if (fail) throw StateError('mock failure');
    return value;
  }

  @override
  Future<List<DiscoverTrack>> leaderboardTracks(String bangid) {
    leaderboardCalls++;
    return _guard([track]);
  }

  @override
  Future<DiscoverTags> tags() {
    tagCalls++;
    return _guard(const DiscoverTags(
      hotTags: [DiscoverTag(id: '华语', name: '华语')],
      categories: [
        DiscoverTagCategory(
          name: '语种',
          tags: [DiscoverTag(id: '华语', name: '华语')],
        ),
      ],
    ));
  }

  @override
  Future<DiscoverPlaylistPage> playlists(String tagId, int page) => _guard(
        DiscoverPlaylistPage(
          playlists: [
            const DiscoverPlaylist(
              id: '123',
              name: '测试歌单',
              author: '作者',
              trackCount: 2,
            ),
          ],
          page: page,
          limit: 30,
          total: 1,
        ),
      );

  @override
  Future<DiscoverPlaylistPage> searchPlaylists(String keyword, int page) =>
      _guard(
        DiscoverPlaylistPage(
          playlists: [
            DiscoverPlaylist(id: '9', name: '搜索:$keyword'),
          ],
          page: page,
          limit: 20,
          total: 1,
        ),
      );

  @override
  Future<DiscoverDetail> playlistDetail(String rawId, int page) => _guard(
        DiscoverDetail(
          info: DiscoverPlaylist(id: rawId, name: '歌单详情'),
          tracks: [track],
        ),
      );

  @override
  Future<List<String>> hotSearches() {
    hotSearchCalls++;
    return _guard(const ['晴天', '夜曲']);
  }
}

/// 供测试使用的 [SourceTrack]（多平台 raw 结构）。
SourceTrack fakeSourceTrack({
  String sourceKey = 'wy',
  String songId = '111',
  String title = '歌曲A',
  Map<String, dynamic>? raw,
}) =>
    SourceTrack(
      sourceKey: sourceKey,
      origin: 'builtin',
      title: title,
      artist: '歌手',
      album: '专辑',
      raw: raw ?? {'songmid': songId, 'source': sourceKey},
    );

/// 便捷：SourceTrack → DiscoverTrack（与内置平台实现同一映射）。
DiscoverTrack fakeDiscoverTrack({
  String sourceKey = 'wy',
  String songId = '111',
  String title = '歌曲A',
  Map<String, dynamic>? raw,
}) =>
    discoverTrackOf(
      fakeSourceTrack(
        sourceKey: sourceKey,
        songId: songId,
        title: title,
        raw: raw,
      ),
    );
