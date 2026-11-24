part of 'app_shell.dart';

/// 顶栏进度条槽高。
///
/// 进度条本体只有 4dp；槽固定为 10dp，顶栏总高与播放页锚点保持一致，
/// 不随播放态或进度条形态变化（避免 play/pause 时整条顶栏跳变）。
const double _shellBarProgressHeight = 10;

/// 顶栏底部进度条：恒为平直形态。
///
/// 顶栏在列表 / 收藏等页面常驻，波浪是 60fps 无限动画，不应在用户读列表时
/// 持续出帧；波浪只留给播放页主场的进度滑杆。槽高固定为
/// [_shellBarProgressHeight]。
class ProgressIndicator extends StatefulWidget {
  /// 当前进度（来自 provider.position 单一时钟，无自外推）。
  final Duration position;
  final double duration;

  const ProgressIndicator({
    super.key,
    required this.position,
    required this.duration,
  });

  @override
  State<ProgressIndicator> createState() => _ProgressIndicatorState();
}

class _ProgressIndicatorState extends State<ProgressIndicator>
    with SingleTickerProviderStateMixin {
  late double _currentProgress;
  late final AnimationController _animationController;
  late Animation<double> _progressAnimation;

  @override
  void initState() {
    super.initState();

    _animationController = AnimationController(
      duration: M3EMotion.medium2,
      vsync: this,
    );

    _currentProgress = widget.position.inMilliseconds.toDouble();

    _progressAnimation =
        Tween<double>(begin: _currentProgress, end: _currentProgress).animate(
          CurvedAnimation(
            parent: _animationController,
            curve: M3EMotion.standard,
          ),
        );
  }

  @override
  void didUpdateWidget(ProgressIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.position.inMilliseconds.toDouble();
    // 仅 seek/切歌等 >1s 的跳变做 300ms 平滑过渡；
    // 常规推进直接跟随 position 通道。减弱动效时直接落位（不补过渡）。
    if ((target - _currentProgress).abs() > 1000) {
      if (reduceMotionOf(context)) {
        _currentProgress = target;
        _animationController.value = 1.0;
        return;
      }
      final display = _animationController.isAnimating
          ? _progressAnimation.value
          : _currentProgress;
      _progressAnimation = Tween<double>(begin: display, end: target).animate(
        CurvedAnimation(
          parent: _animationController,
          curve: M3EMotion.standard,
        ),
      );
      _currentProgress = target;
      _animationController.forward(from: 0);
    } else {
      _currentProgress = target;
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progressAnimation,
      builder: (context, child) {
        final displayProgress = _animationController.isAnimating
            ? _progressAnimation.value
            : _currentProgress;
        final double? fraction = widget.duration > 0
            ? (displayProgress / widget.duration).clamp(0.0, 1.0)
            : null;

        // 顶栏恒用平直进度条：波浪只留给播放页，避免列表常驻时持续出帧。
        return SizedBox(
          height: _shellBarProgressHeight,
          child: M3EProgressIndicator.linear(
            value: fraction,
            linearSize: M3EProgressIndicatorSize.s,
            strokeWidth: 4.0,
            trackStrokeWidth: 4.0,
            trackColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            color: Theme.of(context).colorScheme.primary,
          ),
        );
      },
    );
  }
}

/// 顶栏底部进度条锚点：播放页激活时收起（进度由页面内的同一元素承接）。
class _ShellBarProgress extends StatelessWidget {
  const _ShellBarProgress({required this.morph});

  final PlayerMorphController morph;

  @override
  Widget build(BuildContext context) {
    final duration = effectDurationOf(context, M3EMotion.short3);
    return ListenableBuilder(
      listenable: morph.changes,
      builder: (context, _) => AnimatedOpacity(
        duration: duration,
        // 收起（进播放页）加速让位，恢复时减速落定：与顶栏文本同一节奏。
        curve: morph.state.barHeaderHidden
            ? M3EMotion.emphasizedAccelerate
            : M3EMotion.emphasizedDecelerate,
        opacity: morph.state.barHeaderHidden ? 0 : 1,
        child: ProgressBarSelector(
          builder: (context, position, state, child) {
            if (!state.hasTrack) {
              return const SizedBox(height: _shellBarProgressHeight);
            }
            return ProgressIndicator(
              position: position,
              duration: state.duration.toDouble(),
            );
          },
        ),
      ),
    );
  }
}
