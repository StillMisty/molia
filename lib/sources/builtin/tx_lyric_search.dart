import 'dart:convert';

import 'builtin_search_runner.dart';
import 'lyric_hit.dart';
import 'lyric_search_runner.dart';
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
  }) {
    return runBuiltinLyricSearch(
      _callFor(keyword, page, limit),
      page: page,
      limit: limit,
    );
  }

  /// 平台变体面：签名 POST 体（消息块与搜索共构）/ 业务码判定 / 命中解析。
  static BuiltinLyricSearchCall _callFor(
    String keyword,
    int page,
    int limit,
  ) {
    final bodyText = jsonEncode(TxSearch.searchBody(
      keyword: keyword,
      page: page,
      limit: limit,
      searchType: _searchTypeLyric,
    ));
    return BuiltinLyricSearchCall(
      platform: 'tx',
      method: BuiltinSearchMethod.post,
      url: TxSearch.signedMusicuUrl(bodyText),
      body: bodyText,
      headers: const {'User-Agent': 'QQMusic 14090508(android 12)'},
      isInvalid: (response) => TxSearch.moduleOf(response, _searchModule) == null
          ? true
          : response['code'] != 0 ||
              TxSearch.moduleOf(response, _searchModule)!['code'] != 0,
      parseHits: (response) =>
          parseHits(TxSearch.moduleOf(response, _searchModule)?['data']),
      totalOf: (response) =>
          TxSearch.totalOf(TxSearch.moduleOf(response, _searchModule)?['data']),
    );
  }

  /// 命中列表 → 命中项（供单测复用；结构不符返回空列表）。
  static List<SourceLyricHit> parseHits(dynamic data) {
    final rawList = (data is Map &&
            data['body'] is Map &&
            (data['body'] as Map)['song'] is Map)
        ? ((data['body'] as Map)['song'] as Map)['list']
        : null;
    if (rawList is! List) return const [];
    final hits = <SourceLyricHit>[];
    for (final raw in rawList) {
      final track = TxSearch.parseSongItem(raw);
      if (track == null) continue;
      final lyric = (raw is Map) ? raw['lyric']?.toString() ?? '' : '';
      hits.add(SourceLyricHit(
        track: track,
        snippet: normalizeLyricSnippet(lyric),
      ));
    }
    return hits;
  }

  static const String _searchModule = 'music.search.SearchCgiService';
}
