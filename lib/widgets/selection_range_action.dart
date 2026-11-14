import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';

/// 多选「范围选择」入口：底部右侧的一次性模式开关（歌单 / 歌词选择共用）。
///
/// 为什么是同一个组件：两处都是「先选中起点 → 打开范围选择 → 点终点」的
/// 两段式手势，按钮文案、激活态与无障碍名必须一致，否则同一个动作在两个
/// 页面会读出两种意思。页面只负责摆放位置（`Positioned`）与模式状态。
class SelectionRangeAction extends StatelessWidget {
  const SelectionRangeAction({
    super.key,
    required this.active,
    required this.onPressed,
  });

  /// 是否已进入范围选择：激活时按钮变成「取消范围选择」。
  final bool active;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 激活态用 tonal（低强调）而不是再叠一层主色：此刻用户要做的是点列表，
    // 按钮只是退出路径，视觉不该比「生成海报」等主操作更重。
    return active
        ? M3EButton.tonal(
            onPressed: onPressed,
            icon: const Icon(Icons.close_rounded),
            label: Text(l10n.selectionRangeCancel),
          )
        : M3EButton.filled(
            onPressed: onPressed,
            icon: const Icon(Icons.linear_scale_rounded),
            label: Text(l10n.selectionRangeAction),
          );
  }
}
