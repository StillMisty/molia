import '../source_search_result.dart';
import '../source_track.dart';
import 'builtin_search.dart';
import 'crypto_utils.dart';

/// 咪咕音乐搜索（移植自 lx-music-mobile `mg/musicSearch.js`）。
class MgSearch {
  static const _limit = 20;
  static const _deviceId = '963B7AA0D21511ED807EE5846EC87D20';
  static const _signatureMd5 = '6cdc72a439cef99a3418d2a78aa28c73';
  static const _searchSwitch =
      '%7B%22song%22%3A1%2C%22album%22%3A0%2C%22singer%22%3A0%2C%22tagSong%22%3A1%2C%22mvSong%22%3A0%2C%22bestShow%22%3A1%2C%22songlist%22%3A0%2C%22lyricSong%22%3A0%7D';

  /// 分页搜索：响应 `songResultData.totalCount` 用于计算 hasMore。
  static Future<SourceSearchResult> searchWithMeta(
    String keyword, {
    int page = 1,
    int limit = _limit,
    int retry = 0,
  }) async {
    if (retry > 3) return SourceSearchResult.empty;

    final time = DateTime.now().millisecondsSinceEpoch.toString();
    final sign = md5Hex(
      '$keyword$_signatureMd5'
      'yyapp2d16148780a1dcc7408e06336b98cfd50'
      '$_deviceId$time',
    );

    final url = 'https://jadeite.migu.cn/music_search/v3/search/searchAll'
        '?isCorrect=0&isCopyright=1&searchSwitch=$_searchSwitch'
        '&pageSize=$limit&text=${Uri.encodeComponent(keyword)}'
        '&pageNo=$page&sort=0&sid=USS';

    final result = await lxHttpGet(
      url,
      headers: {
        'uiVersion': 'A_music_3.6.1',
        'deviceId': _deviceId,
        'timestamp': time,
        'sign': sign,
        'channel': '0146921',
        'User-Agent':
            'Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30',
      },
    );

    if (result is! Map || result['code'] != '000000') {
      return searchWithMeta(keyword,
          page: page, limit: limit, retry: retry + 1);
    }

    final songResult = result['songResultData'];
    final resultList = (songResult is Map && songResult['resultList'] is List)
        ? songResult['resultList'] as List
        : const [];
    return SourceSearchResult.fromPage(
      tracks: parseItems(resultList),
      page: page,
      limit: limit,
      total: totalOf(result),
    );
  }

  /// 从响应提取结果总数（供搜索与单元测试复用）。
  static int? totalOf(dynamic result) {
    if (result is! Map) return null;
    final songResult = result['songResultData'];
    if (songResult is! Map) return null;
    return parseSourceCount(songResult['totalCount']);
  }

  /// 解析咪咕搜索响应（供搜索与单元测试复用）。
  static List<SourceTrack> parseItems(List resultList) {
    final tracks = <SourceTrack>[];
    final ids = <String>{};
    for (final group in resultList) {
      if (group is! List) continue;
      for (final item in group) {
        final track = _parseItem(item, ids);
        if (track != null) tracks.add(track);
      }
    }
    return tracks;
  }

  static SourceTrack? _parseItem(dynamic rawItem, Set<String> ids) {
    if (rawItem is! Map) return null;
    final songId = rawItem['songId']?.toString() ?? '';
    final copyrightId = rawItem['copyrightId']?.toString() ?? '';
    if (songId.isEmpty || copyrightId.isEmpty) return null;
    if (!ids.add(copyrightId)) return null;

    final duration = rawItem['duration'];
    final durationSeconds =
        duration is num ? duration.toInt() : int.tryParse('$duration') ?? 0;

    return buildTrack(
      songId: songId,
      copyrightId: copyrightId,
      name: rawItem['name']?.toString() ?? '',
      artist: decodeName(joinSingerNames(rawItem['singerList'])),
      album: rawItem['album']?.toString() ?? '',
      albumId: rawItem['albumId']?.toString() ?? '',
      intervalText:
          durationSeconds > 0 ? formatPlayTime(durationSeconds) : null,
      duration:
          durationSeconds > 0 ? Duration(seconds: durationSeconds) : null,
      types: parseTypes(rawItem['audioFormats']),
      img: fixCoverUrl(rawItem['img3'] ?? rawItem['img2'] ?? rawItem['img1']),
      lrcUrl: rawItem['lrcUrl']?.toString(),
      mrcUrl: rawItem['mrcurl']?.toString(),
      trcUrl: rawItem['trcUrl']?.toString(),
    );
  }

  /// 解析咪咕 `audioFormats` / `newRateFormats` 音质列表（搜索 / 榜单 / 歌单共用）。
  ///
  /// 大小字段按端点差异依次回退（`size` / `androidSize` / `asize` / `isize`）。
  static Map<String, Map<String, dynamic>> parseTypes(dynamic formats) {
    final types = <String, Map<String, dynamic>>{};
    if (formats is! List) return types;
    for (final format in formats) {
      if (format is! Map) continue;
      final size = format['size'] ??
          format['androidSize'] ??
          format['asize'] ??
          format['isize'];
      final sizeNum = size is num ? size : num.tryParse('$size') ?? 0;
      final sizeText = sizeNum > 0 ? sizeFormat(sizeNum) : null;
      final type = switch (format['formatType']) {
        'PQ' => '128k',
        'HQ' => '320k',
        'SQ' => 'flac',
        'ZQ' || 'ZQ24' => 'flac24bit',
        _ => null,
      };
      if (type != null) types[type] = {'size': sizeText};
    }
    return types;
  }

  /// 补齐咪咕封面相对路径为完整 URL（搜索 / 榜单 / 歌单共用）。
  static String? fixCoverUrl(Object? img) {
    final url = img?.toString();
    if (url == null || url.isEmpty) return null;
    if (RegExp(r'https?:').hasMatch(url)) return url;
    return 'http://d.musicapp.migu.cn$url';
  }

  /// 拼接歌手名（`、` 分隔；名字为空忽略）。
  static String joinSingerNames(dynamic singers) {
    if (singers is! List) return '';
    final names = <String>[];
    for (final singer in singers) {
      final name = (singer is Map ? singer['name'] : null)?.toString();
      if (name != null && name.isNotEmpty) names.add(name);
    }
    return names.join('、');
  }

  /// 由已解析字段构建咪咕曲目（搜索 / 榜单 / 歌单共用同一 raw 约定）。
  static SourceTrack buildTrack({
    required String songId,
    required String copyrightId,
    required String name,
    required String artist,
    required String album,
    required String albumId,
    required String? intervalText,
    required Duration? duration,
    required Map<String, Map<String, dynamic>> types,
    String? img,
    String? lrcUrl,
    String? mrcUrl,
    String? trcUrl,
  }) {
    final raw = <String, dynamic>{
      'singer': artist,
      'name': name,
      'albumName': album,
      'albumId': albumId,
      'songmid': songId,
      'copyrightId': copyrightId,
      'source': 'mg',
      'interval': intervalText,
      'img': img,
      'lrc': null,
      'lrcUrl': lrcUrl,
      'mrcUrl': mrcUrl,
      'trcUrl': trcUrl,
      'otherSource': null,
      'types': types.entries
          .map((e) => {'type': e.key, 'size': e.value['size']})
          .toList(),
      '_types': types,
      'typeUrl': <String, dynamic>{},
    };

    return SourceTrack(
      sourceKey: 'mg',
      origin: 'builtin',
      title: name,
      artist: artist,
      album: album,
      coverUrl: (img?.isNotEmpty ?? false) ? img : null,
      duration: duration,
      qualities: buildQualities(types),
      raw: raw,
    );
  }
}
