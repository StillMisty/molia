import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'settings_tiles.dart';

/// 分段卡片行的拖拽排序容器（M3E 列表形状 + 行间 `cardList.gap`）。
///
/// 与 [SettingsSectionCard] 的静态行同源：按 index 下发
/// [SettingsRowPosition]（首末外侧 16dp、内行 4dp）。拖拽手柄由行自己放在
/// trailing（`ReorderableDragStartListener` 只包手柄，行内点击不受影响）。
///
/// [onReorder] 是 `ReorderableListView.onReorderItem` 语义：newIndex 已按
/// 「移除 oldIndex 后」校正过，调用方直接按下标搬移即可。
class SettingsReorderableRows extends StatelessWidget {
  const SettingsReorderableRows({
    super.key,
    required this.itemCount,
    required this.itemKey,
    required this.itemBuilder,
    required this.onReorder,
  });

  final int itemCount;

  /// 每项的稳定 key（`ReorderableListView` 要求）；取业务 id（如渠道 key）。
  final Key Function(int index) itemKey;

  final Widget Function(BuildContext context, int index) itemBuilder;

  final ReorderCallback onReorder;

  @override
  Widget build(BuildContext context) {
    final gap = M3ETheme.of(context).listTheme.cardList.gap;
    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorderItem: onReorder,
      children: [
        for (var index = 0; index < itemCount; index++)
          Padding(
            key: itemKey(index),
            padding: EdgeInsets.only(top: index == 0 ? 0 : gap),
            child: SettingsRowPosition(
              position: calculateCardPosition(index, itemCount),
              child: itemBuilder(context, index),
            ),
          ),
      ],
    );
  }
}
