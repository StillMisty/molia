import '../../data/mapping/track_mapper.dart';
import '../../domain/models/artist.dart';
import '../../domain/models/track.dart';
import '../source_search_result.dart';
import 'artist_source.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'crypto_utils.dart';
import 'mg_search.dart';

/// 咪咕音乐歌手（jadeite / `pc/bmw/singer/*`）。
///
/// - 搜索：`GET jadeite.migu.cn/music_search/v3/search/searchAll`（签名 headers
///   与单曲搜索一致；`searchSwitch.singer=1`，结果在 `singerResultData`，
///   `pageNo` 有效）；
/// - 详情：`GET app.c.nf.migu.cn/pc/bmw/singer/info/v1.1?singerId=`
///   （`ZJ-SingerDetail-Item`：名字 / 头像；**平台不提供简介** → `description` 为空）；
/// - 歌曲：`GET app.c.nf.migu.cn/pc/bmw/singer/song/v1.0?pageNo=&singerId=&type=1`
///   （每页 50；条目在 `ZJ-Singer-Song-Scroll.contents[].songItem`，字段与单曲
///   搜索同构，复用 [MgSearch] 的解析工具）。
///
/// 开发环境已抓到真实响应，见 test/fixtures/artists/mg_*.json。
class MgArtist {
  MgArtist._();

  /// 歌手搜索（`singerResultData.totalCount` 用于分页）。
  static Future<ArtistSearchPage> search(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    final request = MgSearch.searchAllRequest(
      text: keyword,
      page: page,
      limit: limit,
      // 只开歌手开关：结果里不再混单曲 / 歌单等分区。
      searchSwitch: const {
        'song': 0,
        'album': 0,
        'singer': 1,
        'tagSong': 0,
        'mvSong': 0,
        'bestShow': 0,
        'songlist': 0,
        'lyricSong': 0,
      },
    );
    final body = await lxHttpGet(
      request.url,
      headers: request.headers,
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
    final singerData = (body is Map) ? body['singerResultData'] : null;
    final rawList = (singerData is Map) ? singerData['result'] : null;
    if (rawList is! List) {
      throw artistPlatformFailure('mg', '歌手搜索响应非法');
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
        avatarUrl: _firstPic(raw['singerPicUrl']),
        songCount: parseSourceCount(raw['songCount']),
      ));
    }
    final total =
        parseSourceCount(singerData is Map ? singerData['totalCount'] : null);
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
    final songs = await lxHttpGet(
      'https://app.c.nf.migu.cn/pc/bmw/singer/song/v1.0'
      '?pageNo=$page&singerId=$artistId&type=1',
      headers: const {'Referer': 'https://music.migu.cn/'},
      retries: BuiltinTransport.defaultRetries,
    );
    dynamic info;
    try {
      info = await lxHttpGet(
        'https://app.c.nf.migu.cn/pc/bmw/singer/info/v1.1?singerId=$artistId',
        headers: const {'Referer': 'https://music.migu.cn/'},
        retries: BuiltinTransport.defaultRetries,
      );
    } catch (_) {
      info = null;
    }
    return parse(
      info: info,
      songs: songs,
      artistId: artistId,
      page: page,
      limit: limit,
    );
  }

  /// 详情 + 歌曲响应 → 领域模型（供单测复用）。
  static ArtistDetail parse({
    required dynamic info,
    required dynamic songs,
    required String artistId,
    int page = 1,
    int limit = kArtistPageSize,
  }) {
    final data = (songs is Map) ? songs['data'] : null;
    final contents = (data is Map) ? data['contents'] : null;
    final scroll = _findView(contents, 'ZJ-Singer-Song-Scroll');
    final rawList = (scroll is Map) ? scroll['contents'] : null;
    if (rawList is! List) {
      throw artistPlatformFailure('mg', '获取歌手歌曲失败（结构不符）');
    }

    final artist = _singerDetailItem(info);
    final tracks = <Track>[];
    for (final raw in rawList) {
      final track = parseSong(raw);
      if (track != null) tracks.add(track);
    }

    // `header.nextPageUrl` 非空即还有下一页（第 1 页指向 pageNo=2）。
    final header = (data is Map) ? data['header'] : null;
    final next = (header is Map) ? header['nextPageUrl']?.toString() ?? '' : '';
    return ArtistDetail(
      id: artistId,
      name: decodeName(artist?['txt']?.toString()),
      avatarUrl: _nonEmpty(artist?['img']) ?? _nonEmpty(artist?['img2']),
      // 咪咕 v5 前端本身不展示简介，接口也不返回。
      description: '',
      tracks: tracks,
      hasMore: next.isNotEmpty,
    );
  }

  /// 歌手歌曲条目（`ZJ-Singer-Song-Item`）→ 领域曲目。
  static Track? parseSong(dynamic raw) {
    if (raw is! Map) return null;
    final item = raw['songItem'];
    if (item is! Map) return null;
    final songId = item['songId']?.toString() ?? '';
    final copyrightId = item['copyrightId']?.toString() ?? '';
    if (songId.isEmpty || copyrightId.isEmpty) return null;

    final duration = parseSourceCount(item['duration']) ?? 0;
    return trackFromSourceTrack(MgSearch.buildTrack(
      songId: songId,
      copyrightId: copyrightId,
      name: item['songName']?.toString() ?? '',
      artist: MgSearch.joinSingerNames(item['singerList']),
      artists: MgSearch.artistRefsOf(item['singerList']),
      album: item['album']?.toString() ?? '',
      albumId: item['albumId']?.toString() ?? '',
      intervalText: duration > 0 ? formatPlayTime(duration) : null,
      duration: duration > 0 ? Duration(seconds: duration) : null,
      types: MgSearch.parseTypes(item['audioFormats']),
      img: MgSearch.fixCoverUrl(item['img3'] ?? item['img2'] ?? item['img1']),
      lrcUrl: item['lrcUrl']?.toString(),
      mrcUrl: item['mrcUrl']?.toString(),
      trcUrl: item['trcUrl']?.toString(),
    ));
  }

  /// `data.contents` 里按 `view` 取分区（咪咕接口的分区式响应结构）。
  static dynamic _findView(dynamic contents, String view) {
    if (contents is! List) return null;
    for (final item in contents) {
      if (item is Map && item['view'] == view) return item;
    }
    return null;
  }

  /// 歌手信息条目（`ZJ-SingerDetail-Scroll.contents[0]`）。
  static Map? _singerDetailItem(dynamic info) {
    final data = (info is Map) ? info['data'] : null;
    final contents = (data is Map) ? data['contents'] : null;
    final scroll = _findView(contents, 'ZJ-SingerDetail-Scroll');
    final inner = (scroll is Map) ? scroll['contents'] : null;
    if (inner is! List) return null;
    for (final item in inner) {
      if (item is Map) return item;
    }
    return null;
  }

  /// 歌手头像：优先 `imgSizeType=01`（大图），否则取首图。
  static String? _firstPic(dynamic pics) {
    if (pics is! List) return null;
    String? fallback;
    for (final pic in pics) {
      if (pic is! Map) continue;
      final img = _nonEmpty(pic['img']);
      if (img == null) continue;
      if (pic['imgSizeType']?.toString() == '01') return img;
      fallback ??= img;
    }
    return fallback;
  }

  static String? _nonEmpty(Object? value) {
    final text = value?.toString();
    return (text == null || text.isEmpty) ? null : text;
  }
}
