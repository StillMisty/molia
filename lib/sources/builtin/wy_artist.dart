import '../../data/mapping/track_mapper.dart';
import '../../domain/models/artist.dart';
import '../../domain/models/track.dart';
import '../source_search_result.dart';
import 'artist_source.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'crypto_utils.dart';
import 'wy_music_detail.dart';

/// 网易云音乐歌手（搜索 `api/search/get/web?type=100`；详情 weapi）。
///
/// - 搜索：`GET api/search/get/web?s=&type=100&offset=&limit=`
///   （`result.artists` + `result.artistCount`，免签名）；
/// - 详情：`POST weapi/v1/artist/{id}`（`artist.briefDesc` 完整简介 / 别名 / 计数，
///   weapi 加密与歌单详情同一实现）；
/// - 歌曲：`GET api/v1/artist/songs?id=&offset=&limit=&order=hot`（`more`/`total` 分页；
///   免签名端点实测可用，比 weapi 版本少一层加密）→ 取 song id 后经
///   [WyMusicDetail.getList]（`weapi/v3/song/detail`）补成规范 raw
///   （与歌单详情同一流程，音质字段完整）。
///
/// 开发环境已抓到真实响应，见 test/fixtures/artists/wy_*.json。
class WyArtist {
  WyArtist._();

  /// 歌手搜索（`artistCount` 用于分页）。
  static Future<ArtistSearchPage> search(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    final body = await lxHttpGet(
      'https://music.163.com/api/search/get/web'
      '?s=${Uri.encodeComponent(keyword)}'
      '&type=$_searchTypeArtist&offset=${(page - 1) * limit}&limit=$limit',
      headers: const {'Referer': 'https://music.163.com/'},
      retries: BuiltinTransport.defaultRetries,
    );
    return parseSearch(body, page: page, limit: limit);
  }

  /// 歌手搜索响应 → 结果页（供单测复用）。
  static ArtistSearchPage parseSearch(
    dynamic body, {
    required int page,
    required int limit,
  }) {
    final result = (body is Map) ? body['result'] : null;
    final rawList = (result is Map) ? result['artists'] : null;
    if (rawList is! List) {
      throw artistPlatformFailure('wy', '歌手搜索响应非法');
    }
    final artists = <ArtistSummary>[];
    for (final raw in rawList) {
      if (raw is! Map) continue;
      final id = raw['id']?.toString() ?? '';
      final name = decodeName(raw['name']?.toString());
      if (id.isEmpty || name.isEmpty) continue;
      artists.add(ArtistSummary(
        id: id,
        name: name,
        avatarUrl: raw['picUrl']?.toString(),
        songCount: parseSourceCount(raw['musicSize']),
      ));
    }
    final total = parseSourceCount(result is Map ? result['artistCount'] : null);
    return ArtistSearchPage(
      items: artists,
      total: total,
      hasMore: total != null && total > 0 && page * limit < total,
    );
  }

  /// 歌手详情 + 一页歌曲。
  ///
  /// 详情接口 best-effort：失败时退回入口携带的名字，不阻断歌曲列表。
  static Future<ArtistDetail> fetch(
    String artistId, {
    int page = 1,
    int limit = kArtistPageSize,
  }) async {
    final songsPage = await lxHttpGet(
      'https://music.163.com/api/v1/artist/songs'
      '?id=$artistId&offset=${(page - 1) * limit}&limit=$limit&order=hot',
      headers: const {'Referer': 'https://music.163.com/'},
      retries: BuiltinTransport.defaultRetries,
    );

    dynamic info;
    try {
      info = await lxHttpPost(
        'https://music.163.com/weapi/v1/artist/$artistId',
        form: true,
        headers: const {
          'origin': 'https://music.163.com',
          'Referer': 'https://music.163.com/',
        },
        body: weapiForm(const {}),
        retries: BuiltinTransport.defaultRetries,
      );
    } catch (_) {
      info = null;
    }

    // 旧版歌曲字段（artists/album/duration）→ 规范 raw：取 id 走歌曲详情。
    final ids = <Object>[];
    final rawList = (songsPage is Map) ? songsPage['songs'] : null;
    if (rawList is List) {
      for (final raw in rawList) {
        final id = (raw is Map) ? raw['id'] : null;
        if (id != null) ids.add(id);
      }
    }
    final tracks = ids.isEmpty
        ? const <Track>[]
        : [
            for (final track in await WyMusicDetail.getList(ids))
              trackFromSourceTrack(track),
          ];

    return parse(
      info: info,
      tracks: tracks,
      songsPage: songsPage,
      artistId: artistId,
      page: page,
      limit: limit,
    );
  }

  /// 详情 + 歌曲响应 → 领域模型（供单测复用）。
  static ArtistDetail parse({
    required dynamic info,
    required List<Track> tracks,
    required dynamic songsPage,
    required String artistId,
    int page = 1,
    int limit = kArtistPageSize,
  }) {
    if (songsPage is! Map || songsPage['songs'] is! List) {
      throw artistPlatformFailure('wy', '获取歌手歌曲失败（结构不符）');
    }
    final artist = (info is Map && info['artist'] is Map)
        ? info['artist'] as Map
        : const {};
    final more = songsPage['more'];
    final total = parseSourceCount(songsPage['total']);
    final bool hasMore;
    if (more is bool) {
      hasMore = more;
    } else {
      hasMore = total != null && total > 0 && page * limit < total;
    }
    return ArtistDetail(
      id: artistId,
      name: decodeName(artist['name']?.toString()),
      avatarUrl: artist['picUrl']?.toString(),
      description: decodeName(artist['briefDesc']?.toString()),
      tracks: tracks,
      hasMore: hasMore,
    );
  }

  /// 歌手搜索 `type`（1 单曲 / 10 专辑 / 100 歌手 / 1006 歌词）。
  static const int _searchTypeArtist = 100;
}
