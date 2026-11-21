import '../../domain/models/discover.dart';
import 'builtin_transport.dart';
import 'discover_source.dart';
import 'discover_track_mapper.dart';
import 'wy_hot_search.dart';
import 'wy_leaderboard.dart';
import 'wy_songlist.dart';

/// 网易云「发现」适配：包装现有 wy 内置模块。
class WyDiscoverSource extends DiscoverSource {
  const WyDiscoverSource();

  @override
  String get sourceKey => 'wy';

  @override
  List<DiscoverLeaderboard> get leaderboards => WyLeaderboard.boards;

  @override
  bool get hasLeaderboardCoverEndpoint => true;

  @override
  Future<List<DiscoverTrack>> leaderboardTracks(
    BuiltinTransport http,
    String bangid,
  ) async {
    final tracks = await WyLeaderboard.getTracks(http, bangid);
    return [for (final track in tracks) discoverTrackOf(track)];
  }

  @override
  Future<String?> leaderboardCover(BuiltinTransport http, String bangid) =>
      WyLeaderboard.getCover(http, bangid);

  @override
  Future<DiscoverTags> tags(BuiltinTransport http) async {
    final result = await WySongList.getTags(http);
    return DiscoverTags(hotTags: result.hotTag, categories: result.tags);
  }

  @override
  Future<DiscoverPlaylistPage> playlists(
    BuiltinTransport http,
    String tagId,
    int page,
  ) => WySongList.getList(http, 'hot', tagId, page);

  @override
  Future<DiscoverPlaylistPage> searchPlaylists(
    BuiltinTransport http,
    String keyword,
    int page,
  ) => WySongList.search(http, keyword, page);

  @override
  Future<DiscoverDetail> playlistDetail(
    BuiltinTransport http,
    String rawId,
    int page,
  ) => WySongList.getListDetail(http, rawId, page);

  @override
  Future<List<String>> hotSearches(BuiltinTransport http) =>
      WyHotSearch.getList(http);
}
