import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 曲目行尾的 ⋮ 操作菜单（发现详情 / 搜索结果 / AI 推歌共用）。
///
/// 统一两件容易各写各的事，保证全 App 同一种菜单观感：
/// - **锚点**：standard 图标按钮 + tooltip（纯图标不自解释，tooltip 同时
///   承担无障碍语义）；
/// - **条目**：调用方只给动作，规范一律「leading 图标 + 文案」，收藏这类
///   开关态用图标 + 文案表达（如实心 ♥ +「取消收藏」），不用勾选条目——
///   选中即关菜单，勾选态没有第二次阅读的机会。
class TrackActionsMenu extends StatelessWidget {
  const TrackActionsMenu({
    super.key,
    required this.entries,
    required this.onSelected,
    required this.tooltip,
    this.compact = false,
    this.enabled = true,
    this.position = M3EMenuAnchorPosition.bottomEnd,
  });

  /// 菜单条目（各页动作不同；图标规范见类文档）。
  final List<M3EMenuEntry> entries;

  /// 条目选中回调（值与条目的 `value` 对应）。
  final ValueChanged<Object?> onSelected;

  /// 锚点 tooltip（无障碍名称）。
  final String tooltip;

  /// 紧凑锚点（AI 推歌行内与其它行内动作并排时用）。
  final bool compact;

  /// 锚点是否可用（生成中等时刻禁用；入口保留可见，不做显隐切换）。
  final bool enabled;

  /// 菜单弹出位置（默认贴锚点右下）。
  final M3EMenuAnchorPosition position;

  @override
  Widget build(BuildContext context) {
    return M3EMenu.entries(
      position: position,
      anchorBuilder: (context, open) => M3EIconButton(
        variant: M3EIconButtonVariant.standard,
        size: compact ? M3EIconButtonSize.sm : M3EIconButtonSize.md,
        visualSize: compact ? const Size(40, 40) : null,
        icon: const Icon(Icons.more_vert_rounded),
        tooltip: tooltip,
        onPressed: enabled ? open : null,
      ),
      onSelected: onSelected,
      entries: entries,
    );
  }
}
