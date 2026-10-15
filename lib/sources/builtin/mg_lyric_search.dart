import '../source_search_result.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'lyric_search.dart';
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
  }) async {
    final request = MgSearch.searchAllRequest(
      text: keyword,
      page: page,
      limit: limit,
      searchSwitch: _lyricSwitch,
    );
    final body = await lxHttpGet(
      request.url,
      headers: request.headers,
      retries: BuiltinTransport.defaultRetries,
    );
    return parseSearch(body, page: page, limit: limit);
  }

  /// 歌词搜索响应 → 结果页（供单测复用）。
  static LyricSearchPage parseSearch(
    dynamic body, {
    required int page,
    required int limit,
  }) {
    final lyricData = (body is Map) ? body['lyricResultData'] : null;
    final rawList = (lyricData is Map) ? lyricData['result'] : null;
    if (rawList is! List) {
      throw builtinPlatformFailure('mg', '歌词搜索响应非法');
    }
    final hits = <SourceLyricHit>[];
    for (final raw in rawList) {
      final hit = parseItem(raw);
      if (hit != null) hits.add(hit);
    }
    final total =
        parseSourceCount(lyricData is Map ? lyricData['totalCount'] : null);
    return LyricSearchPage(
      hits: hits,
      total: total,
      hasMore: total != null && total > 0 && page * limit < total,
    );
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
    final lyric = _normalize(multiLyric?.toString());
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

  static String? _normalize(String? text) {
    if (text == null) return null;
    final decoded = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return decoded.isEmpty ? null : decoded;
  }
}
