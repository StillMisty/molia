/// AI 生成等待态：脉冲骨架、细进度条、阶段进度。
///
/// 只在显式生成时使用；静默补歌不创建任何可见等待态。动画尊重系统
/// `MediaQuery.disableAnimations` / `reduceMotion`（减弱动效时静态显示）。
library;

import 'package:material_ui/material_ui.dart';

import '../domain/models/ai_dj.dart';
import '../l10n/app_localizations.dart';
import '../theme/m3e_context.dart';
import '../theme/motion_policy.dart';
import 'skeleton.dart';

/// 生成阶段步进：整理偏好 → AI 选歌 → 本地找歌。
///
/// 生成卡只显示一个总标题时，用户无法判断卡在「等模型」还是「找歌」；
/// 三步并排（当前步强调、已完成打勾）能把等待原因说清楚。
class AiDjPhaseSteps extends StatelessWidget {
  const AiDjPhaseSteps({super.key, required this.progress});

  final AiDjProgress progress;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final currentIndex = AiDjPhase.values.indexOf(progress.phase);
    final steps = [
      l10n.aiDjPhaseProfile,
      l10n.aiDjPhaseModel,
      progress.phase == AiDjPhase.resolving && progress.total > 0
          ? l10n.aiDjPhaseResolving(progress.done, progress.total)
          : l10n.aiDjPhaseResolvingShort,
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          if (i > 0)
            Icon(
              Icons.chevron_right_rounded,
              size: 14,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          _PhaseStep(
            label: steps[i],
            state: i < currentIndex
                ? _PhaseStepState.done
                : i == currentIndex
                ? _PhaseStepState.current
                : _PhaseStepState.pending,
          ),
        ],
      ],
    );
  }
}

enum _PhaseStepState { done, current, pending }

class _PhaseStep extends StatelessWidget {
  const _PhaseStep({required this.label, required this.state});

  final String label;
  final _PhaseStepState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (state) {
      _PhaseStepState.done || _PhaseStepState.current => scheme.primary,
      _PhaseStepState.pending => scheme.onSurfaceVariant.withValues(alpha: 0.6),
    };
    final icon = switch (state) {
      _PhaseStepState.done => Icons.check_circle_rounded,
      _PhaseStepState.current => Icons.radio_button_checked_rounded,
      _PhaseStepState.pending => Icons.radio_button_unchecked_rounded,
    };
    final style =
        (state == _PhaseStepState.current
                ? context.emphasizedTypeScale.labelMedium
                : context.typeScale.labelMedium)
            .copyWith(color: color);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(label, style: style),
      ],
    );
  }
}

/// 首次生成时的推荐行骨架（脉冲）。
class AiDjPulsingSkeleton extends StatelessWidget {
  const AiDjPulsingSkeleton({super.key, this.rows = 5});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SkeletonPulse(
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
