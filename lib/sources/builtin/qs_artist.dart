/// 汽水音乐歌手：搜索走 PC 接口，详情走分享页 SSR。
///
/// 平台差异（必须如实告知 UI，能力位保持为真但分页不可信）：
/// - 歌手搜索 `GET /luna/search/artist` 支持游标分页；
/// - 歌手详情没有匿名 API，`share/artist` 只给「热门作品」样本（实测 4 首）
///   与最新 4 张专辑。这里用「按歌手名搜索后按歌手 id 过滤」把列表补到一页，
///   仍然拿不到完整曲库，因此 `hasMore` 恒为 false；
/// - 简介来自 `artistInfo.artist_profile.intro`。
library;

import '../../data/mapping/track_mapper.dart';
import '../../domain/models/artist.dart';
import '../../domain/models/track.dart';
import 'artist_source.dart';
import 'qs_api.dart';
import 'qs_search.dart';
import 'qs_track.dart';

class QsArtist {
  QsArtist._();

  /// 歌手搜索（搜索页「歌手」类型）。
  static Future<ArtistSearchPage> search(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    final response = await QsApi.getJson(
      '/luna/search/artist',
      query: {
        'q': keyword,
        'cursor': '${(page < 1 ? 0 : page - 1) * QsSearch.pageSize}',
        'search_id': '',
        'search_method': 'input',
      },
      tries: QsApi.searchTries,
    );
    return parseSearch(response);
  }

  /// 歌手搜索响应 → 结果页（供单测复用）。
  static ArtistSearchPage parseSearch(dynamic response) {
    if (response is! Map) throw artistPlatformFailure('qs', '歌手搜索响应非法');
    final groups = response['result_groups'];
    if (groups is! List) throw artistPlatformFailure('qs', '歌手搜索响应非法');
    Map<String, dynamic>? group;
    for (final item in groups) {
      if (item is Map && item['id'] == 'artists') {
        group = Map<String, dynamic>.from(item);
        break;
      }
    }
    if (group == null) return ArtistSearchPage.empty;

    final items = <ArtistSummary>[];
    final data = group['data'];
    if (data is List) {
      for (final entry in data) {
        if (entry is! Map) continue;
        final entity = entry['entity'];
        final artist = entity is Map ? entity['artist'] : null;
        if (artist is! Map) continue;
        final id = artist['id']?.toString() ?? '';
        final name =
            artist['simple_display_name']?.toString() ??
            artist['name']?.toString() ??
            '';
        if (id.isEmpty || name.isEmpty) continue;
        items.add(
          ArtistSummary(
            id: id,
            name: name,
            avatarUrl: QsTrack.imageUrlOf(
              artist['url_avatar'],
              suffix: '~c5_300x300.jpg',
            ),
            songCount: _intOrNull(artist['count_tracks']),
          ),
        );
      }
    }

    return ArtistSearchPage(items: items, hasMore: group['has_more'] == true);
  }

  /// 歌手详情 + 一页歌曲。
  static Future<ArtistDetail> fetch(
    String artistId, {
    int page = 1,
    int limit = kArtistPageSize,
  }) async {
    final loader = await QsApi.shareLoaderData('/share/artist', {
      'artist_id': artistId,
    });
    final rawPage = loader['artist_page'];
    if (rawPage is! Map) {
      throw artistPlatformFailure('qs', '歌手详情数据结构不符');
    }
    final info = rawPage['artistInfo'];
    if (info is! Map) throw artistPlatformFailure('qs', '歌手详情数据结构不符');

    final name =
        info['simple_display_name']?.toString() ??
        info['name']?.toString() ??
        '';
    final tracks = <Track>[];
    final seen = <String>{};
    void addTracks(Iterable<Track> candidates) {
      for (final track in candidates) {
        if (tracks.length >= limit) return;
        if (seen.add(track.id.uri)) tracks.add(track);
      }
    }

    addTracks(_tracksOf(rawPage['trackList']));
    // 分享页只有热门样本；按名字再搜一页，能补多少补多少。
    if (page <= 1 && name.isNotEmpty && tracks.length < limit) {
      try {
        final result = await QsSearch.searchWithMeta(
          name,
          page: 1,
          limit: QsSearch.pageSize,
        );
        addTracks([
          for (final track in result.tracks)
            if (_hasArtist(track.raw, artistId)) trackFromSourceTrack(track),
        ]);
      } catch (_) {
        // 补列表是 best-effort：失败时保留分享页样本，不阻断歌手页。
      }
    }

    return ArtistDetail(
      id: info['id']?.toString() ?? artistId,
      name: name,
      avatarUrl: QsTrack.imageUrlOf(
        info['url_avatar'],
        suffix: '~c5_300x300.jpg',
      ),
      description: _introOf(info['artist_profile']),
      tracks: tracks,
      hasMore: false,
    );
  }

  /// 分享页 trackList → 领域曲目。
  static List<Track> _tracksOf(Object? trackList) => [
    for (final track in QsTrack.parseList(trackList))
      trackFromSourceTrack(track),
  ];

  /// 曲目 raw 的 `_artists` 里是否有目标歌手 id。
  static bool _hasArtist(Map<String, dynamic> raw, String artistId) {
    final refs = raw['_artists'];
    if (refs is! List) return false;
    for (final ref in refs) {
      if (ref is Map && ref['id']?.toString() == artistId) return true;
    }
    return false;
  }

  static String _introOf(Object? profile) {
    if (profile is! Map) return '';
    return profile['intro']?.toString().trim() ?? '';
  }

  static int? _intOrNull(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}
