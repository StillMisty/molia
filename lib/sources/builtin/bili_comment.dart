/// B 站视频评论：`/x/v2/reply/main`（老接口，无需 WBI）。
///
/// 热门 `mode=3` / 最新 `mode=2` 都是游标分页：第一页不带
/// `pagination_str`，后续页带上一页 `data.cursor.pagination_reply.next_offset`。
/// 游标按 `bili:$aid:$kind` 存在 [CommentCursorStore]（热门与最新不可互换）。
/// 跳页/状态丢失时退回首页（不带游标），重复项由上层按 id 去重。
///
/// 除 `aid` 外不需要作品信息；楼中楼随列表返回，只解析一层（B 站回复
/// 理论上可继续嵌套，但 UI 也只展示一层，递归没有收益）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../domain/models/comment.dart';
import 'bili_client.dart';
import 'builtin_transport.dart';
import 'comment_utils.dart';
import 'crypto_utils.dart';

class BiliComment {
  BiliComment._();

  /// 热门 / 最新各自一套游标（mode 不同，游标不能跨 tab 复用）。
  static final CommentCursorStore cursorStore = CommentCursorStore();

  /// 测试隔离：游标是静态状态，用例之间必须清空。
  @visibleForTesting
  static void resetForTest() => cursorStore.clear();

  static Future<CommentPage> fetch(
    String aid, {
    required CommentKind kind,
    int page = 1,
    int limit = kCommentPageSize,
  }) async {
    final storeKey = _storeKeyOf(aid, kind);
    final cursor = page > 1 ? cursorStore.read(storeKey, page) : null;
    // 匿名口径：评论接口不能带 buvid Cookie（带 Cookie 会退回「只给 3 条
    // 热评 + is_end=true」的降级响应），也不需要 WBI，client 不会拉会话。
    // JSON 作为 query 值由 Uri 统一编码；平台按 URL 解码后读 offset。
    final response = await BiliClient.shared.get(
      '/x/v2/reply/main',
      query: <String, Object?>{
        'type': '1',
        'oid': aid,
        'mode': kind == CommentKind.hot ? '3' : '2',
        if (cursor != null && cursor.isNotEmpty)
          'pagination_str': jsonEncode({'offset': cursor}),
      },
      retries: BuiltinTransport.defaultRetries,
    );

    final data = response is Map ? response['data'] : null;
    if (data is! Map) throw commentPlatformFailure('bili', '评论数据结构不符');
    final cursorData = data['cursor'] is Map
        ? data['cursor'] as Map
        : const <String, dynamic>{};
    final nextOffset = _nextOffsetOf(cursorData['pagination_reply']);
    if (nextOffset != null) cursorStore.write(storeKey, page + 1, nextOffset);

    return CommentPage(
      kind: kind,
      items: parseItems(data),
      page: page,
      limit: limit,
      total: commentIntOf(cursorData['all_count']),
      // B 站直接给出末页标记，比按 total 推断更可靠（热评顺序不稳定）。
      // 缺少 is_end 时按「有没有下一页游标」判定：空 / 未知游标若继续翻页
      // 会让 pager 请求同一页空数据，形成死循环。
      hasMore: _hasMoreOf(cursorData, nextOffset),
    );
  }

  static bool _hasMoreOf(Map cursorData, String? nextOffset) {
    final isEnd = cursorData['is_end'];
    // is_end 存在时沿用旧语义（`!= true` 即还有下一页）；缺失（null / 无字段）
    // 才看下一页游标。
    if (isEnd != null) return isEnd != true;
    return nextOffset != null && nextOffset.isNotEmpty;
  }

  /// `data.replies[]` → 评论；热评接口个别版本把热门条目放在 `data.hots`。
  static List<Comment> parseItems(Map data) {
    final replies = data['replies'];
    final list = replies is List && replies.isNotEmpty ? replies : data['hots'];
    if (list is! List) return const [];
    final comments = <Comment>[];
    for (final item in list) {
      final comment = _parseItem(item);
      if (comment != null) comments.add(comment);
    }
    return comments;
  }

  static Comment? _parseItem(dynamic raw, {bool includeReplies = true}) {
    if (raw is! Map) return null;
    final id = commentTextOf(raw['rpid']) ?? commentTextOf(raw['rpid_str']);
    final content = raw['content'] is Map
        ? raw['content'] as Map
        : const <String, dynamic>{};
    final text = decodeName(content['message']?.toString() ?? '').trim();
    if (id == null || text.isEmpty) return null;

    final member =
        raw['member'] is Map ? raw['member'] as Map : const <String, dynamic>{};
    final control = raw['reply_control'] is Map
        ? raw['reply_control'] as Map
        : const <String, dynamic>{};
    return Comment(
      id: id,
      text: text,
      createdAt: commentTimeFromEpoch(raw['ctime']),
      location: _locationOf(control['location']),
      authorName: member['uname']?.toString() ?? '',
      avatarUrl: commentUrlOf(member['avatar']),
      likedCount: commentIntOf(raw['like']),
      replies: includeReplies ? _parseReplies(raw['replies']) : const [],
    );
  }

  static List<Comment> _parseReplies(Object? raw) {
    if (raw is! List) return const [];
    final replies = <Comment>[];
    for (final item in raw) {
      final reply = _parseItem(item, includeReplies: false);
      if (reply != null) replies.add(reply);
    }
    return replies;
  }

  /// `IP属地：广东` / `IP属地: 广东` → `广东`。
  static String? _locationOf(Object? value) {
    final text = commentTextOf(value)?.trim();
    if (text == null || text.isEmpty) return null;
    final stripped = text.replaceFirst(RegExp(r'^IP属地\s*[:：]\s*'), '');
    return stripped.isEmpty ? null : stripped;
  }

  static String? _nextOffsetOf(Object? paginationReply) {
    if (paginationReply is! Map) return null;
    return commentTextOf(paginationReply['next_offset']);
  }

  static String _storeKeyOf(String aid, CommentKind kind) =>
      'bili:$aid:${kind.name}';
}
