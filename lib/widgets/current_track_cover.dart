import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/motion_policy.dart';
import 'icon_swap.dart';
import 'playing_indicator.dart';

/// 当前曲目封面：封面右下角叠「播放中 / 暂停」角标。
///
/// 封面内容由调用方给出（曲目行走 [TrackArtwork]）；这里只负责角标与固定
/// 方形槽，保证状态切换不改变行内网格。
class CurrentTrackCover extends StatefulWidget {
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
  State<CurrentTrackCover> createState() => _CurrentTrackCoverState();
}

class _CurrentTrackCoverState extends State<CurrentTrackCover>
    with SingleTickerProviderStateMixin {
  /// 暂停时停住的相位：三柱高低错落，静止时也读得出是均衡器。
  static const double _pausedPhase = 0.25;

  /// 播放中角标的起伏周期。取 M3E extraLong4（1000ms）：起伏要慢到不抢
  /// 列表阅读，又能在扫一行时看出在动。
  late final AnimationController _controller;

  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: M3EMotion.extraLong4,
      value: _pausedPhase,
    );
    // 初始相位已知，但「减弱动效」要等 didChangeDependencies 才能读到：
    // 先按正常动效起跑，下一拍再按真实偏好校正。
    _syncAnimation();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = reduceMotionOf(context);
    _syncAnimation();
  }

  @override
  void didUpdateWidget(CurrentTrackCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  /// 只有「正在播放 + 未减弱动效」才跑 ticker；其余状态停在同一相位。
  ///
  /// 暂停后不能保留 ticker 空转：角标虽不再换图标，但旧 [PlayingIndicator]
  /// 会在 IconSwap 的 150ms 离场淡出里继续被绘制，仍起伏就会违反「暂停时
  /// 完全不动」。
  void _syncAnimation() {
    if (widget.isPlaying && !_reduceMotion) {
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
      return;
    }
    _controller.stop();
    if (_controller.value != _pausedPhase) {
      _controller.value = _pausedPhase;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: widget.size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.cover,
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
                  dimension: CurrentTrackCover.badgeSize,
                  child: Center(
                    child: IconSwap<bool>(
                      value: widget.isPlaying,
                      builder: (context, isPlaying) => isPlaying
                          ? PlayingIndicator(
                              progress: _controller,
                              color: scheme.onPrimary,
                            )
                          : Icon(
                              Icons.pause_rounded,
                              size: 12,
                              color: scheme.onPrimary,
                            ),
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
