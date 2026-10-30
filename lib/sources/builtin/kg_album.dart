import '../../domain/models/album.dart';
import '../../domain/models/track.dart';
import '../source_search_result.dart';
import 'album_utils.dart';
import 'builtin_cover_urls.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'kg_search.dart';

/// 酷狗音乐专辑（`mobilecdn.kugou.com/api/v3/album/song` + `album/info`）。
///
/// - 曲目：`GET http://mobilecdn.kugou.com/api/v3/album/song?albumid={id}`
///   （page/pagesize 分页，响应 `data.info` 与搜索条目同源：hash/音质/时长，
///   歌名歌手由 `filename`（`歌手 - 歌名`）拆分；开发环境已抓到真实响应，
///   见 test/fixtures/albums/kg_songs.json）；
/// - 元信息：`GET .../album/info?albumid={id}`（专辑名 / 歌手 / 封面 / 发行时间；
///   best-effort，失败不阻断曲目展示）。
///
/// 注：LX `kg/album.js` 走 `mobiles.kugou.com` + `gateway.kugou.com` 两步
/// 补全曲目信息；本实现改用同一数据源的单端点版本（字段等价），需真机复验。
class KgAlbum {
  KgAlbum._();

  static Future<Album> fetch(
    String albumId, {
    int page = 1,
    int limit = kAlbumPageSize,
  }) async {
    final songs = await lxHttpGet(
      'http://mobilecdn.kugou.com/api/v3/album/song?version=9108'
      '&albumid=$albumId&plat=0&pagesize=$limit&area_code=0&page=$page'
      '&with_res_tag=0',
      retries: BuiltinTransport.defaultRetries,
      retryIf: _isInvalid,
    );
    // 元信息 best-effort：接口失败时专辑页退回入口携带的名称。
    dynamic info;
    try {
      info = await lxHttpGet(
        'http://mobilecdn.kugou.com/api/v3/album/info?albumid=$albumId'
        '&with_res_tag=0',
        retries: BuiltinTransport.defaultRetries,
      );
    } catch (_) {
      info = null;
    }
    return parse(
      songs: songs,
      info: info,
      albumId: albumId,
      page: page,
      limit: limit,
    );
  }

  static bool _isInvalid(dynamic response) =>
      response is! Map || response['status'] != 1 || response['errcode'] != 0;

  /// 曲目 + 元信息响应 → 领域模型（供单测复用）。
  static Album parse({
    required dynamic songs,
    dynamic info,
    required String albumId,
    int page = 1,
    int limit = kAlbumPageSize,
  }) {
    if (songs is! Map || songs['status'] != 1 || songs['errcode'] != 0) {
      throw albumPlatformFailure(
        'kg',
        '获取专辑失败（errcode=${songs is Map ? songs['errcode'] : '非 JSON'}）',
      );
    }
    final data = songs['data'];
    if (data is! Map) throw albumPlatformFailure('kg', '专辑数据结构不符');

    final infoData = (info is Map && info['data'] is Map) ? info['data'] as Map : const {};
    final albumName = infoData['albumname']?.toString() ?? '';
    final artist = infoData['singername']?.toString() ?? '';
    final coverUrl = kgCoverUrlOf(infoData);

    final rawList = data['info'] is List ? data['info'] as List : const [];
    final tracks = <Track>[];
    for (final raw in rawList) {
      final track = parseSong(
        raw,
        albumName: albumName,
        albumId: albumId,
        fallbackArtist: artist,
        // 专辑歌曲接口不带封面；列表行复用专辑封面，避免整页占位图。
        img: coverUrl,
      );
      if (track != null) tracks.add(track);
    }

    return Album(
      id: infoData['albumid']?.toString() ?? albumId,
      name: albumName,
      artist: artist,
      coverUrl: coverUrl,
      year: albumYearOf(infoData['publishtime']),
      tracks: tracks,
      hasMore: albumHasMore(
        page: page,
        limit: limit,
        total: parseSourceCount(data['total']),
      ),
    );
  }

  /// 单曲响应 → 领域曲目（委托 [KgSearch.parseListSong]，保持专辑侧签名）。
  static Track? parseSong(
    dynamic raw, {
    required String albumName,
    required String albumId,
    String fallbackArtist = '',
    String? img,
  }) =>
      KgSearch.parseListSong(
        raw,
        albumName: albumName,
        albumId: albumId,
        fallbackArtist: fallbackArtist,
        img: img,
      );
}
