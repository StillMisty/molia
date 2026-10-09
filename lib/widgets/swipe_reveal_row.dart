import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 固定行高列表的左滑操作容器（reveal 语义）：
/// 横向拖动露出动作按钮，松手按位移/速度吸附展开或收起。
///
/// 自绘原因：列表为了精确 extent 改用 `ListView.builder(itemExtent:)`，
/// 不再走 M3EList；动作配置沿用 [M3EListSwipeAction] 保持图标与配色一致。
class SwipeRevealRow extends StatefulWidget {
  const SwipeRevealRow({
    super.key,
    required this.actions,
    required this.child,
    this.enabled = true,
  });

  /// 露出宽度即各动作 [M3EListSwipeAction.width] 之和。
  final List<M3EListSwipeAction> actions;

  final Widget child;

  final bool enabled;

  @override
  State<SwipeRevealRow> createState() => _SwipeRevealRowState();
}

class _SwipeRevealRowState extends State<SwipeRevealRow>
    with SingleTickerProviderStateMixin {
  /// 0 = 收起，1 = 完全露出。
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  double get _actionsWidth =>
      widget.actions.fold(0, (sum, action) => sum + action.width);

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails details) {
    _reveal.stop();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_actionsWidth <= 0) return;
    final double delta = details.primaryDelta ?? 0;
    _reveal.value = (_reveal.value - delta / _actionsWidth).clamp(0.0, 1.0);
  }

  void _onDragEnd(DragEndDetails details) {
    final double velocity = details.primaryVelocity ?? 0;
    if (velocity < -350) {
      _open();
    } else if (velocity > 350) {
      _close();
    } else if (_reveal.value >= 0.5) {
      _open();
    } else {
      _close();
    }
  }

  void _open() {
    _reveal.animateTo(1, curve: Curves.easeOut);
  }

  void _close() {
    _reveal.animateTo(0, curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || widget.actions.isEmpty) return widget.child;
    final double actionsWidth = _actionsWidth;
    return Stack(
      children: [
        // 动作按钮常驻在行下方，行左移后露出；未滑动时不构建，
        // 避免图标在整表范围内重复命中（测试/无障碍语义都会重复）。
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _reveal,
            builder: (context, _) {
              if (_reveal.value == 0) return const SizedBox.shrink();
              return Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final action in widget.actions) _buildAction(action),
                  ],
                ),
              );
            },
          ),
        ),
        AnimatedBuilder(
          animation: _reveal,
          builder: (context, child) => Transform.translate(
            offset: Offset(-actionsWidth * _reveal.value, 0),
            child: child,
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            child: widget.child,
          ),
        ),
      ],
    );
  }

  Widget _buildAction(M3EListSwipeAction action) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: action.backgroundColor ?? scheme.secondaryContainer,
      child: InkWell(
        onTap: () {
          _close();
          action.onPressed?.call();
        },
        child: SizedBox(
          width: action.width,
          height: double.infinity,
          child: Center(
            child: IconTheme(
              data: IconThemeData(
                color: action.foregroundColor ?? scheme.onSecondaryContainer,
              ),
              child: action.icon,
            ),
          ),
        ),
      ),
    );
  }
}
