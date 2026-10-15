import '../../data/mapping/track_mapper.dart';
import '../../domain/models/album.dart';
import '../../domain/models/track.dart';
import '../source_search_result.dart';
import 'album_utils.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'crypto_utils.dart';
import 'mg_search.dart';

/// 咪咕音乐专辑（`queryAlbumSong` + `MIGUM3.0/resource/album`）。
///
/// - 曲目：`GET http://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/queryAlbumSong`
///   `?albumId={id}&pageNo={page}`（响应 `data.songList`；开发环境已抓到真实
///   响应，见 test/fixtures/albums/mg_songs.json）；
/// - 元信息：`GET https://app.c.nf.migu.cn/MIGUM3.0/resource/album/v2.0`
///   `?albumId={id}`（专辑名 / 歌手 / 封面 / 发行日期，见 mg_info.json）。
///
/// 注：接口忽略 `pageSize`、按自身页大小分页（小专辑一次全量返回），
/// hasMore 按「已取条数」推进推断；LX `mg/album.js` 同一端点，需真机复验。
class MgAlbum {
  MgAlbum._();

  static Future<Album> fetch(
    String albumId, {
    int page = 1,
    int limit = kAlbumPageSize,
  }) async {
    final songs = await lxHttpGet(
      'http://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/queryAlbumSong'
      '?albumId=$albumId&pageNo=$page',
      retries: BuiltinTransport.defaultRetries,
      retryIf: _isInvalid,
    );
    // 元信息 best-effort：接口失败时专辑页退回入口携带的名称。
    dynamic info;
    try {
      info = await lxHttpGet(
        'https://app.c.nf.migu.cn/MIGUM3.0/resource/album/v2.0?albumId=$albumId',
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
      response is! Map || response['code'] != '000000';

  /// 曲目 + 元信息响应 → 领域模型（供单测复用）。
  static Album parse({
    required dynamic songs,
    dynamic info,
    required String albumId,
    int page = 1,
    int limit = kAlbumPageSize,
  }) {
    if (songs is! Map || songs['code'] != '000000') {
      throw albumPlatformFailure(
        'mg',
        '获取专辑失败（code=${songs is Map ? songs['code'] : '非 JSON'}）',
      );
    }
    final data = songs['data'];
    if (data is! Map) throw albumPlatformFailure('mg', '专辑数据结构不符');

    final rawList = data['songList'] is List ? data['songList'] as List : const [];
    final tracks = <Track>[];
    for (final raw in rawList) {
      final track = parseSong(raw, albumId: albumId);
      if (track != null) tracks.add(track);
    }

    final infoData = (info is Map && info['data'] is Map) ? info['data'] as Map : const {};
    final total = parseSourceCount(
      infoData['totalCount'] ?? data['totalCount'],
    );
    return Album(
      id: infoData['albumId']?.toString() ?? albumId,
      name: infoData['title']?.toString() ?? '',
      artist: infoData['singer']?.toString() ?? '',
      coverUrl: _coverOf(infoData['imgItems']),
      year: albumYearOf(infoData['publishDate']),
      tracks: tracks,
      // 接口忽略 pageSize：按「已取条数 × 页码」推进推断是否还有下一页。
      hasMore: total != null && total > 0 && page * tracks.length < total,
    );
  }

  /// 单曲响应 → 领域曲目（`newRateFormats` 音质 / `albumImgs` 封面）。
  static Track? parseSong(dynamic raw, {required String albumId}) {
    if (raw is! Map) return null;
    final songId = raw['songId']?.toString() ?? '';
    final copyrightId = raw['copyrightId']?.toString() ?? '';
    if (songId.isEmpty || copyrightId.isEmpty) return null;

    final duration = _durationOf(raw);
    final artist = _nonEmpty(raw['singer']) ??
        MgSearch.joinSingerNames(raw['singerList']);
    return trackFromSourceTrack(MgSearch.buildTrack(
      songId: songId,
      copyrightId: copyrightId,
      name: raw['songName']?.toString() ?? '',
      artist: artist,
      artists: MgSearch.artistRefsOf(raw['singerList']),
      album: raw['album']?.toString() ?? '',
      albumId: raw['albumId']?.toString() ?? albumId,
      intervalText: duration > 0 ? formatPlayTime(duration) : null,
      duration: duration > 0 ? Duration(seconds: duration) : null,
      types: MgSearch.parseTypes(
        raw['newRateFormats'] ?? raw['audioFormats'],
      ),
      img: _songCover(raw),
      lrcUrl: raw['lrcUrl']?.toString(),
      mrcUrl: raw['mrcUrl']?.toString(),
      trcUrl: raw['trcUrl']?.toString(),
    ));
  }

  /// 时长（秒）：优先 `duration` 秒数，否则解析 `mm:ss` / `hh:mm:ss` 文本。
  static int _durationOf(Map raw) {
    final duration = parseSourceCount(raw['duration']);
    if (duration != null && duration > 0) return duration;
    final length = raw['length']?.toString() ?? '';
    final parts = length.split(':');
    if (parts.isEmpty) return 0;
    var seconds = 0;
    for (final part in parts) {
      seconds = seconds * 60 + (int.tryParse(part) ?? 0);
    }
    return seconds;
  }

  /// 曲目封面：`albumImgs` 首图优先，回退 `img3/img2/img1`（相对路径补全）。
  static String? _songCover(Map raw) {
    final imgs = raw['albumImgs'];
    if (imgs is List && imgs.isNotEmpty && imgs.first is Map) {
      final url = MgSearch.fixCoverUrl((imgs.first as Map)['img']);
      if (url != null && url.isNotEmpty) return url;
    }
    return MgSearch.fixCoverUrl(raw['img3'] ?? raw['img2'] ?? raw['img1']);
  }

  /// 专辑封面（`imgItems` 首图）。
  static String? _coverOf(Object? imgItems) {
    if (imgItems is! List || imgItems.isEmpty || imgItems.first is! Map) {
      return null;
    }
    final url = MgSearch.fixCoverUrl((imgItems.first as Map)['img']);
    return (url == null || url.isEmpty) ? null : url;
  }

  static String? _nonEmpty(Object? value) {
    final text = value?.toString();
    return (text == null || text.isEmpty) ? null : text;
  }
}
