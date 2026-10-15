import 'dart:convert';

import '../raw_track.dart';
import '../source_search_result.dart';
import '../source_track.dart';
import 'builtin_search.dart';
import 'builtin_search_runner.dart';
import 'crypto_utils.dart';

/// `searchAll` 请求（签名 URL + headers；见 [MgSearch.searchAllRequest]）。
class MgSearchAllRequest {
  final String url;
  final Map<String, String> headers;

  const MgSearchAllRequest({required this.url, required this.headers});
}

/// 咪咕音乐搜索（移植自 lx-music-mobile `mg/musicSearch.js`）。
class MgSearch {
  static const _limit = 20;
  static const _deviceId = '963B7AA0D21511ED807EE5846EC87D20';
  static const _signatureMd5 = '6cdc72a439cef99a3418d2a78aa28c73';

  /// 单曲搜索的分区开关（歌手 / 歌词搜索各自只开对应分区）。
  static const Map<String, Object> _searchSwitch = {
    'song': 1,
    'album': 0,
    'singer': 0,
    'tagSong': 1,
    'mvSong': 0,
    'bestShow': 1,
    'songlist': 0,
    'lyricSong': 0,
  };

  /// 分页搜索：响应 `songResultData.totalCount` 用于计算 hasMore。
  static Future<SourceSearchResult> searchWithMeta(
    String keyword, {
    int page = 1,
    int limit = _limit,
  }) {
    return runBuiltinSearch(
      _callFor(keyword, page, limit),
      page: page,
      limit: limit,
    );
  }

  /// `searchAll` 的签名 URL 与 headers（单曲 / 歌手 / 歌词搜索共用）。
  ///
  /// [searchSwitch] 决定返回哪些分区（如只开 `singer` 时结果在
  /// `singerResultData`）；签名与实际 `text` 绑定，必须同步构造。
  static MgSearchAllRequest searchAllRequest({
    required String text,
    required int page,
    required int limit,
    required Map<String, Object> searchSwitch,
  }) {
    final time = DateTime.now().millisecondsSinceEpoch.toString();
    final sign = md5Hex(
      '$text$_signatureMd5'
      'yyapp2d16148780a1dcc7408e06336b98cfd50'
      '$_deviceId$time',
    );
    final url = 'https://jadeite.migu.cn/music_search/v3/search/searchAll'
        '?isCorrect=0&isCopyright=1'
        '&searchSwitch=${Uri.encodeComponent(jsonEncode(searchSwitch))}'
        '&pageSize=$limit&text=${Uri.encodeComponent(text)}'
        '&pageNo=$page&sort=0&sid=USS';
    return MgSearchAllRequest(url: url, headers: {
      'uiVersion': 'A_music_3.6.1',
      'deviceId': _deviceId,
      'timestamp': time,
      'sign': sign,
      'channel': '0146921',
      'User-Agent':
          'Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30',
    });
  }

  /// 平台变体面：签名 GET / 业务码判定（`code != '000000'`）/ 解析。
  static BuiltinSearchCall _callFor(String keyword, int page, int limit) {
    final request = searchAllRequest(
      text: keyword,
      page: page,
      limit: limit,
      searchSwitch: _searchSwitch,
    );

    bool invalid(dynamic response) =>
        response is! Map || response['code'] != '000000';

    return BuiltinSearchCall(
      platform: 'mg',
      url: request.url,
      headers: request.headers,
      isInvalid: invalid,
      parseItems: (response) {
        final songResult = (response as Map)['songResultData'];
        final resultList = (songResult is Map && songResult['resultList'] is List)
            ? songResult['resultList'] as List
            : const [];
        return parseItems(resultList);
      },
      totalOf: totalOf,
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
    final track = parseResultItem(rawItem);
    if (track == null) return null;
    if (!ids.add(track.raw['copyrightId']?.toString() ?? '')) return null;
    return track;
  }

  /// 搜索结果条目（单曲 / 歌词搜索的 `result` 项；歌手歌曲的 `songItem`
  /// 同构）→ 音源曲目。
  ///
  /// 字段在各端点基本一致，仅少数键名有差异（`name`/`songName`、
  /// `mrcUrl`/`mrcurl`），一并兼容；空字段（如歌词搜索无 `img3`）自然回退。
  static SourceTrack? parseResultItem(dynamic rawItem) {
    if (rawItem is! Map) return null;
    final songId = rawItem['songId']?.toString() ?? '';
    final copyrightId = rawItem['copyrightId']?.toString() ?? '';
    if (songId.isEmpty || copyrightId.isEmpty) return null;

    final duration = rawItem['duration'];
    final durationSeconds =
        duration is num ? duration.toInt() : int.tryParse('$duration') ?? 0;
    final name = (rawItem['name'] ?? rawItem['songName'])?.toString() ?? '';

    return buildTrack(
      songId: songId,
      copyrightId: copyrightId,
      name: name,
      artist: decodeName(joinSingerNames(rawItem['singerList'])),
      artists: artistRefsOf(rawItem['singerList']),
      album: rawItem['album']?.toString() ?? '',
      albumId: rawItem['albumId']?.toString() ?? '',
      intervalText:
          durationSeconds > 0 ? formatPlayTime(durationSeconds) : null,
      duration:
          durationSeconds > 0 ? Duration(seconds: durationSeconds) : null,
      types: parseTypes(rawItem['audioFormats']),
      img: fixCoverUrl(rawItem['img3'] ?? rawItem['img2'] ?? rawItem['img1']),
      lrcUrl: rawItem['lrcUrl']?.toString(),
      mrcUrl: (rawItem['mrcUrl'] ?? rawItem['mrcurl'])?.toString(),
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

  /// 歌手列表（`singerList` / `artists`）→ 歌手引用（名字 + 平台 id）。
  static List<SourceArtistRef> artistRefsOf(dynamic singers) {
    if (singers is! List) return const [];
    final refs = <SourceArtistRef>[];
    for (final singer in singers) {
      if (singer is! Map) continue;
      final name = (singer['name'] ?? '').toString();
      if (name.isEmpty) continue;
      final id = singer['id']?.toString();
      refs.add(
        SourceArtistRef(name: name, id: (id?.isEmpty ?? true) ? null : id),
      );
    }
    return refs;
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
    List<SourceArtistRef>? artists,
  }) {
    final raw = <String, dynamic>{
      'singer': artist,
      if (artists != null && artists.isNotEmpty)
        kRawArtistsField: [for (final item in artists) item.toJson()],
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
