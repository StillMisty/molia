/// B 站全站视频搜索（Dart 原生实现，匿名访问）。
///
/// 与五个音乐平台不同，B 站没有「曲目」实体：搜索结果是视频，播放取它的
/// 音轨。这里负责把 `data.result[]` 映射成 [SourceTrack]（见 `bili_track`），
/// 分页信息取 `numResults / numPages`（接口固定 20 条/页、最多 50 页）。
library;

import '../../domain/models/artist.dart';
import '../../domain/models/failure.dart';
import '../source_search_result.dart';
import '../source_track.dart';
import 'artist_source.dart';
import 'bili_client.dart';
import 'bili_track.dart';

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
  /// 请求生命周期（WBI 签名、风控刷新一次、业务码）全在 [BiliClient]；
  /// 这里只拼查询参数与解析 `data`。
  static Future<SourceSearchResult> searchWithMeta(
    String keyword, {
    int page = 1,
    int limit = pageSize,
  }) async {
    final normalizedPage = page.clamp(1, maxPage);
    try {
      final response = await BiliClient.shared.get(
        '/x/web-interface/wbi/search/type',
        query: {
          'search_type': 'video',
          'order': 'totalrank',
          'keyword': keyword,
          'page': normalizedPage,
        },
        auth: BiliAuth.session,
        // ADR-0014：搜索不细分错误码，任何失败都刷新会话再试一次。
        refreshPolicy: BiliRefreshPolicy.anyFailure,
      );
      final pages = numPagesOf(response);
      return SourceSearchResult.fromPage(
        tracks: parseItemsOf(response) ?? const [],
        page: normalizedPage,
        limit: pageSize,
        total: totalOf(response),
        // 没有分页字段（含「无结果」）时按末页处理：宁可少翻一页，也不
        // 让 hasMore 永远为真、UI 反复请求空页。
        isEnd: pages == null || normalizedPage >= pages,
      );
    } catch (e) {
      return SourceSearchResult.failed(SourceFailure.from(e));
    }
  }

  /// UP 用户搜索（搜索页「歌手」类型）。平台固定 20 条/页，[limit] 只保留
  /// 适配器签名。
  ///
  /// 与视频搜索同一套会话 / 风控策略（[BiliClient] 的 session 口径），
  /// 不再出现「视频搜索会刷新、用户搜索不会」的分叉。
  static Future<ArtistSearchPage> searchUsers(
    String keyword, {
    int page = 1,
    int limit = pageSize,
  }) async {
    final normalizedPage = page.clamp(1, maxPage);
    final response = await BiliClient.shared.get(
      '/x/web-interface/wbi/search/type',
      query: {
        'search_type': 'bili_user',
        'keyword': keyword,
        'page': normalizedPage,
      },
      auth: BiliAuth.session,
      // 与视频搜索同一套 any-failure 刷新口径。
      refreshPolicy: BiliRefreshPolicy.anyFailure,
    );
    return parseUsers(response, page: normalizedPage);
  }

  /// 用户搜索响应 → 歌手页结果（供单测复用）。
  static ArtistSearchPage parseUsers(
    dynamic response, {
    required int page,
  }) {
    final data = response is Map ? response['data'] : null;
    if (data is! Map) {
      throw artistPlatformFailure('bili', '用户搜索响应非法');
    }
    final items = <ArtistSummary>[];
    final rawList = data['result'];
    if (rawList is List) {
      for (final raw in rawList) {
        if (raw is! Map) continue;
        final id = biliRawText(raw['mid']);
        final name = biliText(raw['uname']);
        if (id.isEmpty || name.isEmpty) continue;
        items.add(ArtistSummary(
          id: id,
          name: name,
          avatarUrl: biliCoverUrl(raw['upic']),
          songCount: parseSourceCount(raw['videos']),
        ));
      }
    }

    final total = parseSourceCount(data['numResults']);
    final pages = parseSourceCount(data['numPages']);
    final hasMore = pages != null
        ? page < pages
        : (total != null && page * pageSize < total);
    return ArtistSearchPage(items: items, total: total, hasMore: hasMore);
  }

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
      final track = biliTrackFromItem(item);
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
