import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'crypto_utils.dart';
import 'discover_runner.dart';

/// 网易云热搜词（移植自 lx-music-mobile `wy/hotSearch.js`）。
///
/// eapi `/api/search/chart/detail`（`HOT_SEARCH_SONG#@#`）→ itemList.searchWord；
/// 结果缓存 5 分钟（走发现执行器的注入 transport）。
class WyHotSearch {
  WyHotSearch._();

  static Future<List<String>> getList(BuiltinTransport http) {
    return runDiscoverCall(
      DiscoverRequestCall<List<String>>(
        key: 'wy:hot-search',
        budget: BuiltinRetryBudget.singleAttempt,
        message: '获取热搜词失败',
        request: () => lxHttpPost(
          http,
          'http://interface.music.163.com/eapi/batch',
          form: true,
          headers: {'origin': 'https://music.163.com'},
          body: {
            'params': eapiParams('/api/search/chart/detail', {
              'id': 'HOT_SEARCH_SONG#@#',
            }),
          },
        ),
        isInvalid: (body) => body is! Map || body['code'] != 200,
        parse: (body) {
          final data = body['data'];
          final itemList = (data is Map ? data['itemList'] : null);
          return filterList(itemList is List ? itemList : const []);
        },
      ),
      http,
    );
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
