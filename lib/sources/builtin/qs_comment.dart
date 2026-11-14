/// 汽水音乐评论（`GET /luna/pc/comments`）。
///
/// 平台只有一个评论序（服务端不给排序参数），因此：
/// - 「最新」按平台原序；
/// - 「热门」在本页内按点赞数降序，再按时间降序。
///
/// 这是有意的降级：平台没有全站热门游标，不能伪造「热门前 N 条」。
/// 游标就是偏移量（`cursor = (page - 1) * limit`），无需按曲目保存状态。
library;

import '../../domain/models/comment.dart';
import 'comment_utils.dart';
import 'qs_api.dart';
import 'qs_track.dart';

class QsComment {
  QsComment._();

  static Future<CommentPage> fetch(
    String trackId, {
    required CommentKind kind,
    int page = 1,
    int limit = kCommentPageSize,
  }) async {
    final response = await QsApi.getJson(
      '/luna/pc/comments',
      query: {
        'group_id': trackId,
        // 1 = 单曲；其它值会判 ERR_INVALID_PARAM。
        'group_type': '1',
        'cursor': '${(page < 1 ? 0 : page - 1) * limit}',
        'count': '$limit',
      },
    );
    return parse(response, kind: kind, page: page, limit: limit);
  }

  /// 评论响应 → 领域分页（供单测复用）。
  static CommentPage parse(
    dynamic response, {
    required CommentKind kind,
    required int page,
    required int limit,
  }) {
    if (response is! Map) throw commentPlatformFailure('qs', '评论数据结构不符');
    final rawComments = response['comments'];
    if (rawComments is! List) {
      throw commentPlatformFailure('qs', '评论数据结构不符');
    }
    final items = [for (final raw in rawComments) ?parseComment(raw)];
    if (kind == CommentKind.hot) {
      items.sort((left, right) {
        final byLikes = (right.likedCount ?? 0).compareTo(left.likedCount ?? 0);
        if (byLikes != 0) return byLikes;
        return (right.createdAt ?? DateTime(0)).compareTo(
          left.createdAt ?? DateTime(0),
        );
      });
    }
    return CommentPage(
      kind: kind,
      items: items,
      page: page,
      limit: limit,
      total: commentIntOf(response['count']),
      hasMore: response['has_more'] == true,
    );
  }

  /// 单条评论 → 领域模型；缺 id / 正文时返回 null。
  static Comment? parseComment(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString() ?? '';
    final text = raw['content']?.toString() ?? '';
    if (id.isEmpty || text.trim().isEmpty) return null;
    final user = raw['user'];
    final userMap = user is Map ? user : const {};
    return Comment(
      id: id,
      text: text,
      createdAt: commentTimeFromEpoch(raw['time_created']),
      location: commentTextOf(raw['ip_label']),
      authorName: userMap['nickname']?.toString() ?? '',
      avatarUrl: _avatarOf(userMap),
      likedCount: commentIntOf(raw['count_digg']),
    );
  }

  /// 用户头像：`urls` 已经是完整地址（播放封面那套「前缀 + uri」不适用）。
  static String? _avatarOf(Map user) {
    for (final key in const ['thumb_avatar_url', 'medium_avatar_url']) {
      final image = user[key];
      if (image is! Map) continue;
      final urls = image['urls'];
      if (urls is List) {
        for (final url in urls) {
          final resolved = commentUrlOf(url);
          if (resolved != null) return resolved;
        }
      }
      final fallback = QsTrack.imageUrlOf(image, suffix: '');
      if (fallback != null) return fallback;
    }
    return null;
  }
}
