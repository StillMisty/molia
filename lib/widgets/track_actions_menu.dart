import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 在鼠标落点弹出曲目行操作菜单（全 App「桌面右键菜单跟随落点」的唯一实现）。
///
/// 为什么要有它：桌面端不再显示行尾 ⋮，行表面右键就是唯一入口，菜单必须在
/// 指针落点展开。实现用**零尺寸矩形**（`Rect.fromLTWH(pos.dx, pos.dy, 0, 0)`）
/// 作锚点 + `bottomStart`：菜单自落点向右下展开；靠近屏幕右缘 / 下缘时由 M3E
/// placer 自动水平夹取、空间不足自动上翻——这里不做第二套边界计算。
///
/// 坐标系必须与 [showM3EMenu] 插入的 overlay 一致（它固定插进 root overlay，
/// 并按 overlay 局部坐标摆位）：[globalPosition] 先经 root overlay 的渲染对象
/// 换算成局部坐标；极端情况拿不到 [RenderBox] 时原样使用——根 overlay 无祖先
/// 变换时全局与局部同值。
Future<void> showTrackActionsMenuAtPointer({
  required BuildContext context,
  required Offset globalPosition,
  required List<M3EMenuEntry> entries,
  required ValueChanged<Object?> onSelected,
  M3EMenuAnchorPosition position = M3EMenuAnchorPosition.bottomStart,
}) async {
  final OverlayState overlay = Overlay.of(context, rootOverlay: true);
  final RenderObject? overlayObject = overlay.context.findRenderObject();
  final Offset anchor = overlayObject is RenderBox
      ? overlayObject.globalToLocal(globalPosition)
      : globalPosition;
  final Object? selected = await showM3EMenu<Object>(
    context: context,
    anchor: Rect.fromLTWH(anchor.dx, anchor.dy, 0, 0),
    children: entries,
    position: position,
  );
  if (selected != null) onSelected(selected);
}

/// 曲目行尾的 ⋮ 操作菜单（低层菜单面：触摸端 ⋮ 与 AI 推歌行共用；桌面端
/// 无 ⋮，走行表面右键 [showTrackActionsMenuAtPointer]）。
///
/// 行操作请用 `row_actions.dart` 的 `RowActionMenuButton` / `rowActionsAtPointer`：
/// 它们负责把「一行动作」编译成条目与选中处理，本组件只认条目。
///
/// 统一两件容易各写各的事，保证全 App 同一种菜单观感：
/// - **锚点**：standard 图标按钮 + `semanticLabel`（只留无障碍名，不做
///   悬浮提示——口径见 docs/architecture.md §6「按钮选型」）；
/// - **条目**：调用方只给动作，规范一律「leading 图标 + 文案」，收藏这类
///   开关态用图标 + 文案表达（如实心 ♥ +「取消收藏」），不用勾选条目——
///   选中即关菜单，勾选态没有第二次阅读的机会。
class TrackActionsMenu extends StatelessWidget {
  const TrackActionsMenu({
    super.key,
    required this.entries,
    required this.onSelected,
    required this.semanticLabel,
    this.compact = false,
    this.enabled = true,
    this.position = M3EMenuAnchorPosition.bottomEnd,
  });

  /// 菜单条目（各页动作不同；图标规范见类文档）。
  final List<M3EMenuEntry> entries;

  /// 条目选中回调（值与条目的 `value` 对应）。
  final ValueChanged<Object?> onSelected;

  /// 锚点无障碍名称（纯图标按钮不做悬浮提示）。
  final String semanticLabel;

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
        semanticLabel: semanticLabel,
        onPressed: enabled ? open : null,
      ),
      onSelected: onSelected,
      entries: entries,
    );
  }
}
