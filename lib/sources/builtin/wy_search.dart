import '../source_search_result.dart';
import '../source_track.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'crypto_utils.dart';
import 'wy_music_detail.dart';

/// 网易云音乐搜索（移植自 lx-music-mobile `wy/musicSearch.js`，eapi 协议）。
class WySearch {
  static const _limit = 30;

  static Future<List<SourceTrack>> search(
    String keyword, {
    int page = 1,
    int limit = _limit,
  }) async {
    final result = await searchWithMeta(
      keyword,
      page: page,
      limit: limit,
    );
    return result.tracks;
  }

  /// 分页搜索：响应 `data.totalCount`（仅首页返回）用于计算 hasMore。
  static Future<SourceSearchResult> searchWithMeta(
    String keyword, {
    int page = 1,
    int limit = _limit,
  }) async {
    final params = eapiParams('/api/search/song/list/page', {
      'keyword': keyword,
      'needCorrect': '1',
      'channel': 'typing',
      'offset': limit * (page - 1),
      'scene': 'normal',
      'total': page == 1,
      'limit': limit,
    });

    final result = await lxHttpPost(
      'http://interface.music.163.com/eapi/batch',
      form: true,
      body: {'params': params},
      headers: {
        'User-Agent':
            'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36',
        'origin': 'https://music.163.com',
      },
      retries: BuiltinTransport.defaultRetries,
      retryIf: (json) => json is! Map || json['code'] != 200,
    );

    if (result is! Map || result['code'] != 200) {
      return SourceSearchResult.empty;
    }

    final data = result['data'];
    final resources = (data is Map && data['resources'] is List)
        ? data['resources'] as List
        : const [];
    return SourceSearchResult.fromPage(
      tracks: parseItems(resources),
      page: page,
      limit: limit,
      total: totalOf(data),
    );
  }

  /// 从响应 `data` 提取结果总数（供搜索与单元测试复用）。
  static int? totalOf(dynamic data) {
    if (data is! Map) return null;
    return parseSourceCount(data['totalCount']);
  }

  /// 解析网易云搜索响应（供搜索与单元测试复用）。
  static List<SourceTrack> parseItems(List resources) {
    final tracks = <SourceTrack>[];
    for (final item in resources) {
      final track = _parseItem(item);
      if (track != null) tracks.add(track);
    }
    return tracks;
  }

  static SourceTrack? _parseItem(dynamic rawItem) {
    if (rawItem is! Map) return null;
    final baseInfo = rawItem['baseInfo'];
    final item = (baseInfo is Map) ? baseInfo['simpleSongData'] : null;
    if (item is! Map) return null;

    final privilege = item['privilege'];
    final typeMap = WyMusicDetail.buildTypes(
      privilege: privilege is Map ? privilege : const {},
      song: item,
      flacSize: (item['sq'] is Map) ? (item['sq'] as Map)['size'] : null,
    );
    final reversedTypes = WyMusicDetail.typeList(typeMap);

    final artists = item['ar'];
    final singerNames = <String>[];
    if (artists is List) {
      for (final artist in artists) {
        final name = (artist is Map ? artist['name'] : null)?.toString();
        if (name != null && name.isNotEmpty) singerNames.add(name);
      }
    }
    final singer = singerNames.join('、');

    final album = item['al'];
    final albumName = album is Map ? album['name']?.toString() ?? '' : '';
    final albumId = album is Map ? album['id']?.toString() ?? '' : '';
    final cover = album is Map ? album['picUrl']?.toString() : null;

    final dt = item['dt'];
    final durationMs = dt is num ? dt.toInt() : int.tryParse('$dt') ?? 0;
    final durationSeconds = durationMs ~/ 1000;

    return WyMusicDetail.buildTrack(
      songId: item['id']?.toString() ?? '',
      name: item['name']?.toString() ?? '',
      singer: singer,
      albumName: albumName,
      albumId: albumId,
      img: cover,
      intervalText:
          durationSeconds > 0 ? formatPlayTime(durationSeconds) : null,
      duration:
          durationSeconds > 0 ? Duration(seconds: durationSeconds) : null,
      types: reversedTypes,
      typeMap: typeMap,
    );
  }
}
