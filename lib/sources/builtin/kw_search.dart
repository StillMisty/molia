import '../source_search_result.dart';
import '../source_track.dart';
import 'builtin_search.dart';
import 'crypto_utils.dart';

/// 酷我音乐搜索（移植自 lx-music-mobile `kw/musicSearch.js`）。
class KwSearch {
  static const _mInfoRegExp =
      r'level:(\w+),bitrate:(\d+),format:(\w+),size:([\w.]+)';
  static const _limit = 30;

  /// 分页搜索：响应中的 `TOTAL` 用于计算 hasMore。
  static Future<SourceSearchResult> searchWithMeta(
    String keyword, {
    int page = 1,
    int limit = _limit,
    int retry = 0,
  }) async {
    final url = 'http://search.kuwo.cn/r.s?client=kt'
        '&all=${Uri.encodeComponent(keyword)}'
        '&pn=${page - 1}&rn=$limit'
        '&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1'
        '&show_copyright_off=1&newver=1&ft=music&cluster=0&strategy=2012'
        '&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1';
    final result = await lxHttpGet(url);
    if (result is! Map) return SourceSearchResult.empty;

    final total = result['TOTAL']?.toString();
    final show = result['SHOW']?.toString();
    if (total != '0' && show == '0') {
      if (retry < 2) {
        return searchWithMeta(keyword,
            page: page, limit: limit, retry: retry + 1);
      }
      return SourceSearchResult.empty;
    }
    return SourceSearchResult.fromPage(
      tracks: parseItems(result),
      page: page,
      limit: limit,
      total: totalOf(result),
    );
  }

  /// 从响应提取结果总数（供搜索与单元测试复用）。
  static int? totalOf(dynamic result) {
    if (result is! Map) return null;
    return parseSourceCount(result['TOTAL']);
  }

  /// 解析酷我搜索响应（供搜索与单元测试复用）。
  static List<SourceTrack> parseItems(dynamic result) {
    if (result is! Map) return const [];
    final rawList = result['abslist'];
    if (rawList is! List) return const [];

    final tracks = <SourceTrack>[];
    for (final item in rawList) {
      final track = _parseItem(item);
      if (track != null) tracks.add(track);
    }
    return tracks;
  }

  static SourceTrack? _parseItem(dynamic rawItem) {
    if (rawItem is! Map) return null;
    final songId =
        rawItem['MUSICRID']?.toString().replaceFirst('MUSIC_', '') ?? '';
    final nMinfo = rawItem['N_MINFO']?.toString();
    if (nMinfo == null || nMinfo.isEmpty) return null;

    final interval = int.tryParse(rawItem['DURATION']?.toString() ?? '') ?? 0;
    return buildTrack(
      songId: songId,
      name: decodeName(rawItem['SONGNAME']?.toString()),
      artist: decodeName(rawItem['ARTIST']?.toString()).replaceAll('&', '、'),
      album: decodeName(rawItem['ALBUM']?.toString()),
      albumId: decodeName(rawItem['ALBUMID']?.toString()),
      intervalSeconds: interval,
      types: parseNMinfo(nMinfo),
      img: null,
    );
  }

  /// 解析 `N_MINFO` 音质段（搜索 / 榜单 / 歌单详情共用）。
  ///
  /// 大小统一大写（与榜单解析一致）；未知 bitrate 忽略。
  static Map<String, Map<String, dynamic>> parseNMinfo(String nMinfo) {
    final types = <String, Map<String, dynamic>>{};
    for (final segment in nMinfo.split(';')) {
      final match = RegExp(_mInfoRegExp).firstMatch(segment);
      if (match == null) continue;
      final size = match.group(4)!.toUpperCase();
      switch (match.group(2)) {
        case '4000':
          types['flac24bit'] = {'size': size};
          break;
        case '2000':
          types['flac'] = {'size': size};
          break;
        case '320':
          types['320k'] = {'size': size};
          break;
        case '128':
          types['128k'] = {'size': size};
          break;
      }
    }
    return types;
  }

  /// 由已解析字段构建酷我曲目（搜索 / 榜单 / 歌单详情共用同一 raw 约定）。
  static SourceTrack buildTrack({
    required String songId,
    required String name,
    required String artist,
    required String album,
    required String albumId,
    required int intervalSeconds,
    required Map<String, Map<String, dynamic>> types,
    String? img,
  }) {
    final raw = <String, dynamic>{
      'name': name,
      'singer': artist,
      'source': 'kw',
      'songmid': songId,
      'albumId': albumId,
      'interval': formatPlayTime(intervalSeconds),
      'albumName': album,
      'img': img,
      'lrc': null,
      'otherSource': null,
      'types': types.entries
          .map((e) => {'type': e.key, 'size': e.value['size']})
          .toList(),
      '_types': types,
      'typeUrl': <String, dynamic>{},
    };

    return SourceTrack(
      sourceKey: 'kw',
      origin: 'builtin',
      title: name,
      artist: artist,
      album: album,
      duration: intervalSeconds > 0 ? Duration(seconds: intervalSeconds) : null,
      qualities: buildQualities(types),
      raw: raw,
    );
  }
}
