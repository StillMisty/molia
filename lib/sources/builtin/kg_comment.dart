import '../../domain/models/comment.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'comment_utils.dart';
import 'crypto_utils.dart';

/// 酷狗音乐评论（移植自 lx-music-mobile `kg/comment.js`）。
///
/// - 热门：`m.comment.service.kugou.com/r/v1/rank/topliked`；
/// - 最新：`.../rank/newest`；
/// - 两者均为 `p` 页码分页 + [kgSignatureParams] 签名（`extdata` / `schash` = hash）；
/// - 文本：`[at=id]` 还原为 `@昵称`、HTML 实体解码；`pcontent` 归一化为引用评论。
///
/// 说明：酷狗的楼中楼需要单独接口（LX `getReplyComment`），当前不拉取——
/// 列表随附的 `pcontent`（回复对象）与 `reply_num` 计数保留展示。
class KgComment {
  KgComment._();

  static Future<CommentPage> fetch(
    String hash, {
    required CommentKind kind,
    int page = 1,
    int limit = kCommentPageSize,
  }) async {
    final path = switch (kind) {
      CommentKind.hot => 'topliked',
      CommentKind.latest => 'newest',
    };
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final params = 'dfid=0&mid=16249512204336365674023395779019'
        '&clienttime=$timestamp&uuid=0&extdata=$hash&appid=1005'
        '&code=fc4be23b4e972707f36b8a828a93ba8a&schash=$hash&clientver=11409'
        '&p=$page&clienttoken=&pagesize=$limit&ver=10&kugouid=0';
    final body = await lxHttpGet(
      'http://m.comment.service.kugou.com/r/v1/rank/$path'
      '?$params&signature=${kgSignatureParams(params)}',
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 Edg/107.0.1418.24',
      },
      retries: BuiltinTransport.defaultRetries,
      retryIf: _isInvalid,
    );
    if (body is! Map || body['err_code'] != 0) {
      throw commentPlatformFailure(
        'kg',
        '获取评论失败（err_code=${body is Map ? body['err_code'] : '非 JSON'}）',
      );
    }
    return CommentPage.fromPage(
      kind: kind,
      items: parseItems(body),
      page: page,
      limit: limit,
      total: commentIntOf(body['count']),
    );
  }

  /// 酷狗评论响应 → 领域模型（响应外壳：`{err_code, count, list}`）。
  static List<Comment> parseItems(dynamic body) {
    if (body is! Map) return const [];
    final rawList = body['list'];
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
    final like = raw['like'];
    final quotedAuthor = commentTextOf(raw['puser']);
    final quotedText = commentTextOf(raw['pcontent']);
    return Comment(
      id: id,
      text: _decodeText(raw['content'], raw['atlist']),
      createdAt: commentTimeFromText(raw['addtime']),
      location: commentTextOf(raw['location']),
      authorName: raw['user_name']?.toString() ?? '',
      avatarUrl: commentUrlOf(raw['user_pic']),
      likedCount: like is Map ? commentIntOf(like['likenum']) : null,
      quoted: (quotedAuthor != null || quotedText != null)
          ? Comment(
              id: commentTextOf(raw['pid']) ?? '',
              text: decodeName(quotedText ?? ''),
              authorName: quotedAuthor ?? '',
            )
          : null,
    );
  }

  /// 文本：`[at=id]` → `@昵称`（[atList] 提供 id → 昵称映射）+ HTML 实体解码。
  static String _decodeText(Object? content, Object? atList) {
    var text = content?.toString() ?? '';
    if (atList is List) {
      for (final at in atList) {
        if (at is! Map) continue;
        final id = at['id']?.toString();
        final name = at['name']?.toString();
        if (id == null || id.isEmpty || name == null) continue;
        text = text.replaceAll('[at=$id]', '@$name ');
      }
    }
    return decodeName(text);
  }

  static bool _isInvalid(dynamic response) =>
      response is! Map || response['err_code'] != 0;
}
