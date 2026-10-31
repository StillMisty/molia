/// 评论列表视图（单个 tab：热门 / 最新）。
///
/// 只消费 [CommentsProvider] 的状态：空态 / 错误态（归一化失败，不展示原始
/// 异常）/ 首屏加载 / 触底分页；评论行见 [CommentRow]。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/comment.dart';
import '../l10n/app_localizations.dart';
import '../providers/comments_provider.dart';
import '../theme/m3e_context.dart';
import 'comment_avatar.dart';
import 'detail_page/detail_page_chrome.dart';
import 'paged_list_auto_load.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本组件而不注册 delegate，
/// 此时回退到简体中文（与换源视图同一约定）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 评论时间：1 分钟内「刚刚」、1 小时内「N 分钟前」、24 小时内「N 小时前」，
/// 其余展示日期（与 LX `dateFormat2` 同口径）。
String commentTimeLabel(AppLocalizations l10n, DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inSeconds < 60) return l10n.commentsTimeJustNow;
  if (diff.inMinutes < 60) return l10n.commentsTimeMinutesAgo(diff.inMinutes);
  if (diff.inHours < 24) return l10n.commentsTimeHoursAgo(diff.inHours);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)}';
}

/// 单类评论列表（分页加载 + 刷新 + 空/错误态）。
class CommentListView extends StatelessWidget {
  const CommentListView({super.key, required this.kind});

  final CommentKind kind;

  /// 楼中楼最多内联渲染的条数（平台随列表返回，不单独分页拉取）。
  static const int maxInlineReplies = 3;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<CommentsProvider>();
    final state = provider.stateOf(kind);
    if (!provider.isSupported) {
      return DetailPageEmpty(
        icon: Icons.comments_disabled_rounded,
        message: _l10n(context).commentsUnsupported,
      );
    }
    if (state.isLoading && state.items.isEmpty) {
      return const DetailPageLoading();
    }
    // 空态 / 错误态也要能下拉刷新：内容不满一屏时包一层可滚动的状态容器。
    // 错误态只保留下拉手势，不再放「重试」按钮。
    final Widget content;
    if (state.failed) {
      content = _RefreshableStatus(
        child: DetailPageFailure(
          message: _l10n(context).commentsLoadFailed,
          hint: _l10n(context).commentsPullToRetry,
        ),
      );
    } else if (state.isEmpty) {
      content = _RefreshableStatus(
        child: DetailPageEmpty(
          icon: Icons.forum_rounded,
          message: _l10n(context).commentsEmpty,
        ),
      );
    } else {
      content = PagedListAutoLoad(
        // 触底自动取下一页；失败后不自动重试（页脚保留重试，否则滚动通知
        // 会在失败后持续重放请求）。
        hasMore: state.hasMore,
        isLoadingMore: state.isLoadingMore,
        loadMoreFailed: state.loadMoreFailed,
        onLoadMore: () => unawaited(provider.loadMore()),
        child: ListView.builder(
          padding: const EdgeInsets.only(bottom: 24),
          // 末项固定为页脚（加载中 / 加载更多失败 / 已到底）。
          itemCount: state.items.length + 1,
          itemBuilder: (context, index) {
            if (index == state.items.length) {
              return PagedListFooter(
                hasMore: state.hasMore,
                isLoadingMore: state.isLoadingMore,
                loadMoreFailed: state.loadMoreFailed,
                onRetry: () => unawaited(provider.loadMore()),
                failureLabel: _l10n(context).commentsLoadMoreFailed,
                endLabel: _l10n(context).commentsNoMore,
                retryKey: const Key('commentsLoadMoreRetry'),
              );
            }
            final comment = state.items[index];
            return Column(
              children: [
                CommentRow(comment: comment),
                if (index < state.items.length - 1)
                  const M3EDivider(inset: M3EDividerInset.middle),
              ],
            );
          },
        ),
      );
    }
    return M3ERefreshIndicator(
      // 首屏失败没有缓存可清，重试直接重新取数；其余状态刷新当前 tab。
      onRefresh: state.failed ? provider.retry : provider.refresh,
      child: content,
    );
  }
}

/// 单条评论行：头像 + 昵称 + 时间/IP + 正文 + 点赞数（+ 引用 / 楼中楼）。
class CommentRow extends StatelessWidget {
  const CommentRow({
    super.key,
    required this.comment,
    this.depth = 0,
    this.indent = 0,
  });

  final Comment comment;

  /// 嵌套层级（0 = 主评论，>0 = 楼中楼；更小头像 + 更紧的垂直留白）。
  final int depth;

  /// 额外左侧缩进（不含页面边距）。主评论 0，每层回复 +20；封顶后不再继续缩进。
  ///
  /// 回复必须渲染在主行之外的全宽区域：若塞进父评论的内容列，再叠加
  /// 层级缩进，一级回复就会从屏幕一半处开始，正文被挤成窄条。
  final double indent;

  /// 楼中楼最多渲染的层级（平台通常只有一层，留一层余量防异常数据递归）。
  static const int maxDepth = 2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = _l10n(context);
    final nested = depth > 0;
    final avatarSize = nested ? 24.0 : 36.0;
    final replies = comment.replies.take(CommentListView.maxInlineReplies);
    final horizontal = detailPageHorizontalPadding(context);

    final row = Padding(
      padding: EdgeInsets.fromLTRB(
        horizontal + indent,
        nested ? 8 : 12,
        horizontal,
        nested ? 8 : 12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CommentAvatar(url: comment.avatarUrl, size: avatarSize),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        comment.authorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.typeScale.labelLarge.copyWith(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    if (comment.likedCount != null) ...[
                      const SizedBox(width: 8),
                      _LikedCount(count: comment.likedCount!),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                _buildMeta(context, l10n),
                if (comment.quoted case final quoted?) ...[
                  const SizedBox(height: 6),
                  _QuotedComment(comment: quoted),
                ],
                const SizedBox(height: 6),
                Text(
                  comment.text,
                  style: context.typeScale.bodyMedium.copyWith(
                    color: scheme.onSurface,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (replies.isEmpty || depth >= maxDepth) return row;

    final nextIndent = indent + 20 > 80 ? 80.0 : indent + 20;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        for (final reply in replies)
          CommentRow(comment: reply, depth: depth + 1, indent: nextIndent),
      ],
    );
  }

  /// 时间 + IP 归属（两者都缺时不占行）。
  Widget _buildMeta(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final style = context.typeScale.bodySmall.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final time = comment.createdAt;
    final location = comment.location;
    if (time == null && (location == null || location.isEmpty)) {
      return const SizedBox.shrink();
    }
    return Row(
      children: [
        if (time != null)
          Text(commentTimeLabel(l10n, time), maxLines: 1, style: style),
        if (location != null && location.isNotEmpty) ...[
          if (time != null) const SizedBox(width: 8),
          Flexible(
            child: Text(
              l10n.commentsIpLocation(location),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      ],
    );
  }
}

/// 点赞数：图标 + 数字（无点赞数据时整块隐藏）。
class _LikedCount extends StatelessWidget {
  const _LikedCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.thumb_up_rounded, size: 13, color: color),
        const SizedBox(width: 3),
        Text(
          '$count',
          style: context.typeScale.labelSmall.copyWith(color: color),
        ),
      ],
    );
  }
}

/// 被引用的原评论（回复场景）：弱化底色 + 「昵称：正文」。
class _QuotedComment extends StatelessWidget {
  const _QuotedComment({required this.comment});

  final Comment comment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = _l10n(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: l10n.commentsQuotedAuthor(comment.authorName),
              style: context.typeScale.bodySmall.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(
              text: comment.text,
              style: context.typeScale.bodySmall.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// 空态 / 错误态的可下拉容器：内容不满一屏时也能触发刷新。
class _RefreshableStatus extends StatelessWidget {
  const _RefreshableStatus({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: child,
        ),
      ],
    );
  }
}
