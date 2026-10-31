/// 二级详情页共用 chrome：曲目条、头部、tab 栏与加载 / 空 / 失败态。
///
/// 评论 / 换源 / 本地数据 / 专辑 / 歌手页共用这一份配方：
/// 页边距统一从 [ResponsivePageType.detail] 解析，避免每个页面各自写死
/// 16 / 24，宽屏侧滑与窄屏全屏切换时也不会出现两套对齐。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/track.dart';
import '../../theme/m3e_context.dart';
import '../../utils/responsive.dart';
import '../empty_state.dart';
import '../track_artwork.dart';

/// 详情页正文的左右页边距（平板 / 桌面 24，手机 16）。
double detailPageHorizontalPadding(BuildContext context) =>
    context.layoutType(ResponsivePageType.detail).horizontalPadding;

/// 紧凑曲目身份条：封面 + 歌名 + 歌手（或调用方给的副标题）。
///
/// 用于以单首曲目为对象的二级页（评论 / 本地数据 / 换源）：曲目在两处 tab 之间保持
/// 同一位置，切 tab 不重复占位。视觉与换源页原曲目条一致，只把页边距从
/// 页面外圈收进组件，页面不必再包一层水平 Padding。
class DetailPageTrackHeader extends StatelessWidget {
  const DetailPageTrackHeader({
    super.key,
    required this.track,
    this.subtitle,
    this.padding,
  });

  final Track track;

  /// 副标题；缺省为 [Track.artistLabel]（换源页会补上当前来源）。
  final String? subtitle;

  /// 外层已给页边距时用它覆盖默认值（如列表页首项）。
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final horizontal = detailPageHorizontalPadding(context);
    final subtitleText = subtitle ?? track.artistLabel;
    return Padding(
      padding: padding ?? EdgeInsets.fromLTRB(horizontal, 12, horizontal, 8),
      child: Row(
        children: [
          TrackArtwork(
            track: track,
            size: 40,
            borderRadius: BorderRadius.circular(10),
            // 列表头像按 40dp 容器解码，避免把整张原图留在内存里。
            memCacheWidth: (40 * MediaQuery.devicePixelRatioOf(context))
                .round(),
            fallbackColor: theme.colorScheme.surfaceContainerHighest,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.typeScale.titleMedium,
                ),
                // 无歌手 / 无副标题时不占第二行：空白行会让曲目条看起来缺内容。
                if (subtitleText.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitleText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typeScale.bodySmall.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 详情页头部：封面 / 头像 + 标题 + 副标题 + 可选简介与行动。
///
/// 封面由调用方构建（专辑方图 96、歌手圆头像 96）：组件只负责排版与页边距，
/// 不替调用方决定裁切形状或点击行为。简介与行动都放在标题行下方整宽，
/// 窄屏描述不被封面列挤窄。
class DetailPageHeroHeader extends StatelessWidget {
  const DetailPageHeroHeader({
    super.key,
    required this.artwork,
    required this.title,
    required this.subtitle,
    this.description,
    this.action,
    this.padding,
  });

  /// 调用方构建的 96dp 封面 / 头像。
  final Widget artwork;

  final String title;

  /// 一行身份说明（歌手 · 年份 · 曲目数等，由调用方拼接）。
  final String subtitle;

  /// 可选简介（最多 3 行，超出省略）。
  final String? description;

  /// 头部主行动（如「播放全部」的分裂按钮）。
  final Widget? action;

  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final horizontal = detailPageHorizontalPadding(context);
    final description = this.description;
    final action = this.action;
    return Padding(
      padding: padding ?? EdgeInsets.fromLTRB(horizontal, 8, horizontal, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              artwork,
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.typeScale.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: context.typeScale.bodySmall.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (description != null && description.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: context.typeScale.bodySmall.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 12), action],
        ],
      ),
    );
  }
}

/// 详情页次 tab 栏：统一图标在文案左侧、行高 48 的 secondary 形态。
///
/// 页边距与曲目条 / 头部一致，tab 栏、头部与列表内容左缘才能对齐；
/// 默认底部 8 给下方内容留一点呼吸空间。
class DetailPageTabBar extends StatelessWidget {
  const DetailPageTabBar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onTabSelected,
    this.padding,
  });

  final List<M3ETab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;

  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final horizontal = detailPageHorizontalPadding(context);
    return Padding(
      padding: padding ?? EdgeInsets.fromLTRB(horizontal, 0, horizontal, 8),
      child: M3ETabs(
        variant: M3ETabsVariant.secondary,
        tabs: tabs,
        selectedIndex: selectedIndex,
        onTabSelected: onTabSelected,
      ),
    );
  }
}

/// 详情页居中加载态；[label] 说明正在取什么（首屏无内容时）。
class DetailPageLoading extends StatelessWidget {
  const DetailPageLoading({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = this.label;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const M3ELoadingIndicator(),
            if (label != null) ...[
              const SizedBox(height: 12),
              Text(
                label,
                textAlign: TextAlign.center,
                style: context.typeScale.bodyMedium.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 详情页居中空态：图标 + 文案 + 可选下一步提示 / 行动。
class DetailPageEmpty extends StatelessWidget {
  const DetailPageEmpty({
    super.key,
    required this.icon,
    required this.message,
    this.hint,
    this.action,
  });

  final IconData icon;
  final String message;

  /// 下一步提示（如「换个来源试试」）：告诉用户空态下还能做什么。
  final String? hint;

  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: EmptyState(
          icon: icon,
          message: message,
          hint: hint,
          action: action,
        ),
      ),
    );
  }
}

/// 详情页居中失败态：只说「没取到 + 怎么办」，不展示原始异常。
///
/// [onRetry] 与 [retryLabel] 同时给时才出现重试按钮：部分页面（评论）的
/// 恢复入口只有下拉刷新手势，错误态里再放按钮会与手势重复。
class DetailPageFailure extends StatelessWidget {
  const DetailPageFailure({
    super.key,
    required this.message,
    this.hint,
    this.retryLabel,
    this.onRetry,
  });

  final String message;
  final String? hint;
  final String? retryLabel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = this.hint;
    final retryLabel = this.retryLabel;
    final onRetry = this.onRetry;
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
              message,
              textAlign: TextAlign.center,
              style: context.typeScale.bodyMedium.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: 6),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: context.typeScale.bodySmall.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (retryLabel != null && onRetry != null) ...[
              const SizedBox(height: 16),
              M3EButton.filled(onPressed: onRetry, child: Text(retryLabel)),
            ],
          ],
        ),
      ),
    );
  }
}
