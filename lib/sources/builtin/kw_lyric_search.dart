import 'dart:convert';

import '../source_search_result.dart';
import 'builtin_search.dart';
import 'crypto_utils.dart';
import 'kw_discover.dart';
import 'kw_search.dart';
import 'lyric_search.dart';

/// 酷我音乐「按歌词搜歌」（`r.s?stype=lyric`）。
///
/// 与单曲搜索同端点同结构（`abslist` 条目带 `MUSICRID` / `SONGNAME` /
/// `N_MINFO` 等），额外返回 `lrc`（命中的歌词段落，纯文本）。
///
/// 注意：酷我的歌词模式是**模糊匹配**（无意义查询也会返回结果），命中排序
/// 由平台决定；片段来自 `lrc` 原样展示。
///
/// 开发环境已抓到真实响应，见 test/fixtures/lyric_search/kw.txt。
class KwLyricSearch {
  KwLyricSearch._();

  static Future<LyricSearchPage> search(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    final url = 'http://search.kuwo.cn/r.s?client=kt'
        '&all=${Uri.encodeComponent(keyword)}'
        '&stype=lyric&pn=${page - 1}&rn=$limit'
        '&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1'
        '&newver=1&ft=music&cluster=0&strategy=2012'
        '&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1';
    final text = await lxHttpGetText(url);
    return parseSearch(text, page: page, limit: limit);
  }

  /// 歌词搜索响应（文本）→ 结果页（供单测复用）。
  static LyricSearchPage parseSearch(
    String text, {
    required int page,
    required int limit,
  }) {
    dynamic body;
    try {
      body = jsonDecode(text);
    } catch (_) {
      body = KwDiscoverSource.objStr2JSON(text);
    }
    if (body is! Map || body['abslist'] is! List) {
      throw builtinPlatformFailure('kw', '歌词搜索响应非法');
    }

    final snippets = <String, String>{};
    for (final raw in body['abslist'] as List) {
      if (raw is! Map) continue;
      final id =
          raw['MUSICRID']?.toString().replaceFirst('MUSIC_', '') ?? '';
      final snippet = _normalize(raw['lrc']?.toString());
      if (id.isEmpty || snippet == null) continue;
      snippets[id] = snippet;
    }

    final tracks = KwSearch.parseItems(body);
    final total = parseSourceCount(body['TOTAL']);
    return LyricSearchPage(
      hits: [
        for (final track in tracks)
          SourceLyricHit(
            track: track,
            snippet: snippets[track.raw['songmid']?.toString() ?? ''],
          ),
      ],
      total: total,
      hasMore: total != null && total > 0 && page * limit < total,
    );
  }

  /// 歌词片段归一化：解码实体、把换行/多空格压成单空格；空串视为无片段。
  static String? _normalize(String? text) {
    final decoded =
        decodeName(text).replaceAll(RegExp(r'\s+'), ' ').trim();
    return decoded.isEmpty ? null : decoded;
  }
}
