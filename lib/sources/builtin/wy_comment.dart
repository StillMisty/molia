import '../../domain/models/comment.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'comment_utils.dart';
import 'crypto_utils.dart';

/// 网易云评论（移植自 lx-music-mobile `wy/comment.js`）。
///
/// - 热门：`/weapi/v1/resource/hotcomments/R_SO_4_{songId}`（offset 分页，无状态）；
/// - 最新：`/weapi/comment/resource/comments/get`（游标分页：page>1 必须带上一页
///   返回的 cursor，见 [_cursorFor]）；
/// - 文本表情还原（`[大笑]` → 😃）；`beReplied[0]` 归一化为引用评论。
class WyComment {
  WyComment._();

  /// 最新评论游标状态（按曲目；见 [CommentCursorStore]）。
  static final CommentCursorStore cursorStore = CommentCursorStore();

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
    final rid = 'R_SO_4_$songId';
    final body = await lxHttpPost(
      'https://music.163.com/weapi/v1/resource/hotcomments/$rid',
      form: true,
      headers: const {'origin': 'https://music.163.com'},
      retries: BuiltinTransport.defaultRetries,
      retryIf: _isInvalid,
      body: weapiForm({
        'rid': rid,
        'limit': limit,
        'offset': limit * (page - 1),
        'beforeTime': DateTime.now().millisecondsSinceEpoch.toString(),
      }),
    );
    _ensureValid(body, '获取热门评论失败');
    final total = commentIntOf((body as Map)['total']);
    return CommentPage.fromPage(
      kind: CommentKind.hot,
      items: parseHot(body),
      page: page,
      limit: limit,
      total: total,
    );
  }

  static Future<CommentPage> _fetchLatest(
    String songId,
    int page,
    int limit,
  ) async {
    final rid = 'R_SO_4_$songId';
    final cursor = _cursorFor(songId, page);
    final body = await lxHttpPost(
      'https://music.163.com/weapi/comment/resource/comments/get',
      form: true,
      headers: const {'origin': 'https://music.163.com'},
      retries: BuiltinTransport.defaultRetries,
      retryIf: _isInvalid,
      body: weapiForm({
        'cursor': cursor.cursor,
        'offset': cursor.offset,
        'orderType': cursor.orderType,
        'pageNo': page,
        'pageSize': limit,
        'rid': rid,
        'threadId': rid,
      }),
    );
    _ensureValid(body, '获取评论失败');
    final data = (body as Map)['data'];
    if (data is! Map) throw commentPlatformFailure('wy', '评论数据结构不符');
    final nextCursor = commentTextOf(data['cursor']);
    if (nextCursor != null) cursorStore.write(songId, page + 1, nextCursor);
    return CommentPage.fromPage(
      kind: CommentKind.latest,
      items: parseLatest(body),
      page: page,
      limit: limit,
      total: commentIntOf(data['totalCount']),
    );
  }

  /// 本页游标参数：page 1 取当前时间（最新起点）；连续页复用上一页返回的
  /// cursor（offset 0、orderType 1 = 继续向更早翻）。跳页/状态丢失时退回起点，
  /// 重复项由上层按 id 去重（不抛错，避免偶发状态丢失直接失败）。
  static ({String cursor, int offset, int orderType}) _cursorFor(
    String songId,
    int page,
  ) {
    final stored = page > 1 ? cursorStore.read(songId, page) : null;
    return (
      cursor: stored ?? DateTime.now().millisecondsSinceEpoch.toString(),
      offset: 0,
      orderType: 1,
    );
  }

  /// 热门评论响应 → 领域模型（响应外壳：`{code, hotComments, total}`）。
  static List<Comment> parseHot(dynamic body) {
    if (body is! Map) return const [];
    return _parseList(body['hotComments']);
  }

  /// 最新评论响应 → 领域模型（响应外壳：`{code, data:{comments, totalCount}}`）。
  static List<Comment> parseLatest(dynamic body) {
    if (body is! Map) return const [];
    final data = body['data'];
    if (data is! Map) return const [];
    return _parseList(data['comments']);
  }

  static List<Comment> _parseList(dynamic rawList) {
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
    final id = commentTextOf(raw['commentId']);
    final text = restoreEmoji(raw['content']?.toString() ?? '');
    // 空 id / 空文本多为列表分隔占位（旧接口的「热门评论」分节项）。
    if (id == null || id == '0' || text.isEmpty) return null;
    final user = raw['user'] is Map ? raw['user'] as Map : const {};
    return Comment(
      id: id,
      text: text,
      createdAt: commentTimeFromEpoch(raw['time']),
      location: _locationOf(raw['ipLocation']),
      authorName: user['nickname']?.toString() ?? '',
      avatarUrl: commentTextOf(user['avatarUrl']),
      likedCount: commentIntOf(raw['likedCount']),
      quoted: _quotedOf(raw['beReplied']),
    );
  }

  /// 回复场景：`beReplied[0]` 是被引用的原评论（LX 同样只取第一条）。
  static Comment? _quotedOf(dynamic beReplied) {
    if (beReplied is! List || beReplied.isEmpty) return null;
    final first = beReplied.first;
    if (first is! Map) return null;
    final user = first['user'] is Map ? first['user'] as Map : const {};
    return Comment(
      id: commentTextOf(first['beRepliedCommentId']) ?? '',
      text: restoreEmoji(first['content']?.toString() ?? ''),
      location: _locationOf(first['ipLocation']),
      authorName: user['nickname']?.toString() ?? '',
      avatarUrl: commentTextOf(user['avatarUrl']),
    );
  }

  static String? _locationOf(Object? ipLocation) {
    if (ipLocation is! Map) return null;
    return commentTextOf(ipLocation['location']);
  }

  static bool _isInvalid(dynamic response) => response is! Map ||
      response['code'] != 200;

  static void _ensureValid(dynamic body, String reason) {
    if (body is! Map || body['code'] != 200) {
      throw commentPlatformFailure(
        'wy',
        '$reason（code=${body is Map ? body['code'] : '非 JSON'}）',
      );
    }
  }

  // 表情还原：LX `wy/comment.js` 的表情表（`[名称]` → emoji）。
  static const Map<String, String> _emojis = {
    '大笑': '😃',
    '可爱': '😊',
    '憨笑': '☺️',
    '色': '😍',
    '亲亲': '😙',
    '惊恐': '😱',
    '流泪': '😭',
    '亲': '😚',
    '呆': '😳',
    '哀伤': '😔',
    '呲牙': '😁',
    '吐舌': '😝',
    '撇嘴': '😒',
    '怒': '😡',
    '奸笑': '😏',
    '汗': '😓',
    '痛苦': '😖',
    '惶恐': '😰',
    '生病': '😨',
    '口罩': '😷',
    '大哭': '😂',
    '晕': '😵',
    '发怒': '👿',
    '开心': '😄',
    '鬼脸': '😜',
    '皱眉': '😞',
    '流感': '😢',
    '爱心': '❤️',
    '心碎': '💔',
    '钟情': '💘',
    '星星': '⭐️',
    '生气': '💢',
    '便便': '💩',
    '强': '👍',
    '弱': '👎',
    '拜': '🙏',
    '牵手': '👫',
    '跳舞': '👯‍♀️',
    '禁止': '🙅‍♀️',
    '这边': '💁‍♀️',
    '爱意': '💏',
    '示爱': '👩‍❤️‍👨',
    '嘴唇': '👄',
    '狗': '🐶',
    '猫': '🐱',
    '猪': '🐷',
    '兔子': '🐰',
    '小鸡': '🐤',
    '公鸡': '🐔',
    '幽灵': '👻',
    '圣诞': '🎅',
    '外星': '👽',
    '钻石': '💎',
    '礼物': '🎁',
    '男孩': '👦',
    '女孩': '👧',
    '蛋糕': '🎂',
    '18': '🔞',
    '圈': '⭕',
    '叉': '❌',
  };

  static final RegExp _emojiPattern = RegExp(r'\[([^\[\]]+)\]');

  /// 表情还原（未知名称原样保留）。
  static String restoreEmoji(String text) => text.replaceAllMapped(
        _emojiPattern,
        (match) => _emojis[match[1]] ?? match[0]!,
      );
}
