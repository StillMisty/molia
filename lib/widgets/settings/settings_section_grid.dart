import 'package:material_ui/material_ui.dart';

import 'settings_tiles.dart';

/// 设置首屏分区容器：宽屏两列流式、窄屏单列。
///
/// 两列时按分区顺序左右交替成对（左列 1、3、5…，右列 2、4、6…），同一对
/// 顶对齐，行高取较高者；列间距与行间距同用 [kSettingsSectionSpacing]。
///
/// 只承载首屏分区：子页是长表单（底部导航拖拽排序等），一律单列，不经过
/// 本组件。画布宽度由调用方（`settings_page.dart`）按弹层宽度封顶，列宽
/// 不随窗口继续变宽。
class SettingsSectionGrid extends StatelessWidget {
  const SettingsSectionGrid({
    super.key,
    required this.children,
    this.twoColumn = false,
  });

  /// 按展示顺序排列的分区（首屏 5 个语义分区）。
  final List<Widget> children;

  /// 是否两列流式；判定口径见 `settings_page.dart` 的平台 + 窗口宽谓词。
  final bool twoColumn;

  @override
  Widget build(BuildContext context) {
    if (!twoColumn || children.length < 2) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: kSettingsSectionSpacing),
            children[i],
          ],
        ],
      );
    }

    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += 2) {
      if (i > 0) {
        rows.add(const SizedBox(height: kSettingsSectionSpacing));
      }
      rows.add(
        Row(
          // 顶对齐：同对分区高度不同时较矮的一侧保持自然高度（不拉伸），
          // 下一行紧跟较高者，视觉上仍是两列网格。
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: children[i]),
            const SizedBox(width: kSettingsSectionSpacing),
            Expanded(
              child: i + 1 < children.length
                  ? children[i + 1]
                  // 分区数为奇数时末行只占左列（右列留空），不改变奇偶归属。
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}
