import '../../domain/models/comment.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'comment_utils.dart';

/// QQ 音乐评论（移植自 lx-music-mobile `tx/comment.js`）。
///
/// - 热门：`u.y.qq.com/cgi-bin/musicu.fcg` 的 `GetHotCommentList`（PageNum 分页）；
/// - 最新：`c.y.qq.com/base/fcgi-bin/fcg_global_comment_h5.fcg`（pagenum 分页）；
/// - 文本 `[em]eXXXX[/em]` 表情还原、字面 `\n` 转义还原；
/// - 最新列表的一行是「根评论 + 楼中楼」：根评论为正文，回复按「旧 → 新」
///   排列（行级头像/点赞属于最新一条回复，与 LX 的展示口径一致）。
class TxComment {
  TxComment._();

  static Future<CommentPage> fetch(
    String songId, {
    required CommentKind kind,
    int page = 1,
    int limit = kCommentPageSize,
  }) {
    switch (kind) {
      case CommentKind.hot:
        return _fetchHot(songId, page, limit);
      case CommentKind.latest:
        return _fetchLatest(songId, page, limit);
    }
  }

  static Future<CommentPage> _fetchHot(
    String songId,
    int page,
    int limit,
  ) async {
    final body = await lxHttpPost(
      'https://u.y.qq.com/cgi-bin/musicu.fcg',
      headers: const {
        'referer': 'https://y.qq.com/',
        'origin': 'https://y.qq.com',
      },
      retries: BuiltinTransport.defaultRetries,
      retryIf: _isInvalidHot,
      body: {
        'comm': {
          'cv': 4747474,
          'ct': 24,
          'format': 'json',
          'inCharset': 'utf-8',
          'outCharset': 'utf-8',
          'notice': 0,
          'platform': 'yqq.json',
          'needNewCode': 1,
          'uin': 0,
        },
        'req': {
          'module': 'music.globalComment.CommentRead',
          'method': 'GetHotCommentList',
          'param': {
            'BizType': 1,
            'BizId': songId,
            'LastCommentSeqNo': '',
            'PageSize': limit,
            'PageNum': page - 1,
            'HotType': 1,
            'WithAirborne': 0,
            'PicEnable': 1,
          },
        },
      },
    );
    final commentList = _hotCommentListOf(body);
    if (commentList == null) {
      throw commentPlatformFailure('tx', '获取热门评论失败');
    }
    return CommentPage.fromPage(
      kind: CommentKind.hot,
      items: parseHot(body),
      page: page,
      limit: limit,
      total: commentIntOf(commentList['Total']),
    );
  }

  static Future<CommentPage> _fetchLatest(
    String songId,
    int page,
    int limit,
  ) async {
    final body = await lxHttpPost(
      'http://c.y.qq.com/base/fcgi-bin/fcg_global_comment_h5.fcg',
      form: true,
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)',
      },
      retries: BuiltinTransport.defaultRetries,
      retryIf: _isInvalidLatest,
      body: {
        'uin': '0',
        'format': 'json',
        'cid': '205360772',
        'reqtype': '2',
        'biztype': '1',
        'topid': songId,
        'cmd': '8',
        'needmusiccrit': '1',
        'pagenum': page - 1,
        'pagesize': limit,
      },
    );
    final comment = _commentSectionOf(body);
    if (comment == null) {
      throw commentPlatformFailure('tx', '获取评论失败');
    }
    return CommentPage.fromPage(
      kind: CommentKind.latest,
      items: parseLatest(body),
      page: page,
      limit: limit,
      total: commentIntOf(comment['commenttotal']),
    );
  }

  /// 热门评论响应 → 领域模型（外壳：`{code, req:{code, data:{CommentList}}}`）。
  static List<Comment> parseHot(dynamic body) {
    final commentList = _hotCommentListOf(body);
    final rawList = commentList?['Comments'];
    if (rawList is! List) return const [];
    final comments = <Comment>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      final id = '${commentTextOf(item['SeqNo']) ?? ''}_'
          '${commentTextOf(item['CmId']) ?? ''}';
      comments.add(Comment(
        id: id,
        text: _fixText(item['Content']),
        createdAt: commentTimeFromEpoch(item['PubTime']),
        location: commentTextOf(item['Location']),
        authorName: item['Nick']?.toString() ?? '',
        avatarUrl: commentUrlOf(item['Avatar']),
        likedCount: commentIntOf(item['PraiseNum']),
        replies: _parseHotReplies(item['SubComments'], id),
      ));
    }
    return comments;
  }

  /// 最新评论响应 → 领域模型（外壳：`{code, comment:{commentlist, commenttotal}}`）。
  static List<Comment> parseLatest(dynamic body) {
    final comment = _commentSectionOf(body);
    final rawList = comment?['commentlist'];
    if (rawList is! List) return const [];
    final comments = <Comment>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      comments.add(_parseLatestItem(item));
    }
    return comments;
  }

  static Comment _parseLatestItem(Map<dynamic, dynamic> raw) {
    final rootId = commentTextOf(raw['rootcommentid']) ?? '';
    final commentId = commentTextOf(raw['commentid']) ?? '';
    final replies = _parseLatestReplies(raw, rootId);
    return Comment(
      id: '${rootId}_$commentId',
      text: _fixText(raw['rootcommentcontent']),
      createdAt: commentTimeFromEpoch(raw['time']),
      authorName: _nick(raw['rootcommentnick']),
      // 行级头像 / 点赞属于最新一条回复（见类注释）；无回复时归正文。
      avatarUrl: replies.isEmpty ? commentUrlOf(raw['avatarurl']) : null,
      likedCount: replies.isEmpty ? commentIntOf(raw['praisenum']) : null,
      replies: replies,
    );
  }

  /// 楼中楼：`middlecommentcontent` 为「最新在前」，反转成「旧 → 新」；
  /// 最新一条（原下标 0）携带行级头像 / 点赞 / 时间。
  static List<Comment> _parseLatestReplies(
    Map<dynamic, dynamic> raw,
    String rootId,
  ) {
    final rawList = raw['middlecommentcontent'];
    if (rawList is! List || rawList.isEmpty) return const [];
    final replies = <Comment>[];
    for (var index = rawList.length - 1; index >= 0; index--) {
      final item = rawList[index];
      if (item is! Map) continue;
      final newest = index == 0;
      replies.add(Comment(
        id: 'sub_${rootId}_${commentTextOf(item['subcommentid']) ?? ''}',
        text: _fixText(item['subcommentcontent']),
        createdAt: newest ? commentTimeFromEpoch(raw['time']) : null,
        authorName: _nick(item['replynick']),
        avatarUrl: newest ? commentUrlOf(raw['avatarurl']) : null,
        likedCount: newest ? commentIntOf(raw['praisenum']) : null,
      ));
    }
    return replies;
  }

  static List<Comment> _parseHotReplies(dynamic rawList, String parentId) {
    if (rawList is! List) return const [];
    final replies = <Comment>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      replies.add(Comment(
        id: 'sub_${commentTextOf(item['SeqNo']) ?? ''}_'
            '${commentTextOf(item['CmId']) ?? ''}',
        text: _fixText(item['Content']),
        createdAt: commentTimeFromEpoch(item['PubTime']),
        authorName: item['Nick']?.toString() ?? '',
        avatarUrl: commentUrlOf(item['Avatar']),
        likedCount: commentIntOf(item['PraiseNum']),
      ));
    }
    return replies;
  }

  /// 文本归一化：表情还原 + 字面 `\n` 还原为换行（LX `replace(/\\n/g, '\n')`）。
  static String _fixText(Object? value) =>
      replaceEmoji(value?.toString() ?? '').replaceAll(r'\n', '\n');

  /// 昵称：平台会带前导 `@`（LX `substring(1)`）。
  static String _nick(Object? value) {
    final nick = value?.toString() ?? '';
    return nick.startsWith('@') ? nick.substring(1) : nick;
  }

  static Map? _hotCommentListOf(dynamic body) {
    if (body is! Map) return null;
    final req = body['req'];
    if (req is! Map || req['code'] != 0) return null;
    final data = req['data'];
    if (data is! Map) return null;
    final commentList = data['CommentList'];
    return commentList is Map ? commentList : null;
  }

  static Map? _commentSectionOf(dynamic body) {
    if (body is! Map || body['code'] != 0) return null;
    final comment = body['comment'];
    return comment is Map ? comment : null;
  }

  static bool _isInvalidHot(dynamic response) => _hotCommentListOf(response) == null;

  static bool _isInvalidLatest(dynamic response) =>
      _commentSectionOf(response) == null;

  // 表情还原：LX `tx/comment.js` 的表情表（`[em]eXXXX[/em]` → emoji）。
  static const Map<String, String> _emojis = {
    'e400846': '😘',
    'e400874': '😴',
    'e400825': '😃',
    'e400847': '😙',
    'e400835': '😍',
    'e400873': '😳',
    'e400836': '😎',
    'e400867': '😭',
    'e400832': '😊',
    'e400837': '😏',
    'e400875': '😫',
    'e400831': '😉',
    'e400855': '😡',
    'e400823': '😄',
    'e400862': '😨',
    'e400844': '😖',
    'e400841': '😓',
    'e400830': '😈',
    'e400828': '😆',
    'e400833': '😋',
    'e400822': '😀',
    'e400843': '😕',
    'e400829': '😇',
    'e400824': '😂',
    'e400834': '😌',
    'e400877': '😷',
    'e400132': '🍉',
    'e400181': '🍺',
    'e401067': '☕️',
    'e400186': '🥧',
    'e400343': '🐷',
    'e400116': '🌹',
    'e400126': '🍃',
    'e400613': '💋',
    'e401236': '❤️',
    'e400622': '💔',
    'e400637': '💣',
    'e400643': '💩',
    'e400773': '🔪',
    'e400102': '🌛',
    'e401328': '🌞',
    'e400420': '👏',
    'e400914': '🙌',
    'e400408': '👍',
    'e400414': '👎',
    'e401121': '✋',
    'e400396': '👋',
    'e400384': '👉',
    'e401115': '✊',
    'e400402': '👌',
    'e400905': '🙈',
    'e400906': '🙉',
    'e400907': '🙊',
    'e400562': '👻',
    'e400932': '🙏',
    'e400644': '💪',
    'e400611': '💉',
    'e400185': '🎁',
    'e400655': '💰',
    'e400325': '🐥',
    'e400612': '💊',
    'e400198': '🎉',
    'e401685': '⚡️',
    'e400631': '💝',
    'e400768': '🔥',
    'e400432': '👑',
  };

  static final RegExp _emojiPattern = RegExp(r'\[em\](e\d+)\[/em\]');

  /// 表情还原（未知编码移除，与 LX 的 `emojis[code] || ''` 一致）。
  static String replaceEmoji(String text) => text.replaceAllMapped(
        _emojiPattern,
        (match) => _emojis[match[1]] ?? '',
      );
}
