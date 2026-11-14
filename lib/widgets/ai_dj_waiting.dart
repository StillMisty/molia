/// AI 生成等待态：唯一的细进度条。
///
/// 显式生成只在页面留这一条进度（配单行阶段文案与停止），不再叠脉冲骨架、
/// 阶段步进或等待秒数；静默补歌不创建任何可见等待态。动画尊重系统
/// `MediaQuery.disableAnimations` / `reduceMotion`（减弱动效时静态显示）。
library;

import 'package:material_ui/material_ui.dart';

import '../theme/motion_policy.dart';

/// 细进度条（0..1；未知时显示不确定态滑动动画，受减弱动效约束）。
class AiDjThinProgress extends StatefulWidget {
  const AiDjThinProgress({
    super.key,
    this.value,
    this.semanticLabel,
    this.semanticValue,
  });

  final double? value;

  /// 读屏用的进度名称与当前值（如「正在生成推荐」/「8/24」）。
  final String? semanticLabel;
  final String? semanticValue;

  @override
  State<AiDjThinProgress> createState() => _AiDjThinProgressState();
}

class _AiDjThinProgressState extends State<AiDjThinProgress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disabled = reduceMotionOf(context);
    if (widget.value != null || disabled) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant AiDjThinProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    final disabled = reduceMotionOf(context);
    if (widget.value != null || disabled) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
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
    final fraction = (widget.value ?? 0).clamp(0.0, 1.0);
    final disabled = reduceMotionOf(context);
    final bar = ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 3,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: scheme.surfaceContainerHighest),
            if (widget.value != null)
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: fraction),
                duration: disabled
                    ? Duration.zero
                    : const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: value,
                    child: ColoredBox(color: scheme.primary),
                  ),
                ),
              )
            else if (disabled)
              Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: 0.3,
                  child: ColoredBox(
                    color: scheme.primary.withValues(alpha: 0.55),
                  ),
                ),
              )
            else
              AnimatedBuilder(
                animation: _controller,
                builder: (context, child) => Align(
                  alignment: Alignment(-1.2 + 2.4 * _controller.value, 0),
                  child: child,
                ),
                child: FractionallySizedBox(
                  widthFactor: 0.3,
                  child: ColoredBox(color: scheme.primary),
                ),
              ),
          ],
        ),
      ),
    );
    if (widget.semanticLabel == null && widget.semanticValue == null) {
      return bar;
    }
    return Semantics(
      container: true,
      label: widget.semanticLabel,
      value: widget.semanticValue,
      child: bar,
    );
  }
}
