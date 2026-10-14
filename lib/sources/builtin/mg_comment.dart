import '../../domain/models/comment.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'comment_utils.dart';

/// 咪咕音乐评论（移植自 lx-music-mobile `mg/comment.js`）。
///
/// - 热门：`MIGUM3.0/user/comment/stack/v1.0?queryType=2`（`hotCommentStart` 偏移分页）；
/// - 最新：同接口 `queryType=1`，但为**游标分页**：page>1 必须带上一页最后一条
///   评论的 id（[MgComment] 内按曲目缓存，对应 LX 的 `lastCommentIds`）；
/// - 总数为 `commentNums` / `cfgHotCount`；`replyComments` 直接映射为回复。
class MgComment {
  MgComment._();

  /// 最新评论游标状态（按曲目保存「上一页最后一条评论 id」，见 [CommentCursorStore]）。
  static final CommentCursorStore cursorStore = CommentCursorStore();

  static Future<CommentPage> fetch(
    String songId, {
    required CommentKind kind,
    int page = 1,
    int limit = kCommentPageSize,
  }) async {
    final lastId = kind == CommentKind.latest ? _cursorFor(songId, page) : null;
    final query = kind == CommentKind.hot
        ? 'pageSize=$limit&queryType=2&resourceId=$songId&resourceType=2'
            '&hotCommentStart=${(page - 1) * limit}'
        : 'pageSize=$limit&queryType=1&resourceId=$songId&resourceType=2'
            '&commentId=${lastId ?? ''}';
    final body = await lxHttpGet(
      'https://app.c.nf.migu.cn/MIGUM3.0/user/comment/stack/v1.0?$query',
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1',
      },
      retries: BuiltinTransport.defaultRetries,
      retryIf: _isInvalid,
    );
    if (body is! Map || body['code'] != '000000') {
      throw commentPlatformFailure(
        'mg',
        '获取评论失败（code=${body is Map ? body['code'] : '非 JSON'}）',
      );
    }
    final data = body['data'];
    if (data is! Map) throw commentPlatformFailure('mg', '评论数据结构不符');
    final items = parseItems(data, kind: kind);
    if (kind == CommentKind.latest && items.isNotEmpty) {
      cursorStore.write(songId, page + 1, items.last.id);
    }
    return CommentPage.fromPage(
      kind: kind,
      items: items,
      page: page,
      limit: limit,
      total: commentIntOf(
        kind == CommentKind.hot ? data['cfgHotCount'] : data['commentNums'],
      ),
    );
  }

  /// 咪咕评论响应 → 领域模型（响应外壳：`{code, data:{comments|hotComments}}`）。
  static List<Comment> parseItems(
    dynamic data, {
    required CommentKind kind,
  }) {
    if (data is! Map) return const [];
    final rawList = kind == CommentKind.hot
        ? data['hotComments']
        : data['comments'];
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
    if (id == null) return null;
    return Comment(
      id: id,
      text: raw['commentInfo']?.toString() ?? '',
      createdAt: commentTimeFromText(raw['commentTime']),
      authorName: _userOf(raw)['nickName']?.toString() ?? '',
      avatarUrl: _avatarOf(_userOf(raw)),
      likedCount: _thumbNumOf(raw),
      replies: _repliesOf(raw),
    );
  }

  static List<Comment> _repliesOf(Map raw) {
    final rawList = raw['replyComments'];
    if (rawList is! List) return const [];
    final replies = <Comment>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      final id = commentTextOf(item['replyId']);
      if (id == null) continue;
      replies.add(Comment(
        id: id,
        text: item['replyInfo']?.toString() ?? '',
        createdAt: commentTimeFromText(item['replyTime']),
        authorName: _userOf(item)['nickName']?.toString() ?? '',
        avatarUrl: _avatarOf(_userOf(item)),
      ));
    }
    return replies;
  }

  static Map _userOf(Map raw) =>
      raw['user'] is Map ? raw['user'] as Map : const {};

  /// 头像按「中图 → 大图 → 小图」回退（与 LX 一致）。
  static String? _avatarOf(Map user) {
    for (final key in const ['middleIcon', 'bigIcon', 'smallIcon']) {
      final value = commentTextOf(user[key]);
      if (value != null) return value;
    }
    return null;
  }

  static int? _thumbNumOf(Map raw) {
    final opNum = raw['opNumItem'];
    return opNum is Map ? commentIntOf(opNum['thumbNum']) : null;
  }

  /// 本页游标：最新评论为游标分页，page>1 需要上一页最后一条评论的 id。
  ///
  /// 非连续页（跳页 / 状态丢失）时抛错——缺游标无法定位，静默返回首页数据
  /// 会造成重复项；由 UI 的重试/刷新路径重新从第一页开始。
  static String? _cursorFor(String songId, int page) {
    if (page <= 1) return null;
    final lastId = cursorStore.read(songId, page);
    if (lastId == null || lastId.isEmpty) {
      throw commentPlatformFailure('mg', '评论分页游标缺失（page=$page）');
    }
    return lastId;
  }

  static bool _isInvalid(dynamic response) =>
      response is! Map || response['code'] != '000000';
}
