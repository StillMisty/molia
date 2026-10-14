import 'equality.dart';

/// 评论类型：热门 / 最新（两个 tab 的取数口径）。
enum CommentKind { hot, latest }

/// 评论每页条数（内置平台实现与 UI 分页共用同一口径，与 LX 一致）。
const int kCommentPageSize = 20;

/// 领域层统一评论模型（不可变 + 值相等，UI 只读）。
///
/// 五平台（wy/tx/kg/kw/mg）字段差异在 `lib/sources/builtin/*_comment.dart`
/// 内归一化：文本已做表情还原与转义解码，时间统一为 [createdAt]。
class Comment {
  final String id;

  /// 正文（表情已还原为 emoji；平台转义已解码）。
  final String text;

  /// 平台时间（解析失败 / 平台未返回时为 null，UI 不展示时间）。
  final DateTime? createdAt;

  /// IP 归属地（平台未返回时为空）。
  final String? location;

  final String authorName;

  /// 头像地址（平台未返回时为空，UI 回退默认图）。
  final String? avatarUrl;

  /// 点赞数（平台未返回时为 null，UI 隐藏点赞区）。
  final int? likedCount;

  /// 被引用的原评论（「回复 @某人」场景；平台随列表返回时才有）。
  final Comment? quoted;

  /// 随列表返回的楼中楼回复（不单独分页拉取；UI 只渲染前若干条）。
  final List<Comment> replies;

  const Comment({
    required this.id,
    required this.text,
    this.createdAt,
    this.location,
    this.authorName = '',
    this.avatarUrl,
    this.likedCount,
    this.quoted,
    this.replies = const [],
  });

  bool get hasReplies => replies.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is Comment &&
      other.id == id &&
      other.text == text &&
      other.createdAt == createdAt &&
      other.location == location &&
      other.authorName == authorName &&
      other.avatarUrl == avatarUrl &&
      other.likedCount == likedCount &&
      other.quoted == quoted &&
      deepEquals(other.replies, replies);

  @override
  int get hashCode => Object.hash(
        id,
        text,
        createdAt,
        location,
        authorName,
        avatarUrl,
        likedCount,
        quoted,
        deepHash(replies),
      );

  @override
  String toString() => 'Comment($id, $authorName)';
}

/// 一页评论（分页游标 + 总数 + 是否还有下一页）。
class CommentPage {
  final CommentKind kind;
  final List<Comment> items;
  final int page;
  final int limit;

  /// 平台返回的评论总数（部分平台/分页不返回时为 null）。
  final int? total;

  final bool hasMore;

  const CommentPage({
    required this.kind,
    required this.items,
    required this.page,
    required this.limit,
    this.total,
    required this.hasMore,
  });

  /// 按「本页条数 + 平台总数」推断是否还有下一页：
  /// 有 total 时按页码算，无 total 时以「本页取满」近似。
  factory CommentPage.fromPage({
    required CommentKind kind,
    required List<Comment> items,
    required int page,
    required int limit,
    int? total,
  }) {
    final hasMore = total != null
        ? page * limit < total
        : items.length >= limit && items.isNotEmpty;
    return CommentPage(
      kind: kind,
      items: items,
      page: page,
      limit: limit,
      total: total,
      hasMore: hasMore,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CommentPage &&
      other.kind == kind &&
      deepEquals(other.items, items) &&
      other.page == page &&
      other.limit == limit &&
      other.total == total &&
      other.hasMore == hasMore;

  @override
  int get hashCode => Object.hash(
        kind,
        deepHash(items),
        page,
        limit,
        total,
        hasMore,
      );

  @override
  String toString() => 'CommentPage(${kind.name}, page=$page, ${items.length} 条)';
}
