import '../source_search_result.dart';
import '../source_track.dart';
import 'builtin_search.dart';
import 'crypto_utils.dart';

/// 酷狗音乐搜索（移植自 lx-music-mobile `kg/musicSearch.js`）。
class KgSearch {
  static const _limit = 30;

  /// 分页搜索：响应 `data.total` 用于计算 hasMore。
  static Future<SourceSearchResult> searchWithMeta(
    String keyword, {
    int page = 1,
    int limit = _limit,
    int retry = 0,
  }) async {
    final url = 'https://songsearch.kugou.com/song_search_v2'
        '?keyword=${Uri.encodeComponent(keyword)}'
        '&page=$page&pagesize=$limit&userid=0&clientver=&platform=WebFilter'
        '&filter=2&iscorrection=1&privilege_filter=0&area_code=1';
    final result = await lxHttpGet(url);
    if (result is! Map || result['error_code'] != 0) {
      if (retry < 3) {
        return searchWithMeta(keyword,
            page: page, limit: limit, retry: retry + 1);
      }
      return SourceSearchResult.empty;
    }
    final data = result['data'];
    final rawList = (data is Map) ? data['lists'] : null;
    if (rawList is! List) return SourceSearchResult.empty;
    return SourceSearchResult.fromPage(
      tracks: parseItems(rawList),
      page: page,
      limit: limit,
      total: totalOf(result),
    );
  }

  /// 从响应提取结果总数（供搜索与单元测试复用）。
  static int? totalOf(dynamic result) {
    if (result is! Map) return null;
    final data = result['data'];
    if (data is! Map) return null;
    return parseSourceCount(data['total']);
  }

  /// 解析酷狗搜索响应（供搜索与单元测试复用）。
  static List<SourceTrack> parseItems(List rawList) {
    final ids = <String>{};
    final tracks = <SourceTrack>[];
    void addItem(dynamic item) {
      if (item is! Map) return;
      final key = '${item['Audioid']}${item['FileHash']}';
      if (!ids.add(key)) return;
      final track = _parseItem(item);
      if (track != null) tracks.add(track);
    }

    for (final item in rawList) {
      addItem(item);
      if (item is Map && item['Grp'] is List) {
        for (final child in item['Grp'] as List) {
          addItem(child);
        }
      }
    }
    return tracks;
  }

  static SourceTrack? _parseItem(Map item) {
    final types = <String, Map<String, dynamic>>{};
    addKgQuality(types, '128k',
        size: item['FileSize'], hash: item['FileHash'], requireHash: true);
    addKgQuality(types, '320k',
        size: item['HQFileSize'], hash: item['HQFileHash'], requireHash: true);
    addKgQuality(types, 'flac',
        size: item['SQFileSize'], hash: item['SQFileHash'], requireHash: true);
    addKgQuality(types, 'flac24bit',
        size: item['ResFileSize'], hash: item['ResFileHash'], requireHash: true);

    final singers = item['Singers'];
    final singerNames = <String>[];
    if (singers is List) {
      for (final singer in singers) {
        final name = (singer is Map ? singer['name'] : null)?.toString();
        if (name != null && name.isNotEmpty) singerNames.add(name);
      }
    }

    final duration = item['Duration'] is num
        ? (item['Duration'] as num).toInt()
        : int.tryParse(item['Duration']?.toString() ?? '') ?? 0;
    final suffix = item['Suffix']?.toString() ?? '';
    final name =
        '${item['OriSongName'] ?? ''}${suffix.isNotEmpty ? ' $suffix' : ''}';
    return buildTrack(
      songId: item['Audioid']?.toString() ?? '',
      name: decodeName(name),
      artist: decodeName(singerNames.join('、')),
      album: decodeName(item['AlbumName']?.toString()),
      albumId: item['AlbumID']?.toString() ?? '',
      hash: item['FileHash']?.toString() ?? '',
      intervalText: formatPlayTime(duration),
      duration: duration > 0 ? Duration(seconds: duration) : null,
      types: types,
      rawInterval: duration,
    );
  }

  /// 记录一档酷狗音质（`sizeFormat(size)` + hash；[requireHash] 时缺 hash 跳过）。
  static void addKgQuality(
    Map<String, Map<String, dynamic>> types,
    String type, {
    required dynamic size,
    required dynamic hash,
    bool requireHash = false,
  }) {
    if (requireHash && hash == null) return;
    final sizeNum = size is num ? size : num.tryParse('$size') ?? 0;
    if (sizeNum == 0) return;
    types[type] = {'size': sizeFormat(sizeNum), 'hash': hash?.toString()};
  }

  /// 由已解析字段构建酷狗曲目（搜索 / 榜单 / 歌单详情共用同一 raw 约定）。
  static SourceTrack buildTrack({
    required String songId,
    required String name,
    required String artist,
    required String album,
    required String albumId,
    required String hash,
    required String? intervalText,
    required Duration? duration,
    required Map<String, Map<String, dynamic>> types,
    int? rawInterval,
  }) {
    final raw = <String, dynamic>{
      'singer': artist,
      'name': name,
      'albumName': album,
      'albumId': albumId,
      'songmid': songId,
      'source': 'kg',
      'interval': intervalText,
      if (rawInterval != null) '_interval': rawInterval,
      'img': null,
      'lrc': null,
      'otherSource': null,
      'hash': hash,
      'types': types.entries
          .map((e) => {
                'type': e.key,
                'size': e.value['size'],
                'hash': e.value['hash'],
              })
          .toList(),
      '_types': types,
      'typeUrl': <String, dynamic>{},
    };

    return SourceTrack(
      sourceKey: 'kg',
      origin: 'builtin',
      title: name,
      artist: artist,
      album: album,
      duration: duration,
      qualities: buildQualities(types),
      raw: raw,
    );
  }
}
