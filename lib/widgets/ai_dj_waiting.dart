/// AI 生成等待态：脉冲骨架、细进度条、阶段进度。
///
/// 只在显式生成时使用；静默补歌不创建任何可见等待态。动画尊重系统
/// `MediaQuery.disableAnimations`（减弱动效时静态显示）。
library;

import 'package:material_ui/material_ui.dart';

/// 让子树做呼吸式明暗变化（骨架 / 状态卡）。
class AiDjPulse extends StatefulWidget {
  const AiDjPulse({super.key, required this.child});

  final Widget child;

  @override
  State<AiDjPulse> createState() => _AiDjPulseState();
}

class _AiDjPulseState extends State<AiDjPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _opacity = Tween<double>(begin: 0.5, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disabled = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (disabled) {
      _controller.stop();
      _controller.value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (disabled) return widget.child;
    return FadeTransition(opacity: _opacity, child: widget.child);
  }
}

/// 首次生成时的推荐行骨架（脉冲）。
class AiDjPulsingSkeleton extends StatelessWidget {
  const AiDjPulsingSkeleton({super.key, this.rows = 5});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AiDjPulse(
      child: Column(
        key: const Key('aiDjPulsingSkeleton'),
        children: [
          for (var i = 0; i < rows; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            Container(
              height: 64,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 细进度条（0..1；未知时显示不确定态滑动动画，受减弱动效约束）。
class AiDjThinProgress extends StatefulWidget {
  const AiDjThinProgress({super.key, this.value});

  final double? value;

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
    final disabled = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (widget.value != null || disabled) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant AiDjThinProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    final disabled = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
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
    final disabled = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 3,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: scheme.surfaceContainerHighest),
            if (widget.value != null)
              Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: fraction,
                  child: ColoredBox(color: scheme.primary),
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
  }
}
