/// B 站「发现」：音乐榜 + 热搜；收藏夹只作为导入入口，不提供歌单浏览。
///
/// B 站没有音乐平台那种歌单广场：公开收藏夹可以按链接导入，但没有可浏览 /
/// 可搜索的歌单列表。因此 [supportsPlaylists] / [supportsPlaylistSearch] 恒为
/// false，UI 隐藏「歌单」tab，而不是展示一个必然失败的入口。
library;

import '../../domain/models/discover.dart';
import '../../domain/models/failure.dart';
import 'bili_client.dart';
import 'bili_favorites.dart';
import 'bili_ranking.dart';
import 'builtin_transport.dart';
import 'discover_source.dart';

class BiliDiscoverSource extends DiscoverSource {
  const BiliDiscoverSource();

  @override
  String get sourceKey => 'bili';

  @override
  List<DiscoverLeaderboard> get leaderboards => BiliRanking.boards;

  @override
  Future<List<DiscoverTrack>> leaderboardTracks(String bangid) =>
      BiliRanking.leaderboardTracks(bangid);

  @override
  Future<DiscoverTags> tags() async => const DiscoverTags();

  @override
  Future<DiscoverPlaylistPage> playlists(String tagId, int page) async {
    throw const SourceFailure(
      kind: FailureKind.unsupported,
      message: 'bili: 不支持歌单浏览',
    );
  }

  @override
  Future<DiscoverPlaylistPage> searchPlaylists(String keyword, int page) async {
    throw const SourceFailure(
      kind: FailureKind.unsupported,
      message: 'bili: 不支持歌单浏览',
    );
  }

  @override
  Future<DiscoverDetail> playlistDetail(String rawId, int page) =>
      BiliFavorites.detail(rawId, page);

  /// 热搜：`data.trending.list[].keyword`（只收字符串、去重保序）。
  @override
  Future<List<String>> hotSearches() async {
    final response = await BiliClient.shared.get(
      '/x/web-interface/search/square',
      query: {'limit': '10'},
      retries: BuiltinTransport.defaultRetries,
    );
    return parseHotSearches(response);
  }

  /// 热搜响应 → 关键词列表（供单测复用）。
  static List<String> parseHotSearches(dynamic response) {
    final data = response is Map ? response['data'] : null;
    final trending = data is Map ? data['trending'] : null;
    final list = trending is Map ? trending['list'] : null;
    if (list is! List) return const [];
    final words = <String>[];
    final seen = <String>{};
    for (final item in list) {
      if (item is! Map) continue;
      final keyword = item['keyword'];
      if (keyword is! String) continue;
      final text = keyword.trim();
      if (text.isEmpty || !seen.add(text)) continue;
      words.add(text);
    }
    return words;
  }

  @override
  bool get supportsPlaylists => false;

  @override
  bool get supportsPlaylistSearch => false;

  @override
  bool get supportsHotSearch => true;
}
