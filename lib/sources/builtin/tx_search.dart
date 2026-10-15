import 'dart:convert';
import 'dart:math';

import '../raw_track.dart';
import '../source_search_result.dart';
import '../source_track.dart';
import 'builtin_search.dart';
import 'builtin_search_runner.dart';
import 'builtin_transport.dart';
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
  }) {
    return runBuiltinSearch(
      _callFor(keyword, page, limit),
      page: page,
      limit: limit,
    );
  }

  /// 平台变体面：签名 POST 体 / 业务码判定（外层与 req 内层 `code`）/ 解析。
  static BuiltinSearchCall _callFor(String keyword, int page, int limit) {
    final body = searchBody(
      keyword: keyword,
      page: page,
      limit: limit,
      searchType: _searchTypeSong,
    );

    // 签名必须与实际发送的 JSON 字符串完全一致
    final bodyText = jsonEncode(body);
    final sign = zzcSign(bodyText);

    bool invalid(dynamic response) {
      final service = moduleOf(response, _searchModule);
      if (response is! Map || service == null) return true;
      return response['code'] != 0 || service['code'] != 0;
    }

    return BuiltinSearchCall(
      platform: 'tx',
      method: BuiltinSearchMethod.post,
      url: 'https://u.y.qq.com/cgi-bin/musics.fcg?sign=$sign',
      body: bodyText,
      headers: {'User-Agent': 'QQMusic 14090508(android 12)'},
      retryIf: (json) => json is! Map || json['code'] != 0,
      isInvalid: invalid,
      parseItems: (response) =>
          parseItems(moduleOf(response, _searchModule)?['data']),
      totalOf: (response) =>
          totalOf(moduleOf(response, _searchModule)?['data']),
    );
  }

  /// 搜索模块名（歌手 / 歌词搜索同模块，仅 `search_type` 不同）。
  static const String _searchModule = 'music.search.SearchCgiService';

  /// 单曲搜索 `search_type`（歌手 `1`、歌词 `7`）。
  static const int _searchTypeSong = 0;

  /// musicu 搜索请求体（单曲 / 歌手 / 歌词共用同一客户端指纹块）。
  static Map<String, dynamic> searchBody({
    required String keyword,
    required int page,
    required int limit,
    required int searchType,
  }) {
    return <String, dynamic>{
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
      _searchModule: {
        'module': _searchModule,
        'method': 'DoSearchForQQMusicDesktop',
        'param': {
          'grp': 1,
          'num_per_page': limit,
          'page_num': page,
          'query': keyword,
          'remoteplace': 'txt.newclient.top',
          'search_type': searchType,
          'searchid': _searchId(),
        },
      },
    };
  }

  /// musicu 签名 POST（搜索之外的模块共用；签名必须与发送体完全一致）。
  static Future<dynamic> musicuPost(Map<String, dynamic> body) {
    final bodyText = jsonEncode(body);
    final sign = zzcSign(bodyText);
    return lxHttpPost(
      'https://u.y.qq.com/cgi-bin/musics.fcg?sign=$sign',
      body: bodyText,
      headers: const {'User-Agent': 'QQMusic 14090508(android 12)'},
      retries: BuiltinTransport.defaultRetries,
    );
  }

  /// 响应中取模块数据（键即模块名；兼容旧 `req` 形态）。
  static Map? moduleOf(dynamic response, String module) {
    if (response is! Map) return null;
    final value = response[module] ?? response['req'];
    return value is Map ? value : null;
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
    final artistRefs = <SourceArtistRef>[];
    if (singers is List) {
      for (final singer in singers) {
        if (singer is! Map) continue;
        final name = singer['name']?.toString() ?? '';
        if (name.isEmpty) continue;
        final mid = singer['mid']?.toString() ?? '';
        artistRefs.add(
          SourceArtistRef(name: name, id: mid.isEmpty ? null : mid),
        );
      }
    }
    final singer = artistRefs.map((artist) => artist.name).join('、');

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
      if (artistRefs.isNotEmpty)
        kRawArtistsField: [for (final artist in artistRefs) artist.toJson()],
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
