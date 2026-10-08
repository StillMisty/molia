import 'package:material_ui/material_ui.dart';

/// ColorScheme 过渡构建器：封面取色/莫奈/种子色/亮度切换时，在
/// [duration] 内从旧方案插值到新方案，避免整站配色「闪变」。
///
/// 只插值 ColorScheme 本身，由上层（main.dart）用它同时重建 material
/// ThemeData 与 M3EThemeData，保证两套组件树过渡一致；连续快速换色
/// （连切歌曲）会从「当前视觉值」续接，不跳回旧起点。
class AnimatedSchemeBuilder extends StatefulWidget {
  const AnimatedSchemeBuilder({
    super.key,
    required this.scheme,
    required this.builder,
    this.duration = const Duration(milliseconds: 450),
    this.curve = Curves.easeInOutCubic,
  });

  /// 目标方案（ThemeProvider 的当前输出）。
  final ColorScheme scheme;

  /// 用插值中的方案构建子树；每帧都会调用。
  final Widget Function(BuildContext context, ColorScheme scheme) builder;

  /// 过渡时长；[Duration.zero] 表示直接跳变。
  final Duration duration;

  /// 过渡曲线。
  final Curve curve;

  @override
  State<AnimatedSchemeBuilder> createState() => _AnimatedSchemeBuilderState();
}

class _AnimatedSchemeBuilderState extends State<AnimatedSchemeBuilder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  late ColorScheme _from = widget.scheme;
  late ColorScheme _to = widget.scheme;

  /// 首个方案变化（偏好加载/平台亮度回填）直接跳变，不播启动动画。
  bool _firstChange = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: 1.0,
    )..addListener(_onTick);
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(AnimatedSchemeBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.scheme == oldWidget.scheme) return;

    final disableAnimation =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_firstChange ||
        disableAnimation ||
        widget.duration == Duration.zero) {
      _firstChange = false;
      _from = widget.scheme;
      _to = widget.scheme;
      _controller.value = 1.0;
      return;
    }

    _firstChange = false;
    // 从当前视觉值续接，快速连续换色不跳变。
    _from = ColorScheme.lerp(
      _from,
      _to,
      widget.curve.transform(_controller.value),
    );
    _to = widget.scheme;
    _controller
      ..duration = widget.duration
      ..forward(from: 0.0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = _controller.value >= 1.0
        ? _to
        : ColorScheme.lerp(
            _from,
            _to,
            widget.curve.transform(_controller.value),
          );
    return widget.builder(context, scheme);
  }
}
