import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'card_list_surface.dart';
import 'library_cover.dart';

/// 固定行高的曲目行（队列 / 收藏 / 历史 / 发现详情 / 搜索结果共用）。
///
/// 行高固定为 [extent]（标题/歌手都单行省略），列表可以传 `itemExtent`
/// 预取高度（分段列表再加 [gapOf] 行距），滚动条拇指尺寸与拖动定位精确。
///
/// 表面用共享的 [CardListSurface]（M3E 列表规范 + 弹簧 shape morph）；
/// 为什么不用 `M3EListItem` / `M3EListRowSurface` 见 docs/pitfalls.md #20。
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
    this.position = M3ECardPosition.single,
    this.onTap,
    this.onLongPress,
  });

  /// 固定行高：可直接作为 `itemExtent` / `SliverFixedExtentList` 的高度
  /// （分段列表需再加 [gapOf] 行距）。
  static const double extent = 72;

  final String title;
  final String artist;
  final String? coverUrl;
  final double coverSize;

  /// 行尾元信息（时长/计数），未知时传 null 不占位。
  final String? trailingText;

  /// 行尾插槽（排序把手、菜单按钮等）。
  final Widget? trailing;

  final bool selected;

  /// 多选态下把封面翻转为勾选图标；播放队列的选中行不需要。
  final bool showCheckWhenSelected;

  /// 行在列表中的位置：决定静止形状（首/末行外侧 16dp、内行 4dp）。
  /// 由列表用 `calculateCardPosition(index, count)` 计算。
  final M3ECardPosition position;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 分段列表的相邻行距（M3E 列表卡片 token）。
  /// 列表 itemExtent 用 `TrackRow.extent + TrackRow.gapOf(context)`。
  static double gapOf(BuildContext context) =>
      M3ETheme.of(context).listTheme.cardList.gap;

  @override
  Widget build(BuildContext context) {
    final M3EThemeData m3e = M3ETheme.of(context);
    final M3EColorScheme scheme = m3e.colorScheme;
    final M3ETypeScale type = m3e.typeScale;
    final Color contentColor =
        selected ? scheme.onSecondaryContainer : scheme.onSurface;
    final Color supportingColor =
        selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;

    return CardListSurface(
      position: position,
      selected: selected,
      onPressed: onTap,
      onLongPress: onLongPress,
      semanticLabel: artist.isEmpty ? title : '$title, $artist',
      child: SizedBox(
        height: extent,
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
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
                // 行尾元信息贴行右缘：普通 Text 取自身宽度（不用 Flexible：
                // loose Flexible 会与标题列平分剩余宽度，时长只有 28dp 却
                // 占走一半、右侧留白）。封顶半行宽 + 省略：窄屏/超长元信息
                // 收缩省略，而不是把行撑溢出。
                ConstrainedBox(
                  constraints:
                      BoxConstraints(maxWidth: constraints.maxWidth / 2),
                  child: Text(
                    trailingText!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: type.labelSmall.copyWith(color: supportingColor),
                  ),
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
