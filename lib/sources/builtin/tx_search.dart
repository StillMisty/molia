import 'dart:convert';
import 'dart:math';

import '../source_search_result.dart';
import '../source_track.dart';
import 'builtin_search.dart';
import 'crypto_utils.dart';

/// QQ 音乐搜索（移植自 lx-music-mobile `tx/musicSearch.js`）。
class TxSearch {
  static const _limit = 50;
  static final _random = Random();

  /// 分页搜索：响应 `data.meta.sum` 用于计算 hasMore。
  static Future<SourceSearchResult> searchWithMeta(
    String keyword, {
    int page = 1,
    int limit = _limit,
    int retry = 0,
  }) async {
    if (retry > 5) return SourceSearchResult.empty;

    final body = <String, dynamic>{
      'comm': {
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
      },
      'music.search.SearchCgiService': {
        'module': 'music.search.SearchCgiService',
        'method': 'DoSearchForQQMusicDesktop',
        'param': {
          'grp': 1,
          'num_per_page': limit,
          'page_num': page,
          'query': keyword,
          'remoteplace': 'txt.newclient.top',
          'search_type': 0,
          'searchid': _searchId(),
        },
      },
    };

    // 签名必须与实际发送的 JSON 字符串完全一致
    final bodyText = jsonEncode(body);
    final sign = zzcSign(bodyText);
    final url = 'https://u.y.qq.com/cgi-bin/musics.fcg?sign=$sign';

    final result = await lxHttpPost(
      url,
      body: bodyText,
      headers: {'User-Agent': 'QQMusic 14090508(android 12)'},
    );
    if (result is! Map) return SourceSearchResult.empty;

    final req = (result['music.search.SearchCgiService'] ??
        result['req']) as Map?;
    if (result['code'] != 0 || req == null || req['code'] != 0) {
      return searchWithMeta(keyword,
          page: page, limit: limit, retry: retry + 1);
    }

    final data = req['data'];
    return SourceSearchResult.fromPage(
      tracks: parseItems(data),
      page: page,
      limit: limit,
      total: totalOf(data),
    );
  }

  /// 从响应 `data` 提取结果总数（供搜索与单元测试复用）。
  static int? totalOf(dynamic data) {
    if (data is! Map) return null;
    final meta = data['meta'];
    if (meta is! Map) return null;
    return parseSourceCount(meta['sum']);
  }

  /// 解析 QQ 音乐搜索响应（供搜索与单元测试复用）。
  static List<SourceTrack> parseItems(dynamic data) {
    final songList = (data is Map &&
            data['body'] is Map &&
            (data['body'] as Map)['song'] is Map)
        ? ((data['body'] as Map)['song'] as Map)['list']
        : null;
    if (songList is! List) return const [];

    final tracks = <SourceTrack>[];
    for (final item in songList) {
      final track = parseSongItem(item);
      if (track != null) tracks.add(track);
    }
    return tracks;
  }

  static String _searchId() {
    final buffer = StringBuffer();
    for (var i = 0; i < 32; i++) {
      buffer.write(_random.nextInt(16).toRadixString(16));
    }
    final randomSuffix = _random.nextInt(100000).toString().padLeft(5, '0');
    return '${buffer.toString().toUpperCase()}$randomSuffix';
  }

  /// 解析单条歌曲数据（搜索 / 热榜 / 歌单详情共用同一响应结构）。
  static SourceTrack? parseSongItem(dynamic rawItem) {
    if (rawItem is! Map) return null;
    final file = rawItem['file'];
    if (file is! Map || file['media_mid'] == null) return null;

    final types = <String, Map<String, dynamic>>{};

    void addType(String type, dynamic size) {
      if (size == null || size == 0) return;
      final sizeNum = size is num ? size : num.tryParse(size.toString()) ?? 0;
      if (sizeNum == 0) return;
      types[type] = {'size': sizeFormat(sizeNum)};
    }

    addType('128k', file['size_128mp3']);
    addType('320k', file['size_320mp3']);
    addType('flac', file['size_flac']);
    addType('flac24bit', file['size_hires']);

    final album = rawItem['album'];
    final albumName = album is Map ? album['name']?.toString() ?? '' : '';
    final albumId = album is Map ? album['mid']?.toString() ?? '' : '';

    final singers = rawItem['singer'];
    final singerNames = <String>[];
    if (singers is List) {
      for (final singer in singers) {
        final name = (singer is Map ? singer['name'] : null)?.toString();
        if (name != null && name.isNotEmpty) singerNames.add(name);
      }
    }
    final singer = singerNames.join('、');

    String cover = '';
    if (albumId.isNotEmpty && albumId != '空') {
      cover = 'https://y.gtimg.cn/music/photo_new/T002R500x500M000$albumId.jpg';
    } else if (singers is List && singers.isNotEmpty && singers[0] is Map) {
      final singerMid = (singers[0] as Map)['mid']?.toString() ?? '';
      if (singerMid.isNotEmpty) {
        cover =
            'https://y.gtimg.cn/music/photo_new/T001R500x500M000$singerMid.jpg';
      }
    }

    final interval = rawItem['interval'];
    final intervalSeconds =
        interval is num ? interval.toInt() : int.tryParse('$interval') ?? 0;

    final raw = <String, dynamic>{
      'singer': singer,
      'name': rawItem['title']?.toString() ?? '',
      'albumName': albumName,
      'albumId': albumId,
      'source': 'tx',
      'interval':
          intervalSeconds > 0 ? formatPlayTime(intervalSeconds) : null,
      'songId': rawItem['id']?.toString() ?? '',
      'albumMid': albumId,
      'strMediaMid': file['media_mid']?.toString() ?? '',
      'songmid': rawItem['mid']?.toString() ?? '',
      'img': cover,
      'types': types.entries.map((e) => {'type': e.key, 'size': e.value['size']}).toList(),
      '_types': types,
      'typeUrl': <String, dynamic>{},
    };

    return SourceTrack(
      sourceKey: 'tx',
      origin: 'builtin',
      title: raw['name'] as String,
      artist: singer,
      album: albumName,
      coverUrl: cover.isEmpty ? null : cover,
      duration:
          intervalSeconds > 0 ? Duration(seconds: intervalSeconds) : null,
      qualities: buildQualities(types),
      raw: raw,
    );
  }
}
