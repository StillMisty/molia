/// 汽水音乐「发现」适配：推荐歌单 + 分类 + 歌单搜索 / 详情。
///
/// 匿名接口里没有榜单目录与热搜词，因此：
/// - `leaderboards` 恒为空（UI 隐藏热榜 tab）；
/// - `supportsHotSearch` 为 false（搜索页不展示热搜词）。
///
/// 推荐歌单来自 `POST /luna/discover/mix`：平台没有游标，每次返回一批随机
/// 推荐（约 8–10 个），继续下拉就是再拉一批；跨页重复由列表控制器的去重
/// 兜底（去重后无新增即停止）。分类的 `sub_channel_id` 是平台固定枚举
/// （与官方客户端的频道号一致）。
library;

import '../../domain/models/discover.dart';
import 'discover_source.dart';
import 'discover_track_mapper.dart';
import 'qs_api.dart';
import 'qs_search.dart';
import 'qs_track.dart';

class QsDiscoverSource extends DiscoverSource {
  const QsDiscoverSource();

  /// 歌单搜索与歌单详情的页长（平台固定 20）。
  static const int pageSize = 20;

  /// 推荐歌单单次请求条数（平台上限约 10–20）。
  static const int discoverBatchSize = 20;

  /// 分类频道：`sub_channel_id` 与官方客户端的频道号一致。
  static const List<DiscoverTag> _dailyRecommended = [
    DiscoverTag(id: '0', name: '每日推荐'),
  ];

  static const List<DiscoverTag> _genres = [
    DiscoverTag(id: '14', name: '流行'),
    DiscoverTag(id: '8', name: '华语'),
    DiscoverTag(id: '9', name: '欧美'),
    DiscoverTag(id: '20', name: '国风'),
    DiscoverTag(id: '18', name: '民谣'),
    DiscoverTag(id: '15', name: '摇滚'),
    DiscoverTag(id: '38', name: '说唱'),
    DiscoverTag(id: '16', name: '电子'),
    DiscoverTag(id: '19', name: 'R&B'),
  ];

  static const List<DiscoverTag> _scenes = [
    DiscoverTag(id: '69', name: '治愈'),
    DiscoverTag(id: '45', name: '睡前'),
    DiscoverTag(id: '40', name: '学习'),
  ];

  @override
  String get sourceKey => 'qs';

  @override
  List<DiscoverLeaderboard> get leaderboards => const [];

  @override
  Future<List<DiscoverTrack>> leaderboardTracks(String bangid) async =>
      const [];

  @override
  Future<DiscoverTags> tags() async => DiscoverTags(
    hotTags: const [
      ..._dailyRecommended,
      DiscoverTag(id: '14', name: '流行'),
      DiscoverTag(id: '8', name: '华语'),
      DiscoverTag(id: '9', name: '欧美'),
      DiscoverTag(id: '20', name: '国风'),
    ],
    categories: const [
      DiscoverTagCategory(name: '推荐', tags: _dailyRecommended),
      DiscoverTagCategory(name: '曲风', tags: _genres),
      DiscoverTagCategory(name: '场景', tags: _scenes),
    ],
  );

  @override
  Future<DiscoverPlaylistPage> playlists(String tagId, int page) async {
    final response = await QsApi.postJson('/luna/discover/mix', {
      'sub_channel_id': _channelOf(tagId),
      'count': discoverBatchSize,
    });
    final playlists = _playlistsOf(response);
    final hasMore = response is Map && response['has_more'] != false;
    // 平台没有游标：每页都是新一批随机推荐，页长取本批实际条数。
    final limit = playlists.isEmpty ? 1 : playlists.length;
    return DiscoverPlaylistPage(
      playlists: playlists,
      page: page,
      limit: limit,
      total: page * limit + (hasMore ? 1 : 0),
    );
  }

  @override
  Future<DiscoverPlaylistPage> searchPlaylists(String keyword, int page) async {
    final response = await QsApi.getJson(
      '/luna/search/playlist',
      query: {
        'q': keyword,
        'cursor': '${(page < 1 ? 0 : page - 1) * pageSize}',
        'search_id': '',
        'search_method': 'input',
      },
      tries: QsApi.searchTries,
    );
    final playlists = _playlistsOf(response);
    final hasMore = _groupHasMore(response, 'playlists');
    return DiscoverPlaylistPage(
      playlists: playlists,
      page: page,
      limit: pageSize,
      total: page * pageSize + (hasMore ? 1 : 0),
    );
  }

  @override
  Future<DiscoverDetail> playlistDetail(String rawId, int page) async {
    final requestPage = page < 1 ? 1 : page;
    final response = await QsApi.getJson(
      '/luna/playlist/detail',
      query: {
        'playlist_id': rawId,
        'cursor': '${(requestPage - 1) * pageSize}',
        'count': '$pageSize',
      },
    );
    if (response is! Map) {
      throw StateError('qs: 歌单详情响应非法');
    }
    final info = _playlistOf(response['playlist']);
    if (info == null) throw StateError('qs: 歌单详情缺少 playlist');
    final tracks = <DiscoverTrack>[];
    final media = response['media_resources'];
    if (media is List) {
      for (final item in media) {
        final raw = QsSearch.trackOfItem(item);
        final parsed = raw == null ? null : QsTrack.parse(raw);
        if (parsed != null) tracks.add(discoverTrackOf(parsed));
      }
    }
    return DiscoverDetail(info: info, tracks: tracks);
  }

  @override
  Future<List<String>> hotSearches() async => const [];

  @override
  bool get supportsHotSearch => false;

  static int _channelOf(String tagId) => int.tryParse(tagId.trim()) ?? 0;

  /// 推荐 / 搜索结果里的歌单（两种响应都把歌单放在 `entity.playlist`）。
  static List<DiscoverPlaylist> _playlistsOf(Object? response) {
    if (response is! Map) return const [];
    final groups = response['inner_block'] ?? response['result_groups'];
    if (groups is! List) return const [];
    final playlists = <DiscoverPlaylist>[];
    final seen = <String>{};
    for (final group in groups) {
      final resources = group is Map
          ? (group['resources'] ?? group['data'])
          : null;
      if (resources is! List) continue;
      for (final resource in resources) {
        final entity = resource is Map ? resource['entity'] : null;
        final playlist = entity is Map ? entity['playlist'] : null;
        final parsed = _playlistOf(playlist);
        if (parsed == null || !seen.add(parsed.id)) continue;
        playlists.add(parsed);
      }
    }
    return playlists;
  }

  /// 结果组里的 `has_more`（搜索接口）。
  static bool _groupHasMore(Object? response, String groupId) {
    if (response is! Map) return false;
    final groups = response['result_groups'];
    if (groups is! List) return false;
    for (final group in groups) {
      if (group is Map && group['id'] == groupId) {
        return group['has_more'] == true;
      }
    }
    return false;
  }

  static DiscoverPlaylist? _playlistOf(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    final name =
        raw['title']?.toString() ??
        raw['public_title']?.toString() ??
        raw['name']?.toString() ??
        '';
    final owner = raw['owner'];
    final stats = raw['stats'];
    final createTime = _intOf(raw['create_time']);
    return DiscoverPlaylist(
      id: id,
      name: name,
      coverUrl: QsTrack.imageUrlOf(raw['url_cover']),
      author: owner is Map ? (owner['nickname']?.toString() ?? '') : '',
      playCount: stats is Map ? (_intOf(stats['count_collected'])) : 0,
      trackCount: _intOf(raw['count_tracks']),
      description: _nonEmpty(raw['desc']),
      createdAt: createTime > 0
          ? DateTime.fromMillisecondsSinceEpoch(createTime * 1000)
                .toIso8601String()
                .substring(0, 10)
          : null,
    );
  }

  static int _intOf(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String? _nonEmpty(Object? value) {
    final text = value?.toString().trim();
    return (text == null || text.isEmpty) ? null : text;
  }
}
