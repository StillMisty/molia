import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../utils/responsive.dart';
import 'track_actions_menu.dart';

/// 曲目行操作动作的统一词汇：图标 + 文案 + 回调 + 是否移除类。
///
/// 为什么回调不可空：菜单条目一旦渲染出来，就是「点了会执行」的承诺。可选
/// 回调在接线缺席时不会报错，只会变成点了没反应的条目——入口分散在各页时
/// 这种哑动作最难发现。需要「这次不提供」就干脆不构造这条动作。
class RowAction {
  const RowAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  /// 移除 / 删除类（菜单条目走 error 语义，触摸端左滑胶囊走 error 配色）。
  final bool destructive;
}

/// 动作 → 菜单条目的唯一映射：条目顺序即动作顺序，`value` 记动作下标，
/// 选中后由 [rowMenuSelection] 按下标回读回调。
///
/// 菜单只需要图标与文案；配色（移除类）由菜单组件按 `isDestructive` 决定，
/// 这里不再各页拼一套条目。
List<M3EMenuEntry> rowMenuEntries(List<RowAction> actions) => [
      for (var index = 0; index < actions.length; index++)
        M3EMenuEntry(
          label: actions[index].label,
          leading: Icon(actions[index].icon),
          isDestructive: actions[index].destructive,
          value: index,
        ),
    ];

/// 条目选中回调（值 = [rowMenuEntries] 写入的动作下标）。
ValueChanged<Object?> rowMenuSelection(List<RowAction> actions) =>
    (Object? value) {
      if (value is int && value >= 0 && value < actions.length) {
        actions[value].onPressed();
      }
    };

/// 触摸端的行尾 ⋮ 菜单入口：触摸端唯一的菜单锚点。
///
/// 桌面端不渲染 ⋮（入口是行表面右键，见 [rowActionsAtPointer]），因此只在
/// 触摸端放置本组件；桌面判定留在主机的一处 `trailing` 分支。空动作不渲染
/// 锚点——没有动作就没有入口，而不是弹一个空菜单。
class RowActionMenuButton extends StatelessWidget {
  const RowActionMenuButton({
    super.key,
    required this.actions,
    required this.semanticLabel,
    this.compact = false,
    this.enabled = true,
  });

  /// 行内动作（顺序即条目顺序）。
  final List<RowAction> actions;

  /// 锚点无障碍名称（纯图标按钮不做悬浮提示）。
  final String semanticLabel;

  /// 紧凑锚点（与其它行内动作并排时用）。
  final bool compact;

  /// 锚点是否可用（生成中等时刻禁用；入口保留可见，不做显隐切换）。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return const SizedBox.shrink();
    return TrackActionsMenu(
      entries: rowMenuEntries(actions),
      onSelected: rowMenuSelection(actions),
      semanticLabel: semanticLabel,
      compact: compact,
      enabled: enabled,
    );
  }
}

/// 桌面端的行表面右键入口：直接交给 `TrackRow.onSecondaryTap`。
///
/// 触摸平台 / 没有动作时返回 null（该行不接次级手势）。落点弹菜单的边界
/// 处理全在 [showTrackActionsMenuAtPointer]（M3E placer 夹取 / 上翻）。
void Function(Offset globalPosition)? rowActionsAtPointer(
  BuildContext context,
  List<RowAction> actions,
) {
  if (!isDesktopPlatform() || actions.isEmpty) return null;
  final entries = rowMenuEntries(actions);
  final onSelected = rowMenuSelection(actions);
  return (Offset globalPosition) => showTrackActionsMenuAtPointer(
        context: context,
        globalPosition: globalPosition,
        entries: entries,
        onSelected: onSelected,
      );
}
