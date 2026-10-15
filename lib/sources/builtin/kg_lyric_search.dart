import '../source_search_result.dart';
import 'crypto_utils.dart';
import 'kg_search.dart';
import 'lyric_hit.dart';
import 'lyric_search_runner.dart';

/// 酷狗音乐「按歌词搜歌」（`songsearch.kugou.com/lyric_search`）。
///
/// 条目字段与单曲搜索**不完全同构**：音质在 `FileHash` / `320Hash` / `SQHash`
/// 与 `Res`（无损 24bit），歌名歌手在 `SongName` / `SingerName`（无专辑名），
/// 封面 `Image` 带 `{size}` 占位，命中的歌词段落是 `Lyric`。
///
/// 开发环境已抓到真实响应，见 test/fixtures/lyric_search/kg.json。
class KgLyricSearch {
  KgLyricSearch._();

  static Future<LyricSearchPage> search(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) {
    return runBuiltinLyricSearch(
      _callFor(keyword, page, limit),
      page: page,
      limit: limit,
    );
  }

  /// 平台变体面：请求 / 业务码判定（`error_code != 0`）/ 命中解析。
  static BuiltinLyricSearchCall _callFor(
    String keyword,
    int page,
    int limit,
  ) {
    return BuiltinLyricSearchCall(
      platform: 'kg',
      url: 'https://songsearch.kugou.com/lyric_search'
          '?keyword=${Uri.encodeComponent(keyword)}&page=$page&pagesize=$limit',
      isInvalid: (response) =>
          response is! Map || response['error_code'] != 0,
      parseHits: (response) {
        final data = (response as Map)['data'];
        final rawList = (data is Map) ? data['lists'] : null;
        if (rawList is! List) return null;
        return parseHits(rawList);
      },
      totalOf: (response) {
        final data = (response as Map)['data'];
        return parseSourceCount(data is Map ? data['total'] : null);
      },
    );
  }

  /// 命中列表 → 命中项（供单测复用）。
  static List<SourceLyricHit> parseHits(List<dynamic> rawList) {
    final hits = <SourceLyricHit>[];
    for (final raw in rawList) {
      final hit = parseItem(raw);
      if (hit != null) hits.add(hit);
    }
    return hits;
  }

  /// 歌词搜索条目 → 命中项（供单测复用）。
  static SourceLyricHit? parseItem(dynamic raw) {
    if (raw is! Map) return null;
    final songId = raw['MixSongID']?.toString() ?? '';
    final hash = raw['FileHash']?.toString() ?? '';
    if (songId.isEmpty || hash.isEmpty) return null;

    final types = <String, Map<String, dynamic>>{};
    KgSearch.addKgQuality(types, '128k',
        size: raw['FileSize'], hash: hash, requireHash: true);
    KgSearch.addKgQuality(types, '320k',
        size: raw['320Size'], hash: raw['320Hash'], requireHash: true);
    KgSearch.addKgQuality(types, 'flac',
        size: raw['SQSize'], hash: raw['SQHash'], requireHash: true);
    final res = raw['Res'];
    if (res is Map) {
      KgSearch.addKgQuality(types, 'flac24bit',
          size: res['FileSize'], hash: res['Hash'], requireHash: true);
    }

    final duration = parseSourceCount(raw['TimeLength']) ?? 0;
    final image = raw['Image']?.toString() ?? '';
    final track = KgSearch.buildTrack(
      songId: songId,
      name: decodeName(raw['SongName']?.toString()),
      artist: decodeName(raw['SingerName']?.toString()),
      artists: KgSearch.artistRefsOf(raw['Singers']),
      // 歌词搜索响应不含专辑名（只有 id）；专辑行据此隐藏。
      album: '',
      albumId: raw['AlbumID']?.toString() ?? '',
      hash: hash,
      intervalText: duration > 0 ? formatPlayTime(duration) : null,
      duration: duration > 0 ? Duration(seconds: duration) : null,
      types: types,
      rawInterval: duration,
      img: image.isEmpty ? null : image.replaceAll('{size}', '480'),
    );
    return SourceLyricHit(
      track: track,
      snippet: normalizeLyricSnippet(raw['Lyric']?.toString()),
    );
  }
}
