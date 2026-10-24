import '../../domain/models/comment.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'comment_utils.dart';

/// 酷我音乐评论（移植自 lx-music-mobile `kw/comment.js`）。
///
/// - 热门：`ncomment.kuwo.cn/com.s?type=get_rec_comment`；
/// - 最新：`...?type=get_comment`；
/// - 两者均为 `start` 偏移分页；总数为 `hot_comments_counts` / `comments_counts`；
/// - `child_comments` 随列表返回的楼中楼直接映射为回复（不单独分页拉取）。
class KwComment {
  KwComment._();

  static Future<CommentPage> fetch(
    String songId, {
    required CommentKind kind,
    int page = 1,
    int limit = kCommentPageSize,
  }) async {
    final type = switch (kind) {
      CommentKind.hot => 'get_rec_comment',
      CommentKind.latest => 'get_comment',
    };
    final body = await lxHttpGet(
      'http://ncomment.kuwo.cn/com.s?f=web&type=$type&aapiver=1'
      '&prod=kwplayer_ar_10.5.2.0&digest=15&sid=$songId'
      '&start=${limit * (page - 1)}&msgflag=1&count=$limit&newver=3&uid=0',
      headers: const {'User-Agent': 'Dalvik/2.1.0 (Linux; U; Android 9;)'},
      retries: BuiltinTransport.defaultRetries,
      retryIf: _isInvalid,
    );
    if (body is! Map || body['code'] != '200') {
      throw commentPlatformFailure(
        'kw',
        '获取评论失败（code=${body is Map ? body['code'] : '非 JSON'}）',
      );
    }
    final total = commentIntOf(
      kind == CommentKind.hot
          ? body['hot_comments_counts']
          : body['comments_counts'],
    );
    return CommentPage.fromPage(
      kind: kind,
      items: parseItems(body, kind: kind),
      page: page,
      limit: limit,
      total: total,
    );
  }

  /// 酷我评论响应 → 领域模型（响应外壳：`{code, comments|hot_comments, ...}`）。
  static List<Comment> parseItems(dynamic body, {required CommentKind kind}) {
    if (body is! Map) return const [];
    final rawList = kind == CommentKind.hot
        ? body['hot_comments']
        : body['comments'];
    if (rawList is! List) return const [];
    final comments = <Comment>[];
    for (final item in rawList) {
      final comment = _parseItem(item);
      if (comment != null) comments.add(comment);
    }
    return comments;
  }

  static Comment? _parseItem(dynamic raw) {
    if (raw is! Map) return null;
    final id = commentTextOf(raw['id']);
    if (id == null) return null;
    final children = raw['child_comments'];
    return Comment(
      id: id,
      text: raw['msg']?.toString() ?? '',
      createdAt: commentTimeFromEpoch(raw['time']),
      authorName: raw['u_name']?.toString() ?? '',
      avatarUrl: commentUrlOf(raw['u_pic']),
      likedCount: commentIntOf(raw['like_num']),
      replies: children is List
          ? [
              for (final child in children)
                if (_parseItem(child) case final reply?) reply,
            ]
          : const [],
    );
  }

  static bool _isInvalid(dynamic response) =>
      response is! Map || response['code'] != '200';
}
