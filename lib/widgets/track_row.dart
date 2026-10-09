import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'library_cover.dart';

/// 固定行高的曲目行（队列 / 收藏 / 历史共用）。
///
/// 为什么不直接用 M3EListItem：它的 supportingText 固定 `maxLines: 2`、
/// 容器高度是 `minHeight`，长歌手名会把行撑高，懒加载列表无法给出精确
/// extent（滚动条拇指尺寸与拖动定位会漂移）。本组件把行高固定为 [extent]、
/// 标题/歌手都单行省略，列表因此可以传 `itemExtent` 预取高度。
///
/// 视觉与交互仍取 M3E 主题令牌 + [M3EListRowSurface]（选中底、hover/press
/// 状态层、圆角），与 M3E 列表行保持一致。
class TrackRow extends StatelessWidget {
  const TrackRow({
    super.key,
    required this.title,
    this.artist = '',
    this.coverUrl,
    this.coverSize = 44,
    this.trailingText,
    this.trailing,
    this.selected = false,
    this.showCheckWhenSelected = true,
    this.radius = BorderRadius.zero,
    this.onTap,
    this.onLongPress,
  });

  /// 固定行高：可直接作为 `itemExtent` / `SliverFixedExtentList` 的高度。
  static const double extent = 72;

  final String title;
  final String artist;
  final String? coverUrl;
  final double coverSize;

  /// 行尾元信息（时长/计数），未知时传 null 不占位。
  final String? trailingText;

  /// 行尾插槽（排序把手、均衡器图形等）。
  final Widget? trailing;

  final bool selected;

  /// 多选态下把封面翻转为勾选图标；播放队列的选中行不需要。
  final bool showCheckWhenSelected;

  /// 行表面圆角：整组首/末行传主题圆角，中间行保持直角拼成一张卡片。
  final BorderRadius radius;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final M3EThemeData m3e = M3ETheme.of(context);
    final M3EColorScheme scheme = m3e.colorScheme;
    final M3ETypeScale type = m3e.typeScale;
    final Color contentColor =
        selected ? scheme.onSecondaryContainer : scheme.onSurface;
    final Color supportingColor =
        selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;

    return M3EListRowSurface(
      variant: M3ECardVariant.filled,
      radius: radius,
      color: scheme.surfaceContainerHighest,
      selected: selected,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel: artist.isEmpty ? title : '$title, $artist',
      child: SizedBox(
        height: extent,
        child: Row(
          children: [
            _buildLeading(context, scheme),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.bodyLarge.copyWith(color: contentColor),
                  ),
                  if (artist.isNotEmpty)
                    Text(
                      artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.bodyMedium.copyWith(color: supportingColor),
                    ),
                ],
              ),
            ),
            if (trailingText != null) ...[
              const SizedBox(width: 12),
              Text(
                trailingText!,
                style: type.labelSmall.copyWith(color: supportingColor),
              ),
            ],
            if (trailing != null) ...[
              const SizedBox(width: 12),
              IconTheme.merge(
                data: IconThemeData(color: supportingColor, size: 20),
                child: trailing!,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 缩略图 / 多选勾选翻转（M3E 列表的 selectedIcon 语义）。
  Widget _buildLeading(BuildContext context, M3EColorScheme scheme) {
    final Widget cover = LibraryCoverThumb(url: coverUrl, size: coverSize);
    if (!showCheckWhenSelected) return cover;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: selected
          ? Icon(
              Icons.check_circle_rounded,
              key: const ValueKey<String>('selected'),
              size: coverSize * 0.7,
              color: scheme.onSecondaryContainer,
            )
          : KeyedSubtree(
              key: const ValueKey<String>('cover'),
              child: cover,
            ),
    );
  }
}
