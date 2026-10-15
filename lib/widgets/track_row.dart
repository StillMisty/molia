import 'package:flutter/gestures.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'card_list_surface.dart';
import 'library_cover.dart';

/// 曲目行里的歌手链接（名字 + 点击回调；回调为空 = 纯文本）。
///
/// 搜索结果行传入逐名可点的歌手（内置平台曲目带平台内 id 时）；其它入口
/// 只传整串 [TrackRow.artist]，两者互斥（[TrackRow.artists] 非空即优先）。
class TrackRowArtist {
  final String name;
  final VoidCallback? onTap;

  const TrackRowArtist({required this.name, this.onTap});

  @override
  bool operator ==(Object other) =>
      other is TrackRowArtist && other.name == name && other.onTap == onTap;

  @override
  int get hashCode => Object.hash(name, onTap);
}

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
    this.artists,
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

  /// 逐名可点的歌手（搜索结果）：非空时副标题按链接渲染（[artist] 仍作为
  /// 无障碍文案与回退）。仅当歌手带平台内 id（可进歌手页）时才需要。
  final List<TrackRowArtist>? artists;

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
    final artistLinks = artists;

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
                    if (artistLinks != null && artistLinks.isNotEmpty)
                      _ArtistLinks(
                        artists: artistLinks,
                        style: type.bodyMedium.copyWith(color: supportingColor),
                        linkStyle: type.bodyMedium.copyWith(
                          color: scheme.primary,
                        ),
                      )
                    else if (artist.isNotEmpty)
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

/// 逐名可点的歌手副标题：单行 `Text.rich` + 每个可点名字一个
/// [TapGestureRecognizer]（点击不触发行本身的播放手势）。
///
/// 为什么是 StatefulWidget：识别器必须持有并释放（`dispose`），
/// stateless 的 `Text.rich` 每次 build 新建识别器会泄漏。重建时先释放上一批
/// 识别器——手势只在帧间事件循环里派发，build 期释放是安全的。
class _ArtistLinks extends StatefulWidget {
  const _ArtistLinks({
    required this.artists,
    required this.style,
    required this.linkStyle,
  });

  final List<TrackRowArtist> artists;
  final TextStyle style;
  final TextStyle linkStyle;

  @override
  State<_ArtistLinks> createState() => _ArtistLinksState();
}

class _ArtistLinksState extends State<_ArtistLinks> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _releaseRecognizers();
    super.dispose();
  }

  void _releaseRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _releaseRecognizers();
    final spans = <TextSpan>[];
    for (var index = 0; index < widget.artists.length; index++) {
      final artist = widget.artists[index];
      if (index > 0) spans.add(TextSpan(text: '、', style: widget.style));
      final onTap = artist.onTap;
      if (onTap == null) {
        spans.add(TextSpan(text: artist.name, style: widget.style));
        continue;
      }
      final recognizer = TapGestureRecognizer()..onTap = onTap;
      _recognizers.add(recognizer);
      spans.add(TextSpan(
        text: artist.name,
        style: widget.linkStyle,
        recognizer: recognizer,
      ));
    }
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: widget.style,
    );
  }
}
