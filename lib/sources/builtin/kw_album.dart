import '../../data/mapping/track_mapper.dart';
import '../../domain/models/album.dart';
import '../../domain/models/track.dart';
import '../source_search_result.dart';
import 'album_utils.dart';
import 'builtin_search.dart';
import 'crypto_utils.dart';
import 'kw_discover.dart';
import 'kw_search.dart';

/// 酷我音乐专辑（`search.kuwo.cn/r.s?stype=albuminfo`）。
///
/// 接口：`GET http://search.kuwo.cn/r.s?pn={page-1}&rn={limit}&stype=albuminfo`
/// `&albumid={id}&show_copyright_off=0&encoding=utf&vipver=MUSIC_9.1.0`
/// （响应为酷我伪 JSON（单引号），解析复用发现模块的 `objStr2JSON`；
/// 开发环境已抓到真实响应，见 test/fixtures/albums/kw.json）。
///
/// 注：`www.kuwo.cn/api/www/album/albumInfo` 需要 csrf/cookie（kw_token），
/// 本环境拿不到；LX `kw/album.js` 同样以 r.s 为主路径，需真机复验。
class KwAlbum {
  KwAlbum._();

  static Future<Album> fetch(
    String albumId, {
    int page = 1,
    int limit = kAlbumPageSize,
  }) async {
    final text = await lxHttpGetText(
      'http://search.kuwo.cn/r.s?pn=${page - 1}&rn=$limit&stype=albuminfo'
      '&albumid=$albumId&show_copyright_off=0&encoding=utf&vipver=MUSIC_9.1.0',
    );
    final body = KwDiscoverSource.objStr2JSON(text);
    return parse(body, albumId: albumId, page: page, limit: limit);
  }

  /// 专辑响应 → 领域模型（供单测复用）。
  static Album parse(
    dynamic body, {
    required String albumId,
    int page = 1,
    int limit = kAlbumPageSize,
  }) {
    if (body is! Map || body['musiclist'] is! List) {
      throw albumPlatformFailure('kw', '获取专辑失败（结构不符）');
    }
    final id = body['albumid']?.toString() ?? albumId;
    final rawList = body['musiclist'] as List;
    final tracks = <Track>[];
    for (final raw in rawList) {
      final track = parseSong(raw, albumId: id);
      if (track != null) tracks.add(track);
    }

    final img = _nonEmpty(body['img']) ?? _nonEmpty(body['hts_img']);
    return Album(
      id: id,
      name: decodeName(body['name']?.toString()),
      artist: formatSinger(decodeName(body['artist']?.toString())),
      coverUrl: img,
      year: null,
      tracks: tracks,
      hasMore: albumHasMore(
        page: page,
        limit: limit,
        total: parseSourceCount(body['songnum']),
      ),
    );
  }

  /// 单曲响应 → 领域曲目（音质按 `N_MINFO` 解析，与榜单 / 歌单同一实现）。
  static Track? parseSong(dynamic raw, {required String albumId}) {
    if (raw is! Map) return null;
    final songId = (raw['id'] ?? raw['musicrid'])?.toString() ?? '';
    if (songId.isEmpty) return null;

    final types = KwSearch.parseNMinfo(raw['N_MINFO']?.toString() ?? '');
    const order = ['128k', '320k', 'flac', 'flac24bit'];
    final sorted = <String, Map<String, dynamic>>{
      for (final type in order)
        if (types.containsKey(type)) type: types[type]!,
    };

    final duration = parseSourceCount(raw['duration']) ?? 0;
    return trackFromSourceTrack(KwSearch.buildTrack(
      songId: songId,
      name: decodeName((raw['name'] ?? raw['songname'])?.toString()),
      artist: formatSinger(decodeName(raw['artist']?.toString())),
      album: decodeName(raw['album']?.toString()),
      albumId: raw['albumId']?.toString() ?? albumId,
      intervalSeconds: duration,
      types: sorted,
      img: _nonEmpty(raw['pic120']) ?? _nonEmpty(raw['img']),
    ));
  }

  static String? _nonEmpty(Object? value) {
    final text = value?.toString();
    return (text == null || text.isEmpty) ? null : text;
  }
}
