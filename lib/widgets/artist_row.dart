import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'card_list_surface.dart';
import 'library_cover.dart';

/// 固定行高的歌手行（搜索结果「歌手」类型；与 [TrackRow] 同一行高节奏）。
///
/// 与曲目行共用 [CardListSurface] 表面与形状语义；头像圆形（歌手视觉），
/// 缺图时回退名字首字占位。
class ArtistRow extends StatelessWidget {
  const ArtistRow({
    super.key,
    required this.name,
    this.avatarUrl,
    this.subtitle,
    this.coverSize = 44,
    this.position = M3ECardPosition.single,
    this.onTap,
  });

  /// 固定行高：可直接作为 `itemExtent`（与 [TrackRow.extent] 对齐）。
  static const double extent = 72;

  final String name;
  final String? avatarUrl;

  /// 副标题（歌曲数等）；null 不占位。
  final String? subtitle;

  final double coverSize;
  final M3ECardPosition position;
  final VoidCallback? onTap;

  /// 分段列表的相邻行距（与 [TrackRow.gapOf] 同一 token）。
  static double gapOf(BuildContext context) =>
      M3ETheme.of(context).listTheme.cardList.gap;

  @override
  Widget build(BuildContext context) {
    final M3EThemeData m3e = M3ETheme.of(context);
    final M3EColorScheme scheme = m3e.colorScheme;
    final M3ETypeScale type = m3e.typeScale;
    final supportingColor = scheme.onSurfaceVariant;
    return CardListSurface(
      position: position,
      onPressed: onTap,
      semanticLabel: subtitle == null ? name : '$name, $subtitle',
      child: SizedBox(
        height: extent,
        child: Row(
          children: [
            ClipOval(
              child: SizedBox(
                width: coverSize,
                height: coverSize,
                child: (avatarUrl?.isNotEmpty ?? false)
                    ? LibraryCoverThumb(url: avatarUrl, size: coverSize)
                    : _buildPlaceholder(scheme),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.bodyLarge.copyWith(color: scheme.onSurface),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.bodyMedium.copyWith(color: supportingColor),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(Icons.chevron_right_rounded, size: 20, color: supportingColor),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholder(M3EColorScheme scheme) => ColoredBox(
        color: scheme.surfaceContainerHighest,
        child: Icon(
          Icons.person_rounded,
          size: coverSize * 0.6,
          color: scheme.onSurfaceVariant,
        ),
      );
}
