import 'package:material_ui/material_ui.dart';

import 'settings_tiles.dart';

/// 设置首屏分区容器：宽屏两列瀑布式、窄屏单列。
///
/// 宽屏时按「列」而不是「行」排：两列各自堆叠，短卡不会把同一行撑出大片
/// 空白，视觉口径与 M3E `M3ECardGroupLayout.staggered` 一致（列优先、列内
/// 顺序不变）。哪张卡进左列由 [startColumn] 指定；缺省左右交替（第 1、3、
/// 5… 张进左列）。窄屏仍按 [children] 的阅读顺序单列。
///
/// 只承载首屏分区：子页是长表单（底部导航拖拽排序等），一律单列，不经过
/// 本组件。画布宽度由调用方（`settings_page.dart`）按弹层宽度封顶，列宽
/// 不随窗口继续变宽。
class SettingsSectionGrid extends StatelessWidget {
  const SettingsSectionGrid({
    super.key,
    required this.children,
    this.twoColumn = false,
    this.startColumn = const <int>{},
  });

  /// 按阅读顺序排列的分区（窄屏顺序；宽屏按列重新分配）。
  final List<Widget> children;

  /// 是否两列；判定口径见 `settings_page.dart` 的平台 + 窗口宽谓词。
  final bool twoColumn;

  /// 宽屏时放进左列的分区下标（其余进右列）；空集等价于左右交替。
  ///
  /// 位置按下标而不是按重量贪心分配：设置首屏的分区高度来自用户可展开的
  /// 子项（省流、自定义色），显式分列比按行数估算更稳定、也更好读。
  /// 列内顺序始终与 [children] 一致。
  final Set<int> startColumn;

  @override
  Widget build(BuildContext context) {
    assert(
      startColumn.every((index) => index >= 0 && index < children.length),
      'startColumn 必须是 children 的下标',
    );
    if (!twoColumn || children.length < 2) {
      return _buildColumn(children);
    }

    final left = <Widget>[];
    final right = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      final toStart = startColumn.isEmpty ? i.isEven : startColumn.contains(i);
      (toStart ? left : right).add(children[i]);
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _buildColumn(left)),
        const SizedBox(width: kSettingsSectionSpacing),
        Expanded(child: _buildColumn(right)),
      ],
    );
  }

  Widget _buildColumn(List<Widget> sections) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < sections.length; i++) ...[
          if (i > 0) const SizedBox(height: kSettingsSectionSpacing),
          sections[i],
        ],
      ],
    );
  }
}
