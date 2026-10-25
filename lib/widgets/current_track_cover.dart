import 'package:material_ui/material_ui.dart';

/// 当前曲目封面：封面右下角叠「播放中 / 暂停」角标。
///
/// 封面内容由调用方给出（曲目行走 [TrackArtwork]）；这里只负责角标与固定
/// 方形槽，保证状态切换不改变行内网格。
class CurrentTrackCover extends StatelessWidget {
  const CurrentTrackCover({
    super.key,
    required this.cover,
    required this.size,
    required this.isPlaying,
  });

  /// 已解析的封面（`TrackArtwork` 或同等尺寸的图片组件）。
  final Widget cover;

  final double size;
  final bool isPlaying;

  /// 角标直径：40 / 44 封面共用同一档，图标再小一圈。
  static const double badgeSize = 18;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          cover,
          Positioned(
            right: 0,
            bottom: 0,
            child: ExcludeSemantics(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
                child: SizedBox.square(
                  dimension: badgeSize,
                  child: Center(
                    child: Icon(
                      isPlaying
                          ? Icons.graphic_eq_rounded
                          : Icons.pause_rounded,
                      size: 12,
                      color: scheme.onPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
