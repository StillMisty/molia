/// 空态配方：图标 + 文案 + 可选行动，收藏 / 资料 / 发现几处共用一份。
library;

import 'package:material_ui/material_ui.dart';

import '../theme/m3e_context.dart';

/// 空态：图标（40，`onSurfaceVariant`）+ 文案（`bodyMedium`，居中）+
/// 可选下一步提示 + 可选行动。
///
/// 收藏合集 / 资料页 / 发现热榜与歌单 / 详情二级页的空态共用这一份配方，图标尺寸、
/// 间距（图标 → 文案 12、文案 → 提示 6、提示 / 文案 → 行动 16）与配色
/// 口径只在这里调整。`Column.mainAxisSize: min`：空态不占满宿主，视线
/// 留给文案与主行动。
///
/// 定位留给调用方包一层：页面级空态用 `Center` + 24 内边距（页面里
/// 无处可去），滚动内容（tab / sliver）里的空态用页面对齐的 16/16 内边距。
///
/// 高度受限时（横屏 + 键盘、200% 字号等）不硬塞完整配方：可用高装不下
/// 图标与两行文案就退化为无图标、可滚动的短文案，避免 RenderFlex 溢出。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.hint,
    this.action,
  });

  /// 图标档：空态不占满全屏的统一口径。
  static const double iconSize = 40;

  static const double _iconTextGap = 12;
  static const double _hintGap = 6;
  static const double _actionGap = 16;
  static const double _actionReserve = 48;

  final IconData icon;

  /// 空态文案（多行走居中）。
  final String message;

  /// 下一步提示：补充「为什么是空的 / 还能怎么用」，不是第二个行动入口。
  final String? hint;

  /// 空态下的补充入口（如「导入本地歌曲」「打开设置」）。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final fullHeight = _fullHeightOf(context);
        final short =
            constraints.maxHeight.isFinite &&
            constraints.maxHeight < fullHeight;
        if (short) return _buildCompact(context);
        return _buildFull(context);
      },
    );
  }

  /// 完整配方的保守高度预算：文案按两行估，行动按 48 估。
  ///
  /// 只用于判断「装不装得下」，不做精确布局；宁可早一档退化，也不要
  /// 在键盘弹起 / 200% 字号时溢出。
  double _fullHeightOf(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    var required = iconSize + _iconTextGap + scaler.scale(20) * 2;
    if (hint != null) required += _hintGap + scaler.scale(16) * 2;
    if (action != null) required += _actionGap + _actionReserve;
    return required;
  }

  Widget _buildFull(BuildContext context) {
    final theme = Theme.of(context);
    final hint = this.hint;
    final action = this.action;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: iconSize, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(height: _iconTextGap),
        Text(
          message,
          textAlign: TextAlign.center,
          style: context.typeScale.bodyMedium.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (hint != null) ...[
          const SizedBox(height: _hintGap),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: context.typeScale.bodySmall.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (action != null) ...[const SizedBox(height: _actionGap), action],
      ],
    );
  }

  /// 矮高度退化：只留文案，装在滚动视图里，宿主再矮也不会溢出。
  ///
  /// 不保留图标 / 提示 / 行动：这几项在可见高度不足时本来也点不到，留着
  /// 只会把真正要读的提示挤出屏幕。
  Widget _buildCompact(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: context.typeScale.bodySmall.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
