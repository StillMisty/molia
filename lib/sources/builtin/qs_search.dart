/// 汽水音乐单曲搜索（`GET /luna/search/track`，PC 客户端参数）。
///
/// 平台每页固定 20 条且只认 `cursor`（偏移量），请求里的 `count` 会被忽略；
/// 因此分页按平台自己的步长走，`limit` 只作为「本页最多这么多条」的上限。
///
/// 空响应是平台的概率行为（`200` + 空 body），由 [QsApi] 重试；正常空结果
/// （`extra.empty_search`）按「平台返回空」处理，与失败分开。
library;

import '../../domain/models/failure.dart';
import '../source_search_result.dart';
import '../source_track.dart';
import 'qs_api.dart';
import 'qs_track.dart';

class QsSearch {
  QsSearch._();

  /// 平台固定页长：`next_cursor` 以 20 递增，请求参数改不了。
  static const int pageSize = 20;

  static Future<SourceSearchResult> searchWithMeta(
    String keyword, {
    int page = 1,
    int limit = pageSize,
  }) async {
    try {
      final response = await QsApi.getJson(
        '/luna/search/track',
        query: {
          'q': keyword,
          'cursor': '${(page < 1 ? 0 : page - 1) * pageSize}',
          'search_id': '',
          'search_method': 'input',
        },
        tries: QsApi.searchTries,
      );
      final group = tracksGroupOf(response);
      if (group == null) return SourceSearchResult.empty;
      final tracks = parseItems(group);
      final hasMore = group['has_more'] is bool
          ? group['has_more'] as bool
          : tracks.length >= pageSize;
      return SourceSearchResult.fromPage(
        tracks: tracks,
        page: page,
        limit: pageSize,
        isEnd: !hasMore,
      );
    } catch (error) {
      return SourceSearchResult.failed(SourceFailure.from(error));
    }
  }

  /// 响应里 id 为 `tracks`（或首个带 track 实体的）结果组；没有则 null。
  static Map<String, dynamic>? tracksGroupOf(dynamic response) {
    if (response is! Map) return null;
    final groups = response['result_groups'];
    if (groups is! List) return null;
    Map<String, dynamic>? fallback;
    for (final group in groups) {
      if (group is! Map) continue;
      final map = Map<String, dynamic>.from(group);
      if (map['id'] == 'tracks') return map;
      fallback ??= map;
    }
    return fallback;
  }

  /// 结果组 → 曲目列表（跳过结构不符的条目）。
  static List<SourceTrack> parseItems(Map<String, dynamic> group) {
    final items = group['data'];
    if (items is! List) return const [];
    return [for (final item in items) ?_parseItem(item)];
  }

  static SourceTrack? _parseItem(Object? item) {
    final track = _trackOf(item);
    return track == null ? null : QsTrack.parse(track);
  }

  /// 结果条目的 track 实体：搜索是 `entity.track`，媒体流是
  /// `entity.track_wrapper.track`，两种都接受。
  static Map<String, dynamic>? _trackOf(Object? item) {
    if (item is! Map) return null;
    final entity = item['entity'];
    if (entity is! Map) return null;
    final direct = entity['track'];
    if (direct is Map) return Map<String, dynamic>.from(direct);
    final wrapper = entity['track_wrapper'];
    if (wrapper is Map) {
      final track = wrapper['track'];
      if (track is Map) return Map<String, dynamic>.from(track);
    }
    return null;
  }

  /// 媒体流条目（歌单详情 / 歌单歌单流）里的 track 实体。
  static Map<String, dynamic>? trackOfItem(Object? item) => _trackOf(item);
}
