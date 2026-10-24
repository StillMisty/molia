/// 空态配方：图标 + 文案 + 可选行动，收藏 / 资料 / 发现几处共用一份。
library;

import 'package:material_ui/material_ui.dart';

import '../theme/m3e_context.dart';

/// 空态：图标（40，`onSurfaceVariant`）+ 文案（`bodyMedium`，居中）+
/// 可选行动。
///
/// 收藏合集 / 资料页 / 发现热榜与歌单的空态共用这一份配方，图标尺寸、
/// 间距（图标 → 文案 12、文案 → 行动 16）与配色口径只在这里调整。
/// `Column.mainAxisSize: min`：空态不占满宿主，视线留给文案与主行动。
///
/// 定位留给调用方包一层：页面级空态用 `Center` + 24 内边距（页面里
/// 无处可去），滚动内容（tab / sliver）里的空态用页面对齐的 16/16 内边距。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.action,
  });

  /// 图标档：空态不占满全屏的统一口径。
  static const double iconSize = 40;

  final IconData icon;

  /// 空态文案（多行走居中）。
  final String message;

  /// 空态下的补充入口（如「导入本地歌曲」「打开设置」）。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final action = this.action;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: iconSize, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(height: 12),
        Text(
          message,
          textAlign: TextAlign.center,
          style: context.typeScale.bodyMedium.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (action != null) ...[
          const SizedBox(height: 16),
          action,
        ],
      ],
    );
  }
}
