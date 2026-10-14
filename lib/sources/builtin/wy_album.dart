import '../../data/mapping/track_mapper.dart';
import '../../domain/models/album.dart';
import '../../domain/models/track.dart';
import 'album_utils.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'crypto_utils.dart';
import 'wy_music_detail.dart';

/// 网易云专辑（对应 lx-music-mobile `wy/album.js` 的 weapi 接口）。
///
/// 接口：`GET https://music.163.com/api/v1/album/{id}`，响应 `{code, album, songs}`
/// （一次返回整张专辑，无分页；开发环境已抓到真实响应，见
/// test/fixtures/albums/wy.json）。
///
/// 与 LX 的差异：LX 走 weapi 加密版 `POST /weapi/v1/album/{id}`（同一份数据，
/// 需 RSA/AES 签名）；本实现改用免签名的公开 api 端点，接口需真机复验。
class WyAlbum {
  WyAlbum._();

  static Future<Album> fetch(
    String albumId, {
    int page = 1,
    int limit = kAlbumPageSize,
  }) async {
    final body = await lxHttpGet(
      'https://music.163.com/api/v1/album/$albumId',
      headers: const {'origin': 'https://music.163.com'},
      retries: BuiltinTransport.defaultRetries,
      retryIf: _isInvalid,
    );
    return parse(body, albumId: albumId);
  }

  static bool _isInvalid(dynamic response) =>
      response is! Map || response['code'] != 200;

  /// 专辑响应 → 领域模型（供单测复用；接口无分页，hasMore 恒为 false）。
  static Album parse(dynamic body, {required String albumId}) {
    if (body is! Map || body['code'] != 200) {
      throw albumPlatformFailure(
        'wy',
        '获取专辑失败（code=${body is Map ? body['code'] : '非 JSON'}）',
      );
    }
    final album = body['album'];
    if (album is! Map) throw albumPlatformFailure('wy', '专辑数据结构不符');

    final id = album['id']?.toString() ?? albumId;
    final name = album['name']?.toString() ?? '';
    final artistInfo = album['artist'];
    final artist = artistInfo is Map ? artistInfo['name']?.toString() ?? '' : '';
    final cover = _nonEmpty(album['picUrl']) ?? _nonEmpty(album['blurPicUrl']);

    final songs = body['songs'];
    final tracks = <Track>[];
    if (songs is List) {
      for (final raw in songs) {
        final track = parseSong(
          raw,
          albumName: name,
          albumId: id,
          cover: cover,
        );
        if (track != null) tracks.add(track);
      }
    }

    return Album(
      id: id,
      name: name,
      artist: artist,
      coverUrl: cover,
      year: albumYearOf(album['publishTime']),
      tracks: tracks,
      hasMore: false,
    );
  }

  /// 单曲响应 → 领域曲目（音质按 `privilege` 推导，与歌曲详情同一实现）。
  static Track? parseSong(
    dynamic raw, {
    required String albumName,
    required String albumId,
    String? cover,
  }) {
    if (raw is! Map) return null;
    final privilege = raw['privilege'];
    final sq = raw['sq'];
    final typeMap = WyMusicDetail.buildTypes(
      privilege: privilege is Map ? privilege : const {},
      song: raw,
      flacSize: sq is Map ? sq['size'] : null,
    );

    final album = raw['al'];
    final songAlbumName = album is Map
        ? (album['name']?.toString() ?? albumName)
        : albumName;
    final songAlbumId = album is Map ? album['id'] : albumId;
    final songCover = album is Map ? album['picUrl'] : cover;

    final dt = raw['dt'];
    final durationMs = dt is num ? dt.toInt() : int.tryParse('$dt') ?? 0;

    return trackFromSourceTrack(WyMusicDetail.buildTrack(
      songId: raw['id'],
      name: raw['name']?.toString() ?? '',
      singer: _joinSingers(raw['ar']),
      albumName: songAlbumName,
      albumId: songAlbumId,
      img: songCover,
      intervalText:
          durationMs > 0 ? formatPlayTime(durationMs / 1000) : null,
      duration: durationMs > 0 ? Duration(milliseconds: durationMs) : null,
      types: WyMusicDetail.typeList(typeMap),
      typeMap: typeMap,
    ));
  }

  /// 歌手名拼接（`、` 分隔，与 LX `getSinger` 一致）。
  static String _joinSingers(Object? artists) {
    if (artists is! List) return '';
    final names = <String>[];
    for (final artist in artists) {
      final name = artist is Map ? artist['name']?.toString() : null;
      if (name != null && name.isNotEmpty) names.add(name);
    }
    return names.join('、');
  }

  static String? _nonEmpty(Object? value) {
    final text = value?.toString();
    return (text == null || text.isEmpty) ? null : text;
  }
}
