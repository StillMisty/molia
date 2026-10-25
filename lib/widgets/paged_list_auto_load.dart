/// 分页列表的通用自动加载与底部状态。
///
/// 所有分页列表（搜索 / 发现歌单 / 专辑 / 歌手 / 歌单详情 / 评论）共用同一套
/// 取页时机与页脚：列表滚到底部自动取下一页，不再由用户点「加载更多」；
/// 失败后停在当前页，由页脚提供一次手动重试。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import '../theme/m3e_context.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 触底自动加载：包住列表的滚动视图即可。
///
/// 触发时机：
/// - 用户滚动到距底 [triggerDistance] 内（预取一屏的零头，滚动不中断）；
/// - 首屏内容不满一屏（`maxScrollExtent == 0`）：布局完成后继续取下一页。
///   去掉「加载更多」按钮后，高窗口 / 平台短页没有滚动事件，必须靠这条兜底。
///
/// 失败后不自动重试：滚动通知会随惯性持续到来，自动重试会变成请求风暴；
/// 失败态由 [PagedListFooter] 的「重试」手动恢复。
class PagedListAutoLoad extends StatefulWidget {
  const PagedListAutoLoad({
    super.key,
    required this.hasMore,
    required this.isLoadingMore,
    required this.loadMoreFailed,
    required this.onLoadMore,
    required this.child,
    this.failed = false,
  });

  /// 距底多少像素开始预取。
  static const double triggerDistance = 400;

  /// 是否还有下一页。
  final bool hasMore;

  /// 下一页是否加载中（加载中不重复触发；控制器亦会拦截）。
  final bool isLoadingMore;

  /// 加载更多是否失败（失败后不自动重试，等用户点页脚重试）。
  final bool loadMoreFailed;

  /// 首屏是否失败：错误态不自动取页。
  final bool failed;

  final VoidCallback onLoadMore;

  /// 列表的滚动视图（`CustomScrollView` / `ListView` 等）。
  final Widget child;

  @override
  State<PagedListAutoLoad> createState() => _PagedListAutoLoadState();
}

class _PagedListAutoLoadState extends State<PagedListAutoLoad> {
  /// 已发出请求、但外部状态还没在下一帧反映出来。
  ///
  /// 一次拖动 / 惯性会在同一帧内派发多条滚动通知；仅靠 [widget.isLoadingMore]
  /// 会因 props 还是旧值而重复请求（失败后尤其会连发），这里兜住同帧重入。
  bool _pending = false;

  @override
  void didUpdateWidget(covariant PagedListAutoLoad oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部状态已经反映这次请求（进入加载中 / 失败 / 到底 / 首屏失败）：
    // 释放重入闸门，后续滚动或续取可以再次触发。
    if (oldWidget.hasMore != widget.hasMore ||
        oldWidget.isLoadingMore != widget.isLoadingMore ||
        oldWidget.loadMoreFailed != widget.loadMoreFailed ||
        oldWidget.failed != widget.failed) {
      _pending = false;
    }
  }

  bool get _canLoad =>
      widget.hasMore &&
      !widget.isLoadingMore &&
      !widget.loadMoreFailed &&
      !widget.failed;

  void _maybeLoad() {
    if (!_canLoad || _pending) return;
    _pending = true;
    widget.onLoadMore();
    // 外部状态（isLoadingMore / loadMoreFailed / hasMore）会在下一帧回灌；
    // 若实现方不发布状态也不至于永久卡住。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pending = false;
    });
  }

  bool _onScroll(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return false;
    if (metrics.pixels >=
        metrics.maxScrollExtent - PagedListAutoLoad.triggerDistance) {
      _maybeLoad();
    }
    return false;
  }

  bool _onMetrics(ScrollMetricsNotification notification) {
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return false;
    // 内容不满一屏：没有滚动事件可等，布局完成后直接续取。
    if (metrics.maxScrollExtent <= 0) _maybeLoad();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: _onMetrics,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: widget.child,
      ),
    );
  }
}

/// 分页列表的底部状态：加载中 / 加载更多失败（重试）/ 已到底。
///
/// 只负责状态呈现；取页仍由 [PagedListAutoLoad] 或手动重试触发。
class PagedListFooter extends StatelessWidget {
  const PagedListFooter({
    super.key,
    required this.isLoadingMore,
    required this.loadMoreFailed,
    required this.onRetry,
    this.hasMore = true,
    this.failureLabel,
    this.endLabel,
    this.retryKey,
    this.padding = const EdgeInsets.fromLTRB(16, 16, 16, 8),
  });

  final bool isLoadingMore;
  final bool loadMoreFailed;
  final VoidCallback onRetry;

  /// 是否还有下一页（决定 [endLabel] 是否展示）。
  final bool hasMore;

  /// 加载更多失败的说明（不传则只显示重试按钮）。
  final String? failureLabel;

  /// 已到底的结束文案（评论列表使用；其余列表不占位）。
  final String? endLabel;

  /// 重试按钮的 Key（测试定位用）。
  final Key? retryKey;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (isLoadingMore) {
      return Padding(
        padding: padding,
        child: const Center(
          child: M3EProgressIndicator.circular(size: 28, strokeWidth: 2.5),
        ),
      );
    }
    if (loadMoreFailed) {
      return Padding(
        padding: padding,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (failureLabel case final label?) ...[
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: context.typeScale.bodySmall.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              M3EButton.icon(
                key: retryKey,
                style: M3EButtonStyle.outlined,
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(_l10n(context).retry),
              ),
            ],
          ),
        ),
      );
    }
    final end = endLabel;
    if (!hasMore && end != null) {
      return Padding(
        padding: padding,
        child: Center(
          child: Text(
            end,
            textAlign: TextAlign.center,
            style: context.typeScale.bodySmall.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    // 还有下一页但不加载 / 无结束文案：只留一点与列表的间距。
    return const SizedBox(height: 16);
  }
}
