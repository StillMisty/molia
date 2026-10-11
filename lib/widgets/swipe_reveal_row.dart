import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 固定行高列表的侧滑操作容器（reveal 语义）：
/// 横向拖动露出动作按钮，松手按位移/速度吸附展开或收起。
///
/// 自绘原因：列表为了精确 extent 改用 `ListView.builder(itemExtent:)`，
/// 不再走 M3EList。动作配置沿用 [M3EListSwipeAction]，渲染与几何对齐
/// M3E 列表规范（`M3EListDismissibleTheme`）：胶囊形图标按钮
/// （高度 = 行高 − actionVerticalInset、半高圆角；中性 tonal、
/// 主要/破坏性 filled），动作间距 / 边缘内边距 / 吸附阈值全部取主题。
class SwipeRevealRow extends StatefulWidget {
  const SwipeRevealRow({
    super.key,
    required this.actions,
    required this.child,
    this.enabled = true,
  });

  /// 露出宽度 = Σ 各动作 [M3EListSwipeAction.width] + 动作间距。
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

  /// 露出总宽：各动作分配宽之和 + 动作间距（与 M3E `_computeActionsWidth` 同源）。
  double get _actionsWidth {
    final theme = M3ETheme.of(context).listTheme.dismissible;
    final count = widget.actions.length;
    final sum =
        widget.actions.fold(0.0, (value, action) => value + action.width);
    return sum + (count > 1 ? (count - 1) * theme.actionSpacing : 0);
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails details) {
    _reveal.stop();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final double actionsWidth = _actionsWidth;
    if (actionsWidth <= 0) return;
    final double delta = details.primaryDelta ?? 0;
    _reveal.value = (_reveal.value - delta / actionsWidth).clamp(0.0, 1.0);
  }

  void _onDragEnd(DragEndDetails details, double previewThreshold) {
    final double velocity = details.primaryVelocity ?? 0;
    if (velocity < -350) {
      _open();
    } else if (velocity > 350) {
      _close();
    } else if (_reveal.value >= previewThreshold) {
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
    final M3EListDismissibleTheme style =
        M3ETheme.of(context).listTheme.dismissible;
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
                child: SizedBox(
                  width: actionsWidth,
                  child: LayoutBuilder(
                    builder: (context, constraints) =>
                        _buildActionsRow(constraints, style),
                  ),
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
            onHorizontalDragEnd: (details) =>
                _onDragEnd(details, style.actionPreviewThreshold),
            child: widget.child,
          ),
        ),
      ],
    );
  }

  /// 动作排：边缘内边距 + 动作间距 + 均分单元格，几何对齐 M3E
  /// `_buildActionsRow`（动作 width 只决定露出总宽，视觉按单元格均分）。
  Widget _buildActionsRow(
    BoxConstraints constraints,
    M3EListDismissibleTheme style,
  ) {
    final int count = widget.actions.length;
    final double availableHeight =
        constraints.maxHeight.isFinite ? constraints.maxHeight : 64.0;
    final double horizontalPad =
        math.min(style.actionEdgePadding, constraints.maxWidth / 2);
    final double innerWidth =
        math.max(0, constraints.maxWidth - 2 * horizontalPad);
    if (innerWidth <= 0 || availableHeight <= 0) {
      return const SizedBox.shrink();
    }
    final double pillHeight = math.max(
      style.actionMinHeight,
      availableHeight - style.actionVerticalInset,
    );
    final double gap = count > 1 ? style.actionSpacing : 0;
    final double cellWidth =
        math.max(0, (innerWidth - gap * (count - 1)) / count);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPad),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          for (int i = 0; i < count; i++) ...[
            if (i > 0) SizedBox(width: gap),
            SizedBox(
              width: cellWidth,
              height: pillHeight,
              child: _buildAction(widget.actions[i], cellWidth, pillHeight),
            ),
          ],
        ],
      ),
    );
  }

  /// 单个动作：胶囊图标按钮。中性 = tonal；主要/破坏性（如移除）用
  /// filled + 调用方配色（error/onError），对齐 M3E 示例中的删除动作。
  Widget _buildAction(
    M3EListSwipeAction action,
    double cellWidth,
    double pillHeight,
  ) {
    final Color? background = action.backgroundColor;
    final Color? foreground = action.foregroundColor;
    final M3EIconButtonDecoration? decoration =
        (background == null && foreground == null)
            ? null
            : M3EIconButtonDecoration(
                backgroundColor: background == null
                    ? null
                    : WidgetStatePropertyAll<Color?>(background),
                foregroundColor: foreground == null
                    ? null
                    : WidgetStatePropertyAll<Color?>(foreground),
              );
    return M3EIconButton(
      icon: action.icon,
      variant: action.isPrimary
          ? M3EIconButtonVariant.filled
          : M3EIconButtonVariant.tonal,
      enableFeedback: false,
      visualSize: Size(cellWidth, pillHeight),
      decoration: decoration,
      onPressed: () {
        _close();
        action.onPressed?.call();
      },
    );
  }
}
