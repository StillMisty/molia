import '../../domain/models/discover.dart';
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
  Future<List<DiscoverTrack>> leaderboardTracks(String bangid) async {
    final tracks = await WyLeaderboard.getTracks(bangid);
    return [for (final track in tracks) discoverTrackOf(track)];
  }

  @override
  Future<DiscoverTags> tags() async {
    final result = await WySongList.getTags();
    return DiscoverTags(hotTags: result.hotTag, categories: result.tags);
  }

  @override
  Future<DiscoverPlaylistPage> playlists(String tagId, int page) =>
      WySongList.getList('hot', tagId, page);

  @override
  Future<DiscoverPlaylistPage> searchPlaylists(String keyword, int page) =>
      WySongList.search(keyword, page);

  @override
  Future<DiscoverDetail> playlistDetail(String rawId, int page) =>
      WySongList.getListDetail(rawId, page);

  @override
  Future<List<String>> hotSearches() => WyHotSearch.getList();
}
