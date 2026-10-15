import 'dart:convert';

import '../../data/mapping/track_mapper.dart';
import '../../domain/models/artist.dart';
import '../../domain/models/track.dart';
import '../raw_track.dart';
import '../source_search_result.dart';
import 'artist_source.dart';
import 'builtin_search.dart';
import 'crypto_utils.dart';
import 'kw_discover.dart';
import 'kw_search.dart';

/// 酷我音乐歌手（搜索 `r.s?ft=artist`；详情 / 歌曲走 wbd `artist/*`）。
///
/// - 搜索：`GET http://search.kuwo.cn/r.s?...&ft=artist`（标准 JSON；历史上
///   出现过伪 JSON（单引号），解析先试 [jsonDecode] 再回退
///   `KwDiscoverSource.objStr2JSON`；响应含简介 / 头像 / 歌曲数）；
/// - 详情：`wbd/api/bd/artist/artist_info`（AES-128-ECB + sign，与榜单同一套
///   加密工具；响应为 percent-encoded base64 密文）；
/// - 歌曲：`wbd/api/bd/artist/artist_music`（`pn`/`rn` 分页，`data.total` 为总数）。
///
/// 开发环境已抓到真实响应，见 test/fixtures/artists/kw_*.{json,txt}。
class KwArtist {
  KwArtist._();

  /// 歌手搜索（`TOTAL` 用于分页）。
  static Future<ArtistSearchPage> search(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    final url = 'http://search.kuwo.cn/r.s?client=kt'
        '&all=${Uri.encodeComponent(keyword)}'
        '&pn=${page - 1}&rn=$limit&ft=artist'
        '&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1'
        '&show_copyright_off=1&newver=1&cluster=0&strategy=2012'
        '&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1';
    final text = await lxHttpGetText(url);
    return parseSearch(text, page: page, limit: limit);
  }

  /// 歌手搜索响应（文本）→ 结果页（供单测复用）。
  static ArtistSearchPage parseSearch(
    String text, {
    required int page,
    required int limit,
  }) {
    dynamic body;
    try {
      body = jsonDecode(text);
    } catch (_) {
      body = KwDiscoverSource.objStr2JSON(text);
    }
    if (body is! Map || body['abslist'] is! List) {
      throw artistPlatformFailure('kw', '歌手搜索响应非法');
    }
    final base = body['BASEPICPATH']?.toString() ?? '';
    final artists = <ArtistSummary>[];
    for (final raw in body['abslist'] as List) {
      if (raw is! Map) continue;
      final id = raw['ARTISTID']?.toString() ?? '';
      final name = decodeName(raw['ARTIST']?.toString());
      if (id.isEmpty || name.isEmpty) continue;
      final pic = raw['PICPATH']?.toString() ?? '';
      artists.add(ArtistSummary(
        id: id,
        name: name,
        avatarUrl: pic.isEmpty ? null : '$base$pic',
        songCount: parseSourceCount(raw['SONGNUM']),
      ));
    }
    final total = parseSourceCount(body['TOTAL']);
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
    final songs = await _fetchWbd(
      'artist_music',
      artistId: artistId,
      page: page,
      limit: limit,
    );
    dynamic info;
    try {
      info = await _fetchWbd(
        'artist_info',
        artistId: artistId,
        page: 0,
        limit: 1,
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
    final rawList = (data is Map) ? data['list'] : null;
    if (rawList is! List) {
      throw artistPlatformFailure('kw', '获取歌手歌曲失败（结构不符）');
    }

    final infoData =
        (info is Map && info['data'] is Map) ? info['data'] as Map : const {};
    final name = decodeName(infoData['name']?.toString());
    final tracks = <Track>[];
    for (final raw in rawList) {
      final track = parseSong(raw, artistId: artistId, fallbackArtist: name);
      if (track != null) tracks.add(track);
    }

    final total = parseSourceCount(data is Map ? data['total'] : null);
    return ArtistDetail(
      id: artistId,
      name: name,
      avatarUrl: _nonEmpty(infoData['pic']) ?? _nonEmpty(infoData['headPic']),
      description: decodeName(infoData['desc']?.toString()),
      tracks: tracks,
      hasMore: total != null && total > 0 && page * limit < total,
    );
  }

  /// 歌手歌曲条目 → 领域曲目（音质按 `nMinfo` / `minfo` 解析，与搜索同实现）。
  static Track? parseSong(
    dynamic raw, {
    required String artistId,
    required String fallbackArtist,
  }) {
    if (raw is! Map) return null;
    final songId = (raw['id'] ?? raw['musicrid'])?.toString() ?? '';
    if (songId.isEmpty) return null;

    final types = KwSearch.parseNMinfo(
      (raw['nMinfo'] ?? raw['n_minfo'] ?? raw['minfo'])?.toString() ?? '',
    );
    const order = ['128k', '320k', 'flac', 'flac24bit'];
    final sorted = <String, Map<String, dynamic>>{
      for (final type in order)
        if (types.containsKey(type)) type: types[type]!,
    };

    final artist = formatSinger(decodeName(raw['artist']?.toString()));
    final artistName = artist.isEmpty
        ? fallbackArtist
        : artist.split('、').first.trim();
    final duration = parseSourceCount(raw['duration']) ?? 0;
    return trackFromSourceTrack(KwSearch.buildTrack(
      songId: songId,
      name: decodeName(raw['name']?.toString()),
      artist: artist.isEmpty ? fallbackArtist : artist,
      // 歌手页曲目的歌手引用已知：名字取条目首位（缺省退回歌手名），id 即当前歌手。
      artists: artistName.isEmpty
          ? null
          : [SourceArtistRef(name: artistName, id: artistId)],
      album: decodeName(raw['album']?.toString()),
      albumId: raw['albumId']?.toString() ?? '',
      intervalSeconds: duration,
      types: sorted,
      img: _nonEmpty(raw['pic300']) ?? _nonEmpty(raw['pic']),
    ));
  }

  /// wbd 歌手接口请求（签名 GET → 解密；业务码非 200 抛 [SourceFailure]）。
  static Future<dynamic> _fetchWbd(
    String path, {
    required String artistId,
    required int page,
    required int limit,
  }) async {
    final params = kwWbdBuildParam({
      'uid': '',
      'devId': '',
      'sFrom': 'kuwo_sdk',
      'user_type': 'AP',
      'carSource': 'kwplayercar_ar_6.0.1.0_apk_keluze.apk',
      'id': artistId,
      'pn': page - 1,
      'rn': limit,
    });
    final text = await lxHttpGetText(
      'https://wbd.kuwo.cn/api/bd/artist/$path?$params',
      headers: const {
        'User-Agent': 'kwplayercar_ar_6.0.1.0_apk_keluze.apk',
      },
    );
    final decoded = kwWbdDecodeData(text);
    if (decoded is! Map || decoded['code'] != 200) {
      throw artistPlatformFailure('kw', '歌手接口业务拒绝');
    }
    return decoded;
  }

  static String? _nonEmpty(Object? value) {
    final text = decodeName(value?.toString());
    return text.isEmpty ? null : text;
  }
}
