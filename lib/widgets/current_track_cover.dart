import 'package:material_ui/material_ui.dart';

import 'playing_indicator.dart';

/// 当前曲目封面：封面右下角叠播放状态角标。
///
/// 播放中默认是三柱均衡器**静态相位**；只有调用方显式传 [animate] 才起伏
/// （曲目行 / AI 页会传 true；发现页推荐卡直接用 [AnimatedPlayingBadge]）。
/// 暂停时角标停在当前相位，减弱动效或 [TickerMode] 关闭时不跑 ticker。
///
/// 封面内容由调用方给出（曲目行走 [TrackArtwork]）；这里只负责角标与固定
/// 方形槽，保证状态切换不改变行内网格。
class CurrentTrackCover extends StatelessWidget {
  const CurrentTrackCover({
    super.key,
    required this.cover,
    required this.size,
    required this.isPlaying,
    this.animate = false,
  });

  /// 已解析的封面（`TrackArtwork` 或同等尺寸的图片组件）。
  final Widget cover;

  final double size;
  final bool isPlaying;

  /// 是否播放起伏动画：默认 false（只作状态标识的静态封面）。
  final bool animate;

  /// 角标直径：40 / 44 封面共用同一档，图标再小一圈。
  static const double badgeSize = 18;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          cover,
          Positioned(
            right: 0,
            bottom: 0,
            child: AnimatedPlayingBadge(
              isPlaying: isPlaying,
              animate: animate,
              size: badgeSize,
            ),
          ),
        ],
      ),
    );
  }
}
