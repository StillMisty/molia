import '../source_search_result.dart';
import 'lyric_hit.dart';
import 'lyric_search_runner.dart';
import 'mg_search.dart';

/// 咪咕音乐「按歌词搜歌」（jadeite `searchAll` + `searchSwitch.lyricSong=1`）。
///
/// 条目字段与单曲搜索同构（`songId` / `copyrightId` / `singerList` / `album` /
/// `audioFormats` 等，复用 [MgSearch.parseResultItem]），命中片段来自
/// `multiLyricStr`（命中的歌词段落），缺失时回退 `highlightLyricStrList`。
///
/// 注意：平台对歌词命中的排序偏翻唱（原唱常在后面），本实现原样展示。
///
/// 开发环境已抓到真实响应，见 test/fixtures/lyric_search/mg.json。
class MgLyricSearch {
  MgLyricSearch._();

  /// 只开歌词分区（其余分区关闭，结果在 `lyricResultData`）。
  static const Map<String, Object> _lyricSwitch = {
    'song': 0,
    'album': 0,
    'singer': 0,
    'tagSong': 0,
    'mvSong': 0,
    'bestShow': 0,
    'songlist': 0,
    'lyricSong': 1,
  };

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

  /// 平台变体面：签名 GET（与单曲搜索共用 [MgSearch.searchAllRequest]）/
  /// 业务码判定 / 命中解析。
  static BuiltinLyricSearchCall _callFor(
    String keyword,
    int page,
    int limit,
  ) {
    final request = MgSearch.searchAllRequest(
      text: keyword,
      page: page,
      limit: limit,
      searchSwitch: _lyricSwitch,
    );
    return BuiltinLyricSearchCall(
      platform: 'mg',
      url: request.url,
      headers: request.headers,
      isInvalid: (response) =>
          response is! Map || response['code'] != '000000',
      parseHits: (response) {
        final lyricData = (response as Map)['lyricResultData'];
        final rawList = (lyricData is Map) ? lyricData['result'] : null;
        if (rawList is! List) return null;
        return parseHits(rawList);
      },
      totalOf: (response) {
        final lyricData = (response as Map)['lyricResultData'];
        return parseSourceCount(
          lyricData is Map ? lyricData['totalCount'] : null,
        );
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
    final track = MgSearch.parseResultItem(raw);
    if (track == null) return null;
    final map = raw as Map;
    return SourceLyricHit(
      track: track,
      snippet: _snippetOf(map['multiLyricStr'], map['highlightLyricStrList']),
    );
  }

  /// 命中片段：优先 `multiLyricStr`（歌词段落），否则 `highlightLyricStrList`
  /// （命中词数组，用 `、` 连接）。
  static String? _snippetOf(Object? multiLyric, Object? highlights) {
    final lyric = normalizeLyricSnippet(multiLyric?.toString());
    if (lyric != null) return lyric;
    if (highlights is List) {
      final words = [
        for (final word in highlights)
          if (word?.toString().trim().isNotEmpty ?? false) word.toString().trim(),
      ];
      if (words.isNotEmpty) return words.join('、');
    }
    return null;
  }
}
