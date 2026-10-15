import 'builtin_search.dart';
import 'lyric_search.dart';
import 'tx_search.dart';

/// QQ 音乐「按歌词搜歌」（musicu `search_type=7`，与单曲搜索同模块）。
///
/// 曲目条目与单曲搜索完全同构（复用 [TxSearch.parseSongItem]），
/// 额外返回 `lyric`（命中的歌词段落，换行分隔）。
///
/// 开发环境已抓到真实响应，见 test/fixtures/lyric_search/tx.json。
class TxLyricSearch {
  TxLyricSearch._();

  /// 歌词搜索 `search_type`（单曲 0 / 歌手 1）。
  static const int _searchTypeLyric = 7;

  static Future<LyricSearchPage> search(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    final body = TxSearch.searchBody(
      keyword: keyword,
      page: page,
      limit: limit,
      searchType: _searchTypeLyric,
    );
    final response = await TxSearch.musicuPost(body);
    return parseSearch(response, page: page, limit: limit);
  }

  /// 歌词搜索响应 → 结果页（供单测复用）。
  static LyricSearchPage parseSearch(
    dynamic response, {
    required int page,
    required int limit,
  }) {
    final service = TxSearch.moduleOf(response, _searchModule);
    if (service == null ||
        response is! Map ||
        response['code'] != 0 ||
        service['code'] != 0) {
      throw builtinPlatformFailure('tx', '歌词搜索响应非法');
    }
    final data = service['data'];
    final rawList = (data is Map &&
            data['body'] is Map &&
            (data['body'] as Map)['song'] is Map)
        ? ((data['body'] as Map)['song'] as Map)['list']
        : null;
    if (rawList is! List) {
      throw builtinPlatformFailure('tx', '歌词搜索响应非法');
    }
    final hits = <SourceLyricHit>[];
    for (final raw in rawList) {
      final track = TxSearch.parseSongItem(raw);
      if (track == null) continue;
      final lyric = (raw is Map) ? raw['lyric']?.toString() ?? '' : '';
      hits.add(SourceLyricHit(
        track: track,
        snippet: _normalize(lyric),
      ));
    }
    final total = TxSearch.totalOf(data);
    return LyricSearchPage(
      hits: hits,
      total: total,
      hasMore: total != null && total > 0 && page * limit < total,
    );
  }

  static String? _normalize(String text) {
    final decoded = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return decoded.isEmpty ? null : decoded;
  }

  static const String _searchModule = 'music.search.SearchCgiService';
}
