import '../../data/cache/request_cache.dart';
import 'builtin_search.dart';
import 'crypto_utils.dart';

/// 网易云热搜词（移植自 lx-music-mobile `wy/hotSearch.js`）。
///
/// eapi `/api/search/chart/detail`（`HOT_SEARCH_SONG#@#`）→ itemList.searchWord；
/// 结果缓存 5 分钟。
class WyHotSearch {
  WyHotSearch._();

  static const Duration cacheTtl = Duration(minutes: 5);
  static final RequestCache _cache =
      RequestCache(maxEntries: 2, ttl: cacheTtl);

  static Future<List<String>> getList() {
    return _cache.getOrCreate('wy:hot-search', _fetch);
  }

  static Future<List<String>> _fetch() async {
    final body = await lxHttpPost(
      'http://interface.music.163.com/eapi/batch',
      form: true,
      headers: {'origin': 'https://music.163.com'},
      body: {
        'params': eapiParams('/api/search/chart/detail', {
          'id': 'HOT_SEARCH_SONG#@#',
        }),
      },
    );
    if (body is! Map || body['code'] != 200) {
      throw StateError('获取热搜词失败');
    }
    final data = body['data'];
    final itemList = (data is Map ? data['itemList'] : null);
    return filterList(itemList is List ? itemList : const []);
  }

  /// 解析热搜响应（独立出来便于单元测试）。
  static List<String> filterList(List<dynamic> rawList) {
    final words = <String>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      final word = item['searchWord']?.toString() ?? '';
      if (word.isNotEmpty) words.add(word);
    }
    return words;
  }
}
