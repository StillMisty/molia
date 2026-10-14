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
import 'app_network_image.dart';

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
      return _EmptyState(
        icon: Icons.comments_disabled_rounded,
        text: _l10n(context).commentsUnsupported,
      );
    }
    if (state.isLoading && state.items.isEmpty) {
      return const Center(child: M3ELoadingIndicator());
    }
    if (state.failed) {
      return _ErrorState(onRetry: provider.retry);
    }
    if (state.isEmpty) {
      return _EmptyState(
        icon: Icons.forum_rounded,
        text: _l10n(context).commentsEmpty,
      );
    }
    return M3ERefreshIndicator(
      onRefresh: provider.refresh,
      child: NotificationListener<ScrollNotification>(
        // 触底 400px 内自动取下一页；失败后不自动重试（底部保留重试按钮，
        // 否则滚动通知会在失败后持续重放请求）。
        onNotification: (notification) {
          if (notification.metrics.axis != Axis.vertical) return false;
          if (notification.metrics.pixels >=
              notification.metrics.maxScrollExtent - 400) {
            if (!provider.stateOf(kind).loadMoreFailed) {
              unawaited(provider.loadMore());
            }
          }
          return false;
        },
        child: ListView.builder(
          padding: const EdgeInsets.only(bottom: 24),
          // 末项固定为页脚（加载中 / 加载更多失败 / 已到底）。
          itemCount: state.items.length + 1,
          itemBuilder: (context, index) {
            if (index == state.items.length) {
              return _buildFooter(context, provider, state);
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
      ),
    );
  }

  Widget _buildFooter(
    BuildContext context,
    CommentsProvider provider,
    CommentsTabState state,
  ) {
    final l10n = _l10n(context);
    final theme = Theme.of(context);
    if (state.isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: M3EProgressIndicator.circular(size: 24, strokeWidth: 3),
        ),
      );
    }
    if (state.loadMoreFailed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            Text(
              l10n.commentsLoadMoreFailed,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            M3EButton.text(
              onPressed: () => unawaited(provider.loadMore()),
              child: Text(l10n.retry),
            ),
          ],
        ),
      );
    }
    if (!state.hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            l10n.commentsNoMore,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return const SizedBox(height: 16);
  }
}

/// 单条评论行：头像 + 昵称 + 时间/IP + 正文 + 点赞数（+ 引用 / 楼中楼）。
class CommentRow extends StatelessWidget {
  const CommentRow({super.key, required this.comment, this.depth = 0});

  final Comment comment;

  /// 嵌套层级（0 = 主评论，>0 = 楼中楼；缩进 + 更小头像）。
  final int depth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = _l10n(context);
    final nested = depth > 0;
    final avatarSize = nested ? 24.0 : 36.0;
    final replies = comment.replies.take(CommentListView.maxInlineReplies);

    return Padding(
      padding: EdgeInsets.fromLTRB(nested ? 20.0 + depth * 28 : 20, 12, 20, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppNetworkImage(
            url: comment.avatarUrl,
            width: avatarSize,
            height: avatarSize,
            borderRadius: BorderRadius.circular(avatarSize / 2),
            fallbackIconSize: nested ? 12 : 18,
          ),
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
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
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
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurface,
                    height: 1.35,
                  ),
                ),
                for (final reply in replies)
                  CommentRow(comment: reply, depth: depth + 1),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 时间 + IP 归属（两者都缺时不占行）。
  Widget _buildMeta(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
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
        Text('$count', style: theme.textTheme.labelSmall?.copyWith(color: color)),
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
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text: comment.text,
              style: theme.textTheme.bodySmall?.copyWith(
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 首屏错误态：文案走 l10n（不展示 `$e`），提供重试。
class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = _l10n(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 40,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.commentsLoadFailed,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            M3EButton.filled(
              onPressed: () => unawaited(onRetry()),
              child: Text(l10n.retry),
            ),
          ],
        ),
      ),
    );
  }
}
