import 'package:material_ui/material_ui.dart';

import '../../pages/settings_page.dart';
import '../adaptive_layout.dart';
import '../modal_page_navigator.dart';

/// 打开设置弹层（顶栏入口与测试共用）。
///
/// 弹层内部 Navigator、子页返回与预测返回归属统一由
/// [showPageModalWithNavigator] 提供；设置首屏在桌面双栏时单独加宽，避免
/// 公共 modal 档把两列内容挤窄。
Future<void> showSettingsSheet(BuildContext context) {
  return showPageModalWithNavigator<void>(
    context: context,
    maxWidth: AdaptiveLayoutScope.of(context).isExpanded
        ? kSettingsSheetDesktopWidth
        : null,
    initialPageBuilder: (context, scrollController) =>
        SettingsPage(scrollController: scrollController),
  );
}
