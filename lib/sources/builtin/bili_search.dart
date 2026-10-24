/// B 站全站视频搜索（Dart 原生实现，匿名访问）。
///
/// 与五个音乐平台不同，B 站没有「曲目」实体：搜索结果是视频，播放取它的
/// 音轨。这里负责把 `data.result[]` 映射成 [SourceTrack]（见 `bili_track`），
/// 分页信息取 `numResults / numPages`（接口固定 20 条/页、最多 50 页）。
library;

import '../../domain/models/failure.dart';
import '../source_search_result.dart';
import '../source_track.dart';
import 'bili_api.dart';
import 'bili_track.dart';
import 'builtin_search_runner.dart';

class BiliSearch {
  BiliSearch._();

  static const int pageSize = 20;
  static const int maxPage = 50;

  static Future<List<SourceTrack>> search(
    String keyword, {
    int page = 1,
    int limit = pageSize,
  }) async {
    final result = await searchWithMeta(keyword, page: page, limit: limit);
    return result.tracks;
  }

  /// 分页搜索。失败返回 [SourceSearchResult.failed]（不抛异常，与内置平台
  /// 搜索语义一致）；平台返回空保持正常空结果。
  ///
  /// [limit] 只为适配器签名保留：B 站固定 20 条/页，改不了本页条数。
  /// WBI 会话失效 / 风控（-403/-412）会表现为整次失败：刷新会话后重试一次，
  /// 仍失败才把失败交给调用方。
  static Future<SourceSearchResult> searchWithMeta(
    String keyword, {
    int page = 1,
    int limit = pageSize,
  }) async {
    final normalizedPage = page.clamp(1, maxPage);
    var result = await _run(keyword, normalizedPage);
    if (result.failure == null) return result;
    try {
      await BiliApi.refresh();
    } catch (_) {
      return result;
    }
    result = await _run(keyword, normalizedPage);
    return result;
  }

  static Future<SourceSearchResult> _run(String keyword, int page) async {
    try {
      final session = await BiliApi.session();
      final url = session.signUrl(
        '${BiliApi.baseUrl}/x/web-interface/wbi/search/type',
        {
          'search_type': 'video',
          'order': 'totalrank',
          'keyword': keyword,
          'page': page,
        },
      );
      return await runBuiltinSearch(
        BuiltinSearchCall(
          platform: 'bili',
          url: url,
          headers: session.apiHeaders,
          retries: 1,
          isInvalid: _isInvalid,
          parseItems: parseItemsOf,
          totalOf: totalOf,
          isEndOf: (response) {
            final pages = numPagesOf(response);
            // 没有分页字段（含「无结果」）时按末页处理：宁可少翻一页，也不
            // 让 hasMore 永远为真、UI 反复请求空页。
            return pages == null || page >= pages;
          },
        ),
        page: page,
        limit: pageSize,
      );
    } catch (e) {
      return SourceSearchResult.failed(SourceFailure.from(e));
    }
  }

  static bool _isInvalid(dynamic response) =>
      response is! Map || response['code'] != 0;

  /// 完整响应 → 结果列表。
  static List<SourceTrack>? parseItemsOf(dynamic response) {
    final data = response is Map ? response['data'] : null;
    final result = data is Map ? data['result'] : null;
    if (result is! List) return const [];
    return parseItems(result);
  }

  /// `data.result[]` → 曲目（供搜索与测试复用）。
  static List<SourceTrack> parseItems(List result) {
    final tracks = <SourceTrack>[];
    for (final item in result) {
      final track = biliTrackFromSearchItem(item);
      if (track != null) tracks.add(track);
    }
    return tracks;
  }

  /// 响应 → 结果总数（B 站仅首页给准确值，后续页可能重复返回）。
  static int? totalOf(dynamic response) {
    final data = response is Map ? response['data'] : null;
    if (data is! Map) return null;
    return parseSourceCount(data['numResults']);
  }

  /// 响应 → 总页数（最多 [maxPage] 页）。
  static int? numPagesOf(dynamic response) {
    final data = response is Map ? response['data'] : null;
    if (data is! Map) return null;
    final pages = parseSourceCount(data['numPages']);
    if (pages == null) return null;
    return pages.clamp(0, maxPage);
  }
}
