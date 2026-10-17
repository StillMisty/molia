import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// ⋮ 菜单的外部打开句柄：曲目行右键打开**同一份**菜单（锚点仍是行尾 ⋮
/// 按钮，不新造第二套菜单）。
///
/// 每行一个，由调用方持有（行的 State 创建 / 释放，不能建在 itemBuilder
/// 里——每次重建都会注册一份新回调）。菜单未挂载 / 已打开时 [open] 为空
/// 操作，调用方无需关心挂载时序。
class TrackActionsMenuController {
  VoidCallback? _open;

  /// 打开菜单（锚点 = 行尾 ⋮ 按钮）。
  void open() => _open?.call();

  /// 注册 / 注销打开回调；锚点禁用（生成中等）时注册 null，右键同样不可开。
  void _attach(VoidCallback? open) => _open = open;

  void _detach(VoidCallback? open) {
    // 按回调相等性比对：重建时 anchorBuilder 给的是同一实例，只有换
    // 控制器 / 销毁时才真正清掉，避免误清新一轮注册的回调。
    if (_open == open) _open = null;
  }
}

/// 曲目行尾的 ⋮ 操作菜单（发现详情 / 搜索结果 / AI 推歌共用）。
///
/// 统一两件容易各写各的事，保证全 App 同一种菜单观感：
/// - **锚点**：standard 图标按钮 + tooltip（纯图标不自解释，tooltip 同时
///   承担无障碍语义）；
/// - **条目**：调用方只给动作，规范一律「leading 图标 + 文案」，收藏这类
///   开关态用图标 + 文案表达（如实心 ♥ +「取消收藏」），不用勾选条目——
///   选中即关菜单，勾选态没有第二次阅读的机会。
///
/// 右键复用入口：传 [controller] 后，行表面（[TrackRow.onSecondaryTap]）
/// 可以打开与锚点按钮完全相同的那份菜单。
class TrackActionsMenu extends StatefulWidget {
  const TrackActionsMenu({
    super.key,
    required this.entries,
    required this.onSelected,
    required this.tooltip,
    this.compact = false,
    this.enabled = true,
    this.position = M3EMenuAnchorPosition.bottomEnd,
    this.controller,
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

  /// 外部打开句柄（曲目行右键）；null = 仅锚点按钮可开。
  final TrackActionsMenuController? controller;

  @override
  State<TrackActionsMenu> createState() => _TrackActionsMenuState();
}

class _TrackActionsMenuState extends State<TrackActionsMenu> {
  /// 最近一次 anchorBuilder 注入的打开回调（M3EMenu 私有 State 的方法
  /// tear-off，同一次挂载内重建都是同一实例）。
  VoidCallback? _open;

  @override
  void didUpdateWidget(covariant TrackActionsMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    oldWidget.controller?._detach(_open);
    widget.controller?._attach(_open);
  }

  @override
  void dispose() {
    widget.controller?._detach(_open);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return M3EMenu.entries(
      position: widget.position,
      anchorBuilder: (context, open) {
        // 注册点只能在这里：M3EMenu 不暴露控制器，打开回调只经
        // anchorBuilder 下发（每次 build 重复注册同一实例，幂等）。
        _open = widget.enabled ? open : null;
        widget.controller?._attach(_open);
        return M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          size: widget.compact ? M3EIconButtonSize.sm : M3EIconButtonSize.md,
          visualSize: widget.compact ? const Size(40, 40) : null,
          icon: const Icon(Icons.more_vert_rounded),
          tooltip: widget.tooltip,
          onPressed: widget.enabled ? open : null,
        );
      },
      onSelected: widget.onSelected,
      entries: widget.entries,
    );
  }
}
