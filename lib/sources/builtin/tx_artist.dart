import '../../data/mapping/track_mapper.dart';
import '../../domain/models/artist.dart';
import '../../domain/models/failure.dart';
import '../../domain/models/track.dart';
import '../source_search_result.dart';
import 'artist_source.dart';
import 'crypto_utils.dart';
import 'tx_search.dart';

/// QQ 音乐歌手（musicu 签名 POST，与搜索同一客户端协议）。
///
/// - 搜索：`music.search.SearchCgiService` + `search_type=1`（`data.body.singer.list`
///   + `data.meta.sum`；`page_num` / `num_per_page` 有效）；
/// - 详情 + 歌曲：`music.web_singer_info_svr.get_singer_detail_info`
///   （`data.singer_info` / `singer_brief` / `songlist` / `total_song`）。
///   曲目条目与单曲搜索同构（复用 [TxSearch.parseSongItem]）。
///
/// 平台限制：歌手歌曲的 `begin` 被服务端忽略、`num` 上限 60 → 只有一页
/// （`hasMore=false`），排序由 `sort` 决定（默认 5 = 热度）。
///
/// 开发环境已抓到真实响应，见 test/fixtures/artists/tx_*.json。
class TxArtist {
  TxArtist._();

  /// 歌手搜索（`meta.sum` 用于分页）。
  static Future<ArtistSearchPage> search(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    final body = TxSearch.searchBody(
      keyword: keyword,
      page: page,
      limit: limit,
      searchType: _searchTypeSinger,
    );
    final response = await _post(body);
    return parseSearch(response, page: page, limit: limit);
  }

  /// 歌手搜索响应 → 结果页（供单测复用）。
  static ArtistSearchPage parseSearch(
    dynamic response, {
    required int page,
    required int limit,
  }) {
    final data = _dataOf(response, _searchModule);
    final artists = <ArtistSummary>[];
    final body = data?['body'];
    final singer = (body is Map) ? body['singer'] : null;
    final rawList = (singer is Map) ? singer['list'] : null;
    if (rawList is! List) {
      throw artistPlatformFailure('tx', '歌手搜索响应非法');
    }
    for (final raw in rawList) {
      if (raw is! Map) continue;
      final id = raw['singerMID']?.toString() ?? '';
      final name = decodeName(raw['singerName']?.toString());
      if (id.isEmpty || name.isEmpty) continue;
      artists.add(ArtistSummary(
        id: id,
        name: name,
        // 搜索条目给 150 尺寸头像；换成 500（与详情页同一图源）。
        avatarUrl: raw['singerPic']
            ?.toString()
            .replaceAll('R150x150', 'R500x500'),
        songCount: parseSourceCount(raw['songNum']),
      ));
    }
    final total = TxSearch.totalOf(data);
    return ArtistSearchPage(
      items: artists,
      total: total,
      hasMore: total != null && total > 0 && page * limit < total,
    );
  }

  /// 歌手详情 + 一页歌曲（同一请求返回）。
  static Future<ArtistDetail> fetch(
    String artistId, {
    int page = 1,
    int limit = kArtistPageSize,
  }) async {
    final body = <String, dynamic>{
      'comm': _comm,
      'music.web_singer_info_svr': {
        'module': 'music.web_singer_info_svr',
        'method': 'get_singer_detail_info',
        'param': {
          'sort': 5,
          'singermid': artistId,
          'begin': 0,
          'num': limit,
        },
      },
    };
    final response = await _post(body);
    return parse(response, artistId: artistId, page: page, limit: limit);
  }

  /// 详情响应 → 领域模型（供单测复用）。
  static ArtistDetail parse(
    dynamic response, {
    required String artistId,
    int page = 1,
    int limit = kArtistPageSize,
  }) {
    final data = _dataOf(response, _detailModule);
    if (data == null) {
      throw artistPlatformFailure('tx', '获取歌手详情失败（结构不符）');
    }
    final info = data['singer_info'];
    final infoMap = (info is Map) ? info : const {};
    final rawList = data['songlist'];
    final tracks = <Track>[];
    if (rawList is List) {
      for (final raw in rawList) {
        final track = TxSearch.parseSongItem(raw);
        if (track != null) tracks.add(trackFromSourceTrack(track));
      }
    }
    return ArtistDetail(
      id: artistId,
      name: decodeName(infoMap['name']?.toString()),
      avatarUrl: 'https://y.gtimg.cn/music/photo_new/'
          'T001R500x500M000$artistId.jpg',
      description: decodeName(data['singer_brief']?.toString()),
      tracks: tracks,
      // 平台忽略 begin / num 上限 60：只有一页（见类注释）。
      hasMore: false,
    );
  }

  static Future<dynamic> _post(Map<String, dynamic> body) async {
    try {
      return await TxSearch.musicuPost(body);
    } catch (error) {
      throw SourceFailure.from(error);
    }
  }

  /// 模块数据（`data`）；业务码非 0 → 失败。
  static Map? _dataOf(dynamic response, String moduleName) {
    final module = TxSearch.moduleOf(response, moduleName);
    if (response is! Map ||
        module == null ||
        response['code'] != 0 ||
        module['code'] != 0) {
      return null;
    }
    final data = module['data'];
    return data is Map ? data : null;
  }

  /// 与搜索同一客户端指纹（`comm` 块）。
  static const Map<String, dynamic> _comm = {
    '_channelid': '0',
    '_os_version': '6.2.9200-2',
    'ct': '19',
    'cv': '2151',
    'guid': '1F70E520B2EAA7D25E11760783C53CA9',
    'patch': '118',
    'psrf_access_token_expiresAt': 0,
    'psrf_qqaccess_token': '',
    'psrf_qqopenid': '',
    'psrf_qqunionid': '',
    'tmeAppID': 'qqmusic',
    'tmeLoginType': 0,
    'uin': '0',
    'wid': '7223299733393904640',
  };

  /// 歌手搜索 `search_type`（单曲 0 / 歌词 7）。
  static const int _searchTypeSinger = 1;

  static const String _searchModule = 'music.search.SearchCgiService';
  static const String _detailModule = 'music.web_singer_info_svr';
}
